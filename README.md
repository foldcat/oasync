# oasync

![badge](https://img.shields.io/badge/documentation%20taken%20seriously-ff7eb6)

Welcome to the `new-blocking-behavior` branch. This branch contains a complete 
recode of certain features, and *will* produce runtime crashes. Seek the `master`
branch for a less-likely-to-crash codebase. 

M:N multithreading for Odin. The end goal is to implement virtual threads that 
automatically and quickly parallelize tasks across several os threads.

Now back in active development!

## usage
Note that this library is in a **PRE ALPHA STATE**. It lacks essential features 
and may randomly cause segmented faults.

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
	coord: oa.Coordinator
	oa.init_oa(
		&coord,
		init_fn_arg = nil,
		init_fn = core,
		max_workers = 4,
		max_blocking = 2,
		use_main_thread = true,
  	)
}

core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("test")
	return oa.B_None{}
}
```

### dissection
This may look intimidating at first, but it is quite simple. 
Let's dissect it.

#### initializing
```odin
// entry point of our program
main :: proc() {
	// create a coordinator, we may use it later
	coord: oa.Coordinator

	// initialize the coordinator, see 
	// api docs for default options and what they do
	oa.init_oa(
		// pass in the coordinator
		&coord, 
        	// pass in the procedure
        	// we want to execute immediately 
		// after oasync initializes
		init_fn = core,
        	// the rawptr we want to pass in the procedure
		init_fn_arg = nil,
		// maximum amount of workers oasync may spawn
		max_workers = 4,
		// maximum amount of blocking workers oasync may spawn
		max_blocking = 2,
		// to hog the main thread or yield immediately,
		// in this case, we hog the main thread
		// the main thread count as another extra worker
		// that doesn't contribute to max_workers
        	use_main_thread = true,
  	)
}
```

#### behaviors

Lets take a look at the procedure `core` that we need to 
execute immediately after the oasync runtime initializes.

```odin
core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("goodbye world~")
	return oa.B_None{}
}
```
This one is quite simple. The argument passed in this procedure 
will be the `init_fn_arg` from `init_oa`. You may ask: Why is it a 
`rawptr`? To put it simply, Odin's simplisic type system and the 
lack of metaprogramming support doesn't let me do this in a 
type safe manner like how it's done in Scala.

This procedure also returns an `oa.Behavior`. `oa.Behavior` dictates
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

#### running new tasks

You might want to spawn tasks in the middle of a task, doing 
this is very simple.

```odin
foo :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("hi")
	return oa.B_None{}
}

core :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("core")
	// foo is the task we want to spawn 
	// nil is the argument passed into it, rawptr as always 
	// you may omit it as it defaults to nil
	oa.go(foo, nil) 
	return oa.B_None{}
}
```

#### blocking tasks
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
		oa.gob(blocking)
	}
	return oa.B_None{}
}
```
We only allow `max_blocking` amount of blocking task to run 
at the same time, ensuring there is always rooms for non blocking 
tasks to run.

#### passing in arugments
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

#### unsafe dispatching
You might want to spawn virtual tasks outside of threads managed 
by oasync. This can be done via `unsafe`:
```odin
task :: proc(_: rawptr) -> oa.Behavior {
	fmt.println("hi")
	return oa.B_None{}
}

main :: proc() {
	coord: oa.Coordinator
	// some arguments has default options, see api docs
	oa.init_oa(&coord, init_fn = core, use_main_thread = false)
	oa.unsafe_go(&coord, task)
	// hog the main thread to prevent exiting immediately
	time.sleep(1 * time.Second)
}
```
`unsafe` in this case doesn't mean it will cause segfaults, 
instead, it comes with performance panelity. Avoid this as much 
as possible.

#### context system
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
