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

// fast random number generator via linear congruential 
// algorithm
// seed is pulled from worker, thus only works 
// inside workers
// by default the seed is generated via a rand.int31()
// and then acted on by the lcg
lcg :: proc(worker: ^Worker, max: int) -> i32 {
	m :: 25253
	a :: 148251
	c :: 10007

	worker.rng_seed = (a * worker.rng_seed + c) % m

	return abs(worker.rng_seed) % i32(max)
}

steal :: proc(this: ^Worker) -> (tsk: ^Task, ok: bool) {
	num := len(this.coordinator.workers)

	// choose the worker to start searching at
	start := int(lcg(this, num))

	// limit the times so this doesn't hog forever
	for i in 0 ..< num {
		i := (start + i) % num
		// this must be a pointer
		worker := &this.coordinator.workers[i]
		if worker.id == this.id {
			// same id, and don't steal from self,
			continue
		}

		task, ok := queue_steal(&worker.localq)
		if ok {
			// trace(get_worker_id(), "stole", task.id, "from", worker.id, "where the queue is", worker.localq)
			return task, true
		}
	}
	return
}

compute_blocking_count :: proc(workers: []Worker) -> int {
	// trace("worker count", len(workers))
	count := 0
	for &worker in workers {
		// trace(worker.is_blocking)
		if sync.atomic_load(&worker.is_blocking) {
			count += 1
		}
	}
	return count
}

run_task :: proc(t: ^Task, worker: ^Worker) {
	// if it is running a task, it isn't stealing
	worker.is_stealing = false

	current_count := compute_blocking_count(worker.coordinator.workers)
	// trace(get_worker_id(), "current_count is", current_count)

	is_blocking := sync.atomic_load(&t.is_blocking)
	if is_blocking {
		if current_count >= worker.coordinator.max_blocking_count {
			spawn_task(t)
			return
		}
		sync.atomic_store(&worker.is_blocking, true)
		is_blocking = true
	}

	when ODIN_DEBUG {
		start_time := time.tick_now()
	}

	beh: Behavior
	if _, ok := sync.atomic_compare_exchange_strong_explicit(
		&t.is_done,
		false,
		true,
		.Consume,
		.Relaxed,
	); ok {
		beh = t.effect(t.arg)
		trace(
			get_worker_id(),
			"executed task",
			t.id,
			"now queue has",
			queue_len(&worker.localq),
			"items",
		)
	} else {
		// trace("WARNING: ATTEMPTING TO RE-EXECUTE TASKS THAT ARE DONE")
		return
	}

	when ODIN_DEBUG {
		end_time := time.tick_now()
		diff := time.tick_diff(start_time, end_time)
		exec_duration := time.duration_milliseconds(diff)
		if exec_duration > 40 && !is_blocking {
			log.warn(
				"oasync debug runtime detected a task executing with duration longer than 40ms,",
				"your CPU is likely starving,",
				"this is a sign that you are unintentionally running blocking I/O operations",
				"without using blocking dispatch",
			)
		}

	}

	if is_blocking {
		sync.atomic_store(&worker.is_blocking, false)
	}

	switch behavior in beh {
	case B_None:
	// do nothing
	case B_Cb:
		// call back
		go(behavior.effect, behavior.supply)
	case B_Cbb:
		// blocking callback
		go(behavior.effect, behavior.supply, block = true)
	}

	free(t)
}

calc_steal_couunt :: proc(current_worker: ^Worker) -> (count: int) {
	for worker in current_worker.coordinator.workers {
		if worker.is_stealing {
			count += 1
		}
	}
	return
}

