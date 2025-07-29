#+private
package oasync

import "core:fmt"
import "core:sync"
import "core:testing"

/// local queue is a lock free queue based on an array with circular behaviors
/// based on rust's tokio runtime

Local_Queue :: struct($T: typeid, $S: int) {
	// concurrently updated by many threads
	// this is the result of two u32s packed together,
	// one account for stealer position and the 
	// other account for the "real" head position
	// nothing is stealing when real and stealing position equates
	// this lets us grab both the head and tail position with just 
	// a single atomic load
	head:   u64,
	// only updated by one producer
	tail:   u32,
	// stores items
	buffer: [S]T,
}

when ODIN_DEBUG {
	// helps catch edge cases
	LOCAL_QUEUE_SIZE :: 8
} else {
	// must be the 2^n so we can do a bitmask for 
	// circular behavior, in this case we use
	// 2 ^ 8 as the value
	LOCAL_QUEUE_SIZE :: 256
}
// used for circular behaviors
MASK: u32 : LOCAL_QUEUE_SIZE - 1


// unpack a u64 into the real position and the stealer position
unpack :: proc(pack: u64) -> (steal, real: u32) {
	real = u32((pack >> 16) & 0xFFFF)
	steal = u32(pack & 0xFFFF)
	return steal, real
}

// pack the real position and the stealer position into a singular u64
pack :: proc(real, steal: u32) -> u64 {
	return (u64(real) << 16) | u64(steal)
}

make_queue :: proc($T: typeid, $S: int) -> Local_Queue(T, S) {
	return Local_Queue(T, S){}
}

// subtraction/addition in odin already wraps, but honestly? might as 
// well write this seemingly useless (and actually *is* useless)
// procedure to stay true to the original code~
wrapping_sub :: proc(lhs, rhs: u32) -> u32 {
	return lhs - rhs
}
wrapping_add :: proc(lhs, rhs: u32) -> u32 {
	return lhs + rhs
}

// queue_remaining_slots :: proc(q: ^Local_Queue($T, $S)) -> u32 {
// 	steal, _ := unpack(sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire))
// 	tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Acquire)
// 	return LOCAL_QUEUE_CAPACITY - wrapping_sub(tail, steal)
//
// }

queue_length :: proc(q: ^Local_Queue($T, $S)) -> u32 {
	_, head := unpack(sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire))
	tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Acquire)
	return wrapping_sub(tail, head)
}

queue_is_empty :: proc(q: ^Local_Queue($T, $S)) -> bool {
	return queue_length(q) == 0
}

// push a singular task into a local queue, should the queue overflow, 
// lets injects tasks into global queue~
queue_push_back_or_overflow :: proc(q: ^Local_Queue($T, $S), item: T, overflow: ^Global_Queue(T)) {
	tail: u32
	task := item
	for {
		head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)
		steal, real := unpack(head)
		// only updated by producer, so it needn't be atomic~
		inner_tail := q.tail
		if wrapping_sub(inner_tail, steal) < LOCAL_QUEUE_SIZE {
			// there is capacity for the task
			tail = inner_tail
			break
		} else if steal != real {
			// another worker is stealing, which frees up capacity 
			// lets push our task into overflow instead~
			gqueue_push(overflow, item)
			return
		} else {
			// push current task and half into overflow 
			// as we might have just ran out of capacity
			v, ok := queue_push_overflow(item, real, tail, overflow, q)
			if ok {
				return
			} else {
				// lost the race, try again
				task = v
			}
		}

	}
	push_back_finish(q, task, tail)
}

push_back_finish :: proc(q: ^Local_Queue($T, $S), task: T, tail: u32) {
	idx := tail & MASK
	q.buffer[idx] = task
	sync.atomic_store_explicit(&q.tail, wrapping_add(tail, 1), sync.Atomic_Memory_Order.Release)
}

NUM_TASK_TAKEN: u32 : u32(LOCAL_QUEUE_SIZE / 2)

queue_push_overflow :: proc(
	task: $T,
	head, tail: u32,
	overflow: ^Global_Queue(T),
	local_q: ^Local_Queue(T, $S),
) -> (
	item_output: T,
	ok: bool,
) {
	prev := pack(head, head)

	res, oka := sync.atomic_compare_exchange_strong_explicit(
		&local_q.head,
		prev,
		pack(wrapping_add(head, NUM_TASK_TAKEN), wrapping_add(head, NUM_TASK_TAKEN)),
		sync.Atomic_Memory_Order.Release,
		sync.Atomic_Memory_Order.Relaxed,
	)
	if !oka {
		// failed to claim the tasks, probably because we lost the race
		// try the full push routine instead
		return task, false
	}

	// hold down the mutext till we pushed everything in
	sync.mutex_lock(&overflow.mutex)
	for i in 0 ..< NUM_TASK_TAKEN {
		idx := wrapping_add(i, head) & MASK
		gqueue_push_mutexless(overflow, local_q.buffer[idx])
	}
	sync.mutex_unlock(&overflow.mutex)

	ok = true
	return
}

