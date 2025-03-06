package oasync

import vmem "core:mem/virtual"
import "core:sync"

// 2 ^ 8
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

// heart of the async scheduler
Coordinator :: struct {
	workers:               [dynamic]Worker, // could do a static sized one but requires too much parapoly to make worth
	worker_count:          u8,
	blocking_workers:      [dynamic]Worker,
	blocking_worker_count: u8,
	globalq:               Global_Queue(Task),
	global_blockingq:      Global_Queue(Task),
	search_count:          u8, // ATOMIC ONLY!
}

Config :: struct {
	worker_count:          u8,
	blocking_worker_count: u8,
	use_main_thread:       bool,
}

// injected into context.user_ptr, overriding its content
// fear not, we provide a field named user_ptr which you can access 
// and use at your own pleasure
Ref_Carrier :: struct {
	worker:   ^Worker,
	user_ptr: rawptr,
}
