#+private
package oasync

import "base:runtime"
import "core:log"
import "core:math/rand"
import "core:sync"
import "core:thread"
import "core:time"

compute_blocking_count :: proc(workers: []Worker) -> int {
	count := 0
	for &worker in workers {
		if worker.is_blocking {
			count += 1
		}
	}
	return count
}


compute_steal_count :: proc(current_worker: ^Worker) -> (count: int) {
	for worker in current_worker.coordinator.workers {
		if worker.is_stealing {
			count += 1
		}
	}
	return
}

// should a task be run? should it be dropped? should 
// we requeue it?
get_task_run_status :: proc(t: ^Task, worker: ^Worker) -> Task_Run_Status {
	// resources
	if t.mods.resource != nil && !acquire_res(t.mods.resource, t) {
		return .Requeue
	}

	// cyclic barrier
	if t.mods.cyclic_barrier != nil && !acquire_cb(t.mods.cyclic_barrier, t) {
		return .Requeue
	}

	// count down latch
	if t.mods.count_down_latch != nil && !acquire_cdl(t.mods.count_down_latch, t) {
		return .Requeue
	}

	// sema
	if t.mods.semaphore != nil && !acquire_sem(t.mods.semaphore) {
		return .Requeue
	}

	// backpressure
	if t.mods.backpressure != nil {
		switch acquire_bp(t.mods.backpressure) {
		case .Run:
		// continue
		case .Drop:
			return .Drop
		case .Requeue:
			return .Requeue
		}
	}

	// blocking
	current_count := compute_blocking_count(worker.coordinator.workers)
	if t.mods.is_blocking {
		if current_count >= worker.coordinator.max_blocking_count {
			return .Requeue
		}
		worker.is_blocking = true
	}

	// timed
	EMPTY_TICK :: time.Tick{}
	if t.mods.execute_at != EMPTY_TICK {
		now := time.tick_now()
		diff := time.tick_diff(t.mods.execute_at, now)
		if time.duration_milliseconds(diff) <= 0 {
			// it is in future
			// we are not executing tasks that is supposed to be 
			// ran in future
			return .Requeue
		}
	}

	return .Run
}

trace_execution :: proc(t: ^Task, worker: ^Worker) {
	trace(
		get_worker_id(),
		"executed task",
		t.id,
		"now queue has",
		queue_len(&worker.localq),
		"items",
	)
}

Effect_Union :: union {
	proc(_: rawptr),
	proc(_: rawptr) -> rawptr,
}

wrap_measure :: proc(e: Effect_Union, supply: rawptr, t: ^Task) -> (ret: rawptr) {
	when ODIN_DEBUG {
		start_time := time.tick_now()
	}
	switch v in e {
	case proc(_: rawptr):
		v(supply)
	case proc(_: rawptr) -> rawptr:
		ret = v(supply)
	}
	when ODIN_DEBUG {
		end_time := time.tick_now()
		diff := time.tick_diff(start_time, end_time)
		exec_duration := time.duration_milliseconds(diff)
		if exec_duration > 40 && !t.mods.is_blocking {
			log.warn(
				"oasync debug runtime detected a task at location",
				t.loc,
				"executing with duration longer than 40ms,",
				"this may be sign that you are unintentionally running blocking I/O operations",
				"without using blocking dispatch",
			)
		}
	}
	return
}

Execution_Status :: enum {
	// finish the execution of a task
	Pass,
	// return immediately without cleanup
	Drop,
	// execute next task in chain 
	Advance,
}

// execute effect
run_effect :: proc(t: ^Task, worker: ^Worker) -> Execution_Status {
	switch &v in t.effect {
	case Singleton_Effect:
		if _, ok := sync.atomic_compare_exchange_strong_explicit(
			&v.is_done,
			false,
			true,
			.Consume,
			.Relaxed,
		); ok {
			wrap_measure(v.effect, t.arg, t)
		} else {
			trace("WARNING: ATTEMPTING TO RE-EXECUTE TASKS THAT ARE DONE")
			return .Drop
		}
	case Chain_Effect:
		ef := &v.effects[v.idx]

		if _, ok := sync.atomic_compare_exchange_strong_explicit(
			&ef.is_done,
			false,
			true,
			.Consume,
			.Relaxed,
		); ok {
			t.arg = wrap_measure(ef.effect, t.arg, t)
		} else {
			trace("WARNING: ATTEMPTING TO RE-EXECUTE TASKS THAT ARE DONE")
			return .Drop
		}

		// update the effect chain
		if v.idx < len(v.effects) - 1 {
			v.idx += 1
			return .Advance
		} else {
			return .Pass
		}
	}
	return .Pass
}

