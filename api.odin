package oasync

import "core:os"

/* 
spawn tasks in a virtual thread
*/
go :: proc(p: proc(_: rawptr) -> Behavior, data: rawptr = nil) {
	spawn_task(make_task(p, data))
}

/* 
spawn tasks that will be run in blocking workers
when blocking_worker_count is zero, this procedure is noop 
and may cause memory leaks
*/
gob :: proc(p: proc(_: rawptr) -> Behavior, data: rawptr = nil) {
	spawn_task(make_task(p, data, is_blocking = true))
}

/* 
used when attempting to spawn tasks outside of a thread 
managed by a coordinator, comes with performance penalities
and does not cause instabilities
*/
unsafe_go :: proc(coord: ^Coordinator, p: proc(_: rawptr) -> Behavior, data: rawptr = nil) {
	spawn_unsafe_task(make_task(p, data), coord)
}

/* 
used when attempting to spawn blocking tasks outside of a thread 
managed by a coordinator, comes with performance penalities
and does not cause instabilities
*/
unsafe_gob :: proc(coord: ^Coordinator, p: proc(_: rawptr) -> Behavior, data: rawptr = nil) {
	spawn_unsafe_task(make_task(p, data, is_blocking = true), coord)
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
oa_shutdown :: proc() {
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
to be used for blocking operations, leaving it to 0 disables blocking 
tasks, note that firing off a blocking task with max_blocking set to 0
will cause memory leaks and said task will not be executed
thread used by max_blocking does not countribute towards max_workers, 
but this behavior will be changed in future updates

use_main_thread: when true, this procedure will be blocking, instead of 
yielding immediately to grant control back to the thread executing 
this procedure

init_fn: the first function to execute when oasync is initialized

debug_trace_print: whether to print debug info or not, works 
only when -debug flag is passed into the compiler
*/
init_oa :: proc(
	coord: ^Coordinator,
	max_workers := 0,
	max_blocking := 1,
	use_main_thread := true,
	debug_trace_print := false,
	init_fn: proc(_: rawptr) -> Behavior,
	init_fn_arg: rawptr = nil,
) {
	max_workers := max_workers // make it mutable
	if max_workers == 0 {
		max_workers = os.processor_core_count()
	}

	cfg := Config {
		worker_count          = max_workers,
		blocking_worker_count = max_blocking,
		use_main_thread       = use_main_thread,
		debug_trace_print     = debug_trace_print,
	}

	init_task := make_task(init_fn, init_fn_arg)

	_init(coord, cfg, init_task)
}
