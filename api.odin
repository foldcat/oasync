package oasync

import "core:os"

go_unit :: proc(p: proc()) {
	spawn_task(make_task(p))
}

go_rawptr :: proc(p: proc(supply: rawptr), data: rawptr) {
	spawn_task(make_task(p, data))
}

/* 
spawn tasks in a virtual thread
*/
go :: proc {
	go_unit,
	go_rawptr,
}

gob_unit :: proc(p: proc()) {
	spawn_blocking_task(make_task(p))
}

gob_rawptr :: proc(p: proc(supply: rawptr), data: rawptr) {
	spawn_blocking_task(make_task(p, data))
}

/* 
spawn tasks that will be run in blocking workers
when blocking_worker_count is zero, this procedure is noop 
and may cause memory leaks
*/
gob :: proc {
	gob_unit,
	gob_rawptr,
}

unsafe_go_unit :: proc(p: proc(), coord: ^Coordinator) {
	spawn_unsafe_task(make_task(p), coord)
}

unsafe_go_rawptr :: proc(p: proc(supply: rawptr), data: rawptr, coord: ^Coordinator) {
	spawn_unsafe_task(make_task(p, data), coord)
}

/* 
used when attempting to spawn tasks outside of a thread 
managed by a coordinator, comes with performance penalities
and does not cause instabilities
*/
unsafe_go :: proc {
	unsafe_go_unit,
	unsafe_go_rawptr,
}

unsafe_gob_unit :: proc(p: proc(), coord: ^Coordinator) {
	spawn_unsafe_blocking_task(make_task(p), coord)
}

unsafe_gob_rawptr :: proc(p: proc(supply: rawptr), data: rawptr, coord: ^Coordinator) {
	spawn_unsafe_blocking_task(make_task(p, data), coord)
}

/* 
used when attempting to spawn blocking tasks outside of a thread 
managed by a coordinator, comes with performance penalities
and does not cause instabilities
*/
unsafe_gob :: proc {
	unsafe_gob_unit,
	unsafe_gob_rawptr,
}

/*
starts a coordinator based on arguments passed in, and returns it 

coord: you are responisble for providing a coordinator, note 
that you should not edit any fields ot the coordinator and simply 
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
*/
init_oa :: proc(
	coord: ^Coordinator,
	max_workers := 0,
	max_blocking := 1,
	use_main_thread := true,
	init_fn: proc(),
) -> ^Coordinator {
	mworkers: u8 = cast(u8)max_workers
	mblocking: u8 = cast(u8)max_blocking

	if max_workers == 0 {
		mworkers = cast(u8)os.processor_core_count()
	}

	cfg := Config {
		worker_count          = mworkers,
		blocking_worker_count = mblocking,
		use_main_thread       = use_main_thread,
	}

	init_task := make_task(init_fn)

	_init(coord, cfg, init_task)
	return coord
}
