package oasync

import "base:runtime"
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
	// for lcg
	rng_seed:         i32,
	// for generating unique id for each task
	task_id_gen:      u32,
}

// 16 bits wasted but we could work with this
// is a bit_field as it can be loaded by sync.atomic_load
@(private)
Task_Id :: bit_field i64 {
	// used for unsafe dispatching or the first task dispatched
	is_empty:      bool | 8,
	parentless:    bool | 8,
	parent_worker: u8   | 8,
	task_id:       u32  | 32,
}

@(private)
Effect_Input :: union {
	proc(_: rawptr),
	^[]proc(_: rawptr) -> rawptr,
}

@(private)
Singleton_Effect :: struct {
	effect:  proc(input: rawptr),
	is_done: bool,
}

@(private)
Returning_Effect :: struct {
	effect:  proc(input: rawptr) -> rawptr,
	is_done: bool,
}

@(private)
Chain_Effect :: struct {
	effects: []Returning_Effect,
	idx:     int,
}

@(private)
Effect :: union {
	Singleton_Effect,
	Chain_Effect,
}

@(private)
Task :: struct {
	// void * generic
	// sometimes i wish for a more complex type system
	effect: Effect,
	arg:    rawptr,
	id:     Task_Id,
	mods:   Task_Modifiers,
	// caller location
	loc:    runtime.Source_Code_Location,
}

@(private)
Task_Run_Status :: enum {
	// drop the task, do not run it
	Drop,
	// run the task
	Run,
	// put the task back into a queue
	Requeue,
}

// modifiers of the tasks
@(private)
Task_Modifiers :: struct {
	is_blocking:      bool,
	// if a task is scheduled to run later or not
	// this is NOT garenteed to execute at the exact tick
	execute_at:       time.Tick,

	// concurrency primitives
	resource:         ^Resource,
	backpressure:     ^Backpressure,
	cyclic_barrier:   ^Cyclic_Barrier,
	count_down_latch: ^Count_Down_Latch,
	semaphore:        ^Semaphore,
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
