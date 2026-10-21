{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.RemoteControl.Discovery
  ( pattern ANY_ADDR_V4,
    getLocalAddress,
    mkLastLocalHost,
    preferAddress,
    startTLSServer,
  ) where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad
import Data.Default (def)
import Data.List (delete, find, partition)
import Data.Maybe (mapMaybe)
import Data.String (IsString)
import qualified Data.Text as T
import Data.Word (Word16)
import Network.Info (IPv4 (..), NetworkInterface (..), getNetworkInterfaces)
import qualified Network.Socket as N
import qualified Network.TLS as TLS
import Simplex.Messaging.Transport (TransportPeer (..), defaultSupportedParams)
import qualified Simplex.Messaging.Transport as Transport
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (mkTransportServerConfig, runTransportServerSocket, startTCPServer)
import Simplex.Messaging.Util (ifM, tshow)
import Simplex.RemoteControl.Types
import UnliftIO

pattern ANY_ADDR_V4 :: (IsString a, Eq a) => a
pattern ANY_ADDR_V4 = "0.0.0.0"

getLocalAddress :: Maybe RCCtrlAddress -> IO [RCCtrlAddress]
getLocalAddress preferred_ =
  maybe id preferAddress preferred_ . mkLastLocalHost . mapMaybe toCtrlAddr <$> getNetworkInterfaces
  where
    toCtrlAddr NetworkInterface {name, ipv4 = IPv4 ha} = case N.hostAddressToTuple ha of
      (0, 0, 0, 0) -> Nothing -- "no" address
      (255, 255, 255, 255) -> Nothing -- broadcast
      (169, 254, _, _) -> Nothing -- link-local
      ok -> Just RCCtrlAddress {address = THIPv4 ok, interface = T.pack name}

mkLastLocalHost :: [RCCtrlAddress] -> [RCCtrlAddress]
mkLastLocalHost addrs = other <> local
  where
    (local, other) = partition localHost addrs
    localHost RCCtrlAddress {address = THIPv4 (127, _, _, _)} = True
    localHost _ = False

preferAddress :: RCCtrlAddress -> [RCCtrlAddress] -> [RCCtrlAddress]
preferAddress RCCtrlAddress {address, interface} addrs =
  case find matchAddr addrs <|> find matchIface addrs of
    Nothing -> addrs
    Just p -> p : delete p addrs
  where
    matchAddr RCCtrlAddress {address = a} = a == address
    matchIface RCCtrlAddress {interface = i} = i == interface

startTLSServer :: Maybe Word16 -> TMVar (Maybe N.PortNumber) -> TLS.Credential -> TLS.ServerHooks -> (Transport.TLS 'TServer -> IO ()) -> IO (Async ())
startTLSServer port_ startedOnPort credentials hooks server = async . liftIO $ do
  started <- newEmptyTMVarIO
  bracketOnError (startTCPServer started Nothing $ maybe "0" show port_) (\_e -> setPort Nothing) $ \socket ->
    ifM
      (atomically $ readTMVar started)
      (runServer started socket)
      (setPort Nothing)
  where
    runServer started socket = do
      port <- N.socketPort socket
      logInfo $ "System-assigned port: " <> tshow port
      setPort $ Just port
      runTransportServerSocket started (pure socket) "RCP TLS" serverParams (mkTransportServerConfig True Nothing True) server
    setPort = void . atomically . tryPutTMVar startedOnPort
    serverParams =
      def
        { TLS.serverWantClientCert = True,
          TLS.serverShared = def {TLS.sharedCredentials = TLS.Credentials [credentials]},
          TLS.serverHooks = hooks,
          TLS.serverSupported = defaultSupportedParams
        }
