package oasync

import "core:fmt"
import "core:sync"

// a mutex acquired by a task
Resource :: struct {
	owner: Task_Id,
}

Empty_Id := Task_Id {
	is_empty      = true,
	parentless    = false,
	parent_worker = 0,
	task_id       = 0,
}

make_resource :: proc() -> ^Resource {
	return new_clone(Resource{owner = Empty_Id})
}

free_resource :: proc(r: ^Resource) {
	free(r)
}

acquire_res :: proc(r: ^Resource, t: ^Task) -> bool {
	_, ok := sync.atomic_compare_exchange_strong_explicit(
		&r.owner,
		Empty_Id,
		t.id,
		.Seq_Cst,
		.Acquire,
	)
	return ok
}

release_res :: proc(r: ^Resource, t: ^Task) -> bool {
	_, ok := sync.atomic_compare_exchange_strong_explicit(
		&r.owner,
		t.id,
		Empty_Id,
		.Seq_Cst,
		.Acquire,
	)
	return ok
}