release_primitives :: proc(t: ^Task, worker: ^Worker, rel_bp := true) {
	if t.mods.resource != nil {
		release_res(t.mods.resource, t)
	}

	if rel_bp && t.mods.backpressure != nil {
		release_bp(t.mods.backpressure)
	}

	if t.mods.semaphore != nil {
		release_sem(t.mods.semaphore)
	}

	if t.mods.is_blocking {
		worker.is_blocking = false
	}

}

slot_run_next :: proc(t: ^Task, worker: ^Worker) {
	if worker.run_next != nil {
		// something is already there! push it back!
		spawn_task(worker.run_next)
		// and null it 
		worker.run_next = t
	} else {
		worker.run_next = t
	}
}

run_task :: proc(t: ^Task, worker: ^Worker) {
	// if it is running a task, it isn't stealing
	worker.is_stealing = false

	worker.current_running = t

	_, is_singleton := t.effect.(Singleton_Effect)

	// should not cause casting error due to short circuiting
	if is_singleton || t.effect.(Chain_Effect).idx == 0 {
		switch get_task_run_status(t, worker) {
		case .Run:
		case .Requeue:
			slot_run_next(t, worker)
			return
		case .Drop:
			release_primitives(t, worker, rel_bp = falsee)
			free(t)
			return
		}
	}

	// execute the function pointer
	switch run_effect(t, worker) {
	case .Pass:
	// continue
	case .Advance:
		// spawn task again so the next task in chain could be executed
		// do not release primitives
		spawn_task(t)
		return
	case .Drop:
		// do not execute task 
		// release primitives and drop now
		release_primitives(t, worker)
		return
	}

	if is_singleton {
		release_primitives(t, worker)
	} else {
		se := &t.effect.(Chain_Effect)
		release_primitives(t, worker)
		delete(se.effects)
	}

	free(t)
}

clean_local_queue :: proc(q: ^Local_Queue(^Task)) {
	for {
		item, ok := queue_pop(q)
		if !ok {
			// empty
			return
		}

		switch v in item.effect {
		case Singleton_Effect:
			free(item)
		case Chain_Effect:
			delete(v.effects)
			free(item)
		}
	}

}

_shutdown :: proc(graceful := true) {
	worker := get_worker()

	if worker.coordinator.is_running == false {
		return
	}

	worker.coordinator.is_running = false
	for &worker in worker.coordinator.workers {
		clean_local_queue(&worker.localq)
		if worker.hogs_main_thread {
			continue
		}
		if graceful != true {
			thread.terminate(worker.thread_obj, 0)
		}
		log.info("destroying worker id", worker.id)
		thread.destroy(worker.thread_obj)
	}
	log.info("deleting workers")
	delete(worker.coordinator.workers)
	log.info("deleting global queue")
	gqueue_delete(&worker.coordinator.globalq)
}

make_effect_chain :: proc(s: ^[]proc(_: rawptr) -> rawptr) -> Chain_Effect {
	re := make([]Returning_Effect, len(s))
	for effect, idx in s {
		re[idx] = Returning_Effect {
			effect  = effect,
			is_done = false,
		}
	}
	return Chain_Effect{effects = re, idx = 0}
}

make_task :: proc(
	p: Effect_Input,
	data: rawptr,
	is_blocking: bool,
	execute_at: time.Tick,
	is_parentless: bool,
	res: ^Resource,
	bp: ^Backpressure,
	cdl: ^Count_Down_Latch,
	cb: ^Cyclic_Barrier,
	sem: ^Semaphore,
	loc: runtime.Source_Code_Location,
) -> ^Task {
	tid: Task_Id

	if is_parentless {
		tid.parentless = true
	} else {
		worker := get_worker()
		tid.task_id = worker.task_id_gen
		worker.task_id_gen += 1
	}

	ef: Effect
	switch v in p {
	case proc(_: rawptr):
		ef = Singleton_Effect {
			effect = v,
		}
	case ^[]proc(_: rawptr) -> rawptr:
		ef = make_effect_chain(v)
		free(v)
	}

	tsk := new_clone(
		Task {
			effect = ef,
			arg = data,
			id = tid,
			loc = loc,
			mods = Task_Modifiers {
				is_blocking = is_blocking,
				execute_at = execute_at,
				resource = res,
				backpressure = bp,
				cyclic_barrier = cb,
				count_down_latch = cdl,
				semaphore = sem,
			},
		},
	)

	return tsk
}

// takes a worker context from the context
spawn_task :: proc(task: ^Task) {
	worker := get_worker()

	queue_push_or_overflow(&worker.localq, task, &worker.coordinator.globalq)
}


