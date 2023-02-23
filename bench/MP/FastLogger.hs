module Main where

import Control.Concurrent
import Control.Monad (when, replicateM_)
import System.Log.FastLogger
import Data.IORef

import Common

------------------------------------------------------------------------

lOG_MESSAGE :: LogStr
lOG_MESSAGE = toLogStr "some random string to log"

lOG_FILE :: FilePath
lOG_FILE = "/tmp/pipelined-state-machines-bench-mp-fast-logger.log"

main :: IO ()
main = do
  producersFinished <- newIORef 0
  mpsc setup (producer producersFinished) (consumer producersFinished)
  where
    setup = do
      cleanup lOG_FILE
      newFileLoggerSet defaultBufSize lOG_FILE

    producer producersFinished lgrset = do
      replicateM_ iTERATIONS (pushLogStrLn lgrset lOG_MESSAGE)
      flushLogStr lgrset
      atomicModifyIORef' producersFinished (\n -> (n + 1, ()))

    consumer producersFinished _lgrset consumerFinished = go
      where
        go = do
          p <- readIORef producersFinished
          if p == nUMBER_OF_PRODUCERS
          then putMVar consumerFinished ()
          else do
            threadDelay 10000
            go
