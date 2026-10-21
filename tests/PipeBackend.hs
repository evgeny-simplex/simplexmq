{-# LANGUAGE LambdaCase #-}

module PipeBackend where

import Control.Concurrent.STM
import qualified Data.ByteString as B
import Network.TLS (Backend (..))

-- | Closing either end closes both directions: receivers get the bytes already sent, then EOF.
pipeBackends :: IO (Backend, Backend)
pipeBackends = do
  closed <- newTVarIO False
  aToB <- newTVarIO B.empty
  bToA <- newTVarIO B.empty
  pure (pipeEnd closed aToB bToA, pipeEnd closed bToA aToB)

pipeEnd :: TVar Bool -> TVar B.ByteString -> TVar B.ByteString -> Backend
pipeEnd closed sndBuf rcvBuf =
  Backend
    { backendFlush = pure (),
      backendClose = atomically $ writeTVar closed True,
      backendSend = atomically . send,
      backendRecv = atomically . recv
    }
  where
    send s =
      readTVar closed >>= \case
        True -> throwSTM $ userError "pipe closed"
        False -> modifyTVar' sndBuf (<> s)
    recv n = do
      buf <- readTVar rcvBuf
      isClosed <- readTVar closed
      if B.length buf < n && not isClosed
        then retry
        else do
          let (s, rest) = B.splitAt n buf
          writeTVar rcvBuf rest
          pure s
