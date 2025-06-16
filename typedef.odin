package oasync

import vmem "core:mem/virtual"
import "core:sync"
import "core:thread"

// assigned to each thread
@(private)
Worker :: struct {
	barrier_ref:      ^sync.Barrier,
	thread_obj:       ^thread.Thread,
	localq:           Local_Queue(Task, LOCAL_QUEUE_SIZE),
	run_next:         Task,
	id:               u8,
	coordinator:      ^Coordinator,
	is_blocking:      bool,
	is_stealing:      bool,
	hogs_main_thread: bool,
}

// behavior dictates what to do *after* the task is done, 
// for example, callbacks
Behavior :: union {
	B_None,
	B_Cb,
	B_Cbb,
}

// do nothing
B_None :: struct {
}

// callback to a function
B_Cb :: struct {
	effect: proc(input: rawptr) -> Behavior,
	supply: rawptr,
}

// callback to a function, blocking
B_Cbb :: struct {
	effect: proc(input: rawptr) -> Behavior,
	supply: rawptr,
}

// types of behavior
Btype :: enum {
	// do nothing
	Noop,
	// execute another task upon the current task ending
	Callback,
}

@(private)
Task :: struct {
	// void * generic
	// sometimes i wish for a more complex type system
	effect:      proc(input: rawptr) -> Behavior,
	arg:         rawptr,
	is_blocking: bool,
	is_done:     bool,
	// for debug
	id:          int,
}

/* 
coordinates workers for dispatching virtual threads and 
executing tasks
should not be accessed
*/
Coordinator :: struct {
	workers:            []Worker,
	is_running:         bool,
	worker_count:       int,
	globalq:            Global_Queue(Task),
	steal_count:        int,
	max_steal_count:    int,
	max_blocking_count: int,
}

/*
controls the behavior of a coordinator,
mutating this upon calling init has no effect 
on its behavior
*/
Config :: struct {
	// amount of threads to run tasks
	worker_count:          int,
	// amount of threads to run blocking tasks
	blocking_worker_count: int,
	// use the main thread as a worker 
	// prevents immediate exit of a program
	use_main_thread:       bool,
}

/*
injected into context.user_ptr, overriding its content
the user_ptr field can be modified by an user in any way,
however, the worker field should not be accessed
*/
Ref_Carrier :: struct {
	worker:   ^Worker,
	user_ptr: rawptr,
}
