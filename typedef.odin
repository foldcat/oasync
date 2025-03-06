package oasync

import vmem "core:mem/virtual"
import "core:sync"

// 2 ^ 8
@(private)
LOCAL_QUEUE_SIZE :: 256

@(private)
Worker_Type :: enum {
	Generic,
	Blocking,
}

// assigned to each thread
@(private)
Worker :: struct {
	barrier_ref: ^sync.Barrier,
	localq:      Local_Queue(Task, LOCAL_QUEUE_SIZE),
	run_next:    Task,
	id:          u8,
	coordinator: ^Coordinator,
	arena:       vmem.Arena,
	type:        Worker_Type,
}

@(private)
Rawptr_Task :: struct {
	// void * generic
	// sometimes i wish for a more complex type system
	effect: proc(input: rawptr),
	supply: rawptr,
}

@(private)
Unit_Task :: struct {
	effect: proc(),
}

@(private)
Task :: union {
	Rawptr_Task,
	Unit_Task,
}

/* 
coordinates workers for dispatching virtual threads and 
executing tasks
should not be accessed
*/
Coordinator :: struct {
	workers:               [dynamic]Worker,
	worker_count:          u8,
	blocking_workers:      [dynamic]Worker,
	blocking_worker_count: u8,
	globalq:               Global_Queue(Task),
	global_blockingq:      Global_Queue(Task),
	search_count:          u8,
}

/*
controls the behavior of a coordinator,
mutating this upon calling init has no effect 
on its behavior
*/
Config :: struct {
	// amount of threads to run tasks
	worker_count:          u8,
	// amount of threads to run blocking tasks
	blocking_worker_count: u8,
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
