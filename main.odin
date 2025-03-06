package oasync

import "core:fmt"
import "core:log"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:sync"
import "core:thread"
import "core:time"

Rawptr_Task :: struct {
	// void * generic
	// sometimes i wish for a more complex type system
	effect: proc(input: rawptr),
	supply: rawptr,
}

Unit_Task :: struct {
	effect: proc(),
}

Task :: union {
	Rawptr_Task,
	Unit_Task,
}

// 2 ^ 8
LOCAL_QUEUE_SIZE :: 256

Worker_Type :: enum {
	Generic,
	Blocking,
}

// assigned to each thread
Worker :: struct {
	barrier_ref: ^sync.Barrier,
	localq:      Local_Queue(Task, LOCAL_QUEUE_SIZE),
	run_next:    Task,
	timestamp:   time.Tick, // acts as identifier for each worker, should never collide
	coordinator: ^Coordinator,
	arena:       vmem.Arena,
	type:        Worker_Type,
}

// heart of the async scheduler
Coordinator :: struct {
	workers:               [dynamic]Worker, // could do a static sized one but requires too much parapoly to make worth
	worker_count:          u8,
	blocking_workers:      [dynamic]Worker,
	blocking_worker_count: u8,
	globalq:               Global_Queue(Task),
	global_blockingq:      Global_Queue(Task),
	search_count:          u8, // ATOMIC ONLY!
}

Config :: struct {
	worker_count:          u8,
	blocking_worker_count: u8,
	use_main_thread:       bool,
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
	worker: Worker

	switch this.type {
	case .Generic:
		// generic workers should not be allowed to steal blocking task
		worker = rand.choice(this.coordinator.workers[:])
	case .Blocking:
		if rand.float32() > 0.5 {
			worker = rand.choice(this.coordinator.workers[:])
		} else {
			worker = rand.choice(this.coordinator.blocking_workers[:])
		}
	}

	if worker.timestamp == this.timestamp {
		// same id, and don't steal from self,
		return
	}

	// we don't steal from queues that doesn't have items
	queue_length := queue_length(&worker.localq)
	if queue_length == 0 {
		return
	}

	// steal half of the text once we find one
	for i in 1 ..= u64(queue_length / 2) { 	// TODO: need further testing
		elem, ok := queue_nonlocal_pop(&worker.localq)
		if !ok {
			log.error("failed to steal")
			return
		}

		queue_push(&this.localq, elem)
	}

}

// unsafe function: do not use
run_task :: proc(t: Task) {
	switch tsk in t {
	case Rawptr_Task:
		tsk.effect(tsk.supply)
	case Unit_Task:
		tsk.effect()
	}
}

// event loop that every worker runs
worker_runloop :: proc(t: ^thread.Thread) {
	worker := get_worker()

	log.debug("awaiting barrier started")
	sync.barrier_wait(worker.barrier_ref)

	log.debug("runloop started")
	for {
		// wipe the arena every loop
		arena := worker.arena
		defer vmem.arena_free_all(&arena)

		// tasks in local queue gets scheduled first
		//log.debug("pop")
		tsk, exist := queue_pop(&worker.localq)
		if exist {
			log.debug("pulled from local queue, running")
			run_task(tsk)

			continue
		}

		// here are for a blocking worker 
		if worker.type == .Blocking {
			tsk, exist = gqueue_pop(&worker.coordinator.global_blockingq)
			if exist {
				log.debug("got item from global blocking channel")
				run_task(tsk)

				continue
			}
		}

		// local queue seems to be empty at this point, take a look 
		// at the global channel
		//log.debug("chan recv")
		tsk, exist = gqueue_pop(&worker.coordinator.globalq)
		if exist {
			log.debug("got item from global channel")
			run_task(tsk)

			continue
		}

		// global queue seems to be empty too, enter stealing mode 
		// increment the stealing count
		// this part needs A LOT OF work
		//log.debug("steal")
		scount := sync.atomic_load(&worker.coordinator.search_count)
		if scount < (worker.coordinator.worker_count / 2) { 	// throttle stealing to half the total thread count
			sync.atomic_add(&worker.coordinator.search_count, 1) // register the stealing
			steal(worker) // start stealing
			sync.atomic_sub(&worker.coordinator.search_count, 1) // register the stealing
		}

	}
}


