{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Diag
  ( diagLog,
    diagPort,
    diagSockPort,
    withDiagTest,
    diagAgentLog,
    registerDiagAgent,
  )
where

import Control.Concurrent (myThreadId)
import qualified Control.Exception as E
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.ByteString.Char8 as B
import Data.IORef
import qualified Data.IntMap.Strict as IM
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import Data.Time.Clock (getCurrentTime)
import Network.Socket (SockAddr (..), Socket, getSocketName)
import System.IO (hFlush, stdout)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem.StableName (hashStableName, makeStableName)

diagPorts :: IORef (M.Map String Int)
diagPorts = unsafePerformIO $ newIORef M.empty
{-# NOINLINE diagPorts #-}

diagBufs :: IORef (IM.IntMap [String])
diagBufs = unsafePerformIO $ newIORef IM.empty
{-# NOINLINE diagBufs #-}

diagAgents :: IORef (IM.IntMap (Int, String))
diagAgents = unsafePerformIO $ newIORef IM.empty
{-# NOINLINE diagAgents #-}

diagLine :: String -> IO String
diagLine s = do
  t <- getCurrentTime
  tid <- myThreadId
  pure $ show t <> " " <> show tid <> " " <> s

diagLog :: String -> IO ()
diagLog s = do
  l <- diagLine s
  B.hPutStr stdout $ B.pack $ "DIAG " <> l <> "\n"
  hFlush stdout

diagAppend :: Int -> String -> IO ()
diagAppend testNo s = do
  l <- diagLine s
  atomicModifyIORef' diagBufs $ \m -> (IM.adjust (l :) testNo m, ())

diagPort :: MonadIO m => String -> String -> m ()
diagPort port s = liftIO $ M.lookup port <$> readIORef diagPorts >>= mapM_ (\n -> diagAppend n $ "[" <> port <> "] " <> s)

diagSockPort :: Socket -> IO String
diagSockPort sock =
  (portOf <$> getSocketName sock) `E.catch` \(_ :: E.SomeException) -> pure ""
  where
    portOf = \case
      SockAddrInet p _ -> show p
      SockAddrInet6 p _ _ _ -> show p
      _ -> ""

withDiagTest :: Int -> [String] -> String -> IO a -> IO a
withDiagTest testNo ps tag action = E.bracket_ register unregister $ do
  diagAppend testNo $ tag <> " start"
  E.try action >>= \case
    Right r -> pure r
    Left (e :: E.SomeException) -> do
      diagAppend testNo $ tag <> " FAILED " <> show e
      ls <- maybe [] reverse . IM.lookup testNo <$> readIORef diagBufs
      B.hPutStr stdout $ B.pack $ concatMap (\l -> "DIAG T" <> show testNo <> " " <> l <> "\n") ls
      hFlush stdout
      E.throwIO e
  where
    register = do
      atomicModifyIORef' diagBufs $ \m -> (IM.insert testNo [] m, ())
      atomicModifyIORef' diagPorts $ \m -> (foldr (`M.insert` testNo) m ps, ())
    unregister = do
      atomicModifyIORef' diagPorts $ \m -> (foldr M.delete m ps, ())
      atomicModifyIORef' diagBufs $ \m -> (IM.delete testNo m, ())
      atomicModifyIORef' diagAgents $ \m -> (IM.filter ((/= testNo) . fst) m, ())

registerDiagAgent :: a -> Int -> String -> IO ()
registerDiagAgent c clientId dbPath = do
  ts <- IM.keys <$> readIORef diagBufs
  case filter (\n -> ("/" <> show n <> "/") `isInfixOf` dbPath || ("test" <> show n <> "_") `isInfixOf` dbPath) ts of
    n : _ -> do
      h <- hashStableName <$> (c `seq` makeStableName c)
      let tag = "A" <> show clientId
      atomicModifyIORef' diagAgents $ \m -> (IM.insert h (n, tag) m, ())
      diagAppend n $ tag <> " registered " <> dbPath
    [] -> pure ()

diagAgentLog :: a -> String -> IO ()
diagAgentLog c s = do
  h <- hashStableName <$> (c `seq` makeStableName c)
  IM.lookup h <$> readIORef diagAgents >>= mapM_ (\(n, tag) -> diagAppend n $ tag <> " " <> s)
