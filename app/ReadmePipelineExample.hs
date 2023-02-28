{-# LANGUAGE GADTs #-}
{-# LANGUAGE BangPatterns #-}

module Main where

import Control.Monad
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TQueue
import Data.Time
import Data.List

------------------------------------------------------------------------

data SM s a b where
  Id      :: SM s a a
  Compose :: SM s b c -> SM s a b -> SM s a c
  Fst     :: SM s (a, b) a
  Snd     :: SM s (a, b) b
  (:&&&)  :: SM s a c -> SM s a d -> SM s a (c, d)
  (:***)  :: SM s a c -> SM s b d -> SM s (a, b) (c, d)
  SlowIO  :: SM s a a

swap :: SM () (a, b) (b, a)
swap = Snd :*** Fst `Compose` copy `Compose` SlowIO
  where
    copy = Id :&&& Id

interpret :: SM s a b -> (a -> s -> IO (s, b))
interpret Id            x s = return (s, x)
interpret (Compose g f) x s = do
  (s', y) <- interpret f x s
  interpret g y s'
interpret Fst           x s = return (s, fst x)
interpret Snd           x s = return (s, snd x)
interpret (f :&&& g)    x s = do
  (s', y)  <- interpret f x s
  (s'', z) <- interpret g x s'
  return (s'', (y, z))
interpret (f :*** g)    x s = do
  (s', y)  <- interpret f (fst x) s
  (s'', z) <- interpret g (snd x) s'
  return (s'', (y, z))
interpret SlowIO x s = do
  threadDelay 200000 -- 0.2s
  return (s, x)

data P a b where
  SM     :: String -> SM s a b -> s -> P a b
  (:>>>) :: P a b -> P b c -> P a c
  Shard  :: P a b -> P a b

swapsSequential :: P (a, b) (b, a)
swapsSequential = SM "three swaps" (swap `Compose` swap `Compose` swap) ()

swapsPipelined :: P (a, b) (b, a)
swapsPipelined =
  SM "first swap"  swap () :>>>
  SM "second swap" swap () :>>>
  SM "third swap"  swap ()

data Deployment a = Deployment
  { queue :: TQueue a
  , pids  :: [(String, Async ())]
  }

names :: Deployment a -> String
names = bracket . intercalate "," . reverse . map fst . pids
  where
    bracket s = "[" ++ s ++ "]"

stop :: Deployment a -> IO ()
stop = mapM_ (cancel . snd) . pids

deploy' :: P a b -> Deployment a -> IO (Deployment b)
deploy' (SM name sm s0) d = do
  q' <- newTQueueIO
  pid <- async (go s0 q')
  return Deployment { queue = q', pids = (name, pid) : pids d }
  where
    f = interpret sm

    go s q' = do
      x <- atomically $ readTQueue (queue d)
      (s', o) <- f x s
      atomically $ writeTQueue q' o
      go s' q'
deploy' (sm :>>> sm') d = do
  d' <- deploy' sm d
  deploy' sm' d'
deploy' (Shard p) d = do
  let qIn = queue d
  qEven  <- newTQueueIO
  qOdd   <- newTQueueIO
  pidIn  <- async $ shardQIn qIn qEven qOdd
  dEven  <- deploy' p (Deployment qEven [])
  dOdd   <- deploy' p (Deployment qOdd [])
  qOut   <- newTQueueIO
  pidOut <- async $ shardQOut (queue dEven) (queue dOdd) qOut
  return (Deployment qOut (("shardIn:  " ++ names dEven ++ " & " ++ names dOdd, pidIn) :
                           ("shardOut: " ++ names dEven ++ " & " ++ names dOdd, pidOut) :
                           pids dEven ++ pids dOdd ++ pids d))
  where
    shardQIn :: TQueue a -> TQueue a -> TQueue a -> IO ()
    shardQIn  qIn qEven qOdd = do
      atomically (readTQueue qIn >>= writeTQueue qEven)
      shardQIn qIn qOdd qEven

    shardQOut :: TQueue a -> TQueue a -> TQueue a -> IO ()
    shardQOut qEven qOdd qOut = do
      atomically (readTQueue qEven >>= writeTQueue qOut)
      shardQOut qOdd qEven qOut

deploy :: P a b -> IO (TQueue a, Deployment b)
deploy p = do
  q <- newTQueueIO
  d <- deploy' p (Deployment q [])
  return (q, d)

swapsSharded :: P (a, b) (b, a)
swapsSharded =
  Shard (SM "first swap"  swap ()) :>>>
  Shard (SM "second swap" swap ()) :>>>
  Shard (SM "third swap"  swap ())

data PipelineKind = Sequential | Pipelined | Sharded
  deriving Show

main :: IO ()
main = do
  mapM_ libMain [Sequential, Pipelined, Sharded]

libMain :: PipelineKind -> IO ()
libMain k = do
  (q, d) <- deploy $ case k of
                       Sequential -> swapsSequential
                       Pipelined  -> swapsPipelined
                       Sharded    -> swapsSharded
  print k
  putStrLn $ "Pids: " ++ names d
  !start <- getCurrentTime
  forM_ [(1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7)] $ \x ->
    atomically $ writeTQueue q x
  !resps <- replicateM 6 $ atomically $ readTQueue (queue d)
  !end <- getCurrentTime
  putStrLn $ "Responses: " ++ show resps
  putStrLn $ "Time: " ++ show (diffUTCTime end start)
  putStrLn ""
  stop d
