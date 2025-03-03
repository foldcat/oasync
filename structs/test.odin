package structs

import "core:testing"

// i cannot trust myself...

@(test)
test_queue_wrap_around :: proc(t: ^testing.T) {
	q := make_queue(int, 4)
	testing.expect(t, queue_push(&q, 1))
	testing.expect(t, queue_push(&q, 2))
	testing.expect(t, queue_push(&q, 3))

	res, ok := queue_pop(&q)
	testing.expect(t, res == 1)
	testing.expect(t, ok)

	res, ok = queue_pop(&q)
	testing.expect(t, res == 2)
	testing.expect(t, ok)

	testing.expect(t, queue_push(&q, 4))

	res, ok = queue_pop(&q)
	testing.expect(t, res == 3)
	testing.expect(t, ok)

	res, ok = queue_pop(&q)
	testing.expect(t, res == 4)
	testing.expect(t, ok)
}
