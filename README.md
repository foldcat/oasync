# oasync

![badge](https://img.shields.io/badge/documentation%20taken%20seriously-ff7eb6)

M:N multithreading for Odin. The end goal is to implement virtual threads that 
automatically and quickly parallelize tasks across several os threads.

Now back in active development!

## features
- dispatch tasks throughout a thread pool with load balancing
- supports blocking task pool and scheduling tasks to run in the future
- depends on ONLY the Odin compiler (just like any Odin libraries)
- 100% api docs coverage + walkthough (see below)
- simple and easy to use API
- codebase kept small and commented for those who want to know how oasync works internally

## walkthrough
Note that this library is in a **PRE ALPHA STATE**. It lacks essential features,
may cause segmented fault, contains breaking changes, and probably has house major bugs.

However, please test it out and provide feedbacks and bug reports! Do not hesitate 
if you want to suggest new features, make an issue right here!

Note that oasync is NOT compatable with `core:sync` and any blocking codebase, including 
and not limited to channels (an oasync native implementation of channels is available). 
Native implementation/alternative of many constructs are planned.

In the examples below, we will be importing oasync as so: 
```odin 
import oa "../oasync"
```

Besides the walkthough, I **HEAVILY** recommend doing `odin doc .` in the 
root directory of oasync to read the API documentation. The following 
walkthough does not cover every procedure and their options.

### core functionalities
#### initializing oasync runtime
To use oasync, we first have to initialize it. Note that the following examples 
will all be executed with the following configuration.
```odin
main :: proc() {
    // create a coordinator struct for oasync to store 
    // its internal state
    // should NOT be modified by anything but oasync
    coord: oa.Coordinator
    oa.init_oa(
        // pass in the coordinator
        &coord,
        // what procedure to dispatch when oasync starts
        init_fn = core,
        // a rawptr that will be passed into the init_fn
        init_fn_arg = nil,
        // amount of worker threads oasync will run
        // omit this field or set to 0 for oasync to use 
        // os.processor_core_count() as its value
        max_workers = 4,
        // how many blocking taskes should be allowed 
        // to execute at the same time
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
```odin
foo :: proc(_: rawptr) {
	fmt.println("hi")
}

core :: proc(_: rawptr) {
	fmt.println("core")
	oa.go(foo) 
}
```

#### passing in arugments
It is trival to pass arguments into tasks. The lack of typesafety 
is due to the simplicity of the Odin language.
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
long time to finish, this should be avoided because it hogs 
our scheduler and leaving one of our threads out of commission.
This is why we should spawn blocking tasks in this situation.
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
at the same time, ensuring there are always room for non blocking 
tasks to run.

#### timed schedule
It is possible to delay the execution of a task without needing
`time.sleep()`, which hogs our scheduler. 
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
i.e. tasks are not garenteed to execute at percisely the tick passed into it.


#### unsafe dispatching
You might want to spawn virtual tasks outside of threads managed 
by oasync, we call this unsafe dispatching:
```odin
task :: proc(_: rawptr) {
	fmt.println("hi")
}

main :: proc() {
	coord: oa.Coordinator
	// some arguments has default options, see api docs
	oa.init_oa(&coord, init_fn = core, use_main_thread = false)
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
in a virtual task.
```odin
oa.oa_shutdown()
```
Should `use_main_thread` be true, this will wait for the main 
thread to terminate instead of calling `thread.terminate`, 
causing additional wait time for the procedure to yield.

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
will not hog the scheduler unlike `core:sync`. Some primitives are 
provided by `../oasync` and others are provided by `../oasync/sync`
```odin
import oas "../oasync/sync"
```

Each destructor procedure may have unexpected behaviors, it 
is recommended to seek API documentations.

Note that you should NEVER use the primitives after calling the
destructor procedures, since it may cause segmented fault.

#### resources 
Resources are equivalent to mutexes, where only one task is allowed to access 
each resource, and said resource will be released upon task completion
automatically. This will not hog the scheduler.

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
	// in real world, use the blocking pool
	oa.go(acquire1, acq = res)
	oa.go(acquire2, acq = res)
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
another task to acquire the same resource while a it is acquired.

Resource is allocated on the heap, call `free_resouce()` in order to 
destroy it.

#### backpressure
Backpressure allows us to rate limit task spawns.

There are two strategies for backpressure: Lossy and Loseless.
- Lossy: task will be ran in presence of backpressure
- Loseless: task will not execute until backpressure is alleviated.

Use `oa.destroy_bp` to free it.

```odin
foo :: proc(a: rawptr) {
    // reminder to never time.sleep outside of a 
    // blocking pool
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

#### cyclic barrier
Cyclic barriers are re-usable synchronization primitives 
that allows a set amount of tasks to wait until they've all reached the same point.

Use `oa.destroy_cb` to free it.

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

Note that this is not typesafe due to how `rawptr` is used for 
polymorphism. It is also known that the order of elements placed 
into the channel may not be sequencially consistant.
```odin
consumer :: proc(a: rawptr) {
	input := (cast(^int)a)^
	fmt.println(input)
}

core :: proc(_: rawptr) {
	chan := oas.make_chan(consumer)
	oas.c_put(chan, 1)
	oas.c_put(chan, 2)
	oas.c_put(chan, 3)
}
```

In order to shutdown the channel, `c_stop()` may be used. 
