package oasync

import "core:testing"
import "core:time"

Timed_Queue :: struct {
	tasks: [dynamic]^Task,
}

// returns true if task a should be executed before task b
task_less :: proc(a, b: ^Task) -> bool {
	diff := time.tick_diff(a.mods.execute_at, b.mods.execute_at)
	return time.duration_nanoseconds(diff) > 0
}

timed_queue_push :: proc(q: ^Timed_Queue, task: ^Task) {
	append(&q.tasks, task)
	idx := len(q.tasks) - 1
	for idx > 0 {
		parent := (idx - 1) / 2
		if !task_less(q.tasks[idx], q.tasks[parent]) do break
		q.tasks[idx], q.tasks[parent] = q.tasks[parent], q.tasks[idx]
		idx = parent
	}
}

timed_queue_pop :: proc(q: ^Timed_Queue) -> (task: ^Task, ok: bool) {
	if len(q.tasks) == 0 do return nil, false
	task = q.tasks[0]
	ok = true

	last_idx := len(q.tasks) - 1
	if last_idx > 0 {
		q.tasks[0] = q.tasks[last_idx]
		pop(&q.tasks)

		idx := 0
		n := len(q.tasks)
		for {
			left := idx * 2 + 1
			right := idx * 2 + 2
			smallest := idx

			if left < n && task_less(q.tasks[left], q.tasks[smallest]) {
				smallest = left
			}
			if right < n && task_less(q.tasks[right], q.tasks[smallest]) {
				smallest = right
			}
			if smallest == idx do break
			q.tasks[idx], q.tasks[smallest] = q.tasks[smallest], q.tasks[idx]
			idx = smallest
		}
	} else {
		pop(&q.tasks)
	}
	return
}

timed_queue_peek :: proc(q: ^Timed_Queue) -> (task: ^Task, ok: bool) {
	if len(q.tasks) == 0 do return nil, false
	return q.tasks[0], true
}

@(test)
test_timed_queue_sorting :: proc(t: ^testing.T) {
	q := Timed_Queue {
		tasks = make([dynamic]^Task),
	}
	defer delete(q.tasks)

	t_mid := new(Task)
	t_earliest := new(Task)
	t_latest := new(Task)

	// capture ticks that is in order
	tick1 := time.tick_now()
	time.sleep(time.Millisecond * 5)
	tick2 := time.tick_now()
	time.sleep(time.Millisecond * 5)
	tick3 := time.tick_now()

	t_earliest.mods.execute_at = tick1
	t_mid.mods.execute_at = tick2
	t_latest.mods.execute_at = tick3

	// push into the queue completely out of timed order
	timed_queue_push(&q, t_mid)
	timed_queue_push(&q, t_latest)
	timed_queue_push(&q, t_earliest)

	// verify minheap outputs the closest deadline first
	p1, _ := timed_queue_pop(&q)
	p2, _ := timed_queue_pop(&q)
	p3, _ := timed_queue_pop(&q)

	testing.expect(t, p1 == t_earliest, "expected the earliest chronological task first")
	testing.expect(t, p2 == t_mid, "expected the mid point task second")
	testing.expect(t, p3 == t_latest, "expected the latest task third")

	free(t_earliest)
	free(t_mid)
	free(t_latest)
}
