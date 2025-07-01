package oasync

import "core:sync"

// a mutex acquired by a task
Resource :: struct {
	is_acquired: bool,
	owner:       Task_Id,
}

acquire_res :: proc(r: ^Resource, t: ^Task) -> bool {
	if sync.atomic_load_explicit(&r.is_acquired, .Acquire) {
		return false
	} else {
		sync.atomic_store_explicit(&r.owner, t.id, .Release)
		sync.atomic_store_explicit(&r.is_acquired, true, .Release)
		return true
	}
}

release_res :: proc(r: ^Resource, t: ^Task) -> bool {
	if sync.atomic_load_explicit(&r.is_acquired, .Acquire) &&
	   sync.atomic_load_explicit(&r.owner, .Acquire) == t.id {
		sync.atomic_store_explicit(&r.is_acquired, false, .Release)
		return true
	} else {
		return false
	}
}
