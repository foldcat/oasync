package oasync

import "core:testing"
import "core:time"

TASK_FREE_LIST_INITIAL_CAP :: 256
TASK_FREE_LIST_MAX_CAP :: 4096

@(thread_local)
task_free_list: [dynamic]^Task

task_payload_delete :: proc(t: ^Task) {
	switch v in t.effect {
	case Singleton_Effect:
	// no owned payload
	case Chain_Effect:
		delete(v.effects)
	}
}

task_alloc :: proc(value: Task) -> ^Task {
	if len(task_free_list) > 0 {
		t := pop(&task_free_list)
		t^ = value
		return t
	}

	return new_clone(value)
}

task_recycle :: proc(t: ^Task) {
	if t == nil {
		return
	}

	task_payload_delete(t)

	// clear ref before caching so recycled tasks do not keep old
	// args/modifiers/effect slices alive accidentally
	t^ = Task{}

	if len(task_free_list) < TASK_FREE_LIST_MAX_CAP {
		if cap(task_free_list) == 0 {
			task_free_list = make([dynamic]^Task, 0, TASK_FREE_LIST_INITIAL_CAP)
		}

		append(&task_free_list, t)
		return
	}

	// bound the cache so a burst does not permanently retain unlimited memory.
	free(t)
}

task_free_uncached :: proc(t: ^Task) {
	if t == nil {
		return
	}

	task_payload_delete(t)
	free(t)
}

task_free_list_destroy :: proc() {
	for t in task_free_list {
		free(t)
	}

	delete(task_free_list)
	task_free_list = nil
}

@(test)
test_task_free_list_reuse :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	// start from a clean free list for test thread
	task_free_list_destroy()

	noop :: proc(_: rawptr) {}

	task_a := task_alloc(Task{effect = Singleton_Effect{effect = noop}})

	if task_a == nil {
		testing.fail(t)
		return
	}

	first_ptr := task_a

	task_recycle(task_a)

	if len(task_free_list) != 1 {
		testing.fail(t)
		task_free_list_destroy()
		return
	}

	task_b := task_alloc(Task{effect = Singleton_Effect{effect = noop}})

	if task_b == nil {
		testing.fail(t)
		task_free_list_destroy()
		return
	}

	// next allocation should reuse the previous
	// instead of new_clone
	if task_b != first_ptr {
		testing.fail(t)
		task_recycle(task_b)
		task_free_list_destroy()
		return
	}

	if len(task_free_list) != 0 {
		testing.fail(t)
		task_recycle(task_b)
		task_free_list_destroy()
		return
	}

	task_recycle(task_b)

	if len(task_free_list) != 1 {
		testing.fail(t)
		task_free_list_destroy()
		return
	}

	task_free_list_destroy()
}
