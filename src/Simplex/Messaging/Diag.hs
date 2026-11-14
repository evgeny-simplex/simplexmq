{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Diag (diagLog, diagWatch, diagIOManagers) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, forkOn, newEmptyMVar, putMVar, takeMVar, threadDelay)
import qualified Control.Exception as E
import Control.Monad (forM, unless, void)
import Data.IORef
import Data.Maybe (isNothing)
import Data.Time.Clock (getCurrentTime)
import GHC.Clock (getMonotonicTime)
import GHC.Conc (getNumCapabilities, threadStatus)
import GHC.Event (closeFd, getSystemEventManager)
import System.IO (hFlush, stdout)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

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

diagIOManagers :: IO [(Int, Int)]
diagIOManagers = do
  n <- getNumCapabilities
  vs <- forM [(cap, bucket) | cap <- [0 .. n - 1], bucket <- [0 .. 31]] $ \(cap, bucket) -> do
    v <- newEmptyMVar
    void $ forkOn cap $ do
      blocked <-
        getSystemEventManager >>= \case
          Nothing -> pure False
          Just mgr -> isNothing <$> timeout 2000000 (closeFd mgr (\_ -> pure ()) (Fd $ 1048576 + fromIntegral bucket))
      putMVar v (if blocked then [(cap, bucket)] else [])
    pure v
  concat <$> mapM takeMVar vs
