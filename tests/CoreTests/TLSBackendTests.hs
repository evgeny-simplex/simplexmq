{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module CoreTests.TLSBackendTests where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM (TVar)
import qualified Control.Exception as E
import Crypto.Random (ChaChaDRG)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Default (def)
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.X509 as X
import qualified Network.TLS as T
import PipeBackend (pipeBackends)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Transport (TLS, Transport (..), TransportPeer (..), defaultSupportedParams)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), connectTLSClientBackend, defaultTransportClientConfig)
import Simplex.Messaging.Transport.Credentials (genCredentials, tlsCredentials)
import Simplex.Messaging.Transport.Server (TransportServerConfig, connectTLSServerBackend, mkTransportServerConfig)
import Test.Hspec hiding (fit, it)
import Util

tlsBackendTests :: Spec
tlsBackendTests = do
  describe "pipe backend" $ do
    it "should return exactly the requested bytes across sends" testPipeExactRecv
    it "should deliver buffered bytes, then EOF after close" testPipeEOF
    it "should end pending receives on close" testPipeCloseUnblocks
    it "should allow repeated close and fail sends after close" testPipeCloseIdempotent
  describe "TLS handshake" $ do
    it "should agree tls-unique and expose the pinned server chain" testHandshake
    it "should fail both sides when the CA fingerprint does not match" testWrongCA
  describe "TLS transfer" $ do
    it "should transfer 1 MiB in both directions" testTransfer
    it "should return EOF and then throw after the peer closes" testPeerClose

testPipeExactRecv :: IO ()
testPipeExactRecv = do
  (a, b) <- pipeBackends
  T.backendSend a "ab"
  T.backendSend a "cde"
  T.backendRecv b 4 `shouldReturn` "abcd"
  (received, ()) <- concurrently (T.backendRecv b 3) (T.backendSend a "fg")
  received `shouldBe` "efg"

testPipeEOF :: IO ()
testPipeEOF = do
  (a, b) <- pipeBackends
  T.backendSend a "xy"
  T.backendClose a
  T.backendRecv b 4 `shouldReturn` "xy"
  T.backendRecv b 1 `shouldReturn` ""
  T.backendRecv a 1 `shouldReturn` ""

testPipeCloseUnblocks :: IO ()
testPipeCloseUnblocks = do
  (a, b) <- pipeBackends
  ((own, peer), ()) <- concurrently (concurrently (T.backendRecv a 1) (T.backendRecv b 1)) (T.backendClose a)
  own `shouldBe` ""
  peer `shouldBe` ""

testPipeCloseIdempotent :: IO ()
testPipeCloseIdempotent = do
  (a, b) <- pipeBackends
  T.backendClose a
  T.backendClose a
  T.backendClose b
  T.backendSend b "z" `shouldThrow` anyIOException

data TestCredentials = TestCredentials
  { serverCAHash :: C.KeyHash,
    serverCred :: T.Credential,
    clientCred :: T.Credential
  }

testCredentials :: IO TestCredentials
testCredentials = do
  drg <- C.newRandom
  (serverCAHash, serverCred) <- chainCredential drg
  (_, clientCred) <- chainCredential drg
  pure TestCredentials {serverCAHash, serverCred, clientCred}

chainCredential :: TVar ChaChaDRG -> IO (C.KeyHash, T.Credential)
chainCredential drg = do
  ca <- genCredentials drg Nothing (1, 24) "ca"
  leaf <- genCredentials drg (Just ca) (1, 24) "leaf"
  pure $ tlsCredentials (leaf :| [ca])

testClientConfig :: T.Credential -> TransportClientConfig
testClientConfig cred = defaultTransportClientConfig {clientCredentials = Just cred, logTLSErrors = False}

testServerConfig :: TransportServerConfig
testServerConfig = mkTransportServerConfig False Nothing True

testServerParams :: T.Credential -> T.ServerParams
testServerParams cred =
  def
    { T.serverWantClientCert = True,
      T.serverShared = def {T.sharedCredentials = T.Credentials [cred]},
      T.serverHooks = def {T.onClientCertificate = \_ -> pure T.CertificateUsageAccept},
      T.serverSupported = defaultSupportedParams
    }

withTLSPair :: (TestCredentials -> TLS 'TClient -> TLS 'TServer -> IO a) -> IO a
withTLSPair action = do
  creds@TestCredentials {serverCAHash, serverCred, clientCred} <- testCredentials
  (clientBackend, serverBackend) <- pipeBackends
  E.bracket
    ( concurrently
        (connectTLSClientBackend (testClientConfig clientCred) serverCAHash clientBackend)
        (connectTLSServerBackend testServerConfig (testServerParams serverCred) serverBackend)
    )
    (\(cli, srv) -> closeConnection cli >> closeConnection srv)
    (\(cli, srv) -> action creds cli srv)

testHandshake :: IO ()
testHandshake = withTLSPair $ \TestCredentials {serverCred} cli srv -> do
  tlsUnique cli `shouldBe` tlsUnique srv
  tlsUnique cli `shouldNotBe` ""
  getPeerCertChain cli `shouldBe` fst serverCred
  getPeerCertChain srv `shouldBe` X.CertificateChain []
  certificateSent cli `shouldBe` True
  certificateSent srv `shouldBe` True
  getSessionALPN cli `shouldBe` Nothing
  getSessionALPN srv `shouldBe` Nothing

testWrongCA :: IO ()
testWrongCA = do
  TestCredentials {serverCred, clientCred} <- testCredentials
  TestCredentials {serverCAHash = otherCAHash} <- testCredentials
  (clientBackend, serverBackend) <- pipeBackends
  (clientResult, serverResult) <-
    concurrently
      (tryConnect $ connectTLSClientBackend (testClientConfig clientCred) otherCAHash clientBackend)
      (tryConnect $ connectTLSServerBackend testServerConfig (testServerParams serverCred) serverBackend)
  clientResult `shouldSatisfy` isLeft
  serverResult `shouldSatisfy` isLeft
  where
    tryConnect :: Transport c => IO (c p) -> IO (Either E.SomeException ())
    tryConnect connect = E.try $ connect >>= closeConnection

transferSize :: Int
transferSize = 1024 * 1024

testTransfer :: IO ()
testTransfer = withTLSPair $ \_ cli srv -> do
  let payload = B.pack $ take transferSize $ cycle [0 .. 250]
  transfer cli srv payload
  transfer srv cli payload
  where
    transfer :: TLS p -> TLS p' -> ByteString -> IO ()
    transfer from to s = do
      ((), received) <- concurrently (cPut from s) (cGet to $ B.length s)
      B.length received `shouldBe` B.length s
      C.sha256Hash received `shouldBe` C.sha256Hash s

testPeerClose :: IO ()
testPeerClose = withTLSPair $ \_ cli srv -> do
  closeConnection srv
  cGet cli 1 `shouldReturn` ""
  cGet cli 1 `shouldThrow` anyException
