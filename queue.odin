#+private
package oasync

import "core:fmt"
import "core:sync"
import "core:testing"

ARRAY_SIZE :: 256
#assert(ARRAY_SIZE > 0 && (ARRAY_SIZE & (ARRAY_SIZE - 1)) == 0)

Queue_Index :: u32
Packed_Head :: u64

QUEUE_CAP :: Queue_Index(ARRAY_SIZE)
QUEUE_MASK :: Queue_Index(ARRAY_SIZE - 1)
QUEUE_HALF :: ARRAY_SIZE / 2

// adapted from tokio.rs's code
// note: top becomes a packed value (high 32 bit: steal steal head, lower 32 bits: real head)
// if steal head == real head, there is no active stealer
// when steal head != real head, a stealer has claimed items

Local_Queue :: struct($T: typeid) {
	top:    Packed_Head,
	bottom: Queue_Index,
	array:  [ARRAY_SIZE]T,
}

queue_pack_head :: proc(steal, real: Queue_Index) -> Packed_Head {
	return Packed_Head(real) | (Packed_Head(steal) << 32)
}

queue_unpack_head :: proc(head: Packed_Head) -> (steal, real: Queue_Index) {
	real = Queue_Index(head & 0xffff_ffff)
	steal = Queue_Index(head >> 32)
	return
}

queue_idx :: proc(pos: Queue_Index) -> int {
	return int(pos & QUEUE_MASK)
}

queue_distance :: proc(from, to: Queue_Index) -> Queue_Index {
	// wraps anyways
	return to - from
}

queue_push_finish :: proc(q: ^Local_Queue($T), x: T, tail: Queue_Index) {
	idx := queue_idx(tail)

	// only the owning producer writes to this place, and the capacity check
	// makes sure the slot is not visible to consumers
	q.array[idx] = x

	// publish new task
	// consumer or stealer acquire load bottom before reading from the slot
	sync.atomic_store_explicit(&q.bottom, tail + 1, .Release)
}

@(require_results)
queue_push :: proc(q: ^Local_Queue($T), x: T) -> bool {
	head := sync.atomic_load_explicit(&q.top, .Acquire)
	steal, _ := queue_unpack_head(head)

	// owning thread can write bottom but other threads read it
	tail := sync.atomic_load_explicit(&q.bottom, .Relaxed)

	// use steal head for capacity check
	// if a stealer is active, the real head probably advanced, but the slots
	// from steal real are not free as the stealer has not copied or read completely
	if queue_distance(steal, tail) >= QUEUE_CAP {
		return false
	}

	queue_push_finish(q, x, tail)
	return true
}

queue_push_overflow :: proc(
	q: ^Local_Queue($T),
	x: T,
	head: Queue_Index,
	tail: Queue_Index,
	gq: ^Global_Queue(T),
) -> bool {
	// ensure that queue is full in this path
	if queue_distance(head, tail) != QUEUE_CAP {
		return false
	}

	// claim currently queued tasks
	// makes sure the queue is empty, but the buffer still contains old tasks
	// as tail wraps to the same slots, we can expose the first half again
	// by advancing bottom after cas

	expected := queue_pack_head(head, head)
	claimed := queue_pack_head(tail, tail)

	actual, ok := sync.atomic_compare_exchange_strong_explicit(
		&q.top,
		expected,
		claimed,
		.Seq_Cst,
		.Acquire,
	)

	if !ok {
		_ = actual
		return false
	}

	// reexpose the first half of the old queue locally
	sync.atomic_store_explicit(&q.bottom, tail + Queue_Index(QUEUE_HALF), .Release)

	// move the second half, plus the newly pushed task, into the global queue
	sync.mutex_lock(&gq.mutex)
	defer sync.mutex_unlock(&gq.mutex)

	for i in 0 ..< QUEUE_HALF {
		pos := head + Queue_Index(QUEUE_HALF + i)
		item := q.array[queue_idx(pos)]
		gqueue_push_mutexless(gq, item)
	}

	gqueue_push_mutexless(gq, x)

	return true
}

