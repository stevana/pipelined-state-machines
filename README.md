# pipelined-state-machines

An experiment in declaratively programming parallel pipelines of state machines.

## Motivation

Imagine a flat complex in Sweden. Being the socialist utopia Sweden is there's a
shared laundry room which the people in the flat complex can book. In the
laundry room there's everything one needs to wash, dry and iron your clothes.
You don't even need to bring your own laundry detergent!

Lets call three people living there Ann, Bo and Cecilia, and lets assume they
all want to use the laundry room. Depending on how the booking system is
implemented the total time it would take for all three people to do their
laundry varies.

For example if the booking system allocates a big time slot per person in which
that person can do the whole cycle of *W*ashing, *D*rying and *I*roning then,
assuming each step takes one time unit, we get a situation like this:

          Person
            ^
        Ann | W D I                             W = Washing
         Bo |       W D I                       D = Drying
    Cecilia |             W D I                 I = Ironing
            +-------------------> Time
            0 1 2 3 4 5 6 7 8 9

Bo cannot start washing until Ann is done ironing, because Ann has booked the
room for the whole cycle, and so on.

If the booking system is more granular and allows booking a time slot per step
then we can get a situation that looks like this:

          Person
            ^
        Ann | W D I
         Bo |   W D I
    Cecilia |     W D I
            +-------------------> Time
            0 1 2 3 4 5 6 7 8 9

It should be clear that the total time is shorter in this case, because the
machines are utilised better (Bo can start using the washing machine right after
Ann is done with it). Also note that if each person would start a new washing
after they finish ironing the first one and so on then the time savings would be
even greater.

