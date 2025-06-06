#+private
package oasync

import "core:fmt"
import "core:log"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:sync"
import "core:thread"
import "core:time"

// get worker from context
get_worker :: proc() -> ^Worker {
	carrier := cast(^Ref_Carrier)context.user_ptr
	return carrier.worker
}

steal :: proc(this: ^Worker) -> bool {
	// steal from a random worker
	worker: Worker

	// limit the times so this doesn't hog forever
	for {
		worker = rand.choice(this.coordinator.workers[:])
		if worker.id == this.id {
			// same id, and don't steal from self,
			continue
		}
		break
	}

	// log.debug("worker", get_worker_id(), "is stealing from", worker.id)
	_, ok := queue_steal_into(&worker.localq, &this.localq)
	return ok
}

compute_blocking_count :: proc(workers: []Worker) -> int {
	// log.debug("worker count", len(workers))
	count := 0
	for worker in workers {
		// log.debug(worker.is_blocking)
		if worker.is_blocking {
			count += 1
		}
	}
	return count
}

run_task :: proc(t: Task, worker: ^Worker) {
	current_count := compute_blocking_count(worker.coordinator.workers)
	// log.debug(get_worker_id(), "current_count is", current_count)
	if t.is_blocking {
		if current_count >= worker.coordinator.max_blocking_count {
			spawn_task(t)
			return
		}
		worker.is_blocking = true
	}

	when ODIN_DEBUG {
		start_time := time.tick_now()
	}
	beh := t.effect(t.arg)

	log.debug("executed the task for", get_worker_id())

	when ODIN_DEBUG {
		end_time := time.tick_now()
		diff := time.tick_diff(start_time, end_time)
		exec_duration := time.duration_milliseconds(diff)
		if exec_duration > 40 && !t.is_blocking {
			log.warn(
				"oasync debug runtime detected a task executing with duration longer than 40ms,",
				"your CPU is likely starving,",
				"this is a sign that you are unintentionally running blocking I/O operations",
				"without using blocking dispatch",
			)
		}

	}

	if t.is_blocking {
		worker.is_blocking = false
	}

	switch behavior in beh {
	case B_None:
		// do nothing
		return
	case B_Cb:
		// call back
		go(behavior.effect, behavior.supply)
	case B_Cbb:
		// blocking callback
		gob(behavior.effect, behavior.supply)
	}
}

// event loop that every worker runs
worker_runloop :: proc(t: ^thread.Thread) {
	worker := get_worker()

	log.debug("awaiting barrier started")
	sync.barrier_wait(worker.barrier_ref)

	log.debug("runloop started for worker id", worker.id)
	for {
		// tasks in local queue gets scheduled first
		tsk, exist := queue_pop(&worker.localq)
		if exist {
			// log.debug("pulled from local queue, running")
			run_task(tsk, worker)

			continue
		}

		// local queue seems to be empty at this point, take a look 
		// at the global channel
		//log.debug("chan recv")
		tsk, exist = gqueue_pop(&worker.coordinator.globalq)
		if exist {
			log.debug("got item from global channel")
			run_task(tsk, worker)

			continue
		}

		// global queue seems to be empty too, enter stealing mode 
		// increment the stealing count
		// this part needs A LOT OF work
		//log.debug("steal")
		scount := sync.atomic_load(&worker.coordinator.steal_count)
		if scount < (worker.coordinator.worker_count / 2) { 	// throttle stealing to half the total thread count
			sync.atomic_add(&worker.coordinator.steal_count, 1) // register the stealing
			did_steal := steal(worker) // start stealing
			// if did_steal {
			// 	log.debug(worker.id, "did steal")
			// }
			sync.atomic_sub(&worker.coordinator.steal_count, 1) // register the stealing
		}

	}
}


// takes a worker context from the context
spawn_task :: proc(task: Task) {
	worker := get_worker()

	queue_push_back_or_overflow(&worker.localq, task, &worker.coordinator.globalq)
}


spawn_unsafe_task :: proc(task: Task, coord: ^Coordinator) {
	gqueue_push(&coord.globalq, task)
}

setup_thread :: proc(worker: ^Worker) -> ^thread.Thread {
	log.debug("setting up thread for", worker.id)

	log.debug("init queue")
	worker.localq = make_queue(Task, LOCAL_QUEUE_SIZE)

	// weird name to avoid collision
	thrd := thread.create(worker_runloop) // make a worker thread


	ctx := context

	ref_carrier := new_clone(Ref_Carrier{worker = worker, user_ptr = nil})
	ctx.user_ptr = ref_carrier

	thrd.init_context = ctx

	log.debug("built thread")
	return thrd

}

// doesn't need to be thread safe
// this is for debug only
id_gen: int

make_task :: proc(p: proc(_: rawptr) -> Behavior, data: rawptr, is_blocking := false) -> Task {
	id_gen += 1
	return Task{effect = p, arg = data, is_blocking = is_blocking, id = id_gen}
}

_init :: proc(coord: ^Coordinator, cfg: Config, init_task: Task) {
	log.debug("starting worker system")
	coord.worker_count = cfg.worker_count
	coord.max_blocking_count = cfg.blocking_worker_count

	workers := make([]Worker, int(cfg.worker_count))
	coord.workers = workers


	id_gen: u8

	// set up the global chan
	log.debug("setting up global channel")

	barrier := sync.Barrier{}
	log.info("starting worker system with", cfg.worker_count, "workers")
	sync.barrier_init(&barrier, int(cfg.worker_count))

	coord.globalq = make_gqueue(Task)

	required_worker_count := coord.worker_count
	if cfg.use_main_thread {
		required_worker_count -= 1
	}

	for i in 0 ..< required_worker_count {
		worker := &coord.workers[i]

		worker.id = id_gen
		id_gen += 1

		// load in the barrier
		worker.barrier_ref = &barrier
		worker.coordinator = coord

		thrd := setup_thread(worker)
		thread.start(thrd)
	}

	log.debug("sending first task")
	gqueue_push(&coord.globalq, init_task)

	// theats the main thread as a worker too
	if cfg.use_main_thread == true {
		main_worker := &coord.workers[required_worker_count]
		main_worker.barrier_ref = &barrier
		main_worker.coordinator = coord

		main_worker.localq = make_queue(Task, LOCAL_QUEUE_SIZE)

		log.debug("the id of the main worker is", id_gen)
		main_worker.id = id_gen

		ref_carrier := new_clone(Ref_Carrier{worker = main_worker, user_ptr = nil})
		context.user_ptr = ref_carrier

		shim_ptr: ^thread.Thread // not gonna use it

		coord.worker_count += 1

		worker_runloop(shim_ptr)
	}
}