queue_push_or_overflow :: proc(q: ^Local_Queue($T), x: T, gq: ^Global_Queue(T)) {
	task := x

	for {
		head_packed := sync.atomic_load_explicit(&q.top, .Acquire)
		steal, real := queue_unpack_head(head_packed)

		tail := sync.atomic_load_explicit(&q.bottom, .Relaxed)

		// fast path: enough capacity
		if queue_distance(steal, tail) < QUEUE_CAP {
			queue_push_finish(q, task, tail)
			return
		}

		// if steam is active, overflow does not happen from local queue as
		// the stealer is about to free space
		// put only the new task in gqueue
		if steal != real {
			gqueue_push(gq, task)
			return
		}

		// full queue & no active stealer, try to move half of the queue + new task
		// into em global queue
		if queue_push_overflow(q, task, real, tail, gq) {
			return
		}

		// race lost against stealer, try again
	}
}

queue_pop :: proc(q: ^Local_Queue($T)) -> (x: T, ok: bool) {
	head_packed := sync.atomic_load_explicit(&q.top, .Acquire)

	for {
		steal, real := queue_unpack_head(head_packed)

		// only the owner writes bottojm, so .Relaxed is enough probably
		tail := sync.atomic_load_explicit(&q.bottom, .Relaxed)

		if real == tail {
			return x, false
		}

		next_real := real + 1

		next_packed: Packed_Head
		if steal == real {
			// no active stealer, advance both heads
			next_packed = queue_pack_head(next_real, next_real)
		} else {
			// active stealer, preserve steal head and advance real only
			next_packed = queue_pack_head(steal, next_real)
		}

		actual, exchanged := sync.atomic_compare_exchange_strong_explicit(
			&q.top,
			head_packed,
			next_packed,
			.Seq_Cst,
			.Acquire,
		)

		if exchanged {
			idx := queue_idx(real)
			x = q.array[idx]
			return x, true
		}

		head_packed = actual
	}
}

queue_steal :: proc(q: ^Local_Queue($T)) -> (x: T, okay: bool) {
	head_packed := sync.atomic_load_explicit(&q.top, .Acquire)

	claimed_head: Packed_Head
	claimed_pos: Queue_Index

	for {
		steal, real := queue_unpack_head(head_packed)

		// we should only allow one active stealer per queue
		// if theres differencce then another stealer is in progress
		if steal != real {
			return x, false
		}

		tail := sync.atomic_load_explicit(&q.bottom, .Acquire)

		if real == tail {
			return x, false
		}

		// get one item by advancing real but not steal
		// which makes steal != real
		// this marks the queue as having an active stealer
		next_real := real + 1
		next_packed := queue_pack_head(steal, next_real)

		actual, exchanged := sync.atomic_compare_exchange_strong_explicit(
			&q.top,
			head_packed,
			next_packed,
			.Seq_Cst,
			.Acquire,
		)

		if exchanged {
			claimed_head = next_packed
			claimed_pos = real
			break
		}

		head_packed = actual
	}

	// we own claimed_pos right now
	// owner and other stealer cannot read this anymore
	x = q.array[queue_idx(claimed_pos)]

	// finish the steal
	// while we are reading the task, the owner worker may have popped more
	// tasks and advanced the real head
	// preserve that by casing till we set steal head == real head again
	for {
		_, real := queue_unpack_head(claimed_head)
		next_packed := queue_pack_head(real, real)

		actual, exchanged := sync.atomic_compare_exchange_strong_explicit(
			&q.top,
			claimed_head,
			next_packed,
			.Seq_Cst,
			.Acquire,
		)

		if exchanged {
			return x, true
		}

		claimed_head = actual
	}
}

queue_len :: proc(q: ^Local_Queue($T)) -> int {
	head_packed := sync.atomic_load_explicit(&q.top, .Acquire)
	_, real := queue_unpack_head(head_packed)

	tail := sync.atomic_load_explicit(&q.bottom, .Acquire)

	return int(queue_distance(real, tail))
}

/// we will need a mutex for this

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
	defer sync.mutex_unlock(&q.mutex)

	gqueue_push_mutexless(q, item)
}

gqueue_pop :: proc(q: ^Global_Queue($T)) -> (res: T, ok: bool) {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	return gqueue_pop_mutexless(q)
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
