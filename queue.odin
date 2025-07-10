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


/// global queue is a linked list...
/// we will need a mutex for this

Global_Queue :: struct($T: typeid) {
	head:  ^Node(T),
	last:  ^Node(T),
	size:  u64,
	mutex: sync.Mutex,
}

Node :: struct($T: typeid) {
	item: T,
	next: ^Node(T),
}

make_gqueue :: proc($T: typeid) -> Global_Queue(T) {
	return Global_Queue(T){}
}

gqueue_push_mutexless :: proc(q: ^Global_Queue($T), item: T) {
	new_node := new_clone(Node(T){item = item})
	if q.last == nil {
		q.head = new_node
		q.last = new_node
	} else {
		q.last.next = new_node
		q.last = new_node
	}
	q.size += 1
}

gqueue_push :: proc(q: ^Global_Queue($T), item: T) {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)

	gqueue_push_mutexless(q, item)
}

gqueue_pop_mutexless :: proc(q: ^Global_Queue($T)) -> (res: T, ok: bool) {
	if q.size == 0 {
		return
	}
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
	q.size -= 1
	trace(get_worker_id(), "obtained", data.id)
	return data, true
}

gqueue_pop :: proc(q: ^Global_Queue($T)) -> (res: T, ok: bool) {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	return gqueue_pop_mutexless(q)
}

gqueue_delete :: proc(q: ^Global_Queue($T)) {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	for {
		trace("gqueue pop mutexless delete")
		if _, ok := gqueue_pop_mutexless(q); !ok {
			trace(ok)
			break
		}
	}
}
