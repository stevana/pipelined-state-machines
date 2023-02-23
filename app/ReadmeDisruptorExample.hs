module Main where

import Control.Concurrent
import Control.Concurrent.Async
import Disruptor.SP

main :: IO ()
main = do

  -- Create the shared ring buffer.
  let bufferCapacity = 128
  rb <- newRingBuffer bufferCapacity

  -- The producer keeps a counter and produces events that are merely the pretty
  -- printed value as a string of that counter.
  let produce :: Int -> IO (String, Int)
      produce n = return (show n, n + 1)

      -- The counter starts at zero.
      initialProducerState = 0

      -- No back-pressure is applied in this example.
      backPressure :: Int -> IO ()
      backPressure _ = return ()

  producer <- newEventProducer rb produce backPressure initialProducerState

  -- The consumer merely prints the string event to the terminal.
  let consume :: () -> String -> SequenceNumber -> EndOfBatch -> IO ()
      consume () event snr endOfBatch =
        putStrLn (event ++ if endOfBatch then " (end of batch)" else "")

      -- The consumer doesn't need any state in this example.
      initialConsumerState = ()

      -- Which other consumers do we need to wait for before consuming an event?
      dependencies = []

      -- What to do in case there are no events to consume?
      waitStrategy = Sleep 1

  consumer <- newEventConsumer rb consume initialConsumerState dependencies waitStrategy

  -- Tell the ring buffer which the last consumer is, to avoid overwriting
  -- events that haven't been consumed yet.
  setGatingSequences rb [ecSequenceNumber consumer]

  withEventProducer producer $ \ap ->
    withEventConsumer consumer $ \ac -> do
      threadDelay (3 * 1000 * 1000) -- 3 sec
      cancel ap
      cancel ac
