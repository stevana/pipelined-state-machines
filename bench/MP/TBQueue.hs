module Main where

import Control.Monad
import Control.Concurrent.STM
import Control.Concurrent.MVar

import Common

------------------------------------------------------------------------

main :: IO ()
main = mpsc setup producer consumer
  where
    setup = newTBQueueIO (fromIntegral bUFFER_CAPACITY)

    producer q = replicateM_ iTERATIONS
                             (atomically (writeTBQueue q vALUE_TO_WRITE))

    consumer q consumerFinished = do
      replicateM_ iTERATIONS (atomically (readTBQueue q))
      putMVar consumerFinished ()