spawn_unsafe_task :: proc(task: ^Task, coord: ^Coordinator) {
	gqueue_push(&coord.globalq, task)
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
		ix := (start + i) % num
		// this must be a pointer
		worker := &this.coordinator.workers[ix]
		if worker.id == this.id {
			// same id, and don't steal from self,
			continue
		}

		task, steal_ok := queue_steal(&worker.localq)
		if steal_ok {
			return task, true
		}
	}
	return
}

// event loop that every worker runs
worker_runloop :: proc(t: ^thread.Thread) {
	worker := get_worker()
	// during shutdown, worker is freed 
	// thus segmented fault will be caused by 
	// accessing worker.coordinator.is_running
	// for this reason the coordinator pointer 
	// should be stored on the stack
	coord := worker.coordinator

	sync.barrier_wait(worker.barrier_ref)

	log.info("runloop started for worker id", worker.id)
	for {
		if !coord.is_running {
			// termination
			free(cast(^Ref_Carrier)context.user_ptr)
			return
		}

		if worker.run_next != nil {
			run_task(worker.run_next, worker)
			worker.run_next = nil
			continue
		}

		// tasks in local queue gets scheduled first
		tsk, exist := queue_pop(&worker.localq)
		if exist {
			run_task(tsk, worker)
			continue
		}

		// local queue seems to be empty at this point, take a look 
		// at the global channel
		tsk, exist = gqueue_pop(&worker.coordinator.globalq)
		if exist {
			run_task(tsk, worker)

			continue
		}

		scount := compute_steal_count(worker)
		// global queue seems to be empty too, enter stealing mode 

		// throttle stealing to half the total thread count
		if scount < (worker.coordinator.worker_count / 2) {
			worker.is_stealing = true
		}

		// only steal when allowed
		if worker.is_stealing {
			stolen_task, succ := steal(worker) // start stealing
			if succ {
				run_task(stolen_task, worker)
			}
		}

	}
	log.info("runloop stopped for worker id", worker.id)
}

setup_worker :: proc(
	worker: ^Worker,
	coord: ^Coordinator,
	id: u8,
	thread: ^thread.Thread,
	barrier: ^sync.Barrier,
	is_main: bool,
) {
	worker.id = id
	worker.localq = Local_Queue(^Task){}
	worker.rng_seed = rand.int31()
	worker.thread_obj = thread
	worker.barrier_ref = barrier
	worker.coordinator = coord
	worker.hogs_main_thread = is_main
}

setup_thread :: proc(worker: ^Worker) -> ^thread.Thread {
	worker.localq = Local_Queue(^Task){}
	worker.rng_seed = rand.int31()

	// weird name to avoid collision
	thrd := thread.create(worker_runloop) // make a worker thread

	ctx := context

	ref_carrier := new_clone(Ref_Carrier{worker = worker, user_ptr = nil})
	ctx.user_ptr = ref_carrier

	thrd.init_context = ctx

	worker.thread_obj = thrd

	return thrd

}

_init :: proc(
	coord: ^Coordinator,
	init_task: ^Task,
	worker_count: int,
	blocking_worker_count: int,
	use_main_thread: bool,
	trace_print: bool,
) {
	log.info("starting worker system")

	// setup coordinator
	coord.worker_count = worker_count
	coord.max_blocking_count = blocking_worker_count
	coord.is_running = true
	debug_trace_print = trace_print

	// make workers
	workers := make([]Worker, int(worker_count))
	coord.workers = workers

	// for generating unique id for each worker
	id_gen: u8

	// barrier
	barrier := sync.Barrier{}
	sync.barrier_init(&barrier, int(worker_count))

	// global queue
	coord.globalq = make_gqueue(^Task)

	required_worker_count := coord.worker_count
	if use_main_thread {
		required_worker_count -= 1
	}

	for i in 0 ..< required_worker_count {
		worker := &coord.workers[i]

		thrd := setup_thread(worker)
		setup_worker(
			worker = worker,
			coord = coord,
			id = id_gen,
			thread = thrd,
			barrier = &barrier,
			is_main = false,
		)

		id_gen += 1

		thread.start(thrd)
	}

	gqueue_push(&coord.globalq, init_task)

	// treats the main thread as a worker too
	if use_main_thread == true {
		main_worker := &coord.workers[required_worker_count]
		setup_worker(
			worker = main_worker,
			coord = coord,
			id = id_gen,
			thread = nil,
			barrier = &barrier,
			is_main = true,
		)

		ref_carrier := new_clone(Ref_Carrier{worker = main_worker, user_ptr = nil})
		context.user_ptr = ref_carrier

		worker_runloop(nil)
	}
}
