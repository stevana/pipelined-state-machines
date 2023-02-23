module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Chan.Unagi.NoBlocking.Unboxed
import Control.Concurrent.MVar (putMVar)
import Control.Monad (replicateM_)

import Common

------------------------------------------------------------------------

main :: IO ()
main = spsc newChan (producer . fst) (\(_i, o) -> consumer o)
  where
    producer i = replicateM_ iTERATIONS (writeChan i vALUE_TO_WRITE)

    consumer o consumerFinished = do
      replicateM_ iTERATIONS (readChan (threadDelay sLEEP_TIME) o)
      putMVar consumerFinished ()
