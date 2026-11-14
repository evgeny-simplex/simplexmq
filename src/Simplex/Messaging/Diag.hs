{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Diag (diagLog, diagWatch) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, threadDelay)
import qualified Control.Exception as E
import Control.Monad (unless, void)
import Data.IORef
import Data.Time.Clock (getCurrentTime)
import GHC.Clock (getMonotonicTime)
import GHC.Conc (threadStatus)
import System.IO (hFlush, stdout)

diagLog :: String -> IO ()
diagLog s = do
  t <- getCurrentTime
  putStrLn $ "DIAG " <> show t <> " " <> s
  hFlush stdout

diagWatch :: IO String -> Maybe ThreadId -> IO a -> IO a
diagWatch label target_ action = do
  done <- newIORef False
  start <- getMonotonicTime
  void $ forkIOWithUnmask $ \unmask -> unmask $ watch done start
  action `E.finally` writeIORef done True
  where
    watch done start = do
      threadDelay 3000000
      d <- readIORef done
      unless d $ do
        now <- getMonotonicTime
        l <- label `E.catch` \(e :: E.SomeException) -> pure (show e)
        st <- mapM threadStatus target_
        diagLog $ "stuck " <> show (round (now - start) :: Int) <> "s: " <> l <> maybe "" ((", target " <>) . show) st
        watch done start
