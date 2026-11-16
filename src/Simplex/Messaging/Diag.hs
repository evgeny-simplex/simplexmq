{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Diag
  ( diagLog,
    diagPort,
    diagSockPort,
    withDiagPorts,
    diagTests,
    diagAgentTag,
    registerDiagAgent,
  )
where

import Control.Concurrent (myThreadId)
import qualified Control.Exception as E
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (..))
import qualified Data.ByteString.Char8 as B
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Time.Clock (getCurrentTime)
import Network.Socket (SockAddr (..), Socket, getSocketName)
import System.IO (hFlush, stdout)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem.StableName (StableName, hashStableName, makeStableName)

diagPorts :: IORef (S.Set String)
diagPorts = unsafePerformIO $ newIORef S.empty
{-# NOINLINE diagPorts #-}

diagTests :: IORef (S.Set Int)
diagTests = unsafePerformIO $ newIORef S.empty
{-# NOINLINE diagTests #-}

diagAgents :: IORef (M.Map Int String)
diagAgents = unsafePerformIO $ newIORef M.empty
{-# NOINLINE diagAgents #-}

diagLog :: String -> IO ()
diagLog s = do
  t <- getCurrentTime
  tid <- myThreadId
  B.hPutStr stdout $ B.pack $ "DIAG " <> show t <> " " <> show tid <> " " <> s <> "\n"
  hFlush stdout

diagPort :: MonadIO m => String -> String -> m ()
diagPort port s = liftIO $ do
  ps <- readIORef diagPorts
  when (port `S.member` ps) $ diagLog $ "[" <> port <> "] " <> s

diagSockPort :: Socket -> IO String
diagSockPort sock =
  (portOf <$> getSocketName sock) `E.catch` \(_ :: E.SomeException) -> pure ""
  where
    portOf = \case
      SockAddrInet p _ -> show p
      SockAddrInet6 p _ _ _ -> show p
      _ -> ""

withDiagPorts :: Int -> [String] -> IO a -> IO a
withDiagPorts testNo ps =
  E.bracket_
    (atomicModifyIORef' diagPorts (\s -> (s `S.union` S.fromList ps, ())) >> atomicModifyIORef' diagTests (\s -> (S.insert testNo s, ())))
    (atomicModifyIORef' diagPorts (\s -> (s `S.difference` S.fromList ps, ())) >> atomicModifyIORef' diagTests (\s -> (S.delete testNo s, ())))

registerDiagAgent :: a -> Int -> String -> IO ()
registerDiagAgent c clientId dbPath = do
  ts <- readIORef diagTests
  case filter (\n -> ("/" <> show n <> "/") `isInfixOf` dbPath || ("test" <> show n <> "_") `isInfixOf` dbPath) (S.toList ts) of
    n : _ -> do
      sn <- stableNameOf c
      let tag = "T" <> show n <> " A" <> show clientId
      atomicModifyIORef' diagAgents $ \m -> (M.insert (hashStableName sn) tag m, ())
      diagLog $ tag <> " registered " <> dbPath
    [] -> pure ()

diagAgentTag :: a -> IO (Maybe String)
diagAgentTag c = do
  sn <- stableNameOf c
  M.lookup (hashStableName sn) <$> readIORef diagAgents

stableNameOf :: a -> IO (StableName a)
stableNameOf c = c `seq` makeStableName c
