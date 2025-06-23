#+private
package oasync

import "core:log"
import "core:sync"

ARRAY_SIZE :: 8

// https://fzn.fr/readings/ppopp13.pdf

Local_Queue :: struct($T: typeid) {
	top, bottom: int,
	array:       [ARRAY_SIZE]T,
}

queue_pop :: proc(q: ^Local_Queue($T)) -> (x: T, ok: bool) {
	b := sync.atomic_load_explicit(&q.bottom, .Relaxed) - 1
	sync.atomic_store_explicit(&q.bottom, b, .Relaxed)
	sync.atomic_thread_fence(.Seq_Cst)
	t := sync.atomic_load_explicit(&q.top, .Relaxed)
	is_empty: bool
	if t <= b {
		x = sync.atomic_load_explicit(&q.array[b % ARRAY_SIZE], .Relaxed)
		if t == b {
			if _, ok := sync.atomic_compare_exchange_strong_explicit(
				&q.top,
				t,
				t + 1,
				.Seq_Cst,
				.Relaxed,
			); !ok {
				is_empty = true
			}
			sync.atomic_store_explicit(&q.bottom, b + 1, .Relaxed)
		}
	} else {
		is_empty = true
		sync.atomic_store_explicit(&q.bottom, b + 1, .Relaxed)
	}
	return x, !is_empty
}


@(require_results)
queue_push :: proc(q: ^Local_Queue($T), x: T) -> bool {
	b := sync.atomic_load_explicit(&q.bottom, .Relaxed)
	t := sync.atomic_load_explicit(&q.top, .Acquire)
	if (b + 1) % ARRAY_SIZE == t {
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
		for i in 1 ..= queue_len(q) {
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
	t := sync.atomic_load_explicit(&q.top, .Acquire)
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
	has_item := true
	for has_item {
		trace("gqueue pop mutexless delete")
		_, ok := gqueue_pop_mutexless(q)
		trace(ok)
		has_item = ok
	}
}
