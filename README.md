# oasync

M:N multithreading for Odin. The end goal is to implement virtual threads that 
automatically and quickly parallelize tasks across several os threads.

## notice

Exam extended, and I'm failing it.

Active development may resume early May.

## usage
Note that this library is in **PRE ALPHA STATE**. It lacks essential features 
and may randomly cause segmented faults.

However, please test it out and provide feedbacks and bug reports!

In the examples below, we will be importing Oasync as so: 
```odin 
import oa "../oasync"
```

### seting up the coordinator
```odin
// coordinators are the heart of oasync!
coord := oa.Coordinator{}

// the following examples will use this configuration:
// it will be using
// 4 (generic worker) + 2 (blocking worker) + 1 (main thread) = 7 threads

cfg := oa.Config {
  // amount of threads to use
  worker_count          = 4,

  // amount of threads to use for blocking
  blocking_worker_count = 2,

  // use the main thread as a worker 
  // this prevents the program from exiting immediately
  use_main_thread       = true,
}
```

### fire off the first task
```odin 
core :: proc() {
  // starting point!
}

// multiple coordinator can be spawned at the same time 
// as they are self contained 
// coordinators will not interract with each other
oa.init(&coord, cfg, oa.make_task(core))
```

###  running a virtual task 
```odin
child :: proc() {
	fmt.println("hello from child!")
}

// DO NOT do this outside of threads managed by the coordinator
oa.go(child)
```

### passing argument into another virtual task 
```odin 
// odin lacks the typesystem to express this in a type safe manner
// thus we pass data as a rawptr
child :: proc(raw_data: rawptr) {
	data := cast(^string)raw_data
	fmt.println(data^)
}

// we need to allocate on the heap as the stack gets destroyed upon 
// function finishing
// we allocate with temp allocator since the default allocator in a virtual task
// is swapped with an arena allocator
// the allocator resets itself upon task finishing execution
data := new_clone("pass data into childs threads~", context.temp_allocator)
oa.go(child2, data)
```

### blocking tasks 
```odin 
// some actions blocks the worker, if too many blocking tasks are running, 
// it will paralyse the coordinator!
// please keep every task as short as possible to prevent this~

// if blocking is necessary,
blocking_child :: proc() {
	time.sleep(2 * time.Second)
	fmt.println("blocking child finishes!")
}

// use a blocking worker instead
for i in 1 ..= 4 {
	oa.gob(blocking_child)
}

// output: 
// after 2 seconds...
// blocking child finishes!
// blocking child finishes!
// after 2 more seconds...
// blocking child finishes!
// blocking child finishes!

// blocking workers are a seprate pool of workers, this will make sure 
// there are still rooms for non blocking tasks out there to run!


blocking_child_witharg :: proc(arg: rawptr) {}
// note that you can also pass in a rawptr: 
oa.gob(blocking_child_witharg, input)

// don't worry, they will still be used to perform non-blocking tasks 
// when there are no blocking tasks! 
// of course, this is slightly slower than generic workers, but they 
// are trying their best so don't judge~
```

### unsafe dispatching 
```odin
// sometimes you are in threads not managed by the coordinator,
// but you still want to spawn virtual tasks

// you can do this:
task :: proc() {}
// pass in the coordinator into the last argument!
unsafe_go(task, &coord)
unsafe_gob(task, &coord)

task_witharg :: proc(arg: rawptr) {}
unsafe_go(task, input, &coord)
unsafe_gob(task, input, &coord)

// this really isn't unsafe in the sense that it might cause crashes:
// this is just slower than dispatching normally...
// avoid this as much as possible!

// if these procedures are called before initializing the coordinator, 
// they will be ran when the coordinator gets initialized
// note that this might cause the procedure passed in oa.init 
// to not be run before anything does!
```

### context system
```odin 
// we inject a pointer to a struct named Ref_Carrier into context.user_ptr
// please do NOT modify it!

// if you want to use that field still, cast said pointer 
// into a Ref_Carrier and use the user_ptr field stored inside it 
// please do NOT touch the worker field!

// however, this is still not recommended as context persist 
// across workers and NOT singular virtual threads!
// same applies to ANYTHING related to the context system!
ref_carrier := cast(^Ref_Carrier)context.user_ptr
ref_carrier.user_ptr = ...
```
