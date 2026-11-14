package nautilus

// Task 9 tests: request_seq 防回跳 + 方向感知预取。

import "core:testing"

mk_frames :: proc() -> []u32 {
	f := make([]u32, 20)
	for i in 0 ..< 20 do f[i] = u32(i)
	return f
}

@(test)
flip_stale_result_is_rejected :: proc(t: ^testing.T) {
	frames := mk_frames()
	defer delete(frames)
	st := flip_init(frames)

	// Show frame 0, then the user scrolls twice quickly: seq 1 then 2.
	_, _, c1 := flip_step(&st, .Forward)
	testing.expect(t, c1)
	seq_one := st.request_seq
	testing.expect(t, seq_one == 1)

	_, _, c2 := flip_step(&st, .Forward)
	testing.expect(t, c2)
	seq_two := st.request_seq
	testing.expect(t, seq_two == 2)

	// The seq-1 result arrives late: it must not be shown.
	testing.expect(t, !flip_accept(&st, seq_one), "stale seq must be rejected")
	testing.expect(t, flip_accept(&st, seq_two), "current seq must be accepted")

	cur, ok := flip_current(&st)
	testing.expect(t, ok)
	testing.expect_value(t, cur, u32(2))
}

@(test)
flip_clamps_at_ends_and_keeps_seq :: proc(t: ^testing.T) {
	frames := mk_frames()
	defer delete(frames)
	st := flip_init(frames)

	_, _, changed := flip_step(&st, .Backward)
	testing.expect(t, !changed, "already at the first frame")
	testing.expect_value(t, st.request_seq, u64(0))

	for _ in 0 ..< 25 {
		flip_step(&st, .Forward)
	}
	cur, _ := flip_current(&st)
	testing.expect_value(t, cur, u32(19))
	testing.expect_value(t, st.request_seq, u64(19)) // 19 real moves
}

@(test)
flip_prefetch_follows_direction :: proc(t: ^testing.T) {
	frames := mk_frames()
	defer delete(frames)
	st := flip_init(frames)
	for _ in 0 ..< 10 {
		flip_step(&st, .Forward)
	}

	out: [PREFETCH_RADIUS * 2]u32
	n := flip_prefetch(&st, out[:])
	testing.expect_value(t, n, PREFETCH_RADIUS * 2)

	// Forward first: 11, 9, 12, 10, ...
	testing.expect_value(t, out[0], u32(11))
	testing.expect_value(t, out[1], u32(9))
	testing.expect_value(t, out[2], u32(12))
	testing.expect_value(t, out[3], u32(8))

	// Reversing the scroll flips which side is nearest.
	flip_step(&st, .Backward)
	n2 := flip_prefetch(&st, out[:])
	testing.expect_value(t, n2, PREFETCH_RADIUS * 2)
	testing.expect_value(t, out[0], u32(8)) // cursor is 9, backward first
	testing.expect_value(t, out[1], u32(10))
}

@(test)
flip_prefetch_stops_at_boundaries :: proc(t: ^testing.T) {
	frames := mk_frames()
	defer delete(frames)
	st := flip_init(frames)

	out: [PREFETCH_RADIUS * 2]u32
	n := flip_prefetch(&st, out[:])
	testing.expect_value(t, n, PREFETCH_RADIUS) // only forward exists
	for i in 0 ..< n {
		testing.expect_value(t, out[i], u32(i + 1))
	}
}
