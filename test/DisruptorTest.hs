module DisruptorTest where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Monad
import Data.IORef
import Data.Int
import Data.Set (Set)
import qualified Data.Set as Set
import System.IO
import System.IO.Error
import Test.HUnit
import Test.QuickCheck

import qualified Disruptor.MP.Consumer as MP
import qualified Disruptor.MP.Producer as MP
import qualified Disruptor.MP.RingBuffer as MP
import qualified Disruptor.SP.Consumer as SP
import qualified Disruptor.SP.Producer as SP
import qualified Disruptor.SP.RingBuffer as SP
import Disruptor.SequenceNumber
import Disruptor.AtomicCounterPadded

------------------------------------------------------------------------

(@?->) :: (Eq a, Show a) => IO a -> a -> Assertion
mx @?-> y = do
  x <- mx
  x @?= y

unit_ringBufferSingleNonBlocking :: Assertion
unit_ringBufferSingleNonBlocking = do
  rb <- SP.newRingBuffer 8
  Some i <- SP.tryNext rb
  SP.set rb i 'a'
  SP.publish rb i
  SP.get rb i @?-> Just 'a'
  Some j <- SP.tryNext rb
  SP.set rb j 'b'
  SP.publish rb j
  SP.get rb j @?-> Just 'b'

unit_ringBufferSingleBlocking :: Assertion
unit_ringBufferSingleBlocking = do
  rb <- SP.newRingBuffer 8
  i <- SP.next rb
  SP.set rb i 'a'
  SP.publish rb i
  SP.get rb i @?-> Just 'a'
  j <- SP.next rb
  SP.set rb j 'b'
  SP.publish rb j
  SP.get rb j @?-> Just 'b'

unit_ringBufferRemainingCapacity :: Assertion
unit_ringBufferRemainingCapacity = do
  rb <- SP.newRingBuffer 1
  consumerSnrRef <- newIORef (SequenceNumber (-1))
  SP.setGatingSequences rb [consumerSnrRef]
  SP.size rb @?-> 1
  SP.publish rb (SequenceNumber 0)
  SP.size rb @?-> 0
  SP.tryNext rb @?-> None
  modifyIORef consumerSnrRef succ
  SP.size rb @?-> 1

unit_ringBufferMulti :: Assertion
unit_ringBufferMulti = do
  rb <- MP.newRingBuffer 8
  Some i <- MP.tryNext rb
  MP.set rb i 'a'
  MP.publish rb i
  MP.tryGet rb i @?-> Just 'a'
  Some j <- MP.tryNext rb
  MP.set rb j 'b'
  MP.publish rb j
  MP.tryGet rb j @?-> Just 'b'

unit_ringBufferSP1P1C :: Assertion
unit_ringBufferSP1P1C = do
  rb <- SP.newRingBuffer 128
  consumerFinished <- newEmptyMVar

  let iTERATIONS :: Int64
      iTERATIONS = 1024

      ep = SP.EventProducer (const (go 0)) ()
        where
          go :: Int64 -> IO ()
          go n | n == iTERATIONS = return ()
               | otherwise = do
                   mSnr <- SP.tryNext rb
                   case mSnr of
                     Some snr -> do
                       SP.set rb snr n
                       SP.publish rb snr
                       go (n + 1)
                     None -> do
                       threadDelay 1
                       go n

  let handler seen n snr endOfBatch
        | n /= seen = error (show n ++ " appears twice")
        | otherwise = do
            -- putStrLn ("consumer got: " ++ show n ++
            --           if endOfBatch then ". End of batch!" else "")
            when (endOfBatch && getSequenceNumber snr == iTERATIONS - 1) $
              putMVar consumerFinished ()
            return (seen + 1)

  ec <- SP.newEventConsumer rb handler 0 [] (SP.Sleep 1)

  SP.setGatingSequences rb [SP.ecSequenceNumber ec]

  SP.withEventProducer ep $ \aep ->
    SP.withEventConsumer ec $ \aec -> do
      wait aep
      () <- takeMVar consumerFinished
      cancel aec

unit_ringBufferMP1P1CBlocking :: Assertion
unit_ringBufferMP1P1CBlocking = ringBufferMP1P1C True

unit_ringBufferMP1P1CNonBlocking :: Assertion
unit_ringBufferMP1P1CNonBlocking = ringBufferMP1P1C False

