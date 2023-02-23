module Main where

import Control.Concurrent (putMVar, threadDelay)
import Control.Concurrent.Chan.Unagi.NoBlocking.Unboxed
import Control.Monad (replicateM_)

import Common

------------------------------------------------------------------------

main :: IO ()
main = mpsc newChan (producer . fst) (\(_i, o) -> consumer o)
  where
    producer i = replicateM_ iTERATIONS (writeChan i vALUE_TO_WRITE)

    consumer o consumerFinished = do
      replicateM_ (iTERATIONS * nUMBER_OF_PRODUCERS)
                  (readChan (threadDelay sLEEP_TIME) o)
      putMVar consumerFinished ()
