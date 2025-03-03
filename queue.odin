package oasync

// lock free queue implementation

import "core:sync"

// it looks like a duck, it probably behaves like a duck, 
// i can't verify it tho, lets just treat it like a duck
Queue :: struct($T: typeid, $S: int) {
	// concurrently updated by many threads
	head:   u32,
	// only updated by one producer
	tail:   u32,
	// used for circular behavior
	mask:   u32,
	// stores items
	buffer: [S]T,
}

make_queue :: proc($T: typeid, $S: int) -> Queue(T, S) {
	return Queue(T, S){mask = u32(S - 1)}
}

queue_push :: proc(q: ^Queue($T, $S), item: T) -> bool {
	head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)

	// ONLY thread that updates this cell
	// tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Relaxed)
	tail := q.tail

	if ((tail - head) & q.mask < q.mask) {
		q.buffer[tail] = item
		sync.atomic_store_explicit(&q.tail, (tail + 1) & q.mask, sync.Atomic_Memory_Order.Release)
		return true
	} else {
		return false
	}
}

queue_pop :: proc(q: ^Queue($T, $S)) -> (result: T, ok: bool) {
	head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)

	// ONLY thread that updates this cell
	// tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Relaxed)
	tail := q.tail

	if head == tail {
		// ok init as false
		// anyways its empty
		return
	}

	result = q.buffer[head]

	if _, aok := sync.atomic_compare_exchange_weak_explicit(
		&q.head,
		head,
		(head + 1) & q.mask,
		sync.Atomic_Memory_Order.Release,
		sync.Atomic_Memory_Order.Relaxed,
	); aok {
		ok = true
		return
	} else {
		// i think the race is lost here
		return
	}
}

queue_length :: proc(q: ^Queue($T, $S)) -> u32 {
	head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)
	tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Acquire)

	return (tail - head) & q.mask
}
