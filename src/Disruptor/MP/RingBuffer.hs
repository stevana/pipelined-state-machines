module Disruptor.MP.RingBuffer where

import Control.Concurrent (threadDelay, yield)
import Control.Exception (assert)
import Control.Monad (when)
import Data.Atomics (casIORef, peekTicket, readForCAS)
import Data.Bits (popCount)
import Data.IORef
       (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Vector.Mutable (IOVector)
import qualified Data.Vector.Mutable as Vector
import qualified Data.Vector.Unboxed.Mutable as Unboxed

import Disruptor.SequenceNumber
import Disruptor.AtomicCounterPadded

------------------------------------------------------------------------

-- | The lock-free multi-producer implementation is presented in the following
-- talk:
--
--   Locks? We Don't Need No Stinkin' Locks! by Mike Barker (JAX London 2012)
--   https://youtu.be/VBnLW9mKMh4?t=1813
--
-- and also discussed in the following thread:
--
--   https://groups.google.com/g/lmax-disruptor/c/UhmRuz_CL6E/m/-hVt86bHvf8J
--
-- Note that one can also achieve a similar result by using multiple
-- single-producers and combine them into one as outlined in this thread:
--
-- https://groups.google.com/g/lmax-disruptor/c/hvJVE-h2Xu0/m/mBW0j_3SrmIJ
--
data RingBuffer e = RingBuffer
  {
  -- | The capacity, or maximum amount of values, of the ring buffer.
    rbCapacity :: {-# UNPACK #-} !Int64
  -- | The cursor pointing to the head of the ring buffer.
  , rbCursor :: {-# UNPACK #-} !AtomicCounter
  -- | The values of the ring buffer.
  , rbEvents :: {-# UNPACK #-} !(IOVector e)
  -- | References to the last consumers' sequence numbers, used in order to
  -- avoid wrapping the buffer and overwriting events that have not been
  -- consumed yet.
  -- TODO: use vector instead of list.
  , rbGatingSequences :: {-# UNPACK #-} !(IORef [IORef SequenceNumber])
  -- | Cached value of computing the last consumers' sequence numbers using the
  -- above references.
  , rbCachedGatingSequence :: {-# UNPACK #-} !(IORef SequenceNumber)
  -- | Used to keep track of what has been published in the multi-producer case.
  , rbAvailableBuffer :: {-# UNPACK #-} !(Unboxed.IOVector Int)
  }

newRingBuffer :: Int -> IO (RingBuffer e)
newRingBuffer capacity
  | capacity <= 0          =
      error "newRingBuffer: capacity must be greater than 0"
  | popCount capacity /= 1 =
      -- NOTE: The use of bitwise and (`.&.`) in `index` relies on this.
      error "newRingBuffer: capacity must be a power of 2"
  | otherwise              = do
      snr <- newCounter (-1)
      v   <- Vector.new capacity
      gs  <- newIORef []
      cgs <- newIORef (-1)
      ab  <- Unboxed.new capacity
      Unboxed.set ab (-1)
      return (RingBuffer (fromIntegral capacity) snr v gs cgs ab)
{-# INLINABLE newRingBuffer #-}

-- | The capacity, or maximum amount of values, of the ring buffer.
capacity :: RingBuffer e -> Int64
capacity = rbCapacity
{-# INLINE capacity #-}

getCursor :: RingBuffer e -> IO SequenceNumber
getCursor rb = fromIntegral <$> readCounter (rbCursor rb)
{-# INLINE getCursor #-}

setGatingSequences :: RingBuffer e -> [IORef SequenceNumber] -> IO ()
setGatingSequences rb = writeIORef (rbGatingSequences rb)
{-# INLINE setGatingSequences #-}

getCachedGatingSequence :: RingBuffer e -> IO SequenceNumber
getCachedGatingSequence rb = readIORef (rbCachedGatingSequence rb)
{-# INLINE getCachedGatingSequence #-}

setCachedGatingSequence :: RingBuffer e -> SequenceNumber -> IO ()
setCachedGatingSequence rb = writeIORef (rbCachedGatingSequence rb)
{-# INLINE setCachedGatingSequence #-}

setAvailable :: RingBuffer e -> SequenceNumber -> IO ()
setAvailable rb snr = Unboxed.unsafeWrite
  (rbAvailableBuffer rb)
  (index cap snr)
  (availabilityFlag cap snr)
  where
    cap = capacity rb
{-# INLINE setAvailable #-}

getAvailable :: RingBuffer e -> Int -> IO Int
getAvailable rb ix = Unboxed.unsafeRead (rbAvailableBuffer rb) ix
{-# INLINE getAvailable #-}

minimumSequence :: RingBuffer e -> IO SequenceNumber
minimumSequence rb = do
  cursorValue <- getCursor rb
  minimumSequence' (rbGatingSequences rb) cursorValue
{-# INLINE minimumSequence #-}

minimumSequence' :: IORef [IORef SequenceNumber] -> SequenceNumber -> IO SequenceNumber
minimumSequence' gatingSequences cursorValue = do
  snrs <- mapM readIORef =<< readIORef gatingSequences
  return (minimum (cursorValue : snrs))
{-# INLINE minimumSequence' #-}

-- | Currently available slots to write to.
size :: RingBuffer e -> IO Int64
size rb = do
  consumed <- minimumSequence rb
  produced <- getCursor rb
  return (capacity rb - fromIntegral (produced - consumed))
{-# INLINABLE size #-}

-- | Claim the next event in sequence for publishing.
next :: RingBuffer e -> IO SequenceNumber
next rb = nextBatch rb 1
{-# INLINE next #-}

-- | Claim the next `n` events in sequence for publishing. This is for batch
-- event producing. Returns the highest claimed sequence number, so using it
-- requires a bit of extra work, e.g.:
--
-- @
--     let n = 10
--     hi <- nextBatch rb n
--     let lo = hi - (n - 1)
--     mapM_ f [lo..hi]
--     publishBatch rb lo hi
-- @
--
nextBatch :: RingBuffer e -> Int -> IO SequenceNumber
nextBatch rb n = assert (n > 0 && fromIntegral n <= capacity rb) $ do
  -- (current, nextSequence) <- -- {-# SCC "atomicModifyIORef'" #-}
  --                            -- XXX: The atomic takes 60% of the time of
  --                            -- `nextBatch`... Try using `AtomicCounter` instead
  --                            -- of `IORef SequneceNumber`.
  --                            atomicModifyIORef' (rbCursor rb) $ \current ->
  --                              let
  --                                nextSequence = current + fromIntegral n
  --                              in
  --                                (nextSequence, (current, nextSequence))
  current <- fromIntegral <$> {-# SCC incrCounter #-} getAndIncrCounter n (rbCursor rb)

  let nextSequence :: SequenceNumber
      nextSequence = current + fromIntegral n

      wrapPoint :: SequenceNumber
      wrapPoint = nextSequence - fromIntegral (capacity rb)

  cachedGatingSequence <- getCachedGatingSequence rb

  when (wrapPoint > cachedGatingSequence || cachedGatingSequence > current) $
    waitForConsumers current wrapPoint (rbGatingSequences rb)

  return nextSequence
  where
    waitForConsumers :: SequenceNumber -> SequenceNumber -> IORef [IORef SequenceNumber]
                     -> IO ()
    waitForConsumers current wrapPoint gatingSequences = go
      where
        go :: IO ()
        go = do
          gatingSequence <- minimumSequence' gatingSequences current
          if wrapPoint > gatingSequence
          then do
            threadDelay 1
            go -- SPIN
          else setCachedGatingSequence rb gatingSequence
{-# INLINABLE nextBatch #-}

-- Try to return the next sequence number to write to. If `Nothing` is returned,
-- then the last consumer has not yet processed the event we are about to
-- overwrite (due to the ring buffer wrapping around) -- the callee of `tryNext`
-- should apply back-pressure upstream if this happens.
tryNext :: RingBuffer e -> IO MaybeSequenceNumber
tryNext rb = tryNextBatch rb 1
{-# INLINE tryNext #-}

tryNextBatch :: RingBuffer e -> Int -> IO MaybeSequenceNumber
tryNextBatch rb n = assert (n > 0) go
  where
    go = do
      current_ <- {-# SCC "readCounter" #-} readCounter (rbCursor rb)
      let current = fromIntegral current_
          next_   = current_ + n
          next    = fromIntegral next_
      b <- {-# SCC "hasCapacity" #-} hasCapacity rb n current
      if not b
      then return None
      else do
        success <- {-# SCC casCounter #-} casCounter (rbCursor rb) current_ next_
        if success
        then return (Some next)
        else do
          {-# SCC "threadDelay" #-} threadDelay 1
          -- yield
          go -- SPIN
      {--
      current <- {-# SCC "readForCas" #-} readForCAS (rbCursor rb)
      let current_ = peekTicket current
          next     = current_ + fromIntegral n
      b <- {-# SCC "hasCapacity" #-} hasCapacity rb n current_
      if not b
      then return None
      else do
        (success, _current') <- {-# SCC "casIORef"#-} casIORef (rbCursor rb) current next
        if success
        then return (Some next)
        else do
          {-# SCC "threadDelay" #-}threadDelay 1
          -- yield
          go -- SPIN
-}
{-# INLINABLE tryNextBatch #-}

hasCapacity :: RingBuffer e -> Int -> SequenceNumber -> IO Bool
hasCapacity rb requiredCapacity cursorValue = do
  let wrapPoint = (cursorValue + fromIntegral requiredCapacity) -
                  fromIntegral (capacity rb)
  cachedGatingSequence <- getCachedGatingSequence rb
  if (wrapPoint > cachedGatingSequence || cachedGatingSequence > cursorValue)
  then do
    minSequence <- minimumSequence' (rbGatingSequences rb) cursorValue
    setCachedGatingSequence rb minSequence
    if (wrapPoint > minSequence)
    then return False
    else return True
  else return True
{-# INLINE hasCapacity #-}

set :: RingBuffer e -> SequenceNumber -> e -> IO ()
set rb snr e = Vector.unsafeWrite (rbEvents rb) (index (capacity rb) snr) e
{-# INLINE set #-}

publish :: RingBuffer e -> SequenceNumber -> IO ()
publish rb = setAvailable rb
{-# INLINE publish #-}
    -- XXX: Wake up consumers that are using a sleep wait strategy.

publishBatch :: RingBuffer e -> SequenceNumber -> SequenceNumber -> IO ()
publishBatch rb lo hi = mapM_ (setAvailable rb) [lo..hi]
{-# INLINE publishBatch #-}

get :: RingBuffer e -> SequenceNumber -> IO e
get rb current = go
  where
    cap :: Int64
    cap = capacity rb

    availableValue :: Int
    availableValue = availabilityFlag cap current

    ix :: Int
    ix = index cap current

    go = do
      v <- getAvailable rb ix
      if v /= availableValue
      then do
        threadDelay 1
        go -- SPIN
      else Vector.unsafeRead (rbEvents rb) ix

tryGet :: RingBuffer e -> SequenceNumber -> IO (Maybe e)
tryGet rb want = do
  produced <- getCursor rb
  if want <= produced
  then Just <$> get rb want
  else return Nothing
{-# INLINE tryGet #-}

isAvailable :: RingBuffer e -> SequenceNumber -> IO Bool
isAvailable rb snr =
  (==) <$> Unboxed.unsafeRead (rbAvailableBuffer rb) (index capacity snr)
       <*> pure (availabilityFlag capacity snr)
  where
    capacity = rbCapacity rb
{-# INLINE isAvailable #-}

highestPublished :: RingBuffer e -> SequenceNumber -> SequenceNumber
                 -> IO SequenceNumber
highestPublished rb lowerBound availableSequence = go lowerBound
  where
    go sequence
      | sequence > availableSequence = return availableSequence
      | otherwise                    = do
          available <- isAvailable rb sequence
          if not (available)
          then return (sequence - 1)
          else go (sequence + 1)
