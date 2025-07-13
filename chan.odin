package oasync

import "core:container/queue"

Chan :: struct {
	res:               ^Resource,
	drainer:           proc(_: rawptr),
	should_close:      bool,
	graceful_shutdown: bool,
	q:                 Backing_Queue,
}

Backing_Queue :: union {
	queue.Queue(rawptr),
	Static_Queue(rawptr),
}

@(private)
Packed_Chan_Item :: struct {
	c:    ^Chan,
	item: rawptr,
}

@(private)
Static_Queue :: struct($T: typeid) {
	arr:         []T,
	front, size: int,
	capacity:    int,
}

@(private)
static_dequeue :: proc(q: ^Static_Queue($T)) -> (item: T, ok: bool) {
	// empty
	if q.size == 0 {
		return
	}
	item = q.arr[q.front]
	ok = true
	q.front = (q.front + 1) % q.capacity
	q.size -= 1
	return
}

@(private)
static_enqueue :: proc(q: ^Static_Queue($T), x: T) {
	// full
	if q.size == q.capacity {
		static_dequeue(q)
	}
	rear := (q.front + q.size) % q.capacity
	q.arr[rear] = x
	q.size += 1
}

@(private)
// drains every single item in the static queue
// and calls free() on them
static_queue_drain :: proc(q: ^Static_Queue($T)) {
	for {
		item, ok := static_dequeue(q)
		if !ok {
			return
		}
		free(item)
	}

}


@(private)
chan_runloop :: proc(c: rawptr) {
	chan := cast(^Chan)c
	// cannot acquire 
	// retry
	if !acquire_res(chan.res, get_worker().current_running) {
		go(chan_runloop, c)
		return
	}

	if chan.should_close {
		// clean up
		switch &v in chan.q {
		case queue.Queue(rawptr):
			queue.destroy(&v)
		case Static_Queue(rawptr):
			static_queue_drain(&v)
			delete(v.arr)
		}
		free_resource(chan.res)
		free(chan)
		return
	}

	item: rawptr
	ok: bool
	switch &v in chan.q {
	case queue.Queue(rawptr):
		item, ok = queue.pop_front_safe(&v)
	case Static_Queue(rawptr):
		item, ok = static_dequeue(&v)
	}

	release_res(chan.res, get_worker().current_running)

	if !ok {
		// no item, retry
		go(chan_runloop, c)

		return
	}

	chan.drainer(item)
	free(item)
	go(chan_runloop, c)
}

/*
make a channel, where drainer will be executed every time 
when items are put into the it as a rawptr argument 

capacity determines the maximum amount of tasks 
that can be stored in the channel, should capacity
be 0, the channel will be unbuffered

should it be any positive integer, the channel will 
be sliding, i.e. when capacity is reached, enqueue will 
cause the dropping of the oldest item in the queue

abrupt calls of `oa.shutdown` may result in memory leaks
*/
make_chan :: proc(drainer: proc(_: rawptr), capacity := 0) -> ^Chan {
	c := new(Chan)
	if capacity == 0 {
		// capacity 0 means dynamic queue
		c.q = queue.Queue(rawptr){}
		queue.init(&c.q.(queue.Queue(rawptr)))
	} else {
		c.q = Static_Queue(rawptr) {
			arr      = make([]rawptr, capacity),
			capacity = capacity,
		}
	}
	c.drainer = drainer
	c.res = make_resource()
	go(chan_runloop, c)

	return c
}

@(private)
_chan_put :: proc(input: rawptr) {
	casted := cast(^Packed_Chan_Item)input
	switch &v in casted.c.q {
	case Static_Queue(rawptr):
		static_enqueue(&v, casted.item)
	case queue.Queue(rawptr):
		queue.push_back(&v, casted.item)
	}
	free(input)
}

/*
internally clones item and pass the rawptr into an internal queue 
said cloned item will be freed after drainer runs

note that items are not garenteed to be put into the channel immediately 
after the execution of this procedure, as this procedure is asynchronous
*/
c_put :: proc(c: ^Chan, item: $T) {
	if c.should_close {
		return
	}
	cloned_item := new_clone(item)
	a := new_clone(Packed_Chan_Item{c = c, item = cloned_item})
	go(_chan_put, a)
}

/*
stops the draining

frees allocated channel memories immediately, discarding 
unprocessed data
*/
c_stop :: proc(c: ^Chan) {
	c.should_close = true
}
