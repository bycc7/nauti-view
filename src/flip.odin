package nautilus

// Task 9: 打开序列后的翻页状态机——纯逻辑，可单测。
//
// 规则：
//   - 每个视口持有 `request_seq`；每次用户主动翻页 +1。
//   - 解码结果带 seq；`seq < 当前 seq` 的结果只进缓存，不上屏。
//   - 翻页时按方向预取游标前后各 PREFETCH_RADIUS 帧。

PREFETCH_RADIUS :: 8

Flip_Direction :: enum {
	None,
	Forward,
	Backward,
}

// Flip_State pages through one series inside one viewport.
Flip_State :: struct {
	frames:      []u32, // entries indices, display order
	cursor:      int,
	request_seq: u64,
	dir:         Flip_Direction,
}

flip_init :: proc(frames: []u32) -> Flip_State {
	return {frames = frames}
}

flip_current :: proc(st: ^Flip_State) -> (entry: u32, ok: bool) {
	if st.cursor < 0 || st.cursor >= len(st.frames) do return 0, false
	return st.frames[st.cursor], true
}

// flip_step moves one frame in `d` (clamped), bumps the request
// sequence, and reports the entry now displayed.
flip_step :: proc(st: ^Flip_State, d: Flip_Direction) -> (entry: u32, ok: bool, changed: bool) {
	if len(st.frames) == 0 do return 0, false, false
	before := st.cursor
	switch d {
	case .Forward: st.cursor = min(st.cursor + 1, len(st.frames) - 1)
	case .Backward: st.cursor = max(st.cursor - 1, 0)
	case .None:
		return st.frames[st.cursor], true, false
	}
	st.dir = d
	changed = st.cursor != before
	if changed do st.request_seq += 1
	return st.frames[st.cursor], true, changed
}

// flip_accept gates a decoded result: only the newest request may be
// shown. Stale results still belong in the cache.
flip_accept :: proc(st: ^Flip_State, seq: u64) -> bool {
	return seq == st.request_seq
}

// flip_prefetch fills `out` with the entries to decode next,
// nearest-first and directed by the last scroll. Returns how many were
// written.
flip_prefetch :: proc(st: ^Flip_State, out: []u32) -> int {
	n := 0
	direction := 1
	if st.dir == .Backward do direction = -1

	for step in 1 ..= PREFETCH_RADIUS {
		if n >= len(out) do break
		for sign in ([2]int{direction, -direction}) {
			idx := st.cursor + sign * step
			if idx < 0 || idx >= len(st.frames) do continue
			if n >= len(out) do break
			out[n] = st.frames[idx]
			n += 1
		}
	}
	return n
}