queue_pop :: proc(q: ^Local_Queue($T, $S)) -> (res: T, ok: bool) {
	head := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)

	idx: u32
	for {
		steal, real := unpack(head)
		tail := q.tail
		if real == tail {
			return
		}
		next_real := wrapping_add(real, 1)

		next: u64
		if steal == real {
			next = pack(next_real, next_real)
		} else {
			next = pack(next_real, steal)
		}
		actual, oka := sync.atomic_compare_exchange_strong_explicit(
			&q.head,
			head,
			next,
			sync.Atomic_Memory_Order.Acq_Rel,
			sync.Atomic_Memory_Order.Acquire,
		)
		if oka {
			idx = real & MASK
			break
		} else {
			head = actual
		}
	}
	return q.buffer[idx], true

}

queue_steal_into :: proc(q: ^Local_Queue($T, $S), dst: ^Local_Queue(T, S)) -> (res: T, ok_: bool) {
	dst_tail := dst.tail
	steal, _ := unpack(sync.atomic_load_explicit(&dst.head, sync.Atomic_Memory_Order.Acquire))
	if wrapping_sub(dst_tail, steal) > u32(LOCAL_QUEUE_SIZE / 2) {
		// we could steal less but it would be too complex
		return
	}
	n := queue_steal_into2(q, dst, dst_tail)
	if n == 0 {
		// nothing to steal
		return
	}
	// return a task
	n -= 1
	ret_pos := wrapping_add(dst_tail, n)
	ret_idx := ret_pos & MASK
	ret := dst.buffer[ret_idx]
	if n == 0 {
		// dst empty but a single task is stolen
		return ret, true
	}
	sync.atomic_store_explicit(
		&dst.tail,
		wrapping_add(dst_tail, n),
		sync.Atomic_Memory_Order.Release,
	)
	return ret, true

}

queue_steal_into2 :: proc(q: ^Local_Queue($T, $S), dst: ^Local_Queue(T, S), dst_tail: u32) -> u32 {
	prev_packed := sync.atomic_load_explicit(&q.head, sync.Atomic_Memory_Order.Acquire)
	next_packed: u64

	n: u32
	for {
		src_head_steal, src_head_real := unpack(prev_packed)
		src_tail := sync.atomic_load_explicit(&q.tail, sync.Atomic_Memory_Order.Acquire)

		if src_head_steal != src_head_real {
			// another thread is concurrently stealing 
			// we shouldn't interrupt...
			return 0
		}

		num := wrapping_sub(src_tail, src_head_real)
		num = num - num / 2

		if num == 0 {
			// nothing to steal
			return 0
		}

		steal_to := wrapping_add(src_head_real, num)
		next_packed = pack(src_head_real, steal_to)

		res, ok := sync.atomic_compare_exchange_strong_explicit(
			&q.head,
			prev_packed,
			next_packed,
			sync.Atomic_Memory_Order.Acq_Rel,
			sync.Atomic_Memory_Order.Acquire,
		)
		if ok {
			n = num
		} else {
			prev_packed = res
		}
	}
	first, _ := unpack(next_packed)
	for i in 0 ..< n {
		src_pos := wrapping_add(first, i)
		dst_pos := wrapping_add(dst_tail, i)

		src_idx := src_pos & MASK
		dst_idx := dst_pos & MASK

		task := q.buffer[src_idx]
		dst.buffer[dst_idx] = task
	}
	prev_packed = next_packed
	for {
		_, head := unpack(prev_packed)
		next_packed := pack(head, head)
		res, ok := sync.atomic_compare_exchange_strong_explicit(
			&q.head,
			prev_packed,
			next_packed,
			sync.Atomic_Memory_Order.Acq_Rel,
			sync.Atomic_Memory_Order.Acquire,
		)
		if ok {
			return n
		} else {
			prev_packed = res
		}
	}
}

// we will need a mutex for this

CHUNK_CAPACITY :: 64

Chunk :: struct(T: typeid) {
	head:       int,
	tail:       int,
	size:       int,
	backing:    [CHUNK_CAPACITY]T,
	next_chunk: ^Chunk(T),
	prev_chunk: ^Chunk(T),
}

Global_Queue :: struct(T: typeid) {
	top:    ^Chunk(T),
	bottom: ^Chunk(T),
	mutex:  sync.Mutex,
}

make_gqueue :: proc($T: typeid) -> Global_Queue(T) {
	init_chunk := new(Chunk(T))
	return Global_Queue(T){top = init_chunk, bottom = init_chunk}
}

gqueue_push_mutexless :: proc(q: ^Global_Queue($T), x: T) {
	if q.top == nil {
		q.top = new(Chunk(T))
		q.bottom = q.top // init bottom when the queue is empty
	}

	if q.top.size == CHUNK_CAPACITY {
		// full
		original_top := q.top
		new_chunk := new_clone(Chunk(T){next_chunk = original_top})
		original_top.prev_chunk = new_chunk
		q.top = new_chunk
	}

	q.top.backing[q.top.tail] = x
	q.top.tail = (q.top.tail + 1) % CHUNK_CAPACITY
	q.top.size += 1
}

