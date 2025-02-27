package oasync

import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

Task :: struct {
	effect: proc(_: Worker),
}

// assigned to each thread
Worker :: struct {
	localq:       queue.Queue(Task),
	run_next:     Task,
	timestamp:    time.Tick, // acts as identifier for each worker, should never collide
	coordinator:  ^Coordinator,
	localq_mutex: sync.Mutex,
	arena:        vmem.Arena,
}

// heart of the async scheduler
Coordinator :: struct {
	workers:      [dynamic]Worker, // could do a static sized one but requires too much parapoly to make worth
	worker_count: int,
	globalq:      chan.Chan(Task), // TODO: queue instead
	search_count: u8, // ATOMIC ONLY!
}

Config :: struct {
	worker_count:    int,
	use_main_thread: bool,
}

// injected into context.user_ptr, overriding its content
// fear not, we provide a field named user_ptr which you can access 
// and use at your own pleasure
Ref_Carrier :: struct {
	worker:   ^Worker,
	user_ptr: rawptr,
}


// get worker from context
get_worker :: proc() -> ^Worker {
	carrier := cast(^Ref_Carrier)context.user_ptr
	return carrier.worker
}

steal :: proc(this: ^Worker) {
	// steal from a random worker
	worker := rand.choice(this.coordinator.workers[:])
	if worker.timestamp == this.timestamp {
		// same id, and don't steal from self,
		return
	}

	sync.mutex_lock(&worker.localq_mutex)
	defer sync.mutex_unlock(&worker.localq_mutex) // make sure the mutex doesn't get perma locked
	// we don't steal from queues that doesn't have items
	queue_length := queue.len(worker.localq)
	if queue_length == 0 {
		return
	}

	sync.mutex_lock(&this.localq_mutex)
	defer sync.mutex_unlock(&this.localq_mutex)
	// steal half of the text once we find one
	for i in 1 ..= u64(queue_length / 2) { 	// TODO: need further testing
		elem, ok := queue.pop_front_safe(&worker.localq)
		if !ok {
			log.error("failed to steal")
			return
		}

		queue.push(&this.localq, elem)
	}

}

// unsafe function: do not use
run_task :: proc(t: Task, worker: Worker) {
	t.effect(worker)
}

// event loop that every worker runs
worker_runloop :: proc(t: ^thread.Thread) {
	log.debug("runloop started")
	worker := get_worker()
	for {
		// wipe the arena every loop
		arena := worker.arena
		defer vmem.arena_free_all(&arena)

		// tasks in local queue gets scheduled first
		sync.mutex_lock(&worker.localq_mutex)
		//log.debug("pop")
		tsk, exist := queue.pop_front_safe(&worker.localq)
		sync.mutex_unlock(&worker.localq_mutex)
		if exist {
			log.debug("pulled from local queue, running")
			run_task(tsk, worker^)

			continue
		}

		// local queue seems to be empty at this point, take a look 
		// at the global channel
		//log.debug("chan recv")
		tsk, exist = chan.try_recv(worker.coordinator.globalq)
		if exist {
			log.debug("got item from global channel")
			run_task(tsk, worker^)

			continue
		}

		// global queue seems to be empty too, enter stealing mode 
		// increment the stealing count
		if sync.atomic_load(&worker.coordinator.search_count) >
		   u8(worker.coordinator.worker_count / 2) { 	// throttle stealing to half the total thread count
			sync.atomic_add(&worker.coordinator.search_count, 1) // register the stealing
			steal(worker) // start stealing
			sync.atomic_sub(&worker.coordinator.search_count, 1) // register the stealing
		}

	}
}


// takes a worker context from the context
spawn_task :: proc(task: Task) {
	worker := get_worker()

	sync.mutex_lock(&worker.localq_mutex) // lock the mutex
	defer sync.mutex_unlock(&worker.localq_mutex)

	queue.append_elem(&worker.localq, task)
}

setup_thread :: proc(worker: ^Worker) -> ^thread.Thread {
	log.debug("setting up thread")
	queue.init(&worker.localq)

	// weird name to avoid collision
	thrd := thread.create(worker_runloop) // make a worker thread

	worker.timestamp = time.tick_now()

	ctx := context

	arena_alloc := vmem.arena_allocator(&worker.arena)

	ctx.allocator = arena_alloc

	ref_carrier := new_clone(Ref_Carrier{worker = worker, user_ptr = nil})
	ctx.user_ptr = ref_carrier

	thrd.init_context = ctx

	log.debug("built thread")
	return thrd

}

make_task :: proc(p: proc(_: Worker)) -> Task {
	return Task{effect = p}
}


init :: proc(coord: ^Coordinator, cfg: Config, init_task: Task) {
	log.debug("starting worker system")
	coord.worker_count = cfg.worker_count

	// set up the global chan
	log.debug("setting up global channel")

	ch, aerr := chan.create(chan.Chan(Task), context.allocator)
	coord.globalq = ch

	log.debug("setting up loggers")
	for i in 1 ..= coord.worker_count {
		worker := Worker{}
		worker.coordinator = coord
		append(&coord.workers, worker)

		thrd := setup_thread(&worker)
		thread.start(thrd)
		log.debug("started", i, "th worker")
	}

	// theats the main thread as a worker too
	if cfg.use_main_thread == true {
		main_worker := Worker{}
		main_worker.coordinator = coord
		queue.init(&main_worker.localq)
		arena_alloc := vmem.arena_allocator(&main_worker.arena)
		main_worker.timestamp = time.tick_now()

		context.allocator = arena_alloc

		ref_carrier := new_clone(Ref_Carrier{worker = &main_worker, user_ptr = nil})
		context.user_ptr = ref_carrier

		shim_ptr: ^thread.Thread // not gonna use it

		append(&coord.workers, main_worker)
		coord.worker_count += 1

		log.debug("sending first task")
		if chan.send(ch, init_task) {
			log.debug("first task sent")
		}

		worker_runloop(shim_ptr)
	}

	if chan.send(ch, init_task) {
		log.debug("first task sent")
	}
}