// takes a worker context from the context
spawn_task :: proc(task: Task) {
	worker := get_worker()

	queue_push(&worker.localq, task)
}

// blocking tasks are pushed onto a queue
spawn_blocking_task :: proc(task: Task) {
	worker := get_worker()

	switch worker.type {
	case .Generic:
		gqueue_push(&worker.coordinator.global_blockingq, task)
	case .Blocking:
		queue_push(&worker.localq, task)
	}
}

setup_thread :: proc(worker: ^Worker) -> ^thread.Thread {
	worker.timestamp = time.tick_now()

	log.debug("setting up thread for", worker.timestamp)

	log.debug("init queue")
	worker.localq = make_queue(Task, LOCAL_QUEUE_SIZE)

	// weird name to avoid collision
	thrd := thread.create(worker_runloop) // make a worker thread


	ctx := context

	log.debug("creating arena alloc")
	arena_alloc := vmem.arena_allocator(&worker.arena)

	ctx.allocator = arena_alloc

	ref_carrier := new_clone(Ref_Carrier{worker = worker, user_ptr = nil})
	ctx.user_ptr = ref_carrier

	thrd.init_context = ctx

	log.debug("built thread")
	return thrd

}

make_unit_task :: proc(p: proc()) -> Task {
	return Unit_Task{effect = p}
}

make_rawptr_task :: proc(p: proc(supply: rawptr), supply: rawptr) -> Task {
	return Rawptr_Task{effect = p, supply = supply}
}

make_task :: proc {
	make_unit_task,
	make_rawptr_task,
}

go_unit :: proc(p: proc()) {
	spawn_task(make_task(p))
}

go_rawptr :: proc(p: proc(supply: rawptr), data: rawptr) {
	spawn_task(make_task(p, data))
}

go :: proc {
	go_unit,
	go_rawptr,
}

gob_unit :: proc(p: proc()) {
	spawn_blocking_task(make_task(p))
}

gob_rawptr :: proc(p: proc(supply: rawptr), data: rawptr) {
	spawn_blocking_task(make_task(p, data))
}

gob :: proc {
	gob_unit,
	gob_rawptr,
}

init :: proc(coord: ^Coordinator, cfg: Config, init_task: Task) {
	log.debug("starting worker system")
	coord.worker_count = cfg.worker_count
	coord.blocking_worker_count = cfg.blocking_worker_count

	// set up the global chan
	log.debug("setting up global channel")

	barrier := sync.Barrier{}
	sync.barrier_init(&barrier, int(cfg.worker_count + cfg.blocking_worker_count))

	coord.globalq = make_gqueue(Task)

	for i in 1 ..= coord.worker_count {
		worker := Worker{}
		// load in the barrier
		worker.barrier_ref = &barrier
		worker.coordinator = coord
		worker.type = Worker_Type.Generic
		append(&coord.workers, worker)

		thrd := setup_thread(&worker)
		thread.start(thrd)
		log.debug("started", i, "th worker")
	}

	for i in 1 ..= coord.blocking_worker_count {
		worker := Worker{}
		// load in the barrier
		worker.barrier_ref = &barrier
		worker.coordinator = coord
		worker.type = Worker_Type.Blocking
		append(&coord.workers, worker)

		thrd := setup_thread(&worker)
		thread.start(thrd)
		log.debug("started", i, "th blocking worker")
	}

	// chan send freezes indefinitely when nothing is listening to it
	// thus it is placed here
	log.debug("sending first task")

	gqueue_push(&coord.globalq, init_task)

	// theats the main thread as a worker too
	if cfg.use_main_thread == true {
		main_worker := Worker{}
		main_worker.barrier_ref = &barrier
		main_worker.coordinator = coord

		main_worker.localq = make_queue(Task, LOCAL_QUEUE_SIZE)

		arena_alloc := vmem.arena_allocator(&main_worker.arena)
		main_worker.timestamp = time.tick_now()

		context.allocator = arena_alloc

		ref_carrier := new_clone(Ref_Carrier{worker = &main_worker, user_ptr = nil})
		context.user_ptr = ref_carrier

		shim_ptr: ^thread.Thread // not gonna use it

		append(&coord.workers, main_worker)
		coord.worker_count += 1

		worker_runloop(shim_ptr)
	}
}
