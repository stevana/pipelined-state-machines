{-# LANGUAGE NumericUnderscores #-}

module Main where

import Control.Monad
import Control.Concurrent
import Control.Concurrent.Async
import Data.Time
import Data.Word
import Data.Atomics.Counter
import Data.IORef
import System.CPUTime

import StuntDouble.Histogram
import qualified Disruptor.AtomicCounterPadded as Padded

-- Can't load FastMutInt:
--    Could not load module `FastMutInt'
--    It is a member of the hidden package `ghc-8.10.4'.
--    Perhaps you need to add `ghc' to the build-depends in your .cabal file.
--
-- But when I add ghc to build-depends it says it can't find a build plan, and
-- also https://hackage.haskell.org/package/ghc doesn't seem to have 8.10.4...
--
-- import FastMutInt

------------------------------------------------------------------------

main :: IO ()
main = do
  many "getCurrentTime" (return ()) (const getCurrentTime)

  many "getCPUTime" (return ()) (const getCPUTime)

  many "threadDelay 0" (return ()) (const (threadDelay 0))
  many "threadDelay 1" (return ()) (const (threadDelay 1))
  many "yield" (return ()) (const yield)
  manyConcurrent "threadDelay 0 (concurrent)" 3 (return ()) (const (threadDelay 0))
  manyConcurrent "threadDelay 1 (concurrent)" 3 (return ()) (const (threadDelay 1))
  manyConcurrent "yield (concurrent)" 3 (return ()) (const yield)

  many "incrCounter1" (newCounter 0) (incrCounter 1)
  many "incrCounter1Padded" (Padded.newCounter 0) (Padded.incrCounter 1)
  -- many "incrCounter1FastMutInt" (newFastMutInt 0)
  --      (\r -> readFastMutInt r >>= \v -> writeFastMutInt r (v +1))

  manyConcurrent "incrCounter1 (concurrent)"
    3 (newCounter 0) (incrCounter 1)
  manyConcurrent "incrCounter1Padded (concurrent)"
    3 (Padded.newCounter 0) (Padded.incrCounter 1)

  many "modifyIORef'" (newIORef (0 :: Int)) (\r -> modifyIORef' r succ)

  many "atomicModifyIORef'"
    (newIORef (0 :: Int)) (\r -> atomicModifyIORef' r (\n -> ((n + 1), ())))

  manyConcurrent "atomicModifyIORef' (concurrent)" 3
    (newIORef (0 :: Int)) (\r -> atomicModifyIORef' r (\n -> ((n + 1), ())))

many :: String -> IO a -> (a -> IO b) -> IO ()
many name create use = do
  h <- newHistogram
  r <- create
  replicateM 500000 (once h (use r))
  putStrLn ""
  putStrLn ""
  prettyPrintHistogram name h

manyConcurrent :: String -> Int -> IO a -> (a -> IO b) -> IO ()
manyConcurrent name n create use = do
  h <- newHistogram
  r <- create
  as <- replicateM n (async (replicateM 500000 (once h (use r))))
  mapM_ wait as
  putStrLn ""
  putStrLn ""
  prettyPrintHistogram name h

once :: Histogram -> IO a -> IO ()
once h io = do
  start <- fromInteger <$> getCPUTime
  _     <- io
  end   <- fromInteger <$> getCPUTime

  let diffPico :: Word64
      diffPico = end - start

      diffNano :: Double
      diffNano = realToFrac (fromIntegral diffPico) * 1e-3

  void (measure diffNano h)