// event loop that every worker runs
worker_runloop :: proc(t: ^thread.Thread) {
	worker := get_worker()

	trace("awaiting barrier started")
	sync.barrier_wait(worker.barrier_ref)

	trace("runloop started for worker id", worker.id)
	for {
		if !worker.coordinator.is_running {
			// termination
			return
		}

		// tasks in local queue gets scheduled first
		tsk, exist := queue_pop(&worker.localq)
		if exist {
			// trace(get_worker_id(), "pulled task", tsk.id, "from local queue, running")
			run_task(tsk, worker)
			continue
		}

		// local queue seems to be empty at this point, take a look 
		// at the global channel
		//trace("chan recv")
		tsk, exist = gqueue_pop(&worker.coordinator.globalq)
		if exist {
			// trace(get_worker_id(), "pulled task", tsk.id, "from global queue, running")
			run_task(tsk, worker)

			continue
		}

		scount := calc_steal_couunt(worker)
		// global queue seems to be empty too, enter stealing mode 

		// throttle stealing to half the total thread count
		if scount < (worker.coordinator.worker_count / 2) {
			worker.is_stealing = true
		}

		// only steal when allowed
		if worker.is_stealing {
			tsk, succ := steal(worker) // start stealing
			if succ {
				run_task(tsk, worker)
			}
		}

	}
	trace("runloop stopped for worker id", worker.id)
}


// takes a worker context from the context
spawn_task :: proc(task: ^Task) {
	worker := get_worker()

	queue_push_or_overflow(&worker.localq, task, &worker.coordinator.globalq)
}


spawn_unsafe_task :: proc(task: ^Task, coord: ^Coordinator) {
	gqueue_push(&coord.globalq, task)
}

setup_thread :: proc(worker: ^Worker) -> ^thread.Thread {
	trace("setting up thread for", worker.id)

	trace("init queue")
	worker.localq = Local_Queue(^Task){}
	worker.rng_seed = rand.int31()

	// weird name to avoid collision
	thrd := thread.create(worker_runloop) // make a worker thread


	ctx := context

	ref_carrier := new_clone(Ref_Carrier{worker = worker, user_ptr = nil})
	ctx.user_ptr = ref_carrier

	thrd.init_context = ctx

	worker.thread_obj = thrd

	trace("built thread")
	return thrd

}

// doesn't need to be thread safe
// this is for debug only
id_gen: int

make_task :: proc(p: proc(_: rawptr) -> Behavior, data: rawptr, is_blocking := false) -> ^Task {
	id_gen += 1
	tsk := new_clone(Task{effect = p, arg = data, is_blocking = is_blocking, id = id_gen})

	return tsk
}

_shutdown :: proc() {
	worker := get_worker()
	worker.coordinator.is_running = false
	for worker in worker.coordinator.workers {
		if !worker.hogs_main_thread {
			trace("shutting down", worker.id)
			thread.terminate(worker.thread_obj, 0)
		}
	}
	trace("deleting workers")
	delete(worker.coordinator.workers)
	trace("deleting global queue")
	gqueue_delete(&worker.coordinator.globalq)
}

_init :: proc(coord: ^Coordinator, cfg: Config, init_task: ^Task) {
	trace("starting worker system")
	coord.worker_count = cfg.worker_count
	coord.max_blocking_count = cfg.blocking_worker_count
	coord.is_running = true
	debug_trace_print = cfg.debug_trace_print

	workers := make([]Worker, int(cfg.worker_count))
	coord.workers = workers

	id_gen: u8

	barrier := sync.Barrier{}
	log.info("starting worker system with", cfg.worker_count, "workers")
	sync.barrier_init(&barrier, int(cfg.worker_count))

	coord.globalq = make_gqueue(^Task)

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

	trace("sending first task")
	gqueue_push(&coord.globalq, init_task)

	// theats the main thread as a worker too
	if cfg.use_main_thread == true {
		main_worker := &coord.workers[required_worker_count]
		main_worker.barrier_ref = &barrier
		main_worker.coordinator = coord
		main_worker.hogs_main_thread = true
		main_worker.rng_seed = rand.int31()

		main_worker.localq = Local_Queue(^Task){}

		trace("the id of the main worker is", id_gen)
		main_worker.id = id_gen

		ref_carrier := new_clone(Ref_Carrier{worker = main_worker, user_ptr = nil})
		context.user_ptr = ref_carrier

		shim_ptr: ^thread.Thread // not gonna use it

		coord.worker_count += 1

		worker_runloop(shim_ptr)
	}
}
