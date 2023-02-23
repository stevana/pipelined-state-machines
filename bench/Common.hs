{-# LANGUAGE NumericUnderscores #-}

module Common where

import Control.Monad (when)
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Data.Time
import System.Directory (doesFileExist, removeFile)
import System.Mem (performGC)
import Text.Printf

------------------------------------------------------------------------

iTERATIONS :: Int
iTERATIONS = 100_000_000

vALUE_TO_WRITE :: Int
vALUE_TO_WRITE = 1

nUMBER_OF_PRODUCERS :: Int
nUMBER_OF_PRODUCERS = 3

sLEEP_TIME :: Int
sLEEP_TIME = 0

bUFFER_CAPACITY :: Int
bUFFER_CAPACITY = 1024 * 64

-- Single-producer single-consumer helper.
spsc :: IO a -> (a -> IO ()) -> (a -> MVar () -> IO ()) -> IO ()
spsc setup producer consumer = do
  (r, consumerFinished, start) <- header setup
  withAsync (producer r) $ \ap ->
    withAsync (consumer r consumerFinished) $ \ac -> do
      () <- takeMVar consumerFinished
      end <- getCurrentTime
      cancel ap
      cancel ac
      footer start end

-- Multiple-producers single-consumer helper.
mpsc :: IO a -> (a -> IO ()) -> (a -> MVar () -> IO c) -> IO ()
mpsc setup producer consumer = do
  (r, consumerFinished, start) <- header setup
  withAsync (producer r) $ \ap1 ->
    withAsync (producer r) $ \ap2 ->
      withAsync (producer r) $ \ap3 ->
        withAsync (consumer r consumerFinished) $ \ac -> do
          () <- takeMVar consumerFinished
          end <- getCurrentTime
          mapM_ cancel [ap1, ap2, ap3]
          cancel ac
          footer start end

m10psc :: IO a -> (a -> IO ()) -> (a -> MVar () -> IO c) -> IO ()
m10psc setup producer consumer = do
  (r, consumerFinished, start) <- header setup
  withAsync (producer r) $ \ap1 ->
    withAsync (producer r) $ \ap2 ->
      withAsync (producer r) $ \ap3 ->
        withAsync (producer r) $ \ap4 ->
          withAsync (producer r) $ \ap5 ->
            withAsync (producer r) $ \ap6 ->
              withAsync (producer r) $ \ap7 ->
                withAsync (producer r) $ \ap8 ->
                  withAsync (producer r) $ \ap9 ->
                    withAsync (producer r) $ \ap10 ->
                      withAsync (consumer r consumerFinished) $ \ac -> do
                        () <- takeMVar consumerFinished
                        end <- getCurrentTime
                        mapM_ cancel [ap1, ap2, ap3, ap4, ap5, ap6, ap7, ap8, ap9, ap10]
                        cancel ac
                        footer start end

header :: IO a -> IO (a, MVar (), UTCTime)
header setup = do
  n <- getNumCapabilities
  printf "%-25.25s%10d\n" "CPU capabilities" n
  printf "%-25.25s%10d\n" "Total number of events" iTERATIONS
  r <- setup
  consumerFinished <- newEmptyMVar
  performGC
  start <- getCurrentTime
  return (r, consumerFinished, start)

footer :: UTCTime -> UTCTime -> IO ()
footer start end = do
  let duration :: Double
      duration = realToFrac (diffUTCTime end start)

      throughput :: Double
      throughput = realToFrac iTERATIONS / duration
  printf "%-25.25s%10.2f events/s\n" "Throughput" throughput
  printf "%-25.25s%10.2f s\n" "Duration" duration

  -- XXX: prettyPrintHistogram histo
  -- meanTransactions <- hmean histo
  -- printf "%-25.25s%10.2f\n" "Mean concurrent txs" meanTransactions
  -- Just maxTransactions <- percentile 100.0 histo
  -- printf "%-25.25s%10.2f\n" "Max concurrent txs" maxTransactions
  -- printf "%-25.25s%10.2f ns\n" "Latency" ((meanTransactions / throughput) * 1000000)

cleanup :: FilePath -> IO ()
cleanup fp = do
  b <- doesFileExist fp
  when b (removeFile fp)
