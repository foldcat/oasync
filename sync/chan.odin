package oa_sync

import oa ".."
import "core:container/queue"

// a many to one channel
Chan :: struct {
	q:                 queue.Queue(rawptr),
	res:               ^oa.Resource,
	drainer:           proc(_: rawptr),
	should_close:      bool,
	graceful_shutdown: bool,
}

@(private)
Packed_Chan_Item :: struct {
	c:    ^Chan,
	item: rawptr,
}

@(private)
chan_runloop :: proc(c: rawptr) {
	chan := cast(^Chan)c
	if chan.should_close && !chan.graceful_shutdown {
		// clean up
		queue.destroy(&chan.q)
		oa.free_resource(chan.res)
		free(chan)
		return
	}

	item, ok := queue.pop_front_safe(&chan.q)
	if !ok {
		if chan.should_close && chan.graceful_shutdown {
			queue.destroy(&chan.q)
			oa.free_resource(chan.res)
			free(chan)
			return
		}

		// no item, retry
		oa.go(chan_runloop, c, acq = chan.res)

		return
	}

	chan.drainer(item)
	free(item)
	oa.go(chan_runloop, c, acq = chan.res)
}

/*
make a channel, where drainer will be executed every time 
when items are put into the it as a rawptr argument 
note that items passed into drainer will be freed 
once drainer finished execution
*/
make_chan :: proc(drainer: proc(_: rawptr)) -> ^Chan {
	c := new(Chan)
	c.drainer = drainer
	queue.init(&c.q)
	c.res = oa.make_resource()
	oa.go(chan_runloop, c, acq = c.res)

	return c
}

@(private)
_c_put :: proc(input: rawptr) {
	casted := cast(^Packed_Chan_Item)input
	queue.push_back(&casted.c.q, casted.item)
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
	oa.go(_c_put, a, acq = c.res)
}

/*
stops the draining

should graceful be true, channel will stop accepting items
and the channel alongside the subsequent data will be freed 
once the channel is empty 

otherwise, the channel will be freed immedaitely and the runtime 
will not wait for the queue to be emptied
*/
c_stop :: proc(c: ^Chan, graceful := true) {
	c.should_close = true
	c.graceful_shutdown = graceful
}
