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
starts a coordinator based on arguments passed in:

max_workers (default: 0) dictates maximum amount of threads to use 
for the scheduler, leave it at 0 to use os.processor_core_count()
as it's value


*/
init_coord :: proc(max_workers := 0, max_blocking := 0) {

}

/* 
initialize a coordinator, which stores the state for spawning different tasks
*/
init :: proc(coord: ^Coordinator, cfg: Config, init_task: Task) {
	_init(coord, cfg, init_task)
}
