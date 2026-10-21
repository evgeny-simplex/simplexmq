{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.RemoteControl.Client
  ( RCHostClient (action),
    RCHostConnection,
    newRCHostPairing,
    connectRCHost,
    cancelHostClient,
    RCCtrlClient (action),
    RCCtrlConnection,
    connectRCCtrl,
    confirmCtrlSession,
    cancelCtrlClient,
    RCStepTMVar,
    rcEncryptBody,
    rcDecryptBody,
    xrcpBlockSize,
    -- for tests only
    sendRCPacket,
    receiveRCPacket,
  ) where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import Data.Bitraversable (bimapM)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Default (def)
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isNothing)
import qualified Data.Text as T
import Data.Time.Clock.System (getSystemTime)
import Data.Tuple (swap)
import qualified Data.X509 as X
import Data.X509.Validation (Fingerprint (..), getFingerprint)
import qualified Network.TLS as TLS
import Simplex.Messaging.Agent.Client ()
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Lazy (LazyByteString)
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Crypto.SNTRUP761
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Transport (TSbChainKeys (..), TLS (..), TransportPeer (..), cGet, cPut, closeConnection, defaultSupportedParams)
import Simplex.Messaging.Transport.Buffer (peekBuffered)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), connectTLSClientBackend, defaultTransportClientConfig)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Transport.Server (connectTLSServerBackend, mkTransportServerConfig)
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import Simplex.RemoteControl.Invitation
import Simplex.RemoteControl.Types
import UnliftIO

xrcpBlockSize :: Int
xrcpBlockSize = 16384

helloBlockSize :: Int
helloBlockSize = 12288

newRCHostPairing :: TVar ChaChaDRG -> IO RCHostPairing
newRCHostPairing drg = do
  ((_, caKey), caCert) <- genCredentials drg Nothing (25, 24 * 999999) "ca"
  (_, idPrivKey) <- atomically $ C.generateKeyPair drg
  pure RCHostPairing {caKey, caCert, idPrivKey, knownHost = Nothing}

data RCHostClient = RCHostClient
  { action :: Async (),
    client_ :: RCHClient_
  }

data RCHClient_ = RCHClient_
  { hostCAHash :: TMVar C.KeyHash,
    endSession :: TMVar ()
  }

