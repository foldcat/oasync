package oasync

import "core:container/queue"
import "core:sync"

// a mutex acquired by a task
Resource :: struct {
	owner: Task_Id,
}

// mutable definition due to odin compiler not allowing this 
// to be a constant
@(private)
Empty_Id := Task_Id {
	is_empty      = true,
	parentless    = false,
	parent_worker = 0,
	task_id       = 0,
}

make_resource :: proc() -> ^Resource {
	return new_clone(Resource{owner = Empty_Id})
}

free_resource :: proc(r: ^Resource) {
	free(r)
}

@(private)
acquire_res :: proc(r: ^Resource, t: ^Task) -> bool {
	_, ok := sync.atomic_compare_exchange_strong_explicit(
		&r.owner,
		Empty_Id,
		t.id,
		.Acquire,
		.Acquire,
	)
	return ok
}

@(private)
release_res :: proc(r: ^Resource, t: ^Task) -> bool {
	_, ok := sync.atomic_compare_exchange_strong_explicit(
		&r.owner,
		t.id,
		Empty_Id,
		.Release,
		.Relaxed,
	)
	return ok
}

/*
acquires a resource in the middle of a task via a spinlock
must be released within the same task / task chain
*/
res_spinlock_acquire :: proc(r: ^Resource) {
	worker := get_worker()
	for {
		if acquire_res(r, worker.current_running) {
			return
		}
	}
}

/* 
releases a spinlocked resource
panics when not executed within a task chain / task
that the acquire is in
*/
res_spinlock_release :: proc(r: ^Resource) {
	worker := get_worker()
	if !release_res(r, worker.current_running) {
		panic(
			`
      cannot release spinlock, this may be due to the release procedure being executed 
      not within the task / task chain that acquired the spinlock
      or from releasing the same resources twice
      `,
		)
	}
}


/*
backpressure allows you to control how many tasks (max) are run at 
the same time, 2 modes are offered

should more than max amount of tasks tries to acquire 
backpressure,
Loseless: the task will block until backpressure is alleviated
Lossy: the task will not be ran
*/
Backpressure :: struct {
	max:              int,
	current_runcount: int,
	mode:             BP_Mode,
	is_closed:        bool,
}

BP_Mode :: enum {
	Loseless,
	Lossy,
}

/*
make a backpressure, seek documentation on the 
Backpressure struct for more info

allocated on the heap
*/
make_bp :: proc(max: int, mode: BP_Mode) -> ^Backpressure {
	return new_clone(Backpressure{max = max, mode = mode})
}


/*
wait for all the tasks to be done and frees the backpressure 
in the time of waiting, new tasks dispatched through backpressure 
is dropped 

should all remaining tasks be done, frees the backpressure struct

attempting to reacquire may result in segmented fault
*/
destroy_bp :: proc(bp: ^Backpressure) {
	bp.is_closed = true
	if sync.atomic_load(&bp.current_runcount) == 0 {
		free(bp)
	}
}


// task should be push back into the local queue should 
// this procedure return false
@(private)
acquire_bp :: proc(bp: ^Backpressure) -> Task_Run_Status {
	if bp.is_closed {
		return .Drop
	}
	can_run := sync.atomic_load(&bp.current_runcount) < bp.max
	if can_run {
		sync.atomic_add(&bp.current_runcount, 1)
	}
	switch bp.mode {
	case .Loseless:
		if can_run {
			return .Run
		} else {
			return .Requeue
		}
	case .Lossy:
		if can_run {
			return .Run
		} else {
			return .Drop
		}
	}
	panic("unreachable")
}

@(private)
release_bp :: proc(bp: ^Backpressure) {
	sync.atomic_sub(&bp.current_runcount, 1)
	if bp.is_closed == true {
		if sync.atomic_load(&bp.current_runcount) == 0 {
			free(bp)
		}
	}
}

/* 
one shot concurrency primitive that blocks any tasks
waiting on it until `goal` tasks are waiting

further acquires are no-op
*/
Count_Down_Latch :: struct {
	goal:           int,
	awaiting_tasks: map[Task_Id]bool,
}

make_cdl :: proc(goal: int) -> ^Count_Down_Latch {
	return new_clone(Count_Down_Latch{goal = goal, awaiting_tasks = make(map[Task_Id]bool)})
}

acquire_cdl :: proc(cdl: ^Count_Down_Latch, t: ^Task) -> bool {
	if len(cdl.awaiting_tasks) >= cdl.goal {
		return true
	}
	// anything will work as long as it exists
	cdl.awaiting_tasks[t.id] = false
	return false
}

delete_cdl :: proc(cdl: ^Count_Down_Latch) {
	delete(cdl.awaiting_tasks)
	free(cdl)
}

/*
allows a set of tasks to wait unti the amount of waiting 
tasks reaches a goal
*/
Cyclic_Barrier :: struct {
	goal:             int,
	queue:            queue.Queue(Task_Id),
	release_waitlist: ^[dynamic]Task_Id,
	mutex:            ^Resource,
	set:              ^map[Task_Id]bool,
}

// make a cyclic barrier, see Cyclic_Barrier struct
make_cb :: proc(goal: int) -> ^Cyclic_Barrier {
	cb := new(Cyclic_Barrier)
	queue.init(&cb.queue)
	res := make_resource()
	cb.mutex = res
	set := new(map[Task_Id]bool)
	cb.set = set
	cb.release_waitlist = new([dynamic]Task_Id)
	cb.goal = goal
	return cb
}

destroy_cb :: proc(cb: ^Cyclic_Barrier) {
	queue.destroy(&cb.queue)
	free_resource(cb.mutex)
	delete(cb.release_waitlist^)
	delete(cb.set^)
}

@(private)
acquire_cb :: proc(cb: ^Cyclic_Barrier, t: ^Task) -> bool {
	// can't acquire resource 
	// try again
	if !acquire_res(cb.mutex, t) {
		return false
	}
	defer release_res(cb.mutex, t)

	// search for item in release waitlist
	for item, idx in cb.release_waitlist {
		if item == t.id {
			// item is in release waitlist
			// delete it
			unordered_remove(cb.release_waitlist, idx)
			// also delete the set item
			delete_key(cb.set, item)
			// allow it to execute
			return true
		}
	}

	// is goal reached?
	if queue.len(cb.queue) >= cb.goal {
		for _ in 1 ..= cb.goal {
			item := queue.pop_front(&cb.queue)
			append(cb.release_waitlist, item)
		}
	}

	// push into waiting
	if t.id not_in cb.set {
		trace("push into waiting")
		queue.push_back(&cb.queue, t.id)
		// we use a map as a set 
		// the value of the items doesn't matter 
		// we only care if it exists or not
		cb.set[t.id] = false
	}

	return false
}
