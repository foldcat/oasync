package oasync

go_unit :: proc(p: proc()) {
	spawn_task(make_task(p))
}

go_rawptr :: proc(p: proc(supply: rawptr), data: rawptr) {
	spawn_task(make_task(p, data))
}

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

unsafe_gob :: proc {
	unsafe_gob_unit,
	unsafe_gob_rawptr,
}

init :: proc(coord: ^Coordinator, cfg: Config, init_task: Task) {
	_init(coord, cfg, init_task)
}
