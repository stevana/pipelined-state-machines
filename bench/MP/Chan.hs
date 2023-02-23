module Main where

import Control.Concurrent.Chan
import Control.Concurrent.MVar (putMVar)
import Control.Monad (replicateM_)

import Common

------------------------------------------------------------------------

main :: IO ()
main = mpsc newChan producer consumer
  where
    producer i = replicateM_ iTERATIONS (writeChan i vALUE_TO_WRITE)

    consumer o consumerFinished = do
      replicateM_ iTERATIONS (readChan o)
      putMVar consumerFinished ()
