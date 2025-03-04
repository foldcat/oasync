package oasync

import "core:testing"

@(test)
test_gqueue_basic :: proc(t: ^testing.T) {
	q := make_gqueue(int)
	gqueue_push(&q, 10)
	gqueue_push(&q, 20)

	val, ok := gqueue_pop(&q)
	testing.expect(t, ok == true, "Expected ok to be true")
	testing.expect(t, val == 10, "Expected value 10")

	val, ok = gqueue_pop(&q)
	testing.expect(t, ok == true, "Expected ok to be true")
	testing.expect(t, val == 20, "Expected value 20")

	val, ok = gqueue_pop(&q)
	testing.expect(t, ok == false, "Expected ok to be false")
}


@(test)
test_gqueue_empty :: proc(t: ^testing.T) {
	q := make_gqueue(string)
	val, ok := gqueue_pop(&q)
	testing.expect(t, ok == false, "Expected ok to be false on empty queue")
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
		testing.expect(t, ok == true, "Expected ok to be true")
		testing.expect(t, val == f32(i) * 2.5, "Expected value to match pushed value")
	}

	val, ok := gqueue_pop(&q)
	testing.expect(t, ok == false, "Expected ok to be false after all elements popped")
}
