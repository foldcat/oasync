#+private
package oasync

import "core:sync"

/// local queue is a lock free queue based on an array

Local_Queue :: struct($T: typeid, $S: int) {
	// concurrently updated by many threads
	head:   u32,
	// only updated by one producer
	tail:   u32,
	// used for circular behavior
	mask:   u32,
	// stores items
	buffer: [S]T,
}

make_queue :: proc($T: typeid, $S: int) -> Local_Queue(T, S) {
	return Local_Queue(T, S){mask = u32(S - 1)}
}

queue_push :: proc(q: ^Local_Queue($T, $S), item: T) -> bool {
	for {
		head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)

		// ONLY thread that updates this cell
		tail := q.tail

		if ((tail - head) & q.mask < q.mask) {
			q.buffer[tail] = item
			sync.atomic_store_explicit(
				&q.tail,
				(tail + 1) & q.mask,
				sync.Atomic_Memory_Order.Release,
			)
			return true
		}
	}
}

queue_pop :: proc(q: ^Local_Queue($T, $S)) -> (result: T, ok: bool) {
	for {
		head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)

		// ONLY thread that updates this cell
		tail := q.tail

		if head == tail {
			// ok init as false
			// anyways its empty
			return
		}

		result = q.buffer[head]

		actual, aok := sync.atomic_compare_exchange_weak_explicit(
			&q.head,
			head,
			(head + 1) & q.mask,
			sync.Atomic_Memory_Order.Release,
			sync.Atomic_Memory_Order.Relaxed,
		)
		if actual == head {
			ok = true
			return
		}
	}
}

queue_nonlocal_pop :: proc(q: ^Local_Queue($T, $S)) -> (result: T, ok: bool) {
	for {
		head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)

		// ONLY thread that updates this cell
		tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Acquire)

		if head == tail {
			// ok init as false
			// anyways its empty
			return
		}

		result = q.buffer[head]

		actual, aok := sync.atomic_compare_exchange_weak_explicit(
			&q.head,
			head,
			(head + 1) & q.mask,
			sync.Atomic_Memory_Order.Release,
			sync.Atomic_Memory_Order.Relaxed,
		)
		if actual == head {
			ok = true
			return
		}
	}
}


queue_length :: proc(q: ^Local_Queue($T, $S)) -> u32 {
	head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)
	tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Acquire)

	return (tail - head) & q.mask
}


/// global queue is a linked list...
/// we will need a mutex for this

Global_Queue :: struct($T: typeid) {
	head:  ^Node(T),
	last:  ^Node(T),
	mutex: sync.Mutex,
}

Node :: struct($T: typeid) {
	item: T,
	next: ^Node(T),
}

make_gqueue :: proc($T: typeid) -> Global_Queue(T) {
	return Global_Queue(T){}
}

gqueue_push :: proc(q: ^Global_Queue($T), item: T) {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	new_node := new_clone(Node(T){item = item})
	if q.last == nil {
		q.head = new_node
		q.last = new_node
	} else {
		q.last.next = new_node
		q.last = new_node
	}
}

gqueue_pop :: proc(q: ^Global_Queue($T)) -> (res: T, ok: bool) {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	if q.head == nil {
		return
	}
	temp := q.head
	q.head = temp.next
	data := temp.item

	if q.head == nil {
		q.last = nil
	}

	free(temp)
	return data, true
}
