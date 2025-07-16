package oasync

// the following tests may reveal memory leaks 
// the leaking is false positives and should be ignored for most cases

import "core:log"
import "core:sync"
import "core:testing"
import "core:time"

@(private)
base_coordinator_setup :: proc(core: proc(_: rawptr), arg: ^testing.T = nil) {
	coord := Coordinator{}
	init_oa(
		&coord,
		init_proc = core,
		init_proc_arg = arg,
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

@(test)
test_timed_dispatch :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	increment :: proc(ctr: rawptr) {
		ctr := cast(^int)ctr
		sync.atomic_add(ctr, 1)
	}

	core :: proc(_: rawptr) {
		trg := new(int)
		for _ in 1 ..= 100 {
			go(increment, trg, delay = 1 * time.Second)
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
test_blocking :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	increment :: proc(ctr: rawptr) {
		ctr := cast(^int)ctr
		time.sleep(1 * time.Second)
		sync.atomic_add(ctr, 1)
	}

	core :: proc(t: rawptr) {
		trg := new(int)

		sw := time.Stopwatch{}

		time.stopwatch_start(&sw)

		for _ in 1 ..= 6 {
			go(increment, trg, block = true)
		}

		for {
			if sync.atomic_load(trg) == 6 {
				time.stopwatch_stop(&sw)
				dur := time.stopwatch_duration(sw)
				if dur < 3 * time.Second {
					testing.fail(cast(^testing.T)t)
				}
				shutdown()
				free(trg)
				return
			}
		}
	}

	base_coordinator_setup(core, t)
}

@(test)
test_resource_mutex :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	increment :: proc(ctr: rawptr) {
		ctr := cast(^int)ctr
		ctr^ += 1
	}

	core :: proc(_: rawptr) {
		trg := new(int)
		res := make_resource()

		for _ in 1 ..= 100 {
			// without acquiring resources
			// this will cause race condition and
			// 100 will never be reached
			go(increment, trg, res = res)
		}

		for {
			if trg^ == 100 {
				destroy_resource(res)
				shutdown()
				free(trg)
				return
			}
		}
	}

	base_coordinator_setup(core)
}
