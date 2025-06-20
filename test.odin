package oasync

import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"

// tests are ment to be run with -debug flag enabled

@(test)
test_gqueue_basic :: proc(t: ^testing.T) {
	q := make_gqueue(int)
	gqueue_push(&q, 10)
	gqueue_push(&q, 20)

	val, ok := gqueue_pop(&q)
	testing.expect(t, ok, "expected ok to be true")
	testing.expect_value(t, val, 10)

	val, ok = gqueue_pop(&q)
	testing.expect(t, ok, "expected ok to be true")
	testing.expect_value(t, val, 20)

	val, ok = gqueue_pop(&q)
	testing.expect(t, !ok, "expected ok to be false")
}


@(test)
test_gqueue_empty :: proc(t: ^testing.T) {
	q := make_gqueue(string)
	val, ok := gqueue_pop(&q)
	testing.expect(t, !ok, "expected ok to be false on empty queue")
}

@(test)
test_gqueue_multiple_push_pop :: proc(t: ^testing.T) {
	q := make_gqueue(f32)

	for i in 0 ..= 100 {
		gqueue_push(&q, f32(i) * 2.5)
	}

	for i in 0 ..= 100 {
		val, ok := gqueue_pop(&q)
		testing.expect(t, ok, "expected ok to be true")
		testing.expect_value(t, val, f32(i) * 2.5)
	}

	val, ok := gqueue_pop(&q)
	testing.expect(t, !ok, "expected ok to be false after all elements popped")
}

@(test)
test_lqueue_push_overflow :: proc(t: ^testing.T) {
	q := make_queue(int, 4)
	gq := make_gqueue(int)
	for i in 1 ..= 5 {
		queue_push_back_or_overflow(&q, i, &gq)
	}
	res, ok := gqueue_pop(&gq)
	testing.expect(t, ok, "expected successful pop as overflow")
	testing.expect_value(t, res, 1)
	res, ok = gqueue_pop(&gq)
	testing.expect(t, ok, "expected successful pop as overflow")
	testing.expect_value(t, res, 2)
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
	testing.expect(t, ok, "expected success of stealing")
	testing.expect_value(t, item, 2)

	item, ok = queue_pop(&q1)
	testing.expect(t, ok, "expected success of popping")
	testing.expect_value(t, item, 3)

	item, ok = queue_pop(&q1)
	testing.expect(t, !ok, "expected emptiness")

	item, ok = queue_pop(&q2)
	testing.expect(t, ok, "expected success of popping")
	testing.expect_value(t, item, 1)
	item, ok = queue_pop(&q2)
	testing.expect(t, !ok, "expected emptiness")

	item, ok = queue_steal_into(&q1, &q2)
	testing.expect(t, !ok, "expected failing to steal")
}

// have you ever wonder what madness is
@(test)
test_steal_multithreaded :: proc(t: ^testing.T) {
	Worker_Data :: struct {
		wg:      ^sync.Wait_Group,
		barrier: ^sync.Barrier,
		lq:      Local_Queue(int, 4),
		gq:      ^Global_Queue(int),
		opp:     ^Worker_Data,
	}
	provider_worker :: proc(t: ^thread.Thread) {
		worker_data := cast(^Worker_Data)t.data
		for i in 1 ..= 3 {
			queue_push_back_or_overflow(&worker_data.lq, i, worker_data.gq)
		}
		sync.barrier_wait(worker_data.barrier)

		sync.wait_group_done(worker_data.wg)
	}
	stealer_worker :: proc(t: ^thread.Thread) {
		worker_data := cast(^Worker_Data)t.data
		sync.barrier_wait(worker_data.barrier)
		item, ok := queue_steal_into(&worker_data.opp.lq, &worker_data.lq)
		log.info("stealer id", t.user_index, "stealer got", item, ok)
		sync.wait_group_done(worker_data.wg)
	}

	wg: sync.Wait_Group
	barrier: sync.Barrier
	gq := make_gqueue(int)
	sync.barrier_init(&barrier, 3)
	provider := thread.create(provider_worker)
	provider.init_context = context
	stealer1 := thread.create(stealer_worker)
	stealer1.init_context = context
	stealer1.user_index = 1
	stealer2 := thread.create(stealer_worker)
	stealer2.init_context = context
	stealer2.user_index = 2

	provider.data = &Worker_Data{wg = &wg, barrier = &barrier, lq = make_queue(int, 4), gq = &gq}
	stealer1.data =
	&Worker_Data {
		wg = &wg,
		barrier = &barrier,
		lq = make_queue(int, 4),
		gq = &gq,
		opp = cast(^Worker_Data)provider.data,
	}
	stealer2.data =
	&Worker_Data {
		wg = &wg,
		barrier = &barrier,
		lq = make_queue(int, 4),
		gq = &gq,
		opp = cast(^Worker_Data)provider.data,
	}

	sync.wait_group_add(&wg, 3)

	thread.start(provider)
	thread.start(stealer1)
	thread.start(stealer2)

	sync.wait_group_wait(&wg)

	provider_data := cast(^Worker_Data)provider.data
	log.info(
		"provider local queue status> head (steal, real):",
		unpack(provider_data.lq.head),
		"tail:",
		provider_data.lq.tail,
		"buffer",
		provider_data.lq.buffer,
	)

	stealer1_data := cast(^Worker_Data)stealer1.data
	log.info(
		"stealer 1 local queue status> head (steal, real):",
		unpack(stealer1_data.lq.head),
		"tail:",
		stealer1_data.lq.tail,
		"buffer",
		stealer1_data.lq.buffer,
	)

	stealer2_data := cast(^Worker_Data)stealer2.data
	log.info(
		"stealer 2 local queue status> head (steal, real):",
		unpack(stealer2_data.lq.head),
		"tail:",
		stealer2_data.lq.tail,
		"buffer",
		stealer2_data.lq.buffer,
	)

	log.info("start popping provider")
	for {
		res := queue_pop(&provider_data.lq) or_break
		log.info("provider poped", res)
	}

	log.info("start popping stealer 1")
	for {
		res := queue_pop(&stealer1_data.lq) or_break
		log.info("stealer 1 poped", res)
	}

	log.info("start popping stealer 2")
	for {
		res := queue_pop(&stealer2_data.lq) or_break
		log.info("stealer 2 poped", res)
	}

	thread.destroy(provider)
	thread.destroy(stealer1)
	thread.destroy(stealer2)
}
