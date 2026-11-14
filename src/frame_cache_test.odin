package nautilus

// Task 5: 双上限 LRU 原始帧缓存。上限语义在 §4.2：256 帧且 ≤ 512 MB，
// 淘汰最久未用；get 命中即刷新 LRU 顺序。

import "core:testing"

frame_of_size :: proc(bytes: int) -> []u8 {
	p := make([]u8, bytes)
	return p
}

@(test)
frame_cache_evicts_oldest_by_count :: proc(t: ^testing.T) {
	c: Frame_Cache
	frame_cache_init(&c, 3, 1 << 30)
	defer frame_cache_destroy(&c)

	for i in 0 ..< 3 {
		key := Frame_Key{file = "a.dcm", frame = i}
		frame_cache_put(&c, &Cached_Frame{key = key, raw = frame_of_size(4)})
	}
	testing.expect_value(t, frame_cache_len(&c), 3)

	// 4th insert must evict frame 0 (oldest), keeping 1 and 2.
	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "a.dcm", frame = 3}, raw = frame_of_size(4)})
	testing.expect_value(t, frame_cache_len(&c), 3)
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "a.dcm", frame = 0}) == nil)
	for i in 1 ..= 3 {
		testing.expectf(t, frame_cache_get(&c, Frame_Key{file = "a.dcm", frame = i}) != nil,
			"frame %d should survive", i)
	}
}

@(test)
frame_cache_evicts_oldest_by_bytes :: proc(t: ^testing.T) {
	c: Frame_Cache
	// Byte cap 100 MB; each frame 40 MB, so only two fit at a time.
	frame_cache_init(&c, 256, 100 * 1024 * 1024)
	defer frame_cache_destroy(&c)

	one_mb := 1024 * 1024
	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "big.dcm", frame = 0}, raw = frame_of_size(40 * one_mb)})
	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "big.dcm", frame = 1}, raw = frame_of_size(40 * one_mb)})
	testing.expect_value(t, frame_cache_len(&c), 2)
	testing.expect(t, frame_cache_bytes(&c) <= 100 * one_mb)

	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "big.dcm", frame = 2}, raw = frame_of_size(40 * one_mb)})
	testing.expect(t, frame_cache_bytes(&c) <= 100 * one_mb, "byte cap must hold")
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "big.dcm", frame = 0}) == nil,
		"oldest evicted under byte pressure")
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "big.dcm", frame = 2}) != nil)
}

@(test)
frame_cache_get_refreshes_lru :: proc(t: ^testing.T) {
	c: Frame_Cache
	frame_cache_init(&c, 2, 1 << 30)
	defer frame_cache_destroy(&c)

	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "b.dcm", frame = 0}, raw = frame_of_size(4)})
	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "b.dcm", frame = 1}, raw = frame_of_size(4)})

	// Touch 0 so 1 becomes the eviction victim.
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "b.dcm", frame = 0}) != nil)

	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "b.dcm", frame = 2}, raw = frame_of_size(4)})
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "b.dcm", frame = 0}) != nil,
		"recently used frame survives")
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "b.dcm", frame = 1}) == nil,
		"untouched frame is evicted")
}

@(test)
frame_cache_reput_same_key_replaces_payload :: proc(t: ^testing.T) {
	c: Frame_Cache
	frame_cache_init(&c, 4, 1 << 30)
	defer frame_cache_destroy(&c)

	key := Frame_Key{file = "c.dcm", frame = 0}
	frame_cache_put(&c, &Cached_Frame{key = key, raw = frame_of_size(8)})
	before := frame_cache_bytes(&c)
	frame_cache_put(&c, &Cached_Frame{key = key, raw = frame_of_size(8)})
	testing.expect_value(t, frame_cache_len(&c), 1)
	testing.expect_value(t, frame_cache_bytes(&c), before)
}

@(test)
frame_cache_single_frame_over_budget_is_rejected :: proc(t: ^testing.T) {
	c: Frame_Cache
	frame_cache_init(&c, 256, 8 * 1024 * 1024)
	defer frame_cache_destroy(&c)

	// A 32 MB frame can never fit; the cache must refuse rather than
	// thrash the existing entries to empty.
	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "small.dcm", frame = 0}, raw = frame_of_size(4 * 1024 * 1024)})
	frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = "huge.dcm", frame = 0}, raw = frame_of_size(32 * 1024 * 1024)})
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "huge.dcm", frame = 0}) == nil)
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = "small.dcm", frame = 0}) != nil,
		"existing entry survives an oversized put")
}

// Frame_Key holds a string; Odin's map hashes string content, not the
// pointer, so a key rebuilt from an independently allocated path must hit.
@(test)
frame_cache_key_matches_by_content :: proc(t: ^testing.T) {
	c: Frame_Cache
	frame_cache_init(&c, 4, 1 << 30)
	defer frame_cache_destroy(&c)

	a := make([]u8, len("d.dcm")); copy(a, "d.dcm"); defer delete(a)
	b := make([]u8, len("d.dcm")); copy(b, "d.dcm"); defer delete(b)

	testing.expect(t, frame_cache_put(&c, &Cached_Frame{key = Frame_Key{file = string(a), frame = 7}, raw = frame_of_size(4)}))
	e := frame_cache_get(&c, Frame_Key{file = string(b), frame = 7})
	testing.expect(t, e != nil, "distinct backing arrays, same content")
	testing.expect_value(t, frame_cache_len(&c), 1)

	// A different frame index of the same file is a different key.
	testing.expect(t, frame_cache_get(&c, Frame_Key{file = string(b), frame = 8}) == nil)
}
