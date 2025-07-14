package oasync

import "core:os"
import "core:time"

/* 
dispatch a task

data: a rawptr argument to pass into your task
block: if true, dispatch said task in blocking mode
delay: time.Duration delay for the task to run
coord: if not nil, spawn task in unsafe mode, where 
tasks may be run outside of threads managed by oasync,
comes with heavy performance drawback
res: resource to acquire
bp: backpressure to acquire
*/
singleton_go :: proc(
	p: proc(_: rawptr),
	data: rawptr = nil,
	block: bool = false,
	coord: ^Coordinator = nil,
	delay: time.Duration = 0,
	res: ^Resource = nil,
	bp: ^Backpressure = nil,
	cdl: ^Count_Down_Latch = nil,
	cb: ^Cyclic_Barrier = nil,
	sem: ^Semaphore = nil,
) {
	execute_at: time.Tick
	if delay != 0 {
		execute_at = time.tick_add(time.tick_now(), delay)
	}

	if coord == nil {
		task := make_task(
			p,
			data,
			is_blocking = block,
			execute_at = execute_at,
			is_parentless = false,
			res = res,
			bp = bp,
			cdl = cdl,
			cb = cb,
			sem = sem,
		)
		spawn_task(task)
	} else {
		task := make_task(
			p,
			data,
			is_blocking = block,
			execute_at = execute_at,
			is_parentless = true,
			res = res,
			cdl = cdl,
			cb = cb,
			bp = bp,
			sem = sem,
		)
		spawn_unsafe_task(task, coord)
	}
}

/* 
dispatch a task chain
option are same as `go`
*/
chain_go :: proc(
	p: ..proc(_: rawptr) -> rawptr,
	data: rawptr = nil,
	block: bool = false,
	coord: ^Coordinator = nil,
	delay: time.Duration = 0,
	res: ^Resource = nil,
	bp: ^Backpressure = nil,
	cdl: ^Count_Down_Latch = nil,
	cb: ^Cyclic_Barrier = nil,
	sem: ^Semaphore = nil,
) {
	execute_at: time.Tick
	if delay != 0 {
		execute_at = time.tick_add(time.tick_now(), delay)
	}

	if coord == nil {
		task := make_task(
			new_clone(p),
			data,
			is_blocking = block,
			execute_at = execute_at,
			res = res,
			bp = bp,
			cdl = cdl,
			cb = cb,
			sem = sem,
			is_parentless = false,
		)
		spawn_task(task)
	} else {
		task := make_task(
			new_clone(p),
			data,
			is_blocking = block,
			execute_at = execute_at,
			is_parentless = true,
			res = res,
			cdl = cdl,
			cb = cb,
			bp = bp,
			sem = sem,
		)
		spawn_unsafe_task(task, coord)
	}
}

go :: proc {
	singleton_go,
	chain_go,
}

/*
get worker from context
*/
get_worker :: proc() -> ^Worker {
	carrier := cast(^Ref_Carrier)context.user_ptr
	return carrier.worker
}


/*
obtains the worker id when executed inside a task
might segfault otherwise
*/
get_worker_id :: proc() -> u8 {
	worker := get_worker()
	return worker.id
}

/*
shuts down the coordinator
*/
shutdown :: proc() {
	_shutdown()
}

/*
starts a coordinator based on arguments passed in

coord: you are responisble for providing a coordinator, note 
that you should not edit any fields of the coordinator and simply 
leave it as is

max_workers: maximum amount of threads to use 
for the scheduler, leave it at 0 to use os.processor_core_count()
as it's value

max_blocking: the maximum amount of threads 
to be used for blocking operations, leaving it to 0 to for oasync 
to use max_blocking / 2 as value

use_main_thread: when true, this procedure will be blocking, instead of 
yielding immediately to grant control back to the thread executing 
this procedure

init_proc: the first procedure to execute when oasync is initialized

debug_trace_print: whether to print debug info or not, works 
only when -debug flag is passed into the compiler
should multiple coordinators exist at the same time, this option 
will cause EVERY single coordinator to trace print
*/
init_oa :: proc(
	coord: ^Coordinator,
	init_proc: proc(_: rawptr),
	init_proc_arg: rawptr = nil,
	max_workers := 0,
	max_blocking := 0,
	use_main_thread := true,
	debug_trace_print := false,
) {
	max_workers := max_workers // make it mutable
	max_blocking := max_blocking
	if max_workers == 0 {
		max_workers = os.processor_core_count()
	}
	if max_blocking == 0 {
		max_blocking = max_workers / 2
	}

	init_task := make_task(
		init_proc,
		init_proc_arg,
		is_parentless = true,
		is_blocking = false,
		execute_at = time.Tick{},
		res = nil,
		bp = nil,
		cdl = nil,
		cb = nil,
		sem = nil,
	)
	_init(
		coord,
		init_task,
		worker_count = max_workers,
		blocking_worker_count = max_blocking,
		use_main_thread = use_main_thread,
		trace_print = debug_trace_print,
	)
}
