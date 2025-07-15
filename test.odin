package oasync

import "core:sync"
import "core:testing"
import "core:time"

@(private)
base_coordinator_setup :: proc(core: proc(_: rawptr)) {
	coord := Coordinator{}
	init_oa(
		&coord,
		init_proc = core,
		init_proc_arg = nil,
		max_workers = 4,
		max_blocking = 2,
		use_main_thread = true,
	)
}

@(test)
test_basic_schedule :: proc(t: ^testing.T) {
	// no hog
	testing.set_fail_timeout(t, 5 * time.Second)

	increment :: proc(ctr: rawptr) {
		ctr := cast(^int)ctr
		sync.atomic_add(ctr, 1)
	}

	core :: proc(_: rawptr) {
		trg := new(int)
		for _ in 1 ..= 100 {
			go(increment, trg)
		}

		for {
			if sync.atomic_load(trg) == 100 {
				shutdown()
				free(trg)
				return
			}
		}
	}

	base_coordinator_setup(core)
}


@(test)
test_chain_dispatch :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	increment :: proc(ctr: rawptr) -> rawptr {
		ctr := cast(^int)ctr
		sync.atomic_add(ctr, 1)
		return ctr
	}

	core :: proc(_: rawptr) {
		trg := new(int)
		go(increment, increment, increment, increment, increment, data = trg)

		for {
			if sync.atomic_load(trg) == 5 {
				shutdown()
				free(trg)
				return
			}
		}
	}

	base_coordinator_setup(core)
}
