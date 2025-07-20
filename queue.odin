#+private
package oasync

import "core:fmt"
import "core:sync"
import "core:testing"

ARRAY_SIZE :: 256

// https://fzn.fr/readings/ppopp13.pdf

Local_Queue :: struct($T: typeid) {
	top, bottom: int,
	array:       [ARRAY_SIZE]T,
}

queue_pop :: proc(q: ^Local_Queue($T)) -> (x: T, ok: bool) {
	// defer if ok {
	// 	wid := get_worker_id()
	// 	trace("worker_id", wid, "top", q.top, "bottom", q.bottom)
	// }

	b := sync.atomic_load_explicit(&q.bottom, .Relaxed) - 1
	sync.atomic_store_explicit(&q.bottom, b, .Relaxed)
	sync.atomic_thread_fence(.Seq_Cst)
	t := sync.atomic_load_explicit(&q.top, .Relaxed)
	is_empty: bool
	if t <= b {
		x = sync.atomic_load_explicit(&q.array[b % ARRAY_SIZE], .Relaxed)
		if t == b {
			if _, race_ok := sync.atomic_compare_exchange_strong_explicit(
				&q.top,
				t,
				t + 1,
				.Seq_Cst,
				.Relaxed,
			); !race_ok {
				is_empty = true
			}
			sync.atomic_store_explicit(&q.bottom, b + 1, .Relaxed)
		}
	} else {
		is_empty = true
		sync.atomic_store_explicit(&q.bottom, b + 1, .Relaxed)
	}
	ok = !is_empty

	return
}


@(require_results)
queue_push :: proc(q: ^Local_Queue($T), x: T) -> bool {
	b := sync.atomic_load_explicit(&q.bottom, .Relaxed)
	t := sync.atomic_load_explicit(&q.top, .Acquire)
	if b - t > ARRAY_SIZE - 1 {
		return false
	}
	sync.atomic_store_explicit(&q.array[b % ARRAY_SIZE], x, .Relaxed)
	sync.atomic_thread_fence(.Release)
	sync.atomic_store_explicit(&q.bottom, b + 1, .Relaxed)
	return true
}

queue_push_or_overflow :: proc(q: ^Local_Queue($T), x: T, gq: ^Global_Queue(T)) {
	if queue_push(q, x) {
		return
	} else {
		sync.mutex_lock(&gq.mutex)
		defer sync.mutex_unlock(&gq.mutex)
		for _ in 1 ..= queue_len(q) / 2 {
			item, ok := queue_pop(q)
			if !ok {
				break

			}
			gqueue_push_mutexless(gq, item)
		}
	}

}

queue_steal :: proc(q: ^Local_Queue($T)) -> (x: T, okay: bool) {
	t := sync.atomic_load_explicit(&q.top, .Acquire)
	sync.atomic_thread_fence(.Seq_Cst)
	b := sync.atomic_load_explicit(&q.bottom, .Acquire)

	if t < b {
		// not empty queue
		x = sync.atomic_load_explicit(&q.array[t % ARRAY_SIZE], .Consume)
		if _, ok := sync.atomic_compare_exchange_strong_explicit(
			&q.top,
			t,
			t + 1,
			.Seq_Cst,
			.Relaxed,
		); !ok {
			// failed race
			return x, false
		}
		return x, true
	} else {
		return x, false
	}
}

queue_len :: proc(q: ^Local_Queue($T)) -> int {
	b := sync.atomic_load_explicit(&q.bottom, .Relaxed)
	t := sync.atomic_load_explicit(&q.top, .Relaxed)
	return b - t
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
