# oasync

![badge](https://img.shields.io/badge/documentation%20taken%20seriously-ff7eb6)

M:N multithreading for Odin. The end goal is to implement virtual threads that 
automatically and quickly parallelize tasks across several os threads.

Now back in active development!

## usage
Note that this library is in a **PRE ALPHA STATE**. It lacks essential features,
may segmented fault, and has **major** bugs.

However, please test it out and provide feedbacks and bug reports!

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
core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("test")
	return oa.B_None{}
}
```

### behaviors

Lets take a look at the procedure `core` that we need to 
execute immediately after the oasync runtime initializes.

```odin
core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("goodbye world~")
	return oa.B_None{}
}
```
This procedure returns an `oa.Behavior`. `oa.Behavior` dictates
what oasync does *after* the execution of a task. In this 
case, `oa.B_None` means "do nothing after core finishes execution".

We can use behavior to achieve callbacks:
```odin
core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("core")
	return oa.B_Cb{effect = nextproc}
}

nextproc :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("nextproc")
	return oa.B_None{}
}
```

### running new tasks

You might want to spawn tasks in the middle of a task, doing 
this is simple and easy.

```odin
foo :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("hi")
	return oa.B_None{}
}

core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("core")
	// foo is the task we want to spawn 
	// nil is the argument passed into it, rawptr as always 
	// you may omit it as default parameter of it is nil
	oa.go(foo, nil) 
	return oa.B_None{}
}
```

### blocking tasks
Sometimes you may want to run blocking tasks that takes a 
long time to finish, this should be avoided because it hogs 
up our scheduler and leaving one of our threads out of commission.
This is why we should spawn blocking tasks in this situation.
```odin
blocking :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("done")
	time.sleep(1 * time.Second)
	return oa.B_None{}
}

core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("test")
	for _ in 1 ..= 4 {
		oa.go(blocking, block = true)
	}
	return oa.B_None{}
}
```
We only allow `max_blocking` amount of blocking task to run 
at the same time, ensuring there is always rooms for non blocking 
tasks to run.

### passing in arugments
It is trival to pass arguments into tasks. As Odin is a simple 
language, this could only be done via a `rawptr`.
```odin
foo :: proc(a: rawptr) -> oa.Behavior {
	arg := cast(^string)a
	fmt.println(arg^)
	return oa.B_None{}
}

core :: proc(_: rawptr) -> oa.Behavior {
	// remember to free it
	nextarg := new_clone("hi", context.temp_allocator)
	oa.go(foo, nextarg)
	return oa.B_None{}
}
```

### unsafe dispatching
You might want to spawn virtual tasks outside of threads managed 
by oasync, we call this unsafe dispatching:
```odin
task :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("hi")
	return oa.B_None{}
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
By supplying go with a coordinator, it will be capable of 
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
core :: proc(_: rawptr) -> oa.Behavior {
	// cast it into a ref carrier
	ptr := cast(^oa.Ref_Carrier)context.user_ptr
	// ONLY access the user_ptr field 
	// do NOT access other fields in Ref_Carrier
	ptr.user_ptr := ...
	return oa.B_None{}
}
```

However, please note that the context in a task will not be 
carried over to another task spawned. See below for a 
demonstration.
```odin
core :: proc(_: rawptr) -> oa.Behavior {
	context.user_index = 1
	oa.go(stuff)
	return oa.B_None{}
}

stuff :: proc(_: rawptr) -> oa.Behavior {
	fmt.println(context.user_index) // 0
	return oa.B_None{}
}
```
