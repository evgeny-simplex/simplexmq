{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module RemoteControl where

import AgentTests.FunctionalAPITests (runRight)
import Control.Logger.Simple
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Either (isLeft)
import Data.List (stripPrefix)
import Data.Maybe (isJust, isNothing)
import Data.Time.Clock.System (SystemTime (..))
import Network.TLS (Backend)
import PipeBackend (pipeBackends)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Transport (TSbChainKeys (..), cGet)
import qualified Simplex.RemoteControl.Client as HC (RCHostClient (action))
import qualified Simplex.RemoteControl.Client as RC
import Simplex.RemoteControl.Invitation
  ( RCInvitation (..),
    RCSignedInvitation (..),
    invitationTsValid,
    signInvitation,
    verifySignedInvitation,
  )
import Simplex.RemoteControl.Types
import Test.Hspec hiding (fit, it)
import UnliftIO
import UnliftIO.Concurrent
import Util

remoteControlTests :: Spec
remoteControlTests = do
  describe "Invitation" $ do
    it "should encode v2 invitation without host and port" testInvitationEncoding
    it "should verify signatures and reject tampered app data" testInvitationSignature
    it "should reject v1 invitation with host and port" testInvitationV1Rejected
    it "should accept invitation only within timestamp window" testInvitationTimestamp
  describe "New controller/host pairing" $ do
    it "should connect to new pairing" testNewPairing
    it "should connect to existing pairing" testExistingPairing
    it "should connect with a pairing restored from its stored fields" testStoredCtrlPairing
  describe "Session transport" $ do
    it "should fail when known host CA differs" testKnownHostMismatch
    it "should report backend failure on both sides" testBackendFailure
    it "should cancel session waiting for backend" testCancelWaitingBackend


testSignedInvitation :: IO RCSignedInvitation
testSignedInvitation = do
  drg <- C.newRandom
  (skey, sessPrivKey) <- atomically $ C.generateKeyPair @'C.Ed25519 drg
  (idkey, idPrivKey) <- atomically $ C.generateKeyPair @'C.Ed25519 drg
  (dh, _) <- atomically $ C.generateKeyPair @'C.X25519 drg
  pure . signInvitation sessPrivKey idPrivKey $
    RCInvitation {ca = C.KeyHash "test-ca", v = supportedRCPVRange, app = J.String "app", ts = MkSystemTime 0 0, skey, idkey, dh}

testInvitationEncoding :: IO ()
testInvitationEncoding = do
  RCSignedInvitation {invitation} <- testSignedInvitation
  let uri = strEncode invitation
  B.unpack uri `shouldStartWith` "xrcp:/"
  B.elem '@' uri `shouldBe` False
  ("#/?v=2&app=" `B.isInfixOf` uri) `shouldBe` True
  (strEncode <$> (strDecode uri :: Either String RCInvitation)) `shouldBe` Right uri

testInvitationSignature :: IO ()
testInvitationSignature = do
  signedInv <- testSignedInvitation
  verifySignedInvitation signedInv `shouldSatisfy` isJust
  let uri = strEncode signedInv
      tamperedUri = B.pack . replaceFirst "app=%22app%22" "app=%22other%22" $ B.unpack uri
  tamperedUri `shouldNotBe` uri
  decoded <- either fail pure $ strDecode uri
  verifySignedInvitation decoded `shouldSatisfy` isJust
  tampered <- either fail pure $ strDecode tamperedUri
  verifySignedInvitation tampered `shouldSatisfy` isNothing

testInvitationV1Rejected :: IO ()
testInvitationV1Rejected = do
  RCSignedInvitation {invitation} <- testSignedInvitation
  let v1Uri = B.pack . replaceFirst "#/?" "@127.0.0.1:5223#/?" . B.unpack $ strEncode invitation
  (strDecode v1Uri :: Either String RCInvitation) `shouldSatisfy` isLeft

testInvitationTimestamp :: IO ()
testInvitationTimestamp = do
  RCSignedInvitation {invitation} <- testSignedInvitation
  let validAt offset = invitationTsValid (MkSystemTime 0 0) invitation {ts = MkSystemTime offset 0}
  map validAt [0, -3600, -3660, 3500, 3600] `shouldBe` replicate 5 True
  map validAt [-3661, -3700, 3601, 3700] `shouldBe` replicate 4 False

replaceFirst :: String -> String -> String -> String
replaceFirst needle replacement = go
  where
    go [] = []
    go input@(c : cs) =
      case stripPrefix needle input of
        Just rest -> replacement <> rest
        Nothing -> c : go cs

testNewPairing :: IO ()
testNewPairing = do
  drg <- C.newRandom
  hp <- RC.newRCHostPairing drg
  (ctrlBackend, hostBackend) <- pipeBackends
  invVar <- newEmptyMVar
  ctrlSessId <- async . runRight $ do
    logNote "c 1"
    (inv, hc, r) <- RC.connectRCHost drg hp (J.String "app") (pure ctrlBackend)
    logNote "c 2"
    putMVar invVar (inv, hc)
    logNote "c 3"
    Right (sessId, _tls, r') <- atomically $ takeTMVar r
    logNote "c 4"
    Right (rcHostSession, _rcHelloBody, _hp') <- atomically $ takeTMVar r'
    let RCHostSession {tls, sessionKeys = HostSessKeys {chainKeys}} = rcHostSession
        TSbChainKeys {rcvKey, sndKey} = chainKeys
    sndKeyNonce <- atomically $ stateTVar sndKey C.sbcHkdf
    encCmd <- RC.rcEncryptBody sndKeyNonce "command message"
    RC.sendRCPacket tls $ LB.toStrict encCmd
    encResp <- RC.receiveRCPacket tls
    rcvKeyNonce <- atomically $ stateTVar rcvKey C.sbcHkdf
    resp <- RC.rcDecryptBody rcvKeyNonce $ LB.fromStrict encResp
    liftIO $ resp `shouldBe` "response message"
    logNote "c 5"
    threadDelay 250000
    logNote "ctrl: ciao"
    liftIO $ RC.cancelHostClient hc
    pure sessId

  (signedInv, hc) <- takeMVar invVar
  -- logNote $ decodeUtf8 $ strEncode inv
  inv <- maybe (fail "bad invite") pure $ verifySignedInvitation signedInv

  hostSessId <- async . runRight $ do
    logNote "h 1"
    (rcCtrlClient, r) <- RC.connectRCCtrl drg inv Nothing (J.String "app") (pure hostBackend)
    logNote "h 2"
    Right (sessId', _tls, r') <- atomically $ takeTMVar r
    logNote "h 3"
    liftIO $ RC.confirmCtrlSession rcCtrlClient True
    logNote "h 4"
    Right (rcCtrlSession, _rcCtrlPairing) <- atomically $ takeTMVar r'
    let RCCtrlSession {tls, sessionKeys = CtrlSessKeys {chainKeys}} = rcCtrlSession
        TSbChainKeys {rcvKey, sndKey} = chainKeys
    encCmd <- RC.receiveRCPacket tls
    rcvKeyNonce <- atomically $ stateTVar rcvKey C.sbcHkdf
    cmd <- RC.rcDecryptBody rcvKeyNonce $ LB.fromStrict encCmd
    liftIO $ cmd `shouldBe` "command message"
    sndKeyNonce <- atomically $ stateTVar sndKey C.sbcHkdf
    encResp <- RC.rcEncryptBody sndKeyNonce "response message"
    RC.sendRCPacket tls $ LB.toStrict encResp
    logNote "h 5"
    threadDelay 250000
    logNote "ctrl: adios"
    pure sessId'

  -- the session action ends by itself once endSession is put, so cancellation can find it finished
  waitCatch (HC.action hc) >>= \case
    Left err -> fromException err `shouldBe` Just AsyncCancelled
    Right () -> pure ()

  timeout 5000000 (waitBoth ctrlSessId hostSessId) >>= \case
    Just (sessId, sessId') -> sessId `shouldBe` sessId'
    _ -> fail "timeout"

testExistingPairing :: IO ()
testExistingPairing = do
  drg <- C.newRandom
  invVar <- newEmptyMVar
  hp <- RC.newRCHostPairing drg
  (ctrlBackend, hostBackend) <- pipeBackends
  ctrl <- runCtrl drg hp invVar ctrlBackend
  inv <- takeMVar invVar
  let cp_ = Nothing
  host <- runHostURI drg cp_ inv hostBackend
  timeout 5000000 (waitBoth ctrl host) >>= \case
    Nothing -> fail "timeout"
    Just (hp', cp') -> do
      (ctrlBackend', hostBackend') <- pipeBackends
      ctrl' <- runCtrl drg hp' invVar ctrlBackend'
      inv' <- takeMVar invVar
      host' <- runHostURI drg (Just cp') inv' hostBackend'
      timeout 5000000 (waitBoth ctrl' host') >>= \case
        Nothing -> fail "timeout"
        Just (_hp2, cp2) -> do
          (ctrlBackend2, hostBackend2) <- pipeBackends
          ctrl2 <- runCtrl drg hp' invVar ctrlBackend2 -- old host pairing used to test controller not updating state
          inv2 <- takeMVar invVar
          host2 <- runHostURI drg (Just cp2) inv2 hostBackend2
          timeout 5000000 (waitBoth ctrl2 host2) >>= \case
            Nothing -> fail "timeout"
            Just (hp3, cp3) -> do
              (ctrlBackend3, hostBackend3) <- pipeBackends
              ctrl3 <- runCtrl drg hp3 invVar ctrlBackend3
              inv3 <- takeMVar invVar
              host3 <- runHostURI drg (Just cp3) inv3 hostBackend3
              timeout 5000000 (waitBoth ctrl3 host3) >>= \case
                Nothing -> fail "timeout"
                Just _ -> pure ()

testStoredCtrlPairing :: IO ()
testStoredCtrlPairing = do
  drg <- C.newRandom
  invVar <- newEmptyMVar
  hp <- RC.newRCHostPairing drg
  (ctrlBackend, hostBackend) <- pipeBackends
  ctrl <- runCtrl drg hp invVar ctrlBackend
  host <- takeMVar invVar >>= \inv -> runHostURI drg Nothing inv hostBackend
  timeout 5000000 (waitBoth ctrl host) >>= \case
    Nothing -> fail "timeout"
    Just (hp', RCCtrlPairing {caKey, caCert, ctrlFingerprint, idPubKey}) -> do
      let restored = RCCtrlPairing {caKey, caCert, ctrlFingerprint, idPubKey}
      (ctrlBackend', hostBackend') <- pipeBackends
      ctrl' <- runCtrl drg hp' invVar ctrlBackend'
      host' <- takeMVar invVar >>= \inv -> runHostURI drg (Just restored) inv hostBackend'
      timeout 5000000 (waitBoth ctrl' host') >>= \case
        Nothing -> fail "timeout"
        Just _ -> pure ()

testKnownHostMismatch :: IO ()
testKnownHostMismatch = do
  drg <- C.newRandom
  hp <- RC.newRCHostPairing drg
  (ctrlBackend, hostBackend) <- pipeBackends
  let hp' = hp {knownHost = Just KnownHostPairing {hostFingerprint = C.KeyHash "other-host-ca"}}
  (signedInv, hc, r) <- runRight $ RC.connectRCHost drg hp' (J.String "app") (pure ctrlBackend)
  inv <- maybe (fail "bad invite") pure $ verifySignedInvitation signedInv
  (cc, r') <- runRight $ RC.connectRCCtrl drg inv Nothing (J.String "app") (pure hostBackend)
  atomically (takeTMVar r) >>= \case
    Left _ -> pure ()
    Right _ -> expectationFailure "controller accepted a host with another CA"
  -- the host finishes its handshake before the controller checks the host certificate
  atomically (takeTMVar r') >>= \case
    Left _ -> pure ()
    Right (_, tls, _) -> tryAny (cGet tls 1) >>= either (\_ -> pure ()) (`shouldBe` "")
  RC.cancelCtrlClient cc
  RC.cancelHostClient hc

testBackendFailure :: IO ()
testBackendFailure = do
  drg <- C.newRandom
  hp <- RC.newRCHostPairing drg
  (signedInv, _, r) <- runRight $ RC.connectRCHost drg hp (J.String "app") noBackend
  atomically (takeTMVar r) >>= expectBackendError
  inv <- maybe (fail "bad invite") pure $ verifySignedInvitation signedInv
  (_, r') <- runRight $ RC.connectRCCtrl drg inv Nothing (J.String "app") noBackend
  atomically (takeTMVar r') >>= expectBackendError
  where
    noBackend :: IO Backend
    noBackend = throwIO $ userError "no data channel"
    expectBackendError :: Either RCErrorType a -> Expectation
    expectBackendError = \case
      Left (RCEException e) -> e `shouldContain` "no data channel"
      Left e -> expectationFailure $ "unexpected error: " <> show e
      Right _ -> expectationFailure "session started without a backend"

testCancelWaitingBackend :: IO ()
testCancelWaitingBackend = do
  drg <- C.newRandom
  hp <- RC.newRCHostPairing drg
  waiting <- newEmptyTMVarIO
  backend <- newEmptyTMVarIO
  let getBackend = atomically (putTMVar waiting ()) >> atomically (takeTMVar backend)
  (_, hc, r) <- runRight $ RC.connectRCHost drg hp (J.String "app") getBackend
  atomically $ takeTMVar waiting
  RC.cancelHostClient hc
  waitCatch (HC.action hc) >>= \case
    Left err -> fromException err `shouldBe` Just AsyncCancelled
    Right () -> expectationFailure "session ended without cancellation"
  atomically (isEmptyTMVar r) `shouldReturn` True
  atomically (isEmptyTMVar backend) `shouldReturn` True

runCtrl :: TVar ChaChaDRG -> RCHostPairing -> MVar RCSignedInvitation -> Backend -> IO (Async RCHostPairing)
runCtrl drg hp invVar backend = async . runRight $ do
  (inv, hc, r) <- RC.connectRCHost drg hp (J.String "app") (pure backend)
  putMVar invVar inv
  Right (_sessId, _tls, r') <- atomically $ takeTMVar r
  Right (_rcHostSession, _rcHelloBody, hp') <- atomically $ takeTMVar r'
  threadDelay 250000
  liftIO $ RC.cancelHostClient hc
  pure hp'

runHostURI :: TVar ChaChaDRG -> Maybe RCCtrlPairing -> RCSignedInvitation -> Backend -> IO (Async RCCtrlPairing)
runHostURI drg cp_ signedInv backend = async . runRight $ do
  inv <- maybe (fail "bad invite") pure $ verifySignedInvitation signedInv
  (rcCtrlClient, r) <- RC.connectRCCtrl drg inv cp_ (J.String "app") (pure backend)
  Right (_sessId', _tls, r') <- atomically $ takeTMVar r
  liftIO $ RC.confirmCtrlSession rcCtrlClient True
  Right (_rcCtrlSession, cp') <- atomically $ takeTMVar r'
  threadDelay 250000
  pure cp'
