{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.NtfGroupingBenchmark (ntfGroupingBenchmark) where

import AgentTests.FunctionalAPITests (runRight)
import Control.Concurrent.STM (TVar, atomically)
import Control.Exception (evaluate)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..))
import CoreTests.MsgStoreTests (testNewQueueRec, testNtfCreds, testSMTStoreConfig, withMsgStore)
import Crypto.Random (ChaChaDRG)
import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Word (Word64)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (showFFloat)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (EntityId (..), ErrorType, NotifierId, ServiceId)
import Simplex.Messaging.Server.MsgStore.Types (MsgStoreClass (..), addQueue)
import Simplex.Messaging.Server.QueueStore (NtfCreds (..), QueueRec (..), ServiceRec (..))
import Simplex.Messaging.Server.QueueStore.QueueInfo (QueueMode (..))
import Simplex.Messaging.Server.QueueStore.Types (QueueStoreClass (..))
import Simplex.Messaging.SystemTime (getSystemDate)
import Simplex.Messaging.Transport (SMPServiceRole (..))
import Simplex.Messaging.Transport.Credentials (genCredentials)
import System.Mem (performGC)
import Test.Hspec hiding (fit, it)
import Util

#if defined(dbServerPostgres)
import CoreTests.MsgStoreTests (testPostgresStoreConfig)
#endif

ntfGroupingBenchmark :: Spec
ntfGroupingBenchmark = do
  benchStore "memory" testSMTStoreConfig
#if defined(dbServerPostgres)
  benchStore "postgres" testPostgresStoreConfig
#endif
  where
    benchStore :: MsgStoreClass s => String -> (HasTestEnv => MsgStoreConfig s) -> Spec
    benchStore storeName cfg =
      forM_ [0, 2, 1000] $ \serviceCount ->
        forM_ [1000, 10000] $ \ntfCount ->
          it (unwords [storeName, "S=" <> show serviceCount, "K=" <> show ntfCount]) $
            withMsgStore cfg $ benchGetQueueNtfServices storeName serviceCount ntfCount

benchGetQueueNtfServices :: forall s. MsgStoreClass s => String -> Int -> Int -> s -> IO ()
benchGetQueueNtfServices storeName serviceCount ntfCount ms = do
  ntfs <- addNtfQueues
  Right (groups, []) <- getNtfServices ntfs
  forM_ groups $ \(serviceId_, sNtfs) -> map snd sNtfs `shouldBe` (serviceId_ <$ sNtfs)
  sum (map (length . snd) groups) `shouldBe` ntfCount
  ts <- replicateM runs $ timeNs $ evaluate . groupedCount =<< getNtfServices ntfs
  putStrLn $
    unwords
      [ "BENCH getQueueNtfServices",
        "store=" <> storeName,
        "S=" <> show serviceCount,
        "K=" <> show ntfCount,
        "median_ms=" <> showMs (sort ts !! (runs `div` 2)),
        "min_ms=" <> showMs (minimum ts),
        "max_ms=" <> showMs (maximum ts),
        "runs=" <> show runs
      ]
  where
    st = queueStore ms
    runs = 21
    getNtfServices = getQueueNtfServices @(StoreQueue s) st
    addNtfQueues = do
      g <- C.newRandom
      ntfCreds <- testNtfCreds g
      srs <- replicateM serviceCount $ newServiceRec g
      runRight $ do
        serviceIds <- mapM (ExceptT . getCreateService @(StoreQueue s) st) srs
        ntfs <- forM (take ntfCount $ cycle $ Nothing : map Just serviceIds) $ \ntfServiceId -> do
          (rId, qr) <- liftIO $ testNewQueueRec g QMMessaging
          notifierId <- liftIO $ atomically $ EntityId <$> C.randomBytes 24 g
          void $ ExceptT $ addQueue ms rId qr {notifier = Just ntfCreds {notifierId, ntfServiceId}}
          pure (notifierId, ntfServiceId)
        pure $ M.assocs $ M.fromList ntfs

newServiceRec :: TVar ChaChaDRG -> IO ServiceRec
newServiceRec g = do
  serviceId <- atomically $ EntityId <$> C.randomBytes 24 g
  (_, cert) <- genCredentials g Nothing (0, 2400) "ntf.example.com"
  serviceCreatedAt <- getSystemDate
  pure
    ServiceRec
      { serviceId,
        serviceRole = SRNotifier,
        serviceCert = X.CertificateChain [cert],
        serviceCertHash = XV.getFingerprint cert X.HashSHA256,
        serviceCreatedAt
      }

timeNs :: IO a -> IO Word64
timeNs action = do
  performGC
  t <- getMonotonicTimeNSec
  _ <- action
  subtract t <$> getMonotonicTimeNSec

groupedCount :: Either ErrorType ([(Maybe ServiceId, [(NotifierId, a)])], [(NotifierId, a)]) -> Int
groupedCount = either (const 0) $ \(groups, deleted) -> sum (map (length . snd) groups) + length deleted

showMs :: Word64 -> String
showMs ns = showFFloat (Just 3) (fromIntegral ns / 1000000 :: Double) ""