This optimisation is called pipelining. It's used a lot in manufacturing, for
example Airbus [builds](https://youtu.be/oxjT7veKi9c?t=2682) two airplanes per
day. If you were to order a plane today you'd get it delivered in two months
time. How is that they deliver two per day if it takes two months to build them?
Pipelining! It's also used inside CPUs to [pipeline
instructions](https://en.wikipedia.org/wiki/Instruction_pipelining).

The rest of this document is an experiment in how we can construct such
pipelining in software in a declarative way.

## Usage

The workers or stages in our pipeline will be state machines of the following
type.

```haskell
data SM s a b where
  Id      :: SM s a a
  Compose :: SM s b c -> SM s a b -> SM s a c
  Fst     :: SM s (a, b) a
  Snd     :: SM s (a, b) b
  (:&&&)  :: SM s a c -> SM s a d -> SM s a (c, d)
  (:***)  :: SM s a c -> SM s b d -> SM s (a, b) (c, d)
  SlowIO  :: SM s a a -- Simulate a slow I/O computation.
```

Here's an example of a stage which takes an ordered pair as input and swaps the
elements of the pair. Note the use of `SlowIO` to simulate that some slow I/O
computation happens.

```haskell
swap :: SM () (a, b) (b, a)
swap = Snd :*** Fst `Compose` copy `Compose` SlowIO
  where
    copy = Id :&&& Id
```

We can `interpret` such state machines into plain functions as follows.

```haskell
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
```

Next lets have a look at how we can construct pipelines of such state machines.

```haskell
data P a b where
  SM     :: String -> SM s a b -> s -> P a b
  (:>>>) :: P a b -> P b c -> P a c
```

The following is an example pipeline where there's only one stage in which we do
our pair swapping three times.

```haskell
swapsSequential :: P (a, b) (b, a)
swapsSequential = SM "three swaps" (swap `Compose` swap `Compose` swap) ()
```

The above corresponds to our coarse grained booking system where the laundry was
booked for the whole cycle. Whereas the following corresponds to the more fine
grained approach where we get pipelining.

```haskell
swapsPipelined :: P (a, b) (b, a)
swapsPipelined =
  SM "first swap"  swap () :>>>
  SM "second swap" swap () :>>>
  SM "third swap"  swap ()
```

A pipeline can be deployed, we'll use the following type to keep track of the
queue associated with the pipeline as well as the name and pids of the state
machines involved in the pipeline.

```haskell
data Deployment a = Deployment
  { queue :: TQueue a
  , pids  :: [(String, Async ())]
  }

names :: Deployment a -> String
names = bracket . intercalate "," . reverse . map fst . pids
  where
    bracket s = "[" ++ s ++ "]"
```

Here's the actual `deploy`ment function which takes a pipeline and gives back an
input-queue and a `Deployment` which holds the output-queue and the names and
pids of the state machines.

```haskell
deploy :: P a b -> IO (TQueue a, Deployment b)
deploy p = do
  q <- newTQueueIO
  d <- deploy' p (Deployment q [])
  return (q, d)

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
```

We now have everything we need to run a simple benchmark comparing the
sequential version of three swaps versus the pipelined version.

```haskell
data PipelineKind = Sequential | Pipelined
  deriving Show

main :: IO ()
main = do
  mapM_ libMain [Sequential, Pipelined]

libMain :: PipelineKind -> IO ()
libMain k = do
  (q, d) <- deploy $ case k of
                       Sequential -> swapsSequential
                       Pipelined  -> swapsPipelined
  print k
  putStrLn $ "Pids: " ++ names d
  start <- getCurrentTime
  forM_ [(1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7)] $ \x ->
    atomically $ writeTQueue q x
  resps <- replicateM 6 $ atomically $ readTQueue (queue d)
  end <- getCurrentTime
  putStrLn $ "Responses: " ++ show resps
  putStrLn $ "Time: " ++ show (diffUTCTime end start)
  putStrLn ""
```

We can run the above with `cabal run readme-pipeline-example`, which results in
something like the following being printed to the screen.

```
Sequential
Pids: [three swaps]
Responses: [(2,1),(3,2),(4,3),(5,4),(6,5),(7,6)]
Time: 3.611045787s

Pipelined
Pids: [first swap,second swap,third swap]
Responses: [(2,1),(3,2),(4,3),(5,4),(6,5),(7,6)]
Time: 1.604990775s
```

Cool, we managed to reduce the total running time by more than half! We can do
even better though! In addition to pipelining we can also shard the queues by
letting two state machines work on the same queue, the first processing the
elements in the even positions of the queue and the second processing the
elements in the odd positions.

```diff
data P a b where
  SM     :: String -> SM s a b -> s -> P a b
  (:>>>) :: P a b -> P b c -> P a c
+ Shard  :: P a b -> P a b
```

Here's an example of a sharded pipeline, where each shard will spawn two state
machines (one working on the even indexes of the queue and the other on the
odd).

```haskell
swapsSharded :: P (a, b) (b, a)
swapsSharded =
  Shard (SM "first swap"  swap ()) :>>>
  Shard (SM "second swap" swap ()) :>>>
  Shard (SM "third swap"  swap ())
```

In the deployment of shards, we achieve the even-odd split by reading from the
input queue, `qIn`, and first writing to the even queue, `qEven`, and then
switching over to the odd queue, `qOdd`, when making the recursive call in
`shardQIn`. Whereas `shardQOut` does the inverse and merges the two queues back
into the output queue:

```diff
+ deploy' (Shard p) d = do
+   let qIn = queue d
+   qEven  <- newTQueueIO
+   qOdd   <- newTQueueIO
+   pidIn  <- async $ shardQIn qIn qEven qOdd
+   dEven  <- deploy' p (Deployment qEven [])
+   dOdd   <- deploy' p (Deployment qOdd [])
+   qOut   <- newTQueueIO
+   pidOut <- async $ shardQOut (queue dEven) (queue dOdd) qOut
+   return (Deployment qOut (("shardIn:  " ++ names dEven ++ " & " ++ names dOdd, pidIn) :
+                            ("shardOut: " ++ names dEven ++ " & " ++ names dOdd, pidOut) :
+                            pids dEven ++ pids dOdd ++ pids d))
+   where
+     shardQIn :: TQueue a -> TQueue a -> TQueue a -> IO ()
+     shardQIn  qIn qEven qOdd = do
+       atomically (readTQueue qIn >>= writeTQueue qEven)
+       shardQIn qIn qOdd qEven
+
+     shardQOut :: TQueue a -> TQueue a -> TQueue a -> IO ()
+     shardQOut qEven qOdd qOut = do
+       atomically (readTQueue qEven >>= writeTQueue qOut)
+       shardQOut qOdd qEven qOut
```

Running this version we see more than 3.5x speed-up compared to the sequential
pipeline.

```
Sharded
Pids: [first swap,first swap,shardOut: [first swap] & [first swap],shardIn:  [first swap] & [first swap],second swap,second swap,shardOut: [second swap] & [second swap],shardIn:  [second swap] & [second swap],third swap,third swap,shardOut: [third swap] & [third swap],shardIn:  [third swap] & [third swap]]
Responses: [(2,1),(3,2),(4,3),(5,4),(6,5),(7,6)]
Time: 1.00241912s
```

There are still many more improvements to be made here:

  * Avoid spawning threads for merely shuffling elements between queues, e.g.
    `shardQ{In, Out}` above;
  * Avoid copying elements between queues;
  * Back-pressure;
  * Batching.

I believe all these problems can be solved by choosing a better concurrent queue
data structure than `TQueue`, so that's what we'll have a look at next.

## Disruptor

The `Disruptor*` modules are a Haskell port of the [LMAX
Disruptor](https://github.com/LMAX-Exchange/disruptor), which is a high
performance inter-thread messaging library. The developers at LMAX, which
operates a financial exchange,
[reported](https://www.infoq.com/presentations/LMAX/) in 2010 that they could
process more than 100,000 transactions per second at less than 1 millisecond
latency.

At its core it's just a lock-free concurrent queue, but it also provides
building blocks for achieving several useful concurrent programming tasks that
typical queues don't (or at least don't make obvious how to do). The extra
features include:

  * Multi-cast (many consumers can in parallel process the same event);
  * Batching (both on producer and consumer side);
  * Back-pressure;
  * Sharding for scalability;
  * Dependencies between consumers.

It's also performs better than most queues, as we shall see further down.

### Example

```haskell
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
```

You can run the above example with `cabal run readme-disruptor-example`.

A couple of things we could change to highlight the features we mentioned in the
above section:

  1. Add a second consumer that saves the event to disk, this consumer would be
     slower than the current one which logs to the terminal, but we could use
     buffer up events in memory and only actually write when the end of batch
     flag is set to speed things up;

  2. We could also shard depending on the sequence number, e.g. have two slower
     consumers that write to disk and have one of them handle even sequence numbers
     while the other handles odd ones;

  3. The above producer writes one event at the time to the ring buffer, but
     since we know at which sequence number the last consumer is at we can
     easily make writes in batches as well;

  4. Currently the producer doesn't apply any back-pressure when the ring buffer
     is full, in a more realistic example where the producer would, for example,
     create events from requests made to a http server we could use
     back-pressure to tell the http server to return status code 429 (too many
     requests);

  5. If we have one consumer that writes to the terminal and another one that
     concurrently writes to disk, we could add a third consumer that does
     something with the event only if it has both been logged and stored to disk
     (i.e. the third consumer depends on both the first and the second).

### How it works

The ring buffer is implemented using a bounded array, it keeps track of a
monotonically increasing sequence number and it knows its the capacity of the
array, so to find out where to write the next value by simply taking the modulus
of the sequence number and the capacity. This has several advantages over
traditional queues:

  1. We never remove elements when dequeing, merely overwrite them once we gone
     all way around the ring. This removes write
     [contention](https://en.wikipedia.org/wiki/Resource_contention) between the
     producer and the consumer, one could also imagine avoiding garbage
     collection by only allocating memory the first time around the ring (but we
     don't do this in Haskell);

  2. Using an array rather than linked list increasing
     [striding](https://en.wikipedia.org/wiki/Stride_of_an_array) due to
     [spatial
     locality](https://en.wikipedia.org/wiki/Locality_of_reference#Spatial_and_temporal_locality_usage).

The ring buffer also keeps track of up to which sequence number its last
consumer has consumed, in order to not overwrite events that haven't been handled
yet.

This also means that producers can ask how much capacity left a ring buffer has,
and do batched writes. If there's no capacity left the producer can apply
back-pressure upstream as appropriate.

Consumers need keep track of which sequence number they have processed, in order
to avoid having the ring buffer overwrite unprocessed events as already
mentioned, but this also allows consumers to depend on each other.

When a consumer is done processing an event, it asks the ring buffer for the
event at its next sequence number, the ring buffer then replies that either
there are no new events, in which case the consumer applies it wait strategy, or
the ring buffer can reply that there are new events, the consumer the handles
each one in turn and the last one will be have the end of batch flag set, so
that the consumer can effectively batch the processing.

### Performance

Our Disruptor implementation, which hasn't been optimised much yet, is about 2x
slower than LMAX's Java version on their single-producer single-consumer
[benchmark](https://github.com/LMAX-Exchange/disruptor/blob/master/src/perftest/java/com/lmax/disruptor/sequenced/OneToOneSequencedThroughputTest.java)
(1P1C) (basically the above example) on a couple of years old Linux laptop.

The same benchmark compared to other Haskell libraries:

  * 10.3x faster than
    [`Control.Concurrent.Chan`](https://hackage.haskell.org/package/base-4.15.0.0/docs/Control-Concurrent-Chan.html);

  * 8.3x faster than
    [`Control.Concurrent.STM.TBQueue`](https://hackage.haskell.org/package/stm/docs/Control-Concurrent-STM-TBQueue.html);

  * 1.7x faster than
    [`unagi-chan`](https://hackage.haskell.org/package/unagi-chan);

  * 25.5x faster than
    [`chaselev-deque`](https://hackage.haskell.org/package/chaselev-deque);

  * 700x faster than [`ring-buffer`](https://hackage.haskell.org/package/ring-buffer);

  * 1.3x slower than
    [`lockfree-queue`](https://hackage.haskell.org/package/lockfree-queue);

  * TODO: Compare with
    [`data-ringbuffer`](https://github.com/kim/data-ringbuffer/tree/master/src/Data/RingBuffer).

In the triple-producer single-consumer (3P1C)
[benchmark](https://github.com/LMAX-Exchange/disruptor/blob/master/src/perftest/java/com/lmax/disruptor/sequenced/ThreeToOneSequencedThroughputTest.java),
the Java version is 5x slower than the Java 1P1C case. And our 3P1C is 4.6x
slower than our 1P1C version and our 3P1C version is 2.7x slower than the Java
version.

The same benchmark compared to other Haskell libraries:

  * 73x faster than
    [`Control.Concurrent.Chan`](https://hackage.haskell.org/package/base-4.15.0.0/docs/Control-Concurrent-Chan.html);

  * 3.5x faster than
    [`Control.Concurrent.STM.TBQueue`](https://hackage.haskell.org/package/stm/docs/Control-Concurrent-STM-TBQueue.html);

  * 1.3x faster than
    [`unagi-chan`](https://hackage.haskell.org/package/unagi-chan);

  * 1.9x faster than
    [`lockfree-queue`](https://hackage.haskell.org/package/lockfree-queue).

For a slightly more "real world" example, we modified the 3P1C test to have
three producers that log messages while the consumer writes them to a log file
and compared it to
[`fast-logger`](https://hackage.haskell.org/package/fast-logger). The
`pipelined-state-machines` benchmark has a throughput of 3:4 that of
`fast-logger`. When we bump it to ten concurrently logging threads the
`pipelined-state-machines` benchmark has a throughput of 10:7 that of
`fast-logger`.

See the file [`benchmark.sh`](benchmark.sh) for full details about how the
benchmarks are run.

As always take benchmarks with a grain of salt, we've tried to make them as fair
with respect to each other and as true to the original Java versions as
possible. If you see anything that seems unfair, or if you get very different
results when trying to reproduce the numbers, then please file an issue.

## Contributing

There's a lot of possible paths to explore from here, including:

- [ ] Can we swap out our use of `TQueue` for `Disruptor` in our `deploy` of
      `P`ipelines?
- [ ] Can we add something like a `FanOut :: P a b -> P a c -> P a (b, c)` and a
      `Par :: P a c -> P b d -> P (a, b) (c, d)` combinator to allow two
      parallel queues?
- [ ] What about sum-types and error handling?
- [ ] Our current, and the above just mentioned, pipeline combinators are all
      binary to can we generalise this to N-ary?
- [ ] Can we visualise pipelines using `dot` or similar?
- [ ] Can we build a performance/cost simulator of pipelines?
- [ ] Arrow syntax or monadic DSL for pipelines?
- [ ] We've seen
      [previously](https://github.com/stevana/hot-swapping-state-machines) how
      we can hot-code upgrade state machines, what about hot-code upgrading
      pipelines?
- [ ] Can we implement the Erlang `gen_event` behaviour using Disruptor?
- [ ] Would it make sense to use the spiritual successor of the Disruptor
      instead, i.e. the different array queues from `aeron` and `agrona`:
  + [Single-producer
    single-consumer](https://github.com/real-logic/agrona/blob/master/agrona/src/main/java/org/agrona/concurrent/OneToOneConcurrentArrayQueue.java);
  + [Multiple-producers
    single-consumer](https://github.com/real-logic/agrona/blob/master/agrona/src/main/java/org/agrona/concurrent/ManyToOneConcurrentArrayQueue.java);
  + [Multiple-producers
    multiple-consumers](https://github.com/real-logic/agrona/blob/master/agrona/src/main/java/org/agrona/concurrent/ManyToManyConcurrentArrayQueue.java).
- [ ] How exactly do these pipelines relate to the libraries
      [`pipes`](https://hackage.haskell.org/package/pipes),
      [`conduit`](https://hackage.haskell.org/package/conduit) and
      [`streamly`](https://hackage.haskell.org/package/streamly)?
- [ ] How does it relate to synchronous programming languages such as
      [Esterel](https://en.wikipedia.org/wiki/Esterel),
      [Lustre](https://en.wikipedia.org/wiki/Lustre_(programming_language)),
      [ReactiveML](https://rml.lri.fr), etc? It seems to me that their main
      motivation is to be concurrent or parallel while still determinstic, which
      is what we'd like as well. Looking at ReactiveML's documentation for
      [compositions](https://rml.lri.fr/documentation.html#compositions) we see
      the same constructs as we've discussed: their `;` is our `Compose` (with
      its arguments flipped), their `||` is our `FanOut`, their `|>` is our
      `:>>>` and their `let-and` construct could be achived by adding projection
      functions to our `P`ipelines similar to `Fst` and `Snd` for `SM`.
      Interestingly they don't have any sum-types-like construct here, i.e.
      something like `(:|||) :: P a c -> P b c -> P (Either a b) c`;
- [ ] I like to think of how one constructs a pipeline, i.e. the choice of which
      tasks should happen in parallel or should be sharded etc, as a choice of
      how to best make use of the CPUs/cores of a single computer. If seen this
      way then that begs the question: what about a network of multiple
      computers? Perhaps there should be something like a `Topology` data type
      which describes how multiple pipelines interact and a topology is deployed
      by deploying multiple pipelines over multiple machines?

## See also

### Presentations

  * [LMAX - How to Do 100K TPS at Less than 1ms
    Latency](https://www.infoq.com/presentations/LMAX/) by Martin Thompson (QCon
    2010);

  * [LMAX Disruptor and the Concepts of Mechanical
    Sympathy](https://youtube.com/watch?v=Qho1QNbXBso) by Jamie Allen (2011);

  * [Concurrent Programming with the
    Disruptor](https://www.infoq.com/presentations/Concurrent-Programming-Using-The-Disruptor/)
    by Trisha Gee (2012);

  * [Disruptor 3.0: Details and Advanced
    Patterns](https://youtube.com/watch?v=2Be_Lqa35Y0) by Mike Barker (YOW!
    2013);

  * [Designing for Performance](https://youtube.com/watch?v=fDGWWpHlzvw) by
    Martin Thompson (GOTO 2015);

  * [A quest for predictable latency with Java
    concurrency](https://vimeo.com/181814364) Martin Thompson
    (JavaZone 2016);

  * [Evolution of Financial Exchange
     Architectures](https://www.youtube.com/watch?v=qDhTjE0XmkE) by Martin
     Thompson (QCon 2020)
      + 1,000,000 tx/s and less than 100 microseconds latency, he is no longer
        at LMAX though so we don't know if these exchanges are using the
        disruptor pattern.

  * [*Aeron: Open-source high-performance
    messaging*](https://youtube.com/watch?v=tM4YskS94b0) talk by Martin Thompson
    (Strange Loop, 2014);

  * *Aeron: What, Why and What Next?*
    [talk](https://youtube.com/watch?v=p1bsloPeBzE) by Todd Montgomery (GOTO,
    2015);

  * *Cluster Consensus: when Aeron met Raft*
    [talk](https://youtube.com/watch?v=GFfLCGW_5-w) by Martin Thompson (GOTO,
    2018);

  * *Fault Tolerant 24/7 Operations with Aeron Cluster*
    [talk](https://youtube.com/watch?v=H9yqzfNiEb4) by Todd Montgomery (2022).

### Writings

  * Martin Thompson's [blog](https://mechanical-sympathy.blogspot.com/);
  * The Disruptor [mailing list](https://groups.google.com/g/lmax-disruptor);
  * The Mechanical Sympathy [mailing list](https://groups.google.com/g/mechanical-sympathy);
  * [The LMAX Architecture](https://martinfowler.com/articles/lmax.html) by
    Martin Fowler (2011);
  * [Staged event-driven
    architecture](https://en.wikipedia.org/wiki/Staged_event-driven_architecture);
  * [The Reactive Manifesto](https://www.reactivemanifesto.org/).