ringBufferMP1P1C :: Bool -> Assertion
ringBufferMP1P1C blocking = do
  numCap <- getNumCapabilities
  assertBool "getNumCapabilities < 2" (numCap >= 2)
  rb <- MP.newRingBuffer 8
  counter <- newIORef (-1)
  consumerFinished <- newEmptyMVar

  let ep = MP.EventProducer (const go) ()
        where
          go :: IO ()
          go = do
            n <- atomicModifyIORef' counter (\n -> let n' = n + 1 in (n', n'))
            if n > atLeastThisManyEvents
            then return ()
            else
              if blocking
              then goBlocking n
              else goNonBlocking n

          goBlocking n = do
            snr <- MP.next rb
            MP.set rb snr n
            MP.publish rb snr
            go

          goNonBlocking n = do
            mSnr <- MP.tryNext rb
            case mSnr of
              Some snr -> do
                MP.set rb snr n
                MP.publish rb snr
                go
              None -> do
                threadDelay 1
                goNonBlocking n

  let handler seen n snr endOfBatch
        | n `Set.member` seen = error (show n ++ " appears twice")
        | otherwise           = do
            -- putStrLn ("consumer got, n = " ++ show n ++ ", snr = " ++ show snr ++
            --           if endOfBatch then ". End of batch!" else "")
            let seen' = Set.insert n seen
            when (endOfBatch &&
                  getSequenceNumber snr >= fromIntegral atLeastThisManyEvents) $ do
              putMVar consumerFinished seen'
            return seen'
  ec <- MP.newEventConsumer rb handler Set.empty [] (MP.Sleep 1)

  MP.setGatingSequences rb [MP.ecSequenceNumber ec]

  MP.withEventProducer ep $ \aep ->
    MP.withEventConsumer ec $ \aec -> do
      seen <- takeMVar consumerFinished
      cancel aec
      cancel aep
      assertEqual "increasingByOneFrom"
        (Right ())
        (increasingByOneFrom 0 (Set.toList seen))

atLeastThisManyEvents = 10

increasingByOneFrom :: Int -> [Int] -> Either String ()
increasingByOneFrom n []
  | n >  atLeastThisManyEvents = Right ()
  | n <= atLeastThisManyEvents =
      Left ("n (= " ++ show n ++ ") < atLeastThisManyEvents (= " ++
            show atLeastThisManyEvents ++ ")")
increasingByOneFrom n (i : is) | n == i    = increasingByOneFrom (n + 1) is
                               | otherwise =
  Left ("Expected: " ++ show n ++ ", but got: " ++ show i)

unit_ringBuffer5P1C :: Assertion
unit_ringBuffer5P1C = do
  rb <- MP.newRingBuffer 32
  counter <- newCounter (-1)
  consumerFinished <- newEmptyMVar

  let ep = MP.EventProducer (const go) ()
        where
          go :: IO ()
          go = do
            n <- incrCounter 1 counter
            putStrLn ("producer, n = " ++ show n)
            if n > atLeastThisManyEvents
            then putStrLn "producer: done" >> return ()
            else do
              putStrLn "producer: not done yet"
              mSnr <- MP.tryNext rb
              putStrLn ("producer: mSrn = " ++ show mSnr)
              case mSnr of
                Some snr -> do
                  putStrLn ("producer: setting " ++ show n)
                  MP.set rb snr n
                  MP.publish rb snr
                  putStrLn ("producer: published n = " ++ show n ++ ", snr = " ++ show snr)
                  go
                None -> do
                  putStrLn "producer: none"
                  threadDelay 1
                  go

  let handler seen n snr endOfBatch
        | n `Set.member` seen = error (show n ++ " appears twice")
        | otherwise           = do
            putStrLn ("consumer got: n = " ++ show n ++ ", snr = " ++ show snr ++
                      if endOfBatch then ". End of batch!" else "")
            let seen' = Set.insert n seen
            when (endOfBatch &&
                  getSequenceNumber snr >= fromIntegral atLeastThisManyEvents) $
              putMVar consumerFinished seen'
            return seen'
  ec <- MP.newEventConsumer rb handler Set.empty [] (MP.Sleep 1)

  MP.setGatingSequences rb [MP.ecSequenceNumber ec]

  MP.withEventProducer ep $ \aep1 ->
    MP.withEventProducer ep $ \aep2 ->
      MP.withEventProducer ep $ \aep3 ->
        MP.withEventProducer ep $ \aep4 ->
          MP.withEventProducer ep $ \aep5 ->
            MP.withEventConsumer ec $ \aec -> do
              seen <- takeMVar consumerFinished
              cancel aec
              mapM_ cancel [aep1, aep2, aep3, aep4, aep5]
              assertEqual "increasingByOneFrom"
                (Right ())
                (increasingByOneFrom 0 (Set.toList seen))
