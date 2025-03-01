package structs

import "core:sync"

Barrier :: struct {
	countdown: u8,
}

make_barrier :: proc(required_awaiting: u8) -> Barrier {
	return Barrier{countdown = required_awaiting}
}

barrier_await :: proc(barrier: ^Barrier) {
	// subsequent calls are noop
	if sync.atomic_load(&barrier.countdown) == 0 {
		return
	}

	sync.atomic_sub(&barrier.countdown, 1)
	for sync.atomic_load(&barrier.countdown) != 0 {
	}
}