type RCHostConnection = (RCSignedInvitation, RCHostClient, RCStepTMVar (SessionCode, TLS 'TServer, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)))

connectRCHost :: TVar ChaChaDRG -> RCHostPairing -> J.Value -> IO TLS.Backend -> ExceptT RCErrorType IO RCHostConnection
connectRCHost drg pairing@RCHostPairing {caKey, caCert, idPrivKey, knownHost} ctrlAppInfo getBackend = do
  r <- newEmptyTMVarIO
  c <- liftIO mkClient
  hostKeys <- atomically genHostKeys
  signedInv <- liftIO $ mkInvitation hostKeys
  action <- liftIO . async . void . runExceptT $ runClient c r hostKeys `putRCError` r
  pure (signedInv, RCHostClient {action, client_ = c}, r)
  where
    mkClient :: IO RCHClient_
    mkClient = do
      endSession <- newEmptyTMVarIO
      hostCAHash <- newEmptyTMVarIO
      pure RCHClient_ {hostCAHash, endSession}
    runClient :: RCHClient_ -> RCStepTMVar (SessionCode, TLS 'TServer, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)) -> RCHostKeys -> ExceptT RCErrorType IO ()
    runClient RCHClient_ {hostCAHash, endSession} r hostKeys = do
      tlsCreds <- liftIO $ genTLSCredentials drg caKey caCert
      let params = serverParams tlsCreds $ tlsHooks r knownHost hostCAHash
      ExceptT $ bracket (connectBackend params) closeConnection $ \tls -> runExceptT $ do
        r' <- newEmptyTMVarIO
        whenM (atomically $ tryPutTMVar r $ Right (tlsUniq tls, tls, r')) $
          runSession tls r' `putRCError` r'
      where
        connectBackend srvParams = bracketOnError getBackend TLS.backendClose $ connectTLSServerBackend (mkTransportServerConfig True Nothing True) srvParams
        runSession tls r' = do
          logDebug "Incoming TLS connection"
          hostEncHello <- receiveRCPacket tls
          logDebug "Received host HELLO"
          hostCA <- atomically $ takeTMVar hostCAHash
          (ctrlEncHello, sessionKeys, helloBody, pairing') <- prepareHostSession drg hostCA pairing hostKeys hostEncHello
          sendRCPacket tls ctrlEncHello
          logDebug "Sent ctrl HELLO"
          whenM (atomically $ tryPutTMVar r' $ Right (RCHostSession {tls, sessionKeys}, helloBody, pairing')) $ do
            -- can use `RCHostSession` until `endSession` is signalled
            logDebug "Holding session"
            atomically $ takeTMVar endSession
    tlsHooks :: TMVar a -> Maybe KnownHostPairing -> TMVar C.KeyHash -> TLS.ServerHooks
    tlsHooks r knownHost_ hostCAHash =
      def
        { TLS.onNewHandshake = \_ -> atomically $ isNothing <$> tryReadTMVar r,
          TLS.onClientCertificate = \(X.CertificateChain chain) ->
            case chain of
              [_leaf, ca] -> do
                let kh = certFingerprint ca
                    accept = maybe True (\h -> hostFingerprint h == kh) knownHost_
                if accept
                  then atomically (putTMVar hostCAHash kh) $> TLS.CertificateUsageAccept
                  else pure $ TLS.CertificateUsageReject TLS.CertificateRejectUnknownCA
              _ ->
                pure $ TLS.CertificateUsageReject TLS.CertificateRejectUnknownCA
        }
    genHostKeys :: STM RCHostKeys
    genHostKeys = do
      sessKeys <- C.generateKeyPair drg
      dhKeys <- C.generateKeyPair drg
      pure RCHostKeys {sessKeys, dhKeys}
    mkInvitation :: RCHostKeys -> IO RCSignedInvitation
    mkInvitation RCHostKeys {sessKeys, dhKeys} = do
      ts <- getSystemTime
      let inv =
            RCInvitation
              { ca = certFingerprint caCert,
                v = supportedRCPVRange,
                app = ctrlAppInfo,
                ts,
                skey = fst sessKeys,
                idkey = C.publicKey idPrivKey,
                dh = fst dhKeys
              }
      pure $ signInvitation (snd sessKeys) idPrivKey inv

serverParams :: TLS.Credential -> TLS.ServerHooks -> TLS.ServerParams
serverParams credential hooks =
  def
    { TLS.serverWantClientCert = True,
      TLS.serverShared = def {TLS.sharedCredentials = TLS.Credentials [credential]},
      TLS.serverHooks = hooks,
      TLS.serverSupported = defaultSupportedParams
    }

genTLSCredentials :: TVar ChaChaDRG -> C.APrivateSignKey -> X.SignedCertificate -> IO TLS.Credential
genTLSCredentials drg caKey caCert = do
  let caCreds = (C.signatureKeyPair caKey, caCert)
  leaf <- genCredentials drg (Just caCreds) (1, 24 * 999999) "localhost" -- session-signing cert
  pure . snd $ tlsCredentials (leaf :| [caCreds])

certFingerprint :: X.SignedCertificate -> C.KeyHash
certFingerprint caCert = C.KeyHash fp
  where
    Fingerprint fp = getFingerprint caCert X.HashSHA256

cancelHostClient :: RCHostClient -> IO ()
cancelHostClient RCHostClient {action, client_ = RCHClient_ {endSession}} = do
  void . atomically $ tryPutTMVar endSession ()
  uninterruptibleCancel action

prepareHostSession :: TVar ChaChaDRG -> C.KeyHash -> RCHostPairing -> RCHostKeys -> RCHostEncHello -> ExceptT RCErrorType IO (RCCtrlEncHello, HostSessKeys, RCHostHello, RCHostPairing)
prepareHostSession
  drg
  tlsHostFingerprint
  pairing@RCHostPairing {idPrivKey, knownHost = knownHost_}
  RCHostKeys {sessKeys = (_, sessPrivKey), dhKeys = (_, dhPrivKey)}
  RCHostEncHello {dhPubKey, nonce, encBody} = do
    let sharedKey = C.dh' dhPubKey dhPrivKey
    helloBody <- liftEitherWith (const RCEDecrypt) $ C.cbDecrypt sharedKey nonce encBody
    hostHello@RCHostHello {v, ca, kem = kemPubKey} <- liftEitherWith RCESyntax $ J.eitherDecodeStrict helloBody
    unless (ca == tlsHostFingerprint) $ throwE RCEIdentity
    (kemCiphertext, kemSharedKey) <- liftIO $ sntrup761Enc drg kemPubKey
    let KEMHybridSecret hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
    unless (isCompatible v supportedRCPVRange) $ throwE RCEVersion
    (sndKey, rcvKey) <- bimapM newTVarIO newTVarIO $ C.sbcInit "" hybridKey
    let keys = HostSessKeys {chainKeys = TSbChainKeys {sndKey, rcvKey}, idPrivKey, sessPrivKey}
    knownHost' <- updateKnownHost ca
    let ctrlHello = RCCtrlHello {}
    -- TODO send error response if something fails
    (sk, nonce') <- atomically $ stateTVar sndKey C.sbcHkdf
    encBody' <- liftEitherWith (const RCEBlockSize) $ C.sbEncrypt sk nonce' (LB.toStrict $ J.encode ctrlHello) helloBlockSize
    let ctrlEncHello = RCCtrlEncHello {kem = kemCiphertext, encBody = encBody'}
    pure (ctrlEncHello, keys, hostHello, pairing {knownHost = Just knownHost'})
    where
      updateKnownHost :: C.KeyHash -> ExceptT RCErrorType IO KnownHostPairing
      updateKnownHost ca = case knownHost_ of
        Just h -> do
          unless (hostFingerprint h == tlsHostFingerprint) . throwE $
            RCEInternal "TLS host CA is different from host pairing, should be caught in TLS handshake"
          pure h
        Nothing -> pure KnownHostPairing {hostFingerprint = ca}

data RCCtrlClient = RCCtrlClient
  { action :: Async (),
    client_ :: RCCClient_
  }

data RCCClient_ = RCCClient_
  { confirmSession :: TMVar Bool,
    endSession :: TMVar ()
  }

type RCCtrlConnection = (RCCtrlClient, RCStepTMVar (SessionCode, TLS 'TClient, RCStepTMVar (RCCtrlSession, RCCtrlPairing)))

-- app should determine whether it is a new or known pairing based on CA fingerprint in the invitation
connectRCCtrl :: TVar ChaChaDRG -> RCVerifiedInvitation -> Maybe RCCtrlPairing -> J.Value -> IO TLS.Backend -> ExceptT RCErrorType IO RCCtrlConnection
connectRCCtrl drg (RCVerifiedInvitation inv@RCInvitation {ca, idkey}) pairing_ hostAppInfo getBackend = do
  pairing' <- maybe (liftIO newCtrlPairing) verifyCtrlPairing pairing_
  connectRCCtrl_ drg pairing' inv hostAppInfo getBackend
  where
    newCtrlPairing :: IO RCCtrlPairing
    newCtrlPairing = do
      ((_, caKey), caCert) <- genCredentials drg Nothing (1, 24 * 999999) "ca"
      pure RCCtrlPairing {caKey, caCert, ctrlFingerprint = ca, idPubKey = idkey}
    verifyCtrlPairing :: RCCtrlPairing -> ExceptT RCErrorType IO RCCtrlPairing
    verifyCtrlPairing pairing@RCCtrlPairing {ctrlFingerprint, idPubKey} = do
      unless (ca == ctrlFingerprint && idPubKey == idkey) $ throwE RCEIdentity
      pure pairing

connectRCCtrl_ :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> IO TLS.Backend -> ExceptT RCErrorType IO RCCtrlConnection
connectRCCtrl_ drg pairing'@RCCtrlPairing {caKey, caCert} inv@RCInvitation {ca} hostAppInfo getBackend = do
  r <- newEmptyTMVarIO
  c <- liftIO mkClient
  action <- liftIO . async . void . runExceptT $ runClient c r `putRCError` r
  pure (RCCtrlClient {action, client_ = c}, r)
  where
    mkClient :: IO RCCClient_
    mkClient = do
      confirmSession <- newEmptyTMVarIO
      endSession <- newEmptyTMVarIO
      pure RCCClient_ {confirmSession, endSession}
    runClient :: RCCClient_ -> RCStepTMVar (SessionCode, TLS 'TClient, RCStepTMVar (RCCtrlSession, RCCtrlPairing)) -> ExceptT RCErrorType IO ()
    runClient RCCClient_ {confirmSession, endSession} r = do
      clientCredentials <- liftIO $ Just <$> genTLSCredentials drg caKey caCert
      let clientConfig = defaultTransportClientConfig {clientCredentials}
      ExceptT $ bracket (connectBackend clientConfig) closeConnection $ \tls@TLS {tlsBuffer, tlsContext} -> runExceptT $ do
        -- pump the backend to detect connection problems
        liftIO $ peekBuffered tlsBuffer 100000 (TLS.recvData tlsContext) >>= logDebug . tshow -- should normally be ("", Nothing) here
        logDebug "Got TLS connection"
        r' <- newEmptyTMVarIO
        whenM (atomically $ tryPutTMVar r $ Right (tlsUniq tls, tls, r')) $ do
          logDebug "Waiting for session confirmation"
          atomically (readTMVar confirmSession) >>= \case
            True -> runSession tls r' `putRCError` r'
            False -> throwE RCERejected `putRCError` r'
      where
        connectBackend cfg = bracketOnError getBackend TLS.backendClose $ connectTLSClientBackend cfg ca
        runSession tls r' = do
          (sharedKey, dhPrivKey, kemPrivKey, hostEncHello) <- prepareHostHello drg pairing' inv hostAppInfo
          sendRCPacket tls hostEncHello
          ctrlEncHello <- receiveRCPacket tls
          logDebug "Received ctrl HELLO"
          ctrlSessKeys <- prepareCtrlSession pairing' inv sharedKey dhPrivKey kemPrivKey ctrlEncHello
          whenM (atomically $ tryPutTMVar r' $ Right (RCCtrlSession {tls, sessionKeys = ctrlSessKeys}, pairing')) $ do
            logDebug "Session started"
            atomically $ takeTMVar endSession
            logDebug "Session ended"

putRCError :: ExceptT RCErrorType IO a -> TMVar (Either RCErrorType b) -> ExceptT RCErrorType IO a
a `putRCError` r = a `catchAllErrors` \e -> atomically (tryPutTMVar r $ Left e) >> throwE e

sendRCPacket :: Encoding a => TLS p -> a -> ExceptT RCErrorType IO ()
sendRCPacket tls pkt = do
  b <- liftEitherWith (const RCEBlockSize) $ C.pad (smpEncode pkt) xrcpBlockSize
  liftIO $ cPut tls b

receiveRCPacket :: Encoding a => TLS p -> ExceptT RCErrorType IO a
receiveRCPacket tls = do
  b <- liftIO $ cGet tls xrcpBlockSize
  when (B.length b /= xrcpBlockSize) $ throwE RCEBlockSize
  b' <- liftEitherWith (const RCEBlockSize) $ C.unPad b
  liftEitherWith RCESyntax $ smpDecode b'

prepareHostHello :: TVar ChaChaDRG -> RCCtrlPairing -> RCInvitation -> J.Value -> ExceptT RCErrorType IO (C.DhSecretX25519, C.PrivateKeyX25519, KEMSecretKey, RCHostEncHello)
prepareHostHello
  drg
  RCCtrlPairing {caCert}
  RCInvitation {v, dh = dhPubKey}
  hostAppInfo = do
    logDebug "Preparing session"
    case compatibleVersion v supportedRCPVRange of
      Nothing -> throwE RCEVersion
      Just (Compatible v') -> do
        nonce <- liftIO . atomically $ C.randomCbNonce drg
        (_, dhPrivKey) <- atomically $ C.generateKeyPair drg
        (kemPubKey, kemPrivKey) <- liftIO $ sntrup761Keypair drg
        let helloBody = RCHostHello {v = v', ca = certFingerprint caCert, app = hostAppInfo, kem = kemPubKey}
            sharedKey = C.dh' dhPubKey dhPrivKey
        encBody <- liftEitherWith (const RCEBlockSize) $ C.cbEncrypt sharedKey nonce (LB.toStrict $ J.encode helloBody) helloBlockSize
        -- let sessKeys = CtrlSessKeys {hybridKey, idPubKey, sessPubKey = skey}
        let hostEncHello = RCHostEncHello {dhPubKey = C.publicKey dhPrivKey, nonce, encBody}
        pure (sharedKey, dhPrivKey, kemPrivKey, hostEncHello)

prepareCtrlSession :: RCCtrlPairing -> RCInvitation -> C.DhSecretX25519 -> C.PrivateKeyX25519 -> KEMSecretKey -> RCCtrlEncHello -> ExceptT RCErrorType IO CtrlSessKeys
prepareCtrlSession
  RCCtrlPairing {idPubKey}
  RCInvitation {skey, dh = dhPubKey}
  sharedKey
  dhPrivKey
  kemPrivKey = \case
    RCCtrlEncHello {kem = kemCiphertext, encBody} -> do
      kemSharedKey <- liftIO $ sntrup761Dec kemCiphertext kemPrivKey
      let KEMHybridSecret hybridKey = kemHybridSecret dhPubKey dhPrivKey kemSharedKey
      -- keys are swapped in controller
      (sndKey, rcvKey) <- swap <$> bimapM newTVarIO newTVarIO (C.sbcInit "" hybridKey)
      (sk, nonce) <- atomically $ stateTVar rcvKey C.sbcHkdf
      helloBody <- liftEitherWith (const RCEDecrypt) $ C.sbDecrypt sk nonce encBody
      logDebug "Decrypted ctrl HELLO"
      RCCtrlHello {} <- liftEitherWith RCESyntax $ J.eitherDecodeStrict helloBody
      pure CtrlSessKeys {chainKeys = TSbChainKeys {sndKey, rcvKey}, idPubKey, sessPubKey = skey}
    RCCtrlEncError {nonce, encMessage} -> do
      message <- liftEitherWith (const RCEDecrypt) $ C.cbDecrypt sharedKey nonce encMessage
      throwE $ RCECtrlError $ T.unpack $ safeDecodeUtf8 message

-- * Controller handle operations

-- application should call this function when TMVar resolves
confirmCtrlSession :: RCCtrlClient -> Bool -> IO ()
confirmCtrlSession RCCtrlClient {client_ = RCCClient_ {confirmSession}} res = do
  void . atomically $ tryPutTMVar confirmSession res

cancelCtrlClient :: RCCtrlClient -> IO ()
cancelCtrlClient RCCtrlClient {action, client_ = RCCClient_ {endSession}} = do
  void . atomically $ tryPutTMVar endSession ()
  uninterruptibleCancel action

-- * Session encryption

rcEncryptBody :: C.SbKeyNonce -> LazyByteString -> ExceptT RCErrorType IO LazyByteString
rcEncryptBody keyNonce s = do
  liftEitherWith (const RCEEncrypt) $ LC.sbEncryptTailTagNoPad keyNonce s

rcDecryptBody :: C.SbKeyNonce -> LazyByteString -> ExceptT RCErrorType IO LazyByteString
rcDecryptBody keyNonce ct = do
  let len = LB.length ct - 16
  when (len < 0) $ throwE RCEDecrypt
  (ok, s) <- liftEitherWith (const RCEDecrypt) $ LC.sbDecryptTailTagNoPad keyNonce len ct
  unless ok $ throwE RCEDecrypt
  pure s
