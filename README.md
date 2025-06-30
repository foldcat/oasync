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
- small and commented codebase for those who want to know how oasync works internally

## usage
Note that this library is in a **PRE ALPHA STATE**. It lacks essential features,
may cause segmented fault, contains breaking changes, and probably has house major bugs.

However, please test it out and provide feedbacks and bug reports!

Note that oasync is NOT compatable with `core:sync` and any blocking codebase, including 
and not limited to channels. Native implementation/alternative of said constructs are 
planned.

In the examples below, we will be importing oasync as so: 
```odin 
import oa "../oasync"
```

Besides the walkthough, I **HEAVILY** recommend doing `odin doc .` in the 
root directory of oasync to read the API documentation. The following 
walkthough does not cover every procedure and their options.

### initializing oasync runtime
To use oasync, we first have to initialize it. 
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

### running new tasks
You might want to spawn tasks in the middle of a task, doing 
this is simple and easy.

```odin
foo :: proc(_: rawptr) {
	fmt.println("hi")
}

core :: proc(_: rawptr) {
	fmt.println("core")
	// foo is the task we want to spawn 
	// nil is the argument passed into it, rawptr as always 
	// you may omit it as default parameter of it is nil
	oa.go(foo, nil) 
}
```

### blocking tasks
Sometimes you may want to run blocking tasks that takes a 
long time to finish, this should be avoided because it hogs 
up our scheduler and leaving one of our threads out of commission.
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
at the same time, ensuring there is always rooms for non blocking 
tasks to run.

### timed schedule
It is possible to delay the execution of a task without hogging 
threads with `time.sleep()`. 
```odin
stuff :: proc(a: rawptr) -> {
	fmt.println("done!", (cast(^int)a)^)
}

core :: proc(_: rawptr) {
	fmt.println("started")
	for i in 0 ..= 20 {
		data := new_clone(i, context.temp_allocator)
		next := time.tick_add(time.tick_now(), 5 * time.Second)
		oa.go(stuff, data, exe_at = next)
	}
}
```
Note that timed tasks will execute *during* or *after* the tick you supplied, 
i.e. tasks are not garenteed to execute at percisely the tick passed into it.

### passing in arugments
It is trival to pass arguments into tasks. As Odin is a simple 
language, this could only be done via a `rawptr`.
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

### unsafe dispatching
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

### shutdown
Shutting down oasync can be done by executing the following 
in a virtual task.
```odin
oa.oa_shutdown()
```
Should `use_main_thread` be true, this will wait for the main 
thread to terminate instead of calling `thread.terminate`, 
causing additional wait time for the procedure to yield.

### context system
To spawn tasks, oasync injects info into `context.user_ptr`. 
This means that you should NEVER change it. Should you still 
wish to use `context.user_ptr`, we offer a way to do so.
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
