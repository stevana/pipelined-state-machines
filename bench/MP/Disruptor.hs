module Main where

import Control.Concurrent
import Control.Monad

import Common
import Disruptor.MP.Consumer
import Disruptor.MP.Producer
import Disruptor.MP.RingBuffer
import Disruptor.SequenceNumber

------------------------------------------------------------------------

main :: IO ()
main = mpsc setup producer consumer
  where
    setup = newRingBuffer bUFFER_CAPACITY

    producer :: RingBuffer Int -> IO ()
    producer rb = go iTERATIONS
      where
        go :: Int -> IO ()
        go 0 = return ()
        go n = do
          mSnr <- tryNext rb
          case mSnr of
            Some snr -> do
              set rb snr vALUE_TO_WRITE
              publish rb snr
              go (n - 1)
            None ->
              -- NOTE: No sleep needed here.
              go n

    consumer :: RingBuffer Int -> MVar () -> IO ()
    consumer rb consumerFinished = do
      let handler _s _n snr endOfBatch = do
            when (endOfBatch &&
                  getSequenceNumber snr ==
                  fromIntegral (iTERATIONS * nUMBER_OF_PRODUCERS - 1)) $
              putMVar consumerFinished ()
            return ()
      ec <- newEventConsumer rb handler () [] (Sleep sLEEP_TIME)
      setGatingSequences rb [ecSequenceNumber ec]
      ecWorker ec ()
