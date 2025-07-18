#+private
package oasync

import "core:sync"

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
	top_idx:    int,
	bottom_idx: int,
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
	}

	if q.top.top_idx == CHUNK_CAPACITY {
		// full
		original_top := q.top
		new_chunk := new_clone(Chunk(T){next_chunk = original_top})
		new_chunk.next_chunk = original_top
		original_top.prev_chunk = new_chunk
		q.top = new_chunk
	}

	q.top.backing[q.top.top_idx] = x
	q.top.top_idx += 1
}

gqueue_pop_mutexless :: proc(q: ^Global_Queue($T)) -> (x: T, ok: bool) {
	if q.bottom == nil {
		return
	}

	if q.bottom.bottom_idx == q.bottom.top_idx {
		// empty
		bot := q.bottom
		if q.bottom.prev_chunk == nil {
			return
		}
		q.bottom = q.bottom.prev_chunk
		free(bot)
	}

	x = q.bottom.backing[q.bottom.bottom_idx]
	ok = true
	q.bottom.bottom_idx += 1
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
