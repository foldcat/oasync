#+private
package oasync

import "base:runtime"
import "core:log"
import "core:math/rand"
import "core:sync"
import "core:thread"
import "core:time"

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
		switch acquire_bp(t.mods.backpressure, t) {
		case .Run:
		// continue
		case .Drop:
			return .Drop
		case .Requeue:
			return .Requeue
		case .Delay:
			return .Delay
		}
	}

	// blocking
	current_count := sync.atomic_load_explicit(&worker.coordinator.blocking_count, .Relaxed)
	if t.mods.is_blocking {
		if current_count >= worker.coordinator.max_blocking_count {
			return .Requeue
		}
		worker.is_blocking = true
		sync.atomic_add_explicit(&worker.coordinator.blocking_count, 1, .Relaxed)
	}

	// timed
	EMPTY_TICK :: time.Tick{}
	if t.mods.execute_at != EMPTY_TICK {
		now := time.tick_now()
		diff := time.tick_diff(now, t.mods.execute_at)

		// it is in future
		// we are not executing tasks that is supposed to be
		// ran in future
		if time.duration_nanoseconds(diff) > 0 {
			return .Delay
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
		sync.atomic_sub_explicit(&worker.coordinator.blocking_count, 1, .Relaxed)
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
	sync.atomic_sub_explicit(&worker.coordinator.stealing_count, 1, .Relaxed)

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
			release_primitives(t, worker, rel_bp = false)
			free(t)
			return

		case .Delay:
			coord := worker.coordinator
			sync.mutex_lock(&coord.timed_mutex)
			timed_queue_push(&coord.timed_q, t)
			sync.cond_signal(&coord.timed_cond) // wake bg thread if this is the new closest task
			sync.mutex_unlock(&coord.timed_mutex)
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

	if !worker.coordinator.is_running {
		return
	}

	worker.coordinator.is_running = false

	sync.mutex_lock(&worker.coordinator.timed_mutex)
	sync.cond_signal(&worker.coordinator.timed_cond)
	sync.mutex_unlock(&worker.coordinator.timed_mutex)

	if worker.coordinator.timed_thread != nil {
		thread.join(worker.coordinator.timed_thread)
		thread.destroy(worker.coordinator.timed_thread)
	}

	// free tasks sitting in the timed queue
	for len(worker.coordinator.timed_q.tasks) > 0 {
		item, _ := timed_queue_pop(&worker.coordinator.timed_q)
		switch v in item.effect {
		case Singleton_Effect:
			free(item)
		case Chain_Effect:
			delete(v.effects)
			free(item)
		}
	}
	delete(worker.coordinator.timed_q.tasks)

	for &worker in worker.coordinator.workers {
		clean_local_queue(&worker.localq)
		if worker.hogs_main_thread {
			continue
		}
		if !graceful {
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
	a: u32 : 1103515245
	c: u32 : 12345
	mask: u32 : 0x7fffffff

	next_seed := (a * u32(worker.rng_seed) + c) & mask
	worker.rng_seed = type_of(worker.rng_seed)(next_seed)

	return i32(next_seed) % i32(max)
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

timed_worker_loop :: proc(t: ^thread.Thread) {
	coord := cast(^Coordinator)t.data

	for {
		sync.mutex_lock(&coord.timed_mutex)

		if !coord.is_running {
			sync.mutex_unlock(&coord.timed_mutex)
			return
		}

		task, has_task := timed_queue_peek(&coord.timed_q)
		if !has_task {
			// no timed task, just sleep indefinitely till a new one arrive
			// or the system shuts down
			sync.cond_wait(&coord.timed_cond, &coord.timed_mutex)
			sync.mutex_unlock(&coord.timed_mutex)
			continue
		}

		now := time.tick_now()
		diff := time.tick_diff(now, task.mods.execute_at)
		dur_ns := time.duration_nanoseconds(diff)

		if dur_ns <= 0 {
			// task is ready
			// gotta throw it outta the heap and drop it into gqueue
			_, _ = timed_queue_pop(&coord.timed_q)
			sync.mutex_unlock(&coord.timed_mutex)

			gqueue_push(&coord.globalq, task)
		} else {
			// in future task, sleep till it is ready or a closer task wakes up
			dur := time.Duration(dur_ns)
			sync.cond_wait_with_timeout(&coord.timed_cond, &coord.timed_mutex, dur)
			sync.mutex_unlock(&coord.timed_mutex)
		}
	}
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

		scount := sync.atomic_load_explicit(&worker.coordinator.stealing_count, .Relaxed)
		// global queue seems to be empty too, enter stealing mode

		// throttle stealing to half the total thread count
		if scount < (worker.coordinator.worker_count / 2) {
			worker.is_stealing = true
			sync.atomic_add_explicit(&worker.coordinator.stealing_count, 1, .Relaxed)
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

	// timed threads
	coord.timed_q = Timed_Queue {
		tasks = make([dynamic]^Task),
	}
	coord.timed_thread = thread.create(timed_worker_loop)
	coord.timed_thread.data = coord
	thread.start(coord.timed_thread)

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
	if use_main_thread {
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
