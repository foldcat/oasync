<picture>
  <source media="(prefers-color-scheme: dark)" width="50%" height="auto" srcset="https://github.com/user-attachments/assets/5f3989b2-c89e-4961-a485-d05915c3829e">
  <img alt="logo" width="50%" height="auto" src="https://github.com/user-attachments/assets/251c7ad8-25e4-4453-bc4a-bb487205eb4e">
</picture>

---

![badge](https://img.shields.io/badge/documentation%20taken%20seriously-ff7eb6) ![Static Badge](https://img.shields.io/badge/odin_version-dev--2025--07-blue)

Now officially in beta state!

M:N multithreading for Odin. The end goal is to implement virtual threads that 
automatically and quickly parallelize tasks across several os threads.

Feel free to report bugs and request features by creating issues!

Also note that oasync is NOT compatable with `core:sync`. Please use 
the synchronization primitives provided by oasync instead.

## features
- quickly and automatically parallelize tasks across a thread pool
- supports blocking task pool and scheduling tasks to run in the future
- depends on ONLY the Odin compiler (just like any Odin libraries)
- 100% API documentation coverage
- simple and easy to use API
- small and commented codebase

## walkthrough
It is **HEAVILY** recommend to execute `odin doc .` in the 
root directory of oasync to read the API documentation. The following 
walkthough does not cover every procedure and their options.

In the examples below, we will be importing oasync as so: 
```odin 
import oa "../oasync"
```

### core functionalities
#### initializing oasync runtime
To use oasync, we first have to initialize it. Note that the following examples 
will all be executed with the following configuration.
```odin
main :: proc() {
    // create a coordinator struct for oasync to store 
    // its internal state
    // it should NOT be modified by the user
    coord: oa.Coordinator
    oa.init_oa(
        // coordinator
        &coord,
        // what procedure to dispatch when oasync starts
        init_proc = core,
        // a rawptr that will be passed into the init_proc
        init_proc_arg = nil,
        // amount of worker threads oasync will run
        // omit this field or set to 0 for oasync to use 
        // os.processor_core_count() as its value
        max_workers = 4,
        // how many blocking taskes should be allowed 
        // to execute at the same time
        // set as 0 for oasync to use max_workers / 2 
        // as its value
        max_blocking = 2,
        // whether to use the main thread as a worker or not, 
        // counts toward max_workers
        use_main_thread = true,
    )
}

// the task to run
core :: proc(_: rawptr) {
	fmt.println("test")
	return oa.B_None{}
}
```

#### running new tasks
It is quite simple to spawn new tasks.

Note that the order of task spawning is not guaranteed
to be the same as the order of `oa.go` calls.
```odin
foo :: proc(_: rawptr) {
	fmt.println("hi")
}

core :: proc(_: rawptr) {
	fmt.println("core")
	oa.go(foo) 
}
```

#### passing in arguments
It is trival to pass arguments into tasks.
```odin
foo :: proc(a: rawptr) {
	arg := cast(^string)a
	fmt.println(arg^)
}

core :: proc(_: rawptr) {
	// remember to free it
	nextarg := new_clone("hi", context.temp_allocator)
	oa.go(foo, nextarg)
}
```

#### blocking tasks
Sometimes you may want to run blocking tasks that takes a 
long time to complete, this should be avoided as it hogs 
the scheduler and leaves one of our threads out of commission.
One should use `blocking` in this situation.
```odin
blocking :: proc(_: rawptr) {
	time.sleep(1 * time.Second)
	fmt.println("done")
}

core :: proc(_: rawptr) {
	fmt.println("test")
	for _ in 1 ..= 4 {
		oa.go(blocking, block = true)
	}
}
```
We only allow `max_blocking` amount of blocking task to run 
simultaneously, allowing non-blocking tasks to execute under load.

#### timed schedule
It is possible to delay the execution of a task without needing
`time.sleep()`, as `time.sleep()` hogs the scheduler.
```odin
stuff :: proc(a: rawptr) {
	fmt.println("done!", (cast(^int)a)^)
}

core :: proc(_: rawptr) {
	fmt.println("started")
	for i in 0 ..= 20 {
		data := new_clone(i, context.temp_allocator)
		oa.go(stuff, data, delay = 5 * time.Second)
	}
}
```
Note that timed tasks will execute *during* or *after* the tick you supplied, 
i.e. tasks are not guaranteed to execute at percisely after 5 seconds.

#### unsafe dispatching
You might want to spawn tasks outside of threads managed 
by oasync, we call this unsafe dispatching:
```odin
task :: proc(_: rawptr) {
	fmt.println("hi")
}

main :: proc() {
	coord: oa.Coordinator
	// some arguments has default options, see api docs
	oa.init_oa(&coord, init_proc = core, use_main_thread = false)
	oa.go(&coord, task, coord = &coord)
	// hog the main thread to prevent exiting immediately
	time.sleep(1 * time.Second)
}
```
By supplying `go` with a coordinator, it will be capable of 
dispatching tasks outside of threads managed not by oasync.

This imposes a heavy performance penality and should be 
avoided.

#### shutdown
Shutting down oasync can be done by executing the following 
in a task.

```odin
oa.shutdown(graceful = true)
```

Shutdown is `graceful` by default, where the scheduler will wait for 
the current task to complete before destroying the worker. Should 
`graceful` be false, `thread.terminate()` will be called on worker 
threads immediately. It is known that non-`graceful` termination may 
result in memory leak and segmented fault.

Even with non-`graceful` shutdown, should `use_main_thread` be true,
the main thread will be terminated gracefully instead of calling 
`thread.terminate`, causing additional wait time for the 
procedure to yield.


### context system
To spawn tasks, oasync injects data into `context.user_ptr`. 
This means that you should NEVER change it. Should you still 
wish to use `context.user_ptr`, the following may be done.
```odin 
core :: proc(_: rawptr) {
	// cast it into a ref carrier
	ptr := cast(^oa.Ref_Carrier)context.user_ptr
	// ONLY access the user_ptr field 
	// do NOT access other fields in Ref_Carrier
	ptr.user_ptr := ...
}
```

However, please note that the context in a task will not be 
carried over to another task spawned. See below for a 
demonstration.
```odin
core :: proc(_: rawptr) {
	context.user_index = 1
	oa.go(stuff)
}

stuff :: proc(_: rawptr) {
	fmt.println(context.user_index) // 0
}
```

### synchronization primitives
We provide oasync native synchronization primitives. These primitives 
will not hog the scheduler unlike `core:sync`.

Each destructor procedure have special behaviors, thus it 
is recommended to seek API documentations.

Note that you should NEVER use the primitives after calling the
destructor procedures, since it may cause segmented fault.

The following examples uses `time.sleep()` for convenience sake. Please do 
not use `time.sleep()` for real world usage unless it is in a blocking task.

#### resources 
Resources are equivalent to mutexes, where only one task is allowed to access 
each resource, and said resource will be released upon task completion
automatically.

`free_resouce()` may be used to delete it.
```odin
acquire1 :: proc(_: rawptr) {
	fmt.println("first acquire")
	time.sleep(3 * time.Second)
	fmt.println("first release")
}

acquire2 :: proc(_: rawptr) {
	fmt.println("second acquire")
	time.sleep(3 * time.Second)
	fmt.println("second release")
}

core :: proc(_: rawptr) {
	fmt.println("started")

	res := oa.make_resource()
	oa.go(acquire1, res = res)
	oa.go(acquire2, res = res)
}

/*
started
first acquire
first release
second acquire
second release
*/
```

The order of acquire might be different, but it should be impossible for 
another task to acquire the same resource while it is acquired.

Note that it is possible to acquire / release a resource in the middle of 
a resources via a spinlock. This should be avoided, and should also be 
used in a blocking task.

```odin
res := oa.make_resource()

stuff :: proc(a: rawptr) {
	oa.res_spinlock_acquire(res)
	time.sleep(1 * time.Second)
	fmt.println("acquiring task done")
	oa.res_spinlock_release(res)
}


core :: proc(_: rawptr) {
	fmt.println("started")
	oa.go(stuff)
	oa.go(stuff)
}
```

#### backpressure
Backpressure allows us to rate limit task spawns.

There are two strategies for backpressure:
- Lossy: task will be ran in presence of backpressure
- Loseless: task will not execute until backpressure is alleviated.

Use `oa.destroy_bp()` to free it.

```odin
foo :: proc(a: rawptr) {
    time.sleep(3 * time.Second)
    fmt.println((cast(^int)a)^)
    free(a)
}

core :: proc(_: rawptr) {
    // allow only 3 tasks to run at the same time
    bp := oa.make_bp(3, .Lossy)
    for i in 1 ..= 5 {
        inp := new_clone(i)
        oa.go(foo, inp, bp = bp)
    }
}
```

#### count down latch 
Count down latches are one shot concurrency primitives that 
blocks any tasks waiting on it until `goal` tasks are waiting.

Use `delete_cdl()` to free it.

```odin
stuff :: proc(a: rawptr) {
  fmt.println("done!")
}

core :: proc(_: rawptr) {
  fmt.println("started")
  cdl := oa.make_cdl(2)

  oa.go(stuff, cdl = cdl)
  time.sleep(4 * time.Second)
  oa.go(stuff, cdl = cdl)
  time.sleep(6 * time.Second)
  // further acquires are allowed to execute immediately
  oa.go(stuff, cdl = cdl)
}
```

#### cyclic barrier
Cyclic barriers are re-usable synchronization primitives 
that allows a set amount of tasks to wait until they've all reached the same point.

Use `oa.destroy_cb()` to free it.

```odin
stuff :: proc(a: rawptr) {
    fmt.println("done!")
}

core :: proc(_: rawptr) {
    fmt.println("started")
    cb := oa.make_cb(2)

    for i in 1 ..= 2 {
        oa.go(stuff, cb = cb)
        time.sleep(1 * time.Second)
        oa.go(stuff, cb = cb)
        time.sleep(1 * time.Second)
    }
}

/* 
*nothing for 1 second*
done!
done!
*nothing for 2 seconds*
done!
done!
*/

```

#### channels
We offer many to one channels.

It is known that the order of elements placed 
into the channel may not be sequencially consistant.
```odin
consumer :: proc(a: rawptr) {
	input := (cast(^int)a)^
	fmt.println(input) 
}

core :: proc(_: rawptr) {
	chan := oa.make_chan(consumer)
	oa.c_put(chan, 1)
	oa.c_put(chan, 2)
	oa.c_put(chan, 3)
}
```

It is possible to make buffered sliding channels. Buffered 
sliding channels may only hold `capacity` amount of data.
When capacity is full, buffered sliding channels drops the 
last item to make room for new items.
```odin
consumer :: proc(a: rawptr) {
	input := (cast(^int)a)^
	time.sleep(1 * time.Second)
	fmt.println(input)
}

core :: proc(_: rawptr) {
	chan := oa.make_chan(consumer, capacity = 2)
	for i in 1 ..= 10 {
		oa.c_put(chan, i)
	}
}
```

In order to shutdown the channel, `c_stop()` may be used. 

#### task chaining 
It is possible to make a sequencial task chain acquire one or 
more primitives, releasing only after every single task completes.

```odin
stuff :: proc(a: rawptr) -> rawptr {
	time.sleep(1 * time.second)
	fmt.println("chained resource acquiring task done")
	return nil
}

stuff2 :: proc(a: rawptr) {
	fmt.println("single resource acquiring task done")
}

core :: proc(_: rawptr) {
	fmt.println("started")
	res := oa.make_resource()
	oa.go(stuff, stuff, stuff, res = res)
	oa.go(stuff2, res = res)
}
```

Note that chained executions require procedures returning a `rawptr`.
The return of the first procedure passed into `oa.go` will be passed 
to the next procedure, vice versa.
