package oasync

import "core:sync"
import "core:thread"
import "core:time"

/* 
coordinates workers for dispatching virtual threads and 
executing tasks
should not be accessed
*/
Coordinator :: struct {
	workers:            []Worker,
	is_running:         bool,
	worker_count:       int,
	globalq:            Global_Queue(^Task),
	max_blocking_count: int,
}

// assigned to each thread
@(private)
Worker :: struct {
	barrier_ref:      ^sync.Barrier,
	thread_obj:       ^thread.Thread,
	localq:           Local_Queue(^Task),
	current_running:  ^Task,
	run_next:         ^Task,
	id:               u8,
	coordinator:      ^Coordinator,
	is_blocking:      bool,
	is_stealing:      bool,
	hogs_main_thread: bool,
	rng_seed:         i32,
	task_id_gen:      u32,
}

// 16 bits wasted but we could work with this
// is a bit_field as it can be loaded by sync.atomic_load
Task_Id :: bit_field i64 {
	// used for unsafe dispatching or the first task dispatched
	is_empty:      bool | 8,
	parentless:    bool | 8,
	parent_worker: u8   | 8,
	task_id:       u32  | 32,
}

Task :: struct {
	// void * generic
	// sometimes i wish for a more complex type system
	effect:      proc(input: rawptr),
	arg:         rawptr,
	is_blocking: bool,
	is_done:     bool,
	id:          Task_Id,
	mods:        Task_Modifiers,
}

// modifiers of the tasks
Task_Modifiers :: struct {
	// if a task is scheduled to run later or not
	// this is NOT garenteed to execute at the exact tick
	execute_at:     time.Tick,

	// concurrency primitives
	resource:       ^Resource,
	backpressure:   ^Backpressure,
	cyclic_barrier: ^Cyclic_Barrier,
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
	// should oasync print debug info
	// only works with -debug compiler flag enabled
	debug_trace_print:     bool,
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
