package oasync

import "core:log"
import "core:testing"

@(test)
test_gqueue_basic :: proc(t: ^testing.T) {
	q := make_gqueue(int)
	gqueue_push(&q, 10)
	gqueue_push(&q, 20)

	val, ok := gqueue_pop(&q)
	testing.expect(t, ok, "Expected ok to be true")
	testing.expect(t, val == 10, "Expected value 10")

	val, ok = gqueue_pop(&q)
	testing.expect(t, ok, "Expected ok to be true")
	testing.expect(t, val == 20, "Expected value 20")

	val, ok = gqueue_pop(&q)
	testing.expect(t, !ok, "Expected ok to be false")
}


@(test)
test_gqueue_empty :: proc(t: ^testing.T) {
	q := make_gqueue(string)
	val, ok := gqueue_pop(&q)
	testing.expect(t, !ok, "Expected ok to be false on empty queue")
	testing.expect(t, val == "", "Expected zero value on empty queue")
}

@(test)
test_gqueue_multiple_push_pop :: proc(t: ^testing.T) {
	q := make_gqueue(f32)

	for i in 0 ..= 100 {
		gqueue_push(&q, f32(i) * 2.5)
	}

	for i in 0 ..= 100 {
		val, ok := gqueue_pop(&q)
		testing.expect(t, ok, "Expected ok to be true")
		testing.expect(t, val == f32(i) * 2.5, "Expected value to match pushed value")
	}

	val, ok := gqueue_pop(&q)
	testing.expect(t, !ok, "Expected ok to be false after all elements popped")
}

@(test)
test_lqueue_push_overflow :: proc(t: ^testing.T) {
	q := make_queue(int, 4)
	gq := make_gqueue(int)
	for i in 1 ..= 5 {
		queue_push_back_or_overflow(&q, i, &gq)
	}
	res, ok := gqueue_pop(&gq)
	testing.expect(t, ok, "Expected successful pop as overflow")
	testing.expect(t, res == 1, "Expected correct value of pop")
	res, ok = gqueue_pop(&gq)
	testing.expect(t, ok, "expected successful pop as overflow")
	testing.expect(t, res == 2, "Expected correct value of pop")
	res, ok = gqueue_pop(&gq)
	testing.expect(t, !ok, "expected unsuccessful pop as overflow")
}

@(test)
test_steal :: proc(t: ^testing.T) {
	q1 := make_queue(int, 4)
	q2 := make_queue(int, 4)
	gq := make_gqueue(int)

	for i in 1 ..= 3 {
		queue_push_back_or_overflow(&q1, i, &gq)
	}

	item, ok := queue_steal_into(&q1, &q2)
	testing.expect(t, ok, "Expected success of stealing")
	testing.expect(t, item == 2, "Expected correct return")

	item, ok = queue_pop(&q1)
	testing.expect(t, ok, "Expected success of popping")
	testing.expect(t, item == 3, "Expected correct return")

	item, ok = queue_pop(&q1)
	testing.expect(t, !ok, "Expected emptiness")

	item, ok = queue_pop(&q2)
	testing.expect(t, ok, "Expected success of popping")
	testing.expect(t, item == 1, "Expected correct return")
	item, ok = queue_pop(&q2)
	testing.expect(t, !ok, "Expected emptiness")
}
