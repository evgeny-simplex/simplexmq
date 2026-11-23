{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Util where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception as E
import Control.Logger.Simple
import Control.Monad (forM, forM_, forever, replicateM, replicateM_, when)
import Data.Bits ((.&.))
import Data.Either (partitionEithers)
import qualified Data.IntMap.Strict as IM
import Data.List (foldl', isPrefixOf, tails)
import qualified Data.Map.Strict as M
import Data.String (IsString (..))
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Clock (getMonotonicTime)
import GHC.Conc (forkOn, getNumCapabilities, getNumProcessors, setNumCapabilities, threadWaitWrite)
import GHC.IO.Exception (IOException (..))
import qualified GHC.IO.Exception as IOException
import Network.Socket (Family (AF_UNIX), ServiceName, Socket, SocketType (Stream), close, defaultProtocol, socketPair, unsafeFdSocket)
import System.Posix.Types (Fd (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive, removeFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Process (callCommand)
import System.Timeout (timeout)
import Test.Hspec hiding (fit, it, xit)
import qualified Test.Hspec as Hspec
import Test.Hspec.Core.Spec (Example (..), Result (..), ResultStatus (..))

withNumCapabilities :: Int -> IO a -> IO a
withNumCapabilities new a = getNumCapabilities >>= \old -> bracket_ (setCaps old new) (setCaps new old) a
  where
    setCaps from to = do
      ts <- getCurrentTime
      putStrLn $ "Capabilities " <> show from <> " -> " <> show to <> " at " <> show ts
      setNumCapabilities to

withNCPUCapabilities :: IO a -> IO a
withNCPUCapabilities a = getNumProcessors >>= \p -> withNumCapabilities p a

inParrallel :: Int -> IO () -> IO ()
inParrallel n action = do
  streams <- replicateM n $ async action
  (es, rs) <- partitionEithers <$> mapM waitCatch streams
  map show es `shouldBe` []
  length rs `shouldBe` n

combinations :: Int -> [a] -> [[a]]
combinations 0 _ = [[]]
combinations k xs = [y : ys | y : xs' <- tails xs, ys <- combinations (k - 1) xs']

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists filePath = do
  fileExists <- doesFileExist filePath
  when fileExists $ removeFile filePath

data TestEnv = TestEnv
  { testNo :: Int,
    portBase :: Int
  }

type HasTestEnv = (?testEnv :: TestEnv)

tmpDir :: FilePath
tmpDir = "tests/tmp"

testDir :: HasTestEnv => FilePath
testDir = tmpDir </> show (testNo ?testEnv)

testPath :: HasTestEnv => FilePath -> FilePath
testPath = (testDir </>)

testServerPort :: HasTestEnv => Int -> ServiceName
testServerPort offset = show (portBase ?testEnv + offset)

testSchemaName :: (HasTestEnv, IsString s) => String -> s
testSchemaName name = fromString $ "test" <> show (testNo ?testEnv) <> "_" <> name

senderFiles :: HasTestEnv => FilePath
senderFiles = testPath "xftp-sender-files"

recipientFiles :: HasTestEnv => FilePath
recipientFiles = testPath "xftp-recipient-files"

testCounter :: TVar Int
testCounter = unsafePerformIO $ newTVarIO 0
{-# NOINLINE testCounter #-}

portBases :: TVar [Int]
portBases = unsafePerformIO $ newTVarIO [10000, 10010 .. 19990]
{-# NOINLINE portBases #-}

withTestEnv :: (HasTestEnv => IO a) -> IO a
withTestEnv action =
  bracket takePortBase releasePortBase $ \portBase -> do
    testNo <- atomically $ stateTVar testCounter $ \n -> (n, n + 1)
    let ?testEnv = TestEnv {testNo, portBase}
    bracket_
      (mapM_ (createDirectoryIfMissing True) [senderFiles, recipientFiles])
      (eventuallyRemove testDir 3)
      action
  where
    takePortBase =
      atomically $
        readTVar portBases >>= \case
          b : bs -> b <$ writeTVar portBases bs
          [] -> retry
    releasePortBase b = atomically $ modifyTVar' portBases (<> [b])

eventuallyRemove :: FilePath -> Int -> IO ()
eventuallyRemove path retries = case retries of
  0 -> action
  n ->
    action `E.catch` \ioe@IOError {ioe_type, ioe_filename} -> case ioe_type of
      IOException.UnsatisfiedConstraints | ioe_filename == Just path -> threadDelay 1000000 >> eventuallyRemove path (n - 1)
      _ -> E.throwIO ioe
  where
    action = removeDirectoryRecursive path

data TestWrapper a = TestWrapper String (HasTestEnv => a)

-- TODO [ntfdb] running wiht LogWarn level shows potential issue "Queue count differs"
testLogLevel :: LogLevel
testLogLevel = LogError

instance Example a => Example (TestWrapper a) where
  type Arg (TestWrapper a) = Arg a
  evaluateExample (TestWrapper label action) params hooks state = do
    ci <- envCI
    E.try runTest >>= either (\e -> maybe (onTestException ci e) (onTestFailure ci) (E.fromException e)) pure
    where
      tt = 300
      runTest =
        withTestEnv $ trackRunning label $
          timeout (tt * 1000000) (evaluateExample action params hooks state) `finally` callCommand "sync" >>= \case
            Just r -> pure r
            Nothing -> throwIO $ userError $ "test timed out after " <> show tt <> " seconds"
      onTestFailure :: Bool -> ResultStatus -> IO Result
      onTestFailure ci = \case
        Failure loc_ reason | ci -> do
          putStrLn $ "Test failed: " ++ show label ++ ", location " ++ show loc_ ++ ", reason: " ++ show reason
          printProbe $ "failure of " <> show label
          retryTest
        r -> E.throwIO r
      onTestException :: Bool -> SomeException -> IO Result
      onTestException False e = E.throwIO e
      onTestException True e = do
        putStrLn $ "Test exception: " ++ show label ++ ", " ++ show e
        printProbe $ "exception of " <> show label
        retryTest
      retryTest = do
        putStrLn "Retrying with more logs..."
        setLogLevel LogDebug
        runTest `finally` setLogLevel testLogLevel -- change this to match log level in Test.hs

envCI :: IO Bool
envCI = (Just "true" ==) <$> lookupEnv "CI"

runningTests :: TVar (M.Map Int (String, UTCTime))
runningTests = unsafePerformIO $ newTVarIO M.empty
{-# NOINLINE runningTests #-}

trackRunning :: HasTestEnv => String -> IO a -> IO a
trackRunning label =
  bracket_
    (getCurrentTime >>= \t -> atomically $ modifyTVar' runningTests $ M.insert (testNo ?testEnv) (label, t))
    (atomically $ modifyTVar' runningTests $ M.delete (testNo ?testEnv))

probeSockets :: [(Int, Fd, Socket)]
probeSockets = unsafePerformIO $ collect IM.empty
  where
    collect m
      | IM.size m == 32 = pure [(b, fd, s) | (b, (fd, s)) <- IM.toList m]
      | otherwise = do
          (s1, s2) <- socketPair AF_UNIX Stream defaultProtocol
          fds <- forM [s1, s2] $ \s -> (\fd -> (Fd fd, s)) <$> unsafeFdSocket s
          collect $ foldl' (\m' p@(Fd fd, _) -> IM.insertWith (\_ old -> old) (fromIntegral fd .&. 31) p m') m fds
{-# NOINLINE probeSockets #-}

probeIOManagers :: IO [(Int, [Int])]
probeIOManagers = do
  n <- getNumCapabilities
  vs <- forM [(k, b, fd) | k <- [0 .. n - 1], (b, fd, _) <- probeSockets] $ \(k, b, fd) -> do
    v <- newEmptyMVar
    _ <- forkOn k $ (timeout 2000000 (threadWaitWrite fd) >>= putMVar v . (Just () ==)) `E.catch` \(_ :: SomeException) -> putMVar v False
    pure (k, b, v)
  rs <- forM vs $ \(k, b, v) -> (\r -> (k, b, r == Just True)) <$> timeout 5000000 (takeMVar v)
  pure [(k, bs) | k <- [0 .. n - 1], let bs = [b | (k', b, ok) <- rs, k' == k, not ok], not (null bs)]

printProbe :: String -> IO ()
printProbe event = do
  r <- probeIOManagers
  ts <- getCurrentTime
  running <- readTVarIO runningTests
  putStrLn $ "IO manager probe at " <> event <> ", " <> show ts <> ": blocked (capability, buckets) " <> show r <> ", running " <> show (M.toList running)

ioManagerCloseStress :: IO ()
ioManagerCloseStress = do
  n <- getNumCapabilities
  r0 <- probeIOManagers
  putStrLn $ "IO manager close stress: " <> show n <> " capabilities, blocked before " <> show r0
  registrars <- forM [0 .. 4 * n - 1] $ \i -> forkOn (i `mod` n) $ forever $ mapM_ (\(_, fd, _) -> threadWaitWrite fd) probeSockets
  interrupted <- newTVarIO (0 :: Int)
  forM_ ([1 .. 20] :: [Int]) $ \round_ -> do
    replicateConcurrently_ 16 $ replicateM_ 250 $ do
      (s1, s2) <- socketPair AF_UNIX Stream defaultProtocol
      done <- newEmptyMVar
      t <- E.mask_ $ forkIO $ (close s1 >> close s2 >> putMVar done True) `E.catch` \(_ :: SomeException) -> putMVar done False
      killThread t
      ok <- takeMVar done
      when (not ok) $ atomically $ modifyTVar' interrupted (+ 1)
    r <- probeIOManagers
    c <- readTVarIO interrupted
    putStrLn $ "IO manager close stress: round " <> show round_ <> ", closes interrupted " <> show c <> ", blocked (capability, buckets) " <> show r
  mapM_ killThread registrars
  r1 <- probeIOManagers
  putStrLn $ "IO manager close stress: blocked after " <> show r1

memoryInfo :: IO String
memoryInfo = do
  st <- lines <$> readFile "/proc/self/status"
  mi <- lines <$> readFile "/proc/meminfo"
  let sel ks = filter (\l -> any (`isPrefixOf` l) ks)
      s = unwords $ map (unwords . words) $ sel ["VmRSS", "VmSwap"] st <> sel ["MemAvailable", "SwapTotal", "SwapFree"] mi
  length s `seq` pure s

stallMonitor :: IO ()
stallMonitor = forever $ do
  t0 <- getMonotonicTime
  threadDelay 100000
  t1 <- getMonotonicTime
  when (t1 - t0 > 1) $ do
    ts <- getCurrentTime
    caps <- getNumCapabilities
    mem <- memoryInfo
    running <- readTVarIO runningTests
    putStrLn $ "Stall: a 0.1 s delay took " <> show (t1 - t0) <> " s, at " <> show ts <> ", capabilities " <> show caps <> ", " <> mem <> ", running " <> show (map fst $ M.elems running)

memoryMonitor :: IO ()
memoryMonitor = forever $ do
  ts <- getCurrentTime
  mem <- memoryInfo
  n <- M.size <$> readTVarIO runningTests
  putStrLn $ "Memory at " <> show ts <> ": " <> mem <> ", running tests " <> show n
  threadDelay 30000000

ioManagerMonitor :: IO ()
ioManagerMonitor = do
  _ <- forkIO stallMonitor
  _ <- forkIO memoryMonitor
  r0 <- probeIOManagers
  putStrLn $ "IO manager probe started: " <> show (length probeSockets) <> " buckets, blocked " <> show r0
  loop r0
  where
    loop prev = do
      threadDelay 2000000
      r <- probeIOManagers
      if r == prev
        then loop r
        else do
          ts <- getCurrentTime
          running <- readTVarIO runningTests
          r' <- probeIOManagers
          putStrLn $ "IO manager probe changed at " <> show ts <> ": blocked (capability, buckets) " <> show r <> ", second probe " <> show r' <> ", running " <> show (M.toList running)
          loop r'

it :: (HasCallStack, Example a) => String -> (HasTestEnv => a) -> SpecWith (Arg a)
it label action = Hspec.it label (TestWrapper label action)

fit :: (HasCallStack, Example a) => String -> (HasTestEnv => a) -> SpecWith (Arg a)
fit label action = focus $ it label action

xit :: (HasCallStack, Example a) => String -> (HasTestEnv => a) -> SpecWith (Arg a)
xit label action = Hspec.xit label (TestWrapper label action)