gqueue_pop_mutexless :: proc(q: ^Global_Queue($T)) -> (x: T, ok: bool) {
	if q.bottom == nil || q.bottom.size == 0 {
		return
	}

	x = q.bottom.backing[q.bottom.head]
	q.bottom.head = (q.bottom.head + 1) % CHUNK_CAPACITY
	q.bottom.size -= 1
	ok = true

	if q.bottom.size == 0 {
		bot := q.bottom
		if q.bottom.prev_chunk == nil {
			// last chunk, reset head and tail
			// dont free
			q.bottom.head = 0
			q.bottom.tail = 0

		} else {
			q.bottom = q.bottom.prev_chunk
			free(bot)
		}
	}
	return
}

gqueue_delete :: proc(q: ^Global_Queue($T)) {
	sync.mutex_lock(&q.mutex)
	curr := q.bottom
	for curr != nil {
		prev := curr.prev_chunk
		free(curr)
		curr = prev
	}
	q.top = nil
	q.bottom = nil
	sync.mutex_unlock(&q.mutex)
}


gqueue_push :: proc(q: ^Global_Queue($T), item: T) {
	sync.mutex_lock(&q.mutex)
	gqueue_push_mutexless(q, item)
	sync.mutex_unlock(&q.mutex)
}

gqueue_pop :: proc(q: ^Global_Queue($T)) -> (res: T, ok: bool) {
	sync.mutex_lock(&q.mutex)
	res, ok = gqueue_pop_mutexless(q)
	sync.mutex_unlock(&q.mutex)
	return
}

@(test)
test_gqueue_basic :: proc(t: ^testing.T) {
	q := make_gqueue(int)
	gqueue_push_mutexless(&q, 1)
	gqueue_push_mutexless(&q, 2)
	gqueue_push_mutexless(&q, 3)

	val, ok := gqueue_pop_mutexless(&q)
	testing.expect(t, ok == true, "expected pop to succeed")
	testing.expect(t, val == 1, "expected value 1")

	val, ok = gqueue_pop_mutexless(&q)
	testing.expect(t, ok == true, "expected pop to succeed")
	testing.expect(t, val == 2, "expected value 2")

	val, ok = gqueue_pop_mutexless(&q)
	testing.expect(t, ok == true, "expected pop to succeed")
	testing.expect(t, val == 3, "expected value 3")

	val, ok = gqueue_pop_mutexless(&q)
	testing.expect(t, ok == false, "expected pop to fail")

	gqueue_delete(&q)
}

@(test)
test_gqueue_multiple_chunks :: proc(t: ^testing.T) {
	q := make_gqueue(int)

	for i in 0 ..< CHUNK_CAPACITY * 3 {
		gqueue_push_mutexless(&q, i)
	}

	for i in 0 ..< CHUNK_CAPACITY * 3 {
		val, ok := gqueue_pop_mutexless(&q)
		testing.expect(t, ok == true, "expected pop to succeed")
		testing.expect(t, val == i, fmt.tprintf("expected value %d, got %d", i, val))
	}

	val, ok := gqueue_pop_mutexless(&q)
	testing.expect(t, ok == false, "expected pop to fail")

	gqueue_delete(&q)

}

@(test)
test_gqueue_empty_refill :: proc(t: ^testing.T) {
	q := make_gqueue(int)

	for i in 0 ..< CHUNK_CAPACITY {
		gqueue_push_mutexless(&q, i)
	}

	for i in 0 ..< CHUNK_CAPACITY {
		_, ok := gqueue_pop_mutexless(&q)
		testing.expect(t, ok == true, "expected pop to succeed")
	}

	for i in 0 ..< CHUNK_CAPACITY {
		gqueue_push_mutexless(&q, i + CHUNK_CAPACITY)
	}

	for i in 0 ..< CHUNK_CAPACITY {
		val, ok := gqueue_pop_mutexless(&q)
		testing.expect(t, ok == true, "expected pop to succeed")
		testing.expect(
			t,
			val == i + CHUNK_CAPACITY,
			fmt.tprintf("expected value %d, got %d", i + CHUNK_CAPACITY, val),
		)
	}

	gqueue_delete(&q)
}


@(test)
test_gqueue_interleaved_push_pop :: proc(t: ^testing.T) {
	q := make_gqueue(int)

	for i in 0 ..< CHUNK_CAPACITY {
		gqueue_push_mutexless(&q, i)
		val, ok := gqueue_pop_mutexless(&q)
		testing.expect(t, ok == true, "expected pop to succeed")
		testing.expect(t, val == i, fmt.tprintf("expected value %d, got %d", i, val))
	}

	gqueue_delete(&q)
}
