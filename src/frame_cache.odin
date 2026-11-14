package nautilus

// Task 5: 双上限 LRU——原始解码帧缓存。键是 (file, frame)，值是一个
// 拥有 raw 字节的 Cached_Frame。淘汰发生在 put 之后，按「同容量链表
// 尾部最久未用」推进，直到同时满足帧数与字节数两个上限。
//
// 单帧超过字节上限的 put 被拒绝而不是把整表清空：一个 13.6 MP 的
// 32-bit 帧（218 MB）不该把 255 个可用帧换成 0 个。

import "core:strings"
import d "../vendor/dicom"

Frame_Key :: struct {
	file:  string, // 稳定的堆字符串（缓存克隆）
	frame: int,
}

Rescale :: struct {
	slope:     f64,
	intercept: f64,
	valid:     bool,
}
Spacing_Kind :: enum u8 {
	None,
	Pixel_Spacing,  // (0028,0030) calibrated patient-plane mm
	Imager_Spacing, // (0018,1164) detector-plane mm (Imager)
}

Cached_Frame :: struct {
	key:           Frame_Key,
	info:          d.Pixel_Info,
	raw:           []u8, // 已解码的单帧样本，由缓存拥有
	rescale:       Rescale,
	window:        d.Render_Options, // 数据集默认窗（valid_window=false 表示按帧统计）
	pixel_spacing: [2]f64,
	has_spacing:   bool,
	spacing_kind:  Spacing_Kind,
	palette_rgb:   []u8, // Palette Color 的 RGB 表，缓存拥有
	palette:       d.Palette, // LUT slices owned by the cache
	decode_ms:     f64,

	// LRU 链表：head = 最近使用，tail = 最久未用。侵入式，无单独分配。
	prev, next: ^Cached_Frame,
}

Frame_Cache :: struct {
	entries:     map[Frame_Key]^Cached_Frame,
	head, tail:  ^Cached_Frame,
	max_frames:  int,
	max_bytes:   int,
	bytes_used:  int,
	hits:        u64,
	misses:      u64,
}

frame_key_make :: proc(file: string, frame: int) -> Frame_Key {
	return {file = file, frame = frame}
}

frame_cache_init :: proc(c: ^Frame_Cache, max_frames: int, max_bytes: int) {
	c.entries = make(map[Frame_Key]^Cached_Frame)
	c.max_frames = max_frames
	c.max_bytes = max_bytes
}

frame_cache_destroy :: proc(c: ^Frame_Cache) {
	for c.head != nil {
		n := c.head.next
		frame_cache_free_entry(c.head)
		c.head = n
	}
	delete(c.entries)
	c.entries = nil
	c.head = nil
	c.tail = nil
	c.bytes_used = 0
}

@(private)
frame_cache_free_entry :: proc(e: ^Cached_Frame) {
	if e.key.file != "" do delete(e.key.file)
	delete(e.raw)
	if e.palette_rgb != nil do delete(e.palette_rgb)
	if e.palette.valid {
		delete(e.palette.red)
		delete(e.palette.green)
		delete(e.palette.blue)
	}
	free(e)
}

@(private)
frame_cache_unlink :: proc(c: ^Frame_Cache, e: ^Cached_Frame) {
	if e.prev != nil { e.prev.next = e.next } else { c.head = e.next }
	if e.next != nil { e.next.prev = e.prev } else { c.tail = e.prev }
	e.prev = nil
	e.next = nil
}

@(private)
frame_cache_push_front :: proc(c: ^Frame_Cache, e: ^Cached_Frame) {
	e.prev = nil
	e.next = c.head
	if c.head != nil do c.head.prev = e
	c.head = e
	if c.tail == nil do c.tail = e
}

@(private)
frame_cache_touch :: proc(c: ^Frame_Cache, e: ^Cached_Frame) {
	if c.head == e do return
	frame_cache_unlink(c, e)
	frame_cache_push_front(c, e)
}

// frame_cache_get returns the entry and marks it most-recently-used.
frame_cache_get :: proc(c: ^Frame_Cache, key: Frame_Key) -> ^Cached_Frame {
	e, ok := c.entries[key]
	if !ok || e == nil {
		c.misses += 1
		return nil
	}
	c.hits += 1
	frame_cache_touch(c, e)
	return e
}

// frame_cache_peek looks up without disturbing LRU order; used by the
// prefetcher to skip already-resident frames.
frame_cache_peek :: proc(c: ^Frame_Cache, key: Frame_Key) -> ^Cached_Frame {
	e, ok := c.entries[key]
	if !ok do return nil
	return e
}

// frame_cache_put takes ownership of `raw` (and `palette_rgb` when
// non-nil). An existing entry under `key` is replaced in place. A frame
// larger than max_bytes is rejected and freed by the caller's contract
// unaffected: nothing is stored.
frame_cache_put :: proc(c: ^Frame_Cache, entry: ^Cached_Frame) -> bool {
	if entry == nil do return false
	size := len(entry.raw) + len(entry.palette_rgb)
	if size > c.max_bytes do return false

	if old, ok := c.entries[entry.key]; ok {
		frame_cache_unlink(c, old)
		c.bytes_used -= len(old.raw) + len(old.palette_rgb)
		delete_key(&c.entries, entry.key)
		// old.key.file is the same value as entry.key.file only if the
		// caller reused the cache's clone; compare pointers instead.
		if old.key.file != entry.key.file do delete(old.key.file)
		delete(old.raw)
		if old.palette_rgb != nil do delete(old.palette_rgb)
		free(old)
	}

	// The cache owns the entry allocation and a clone of the file path so
	// both outlive the caller (whose literal may sit on a stack frame and
	// whose string is often temp-allocated).
	own := new(Cached_Frame)
	own^ = entry^
	if own.key.file != "" do own.key.file = strings.clone(own.key.file)
	own.prev = nil
	own.next = nil
	c.entries[own.key] = own
	c.bytes_used += size
	frame_cache_push_front(c, own)

	for c.head != nil && (frame_cache_len(c) > c.max_frames || c.bytes_used > c.max_bytes) {
		victim := c.tail
		frame_cache_unlink(c, victim)
		delete_key(&c.entries, victim.key)
		c.bytes_used -= len(victim.raw) + len(victim.palette_rgb)
		frame_cache_free_entry(victim)
	}
	return true
}

frame_cache_len :: proc(c: ^Frame_Cache) -> int {
	return len(c.entries)
}

frame_cache_bytes :: proc(c: ^Frame_Cache) -> int {
	return c.bytes_used
}

// frame_cache_hit_rate returns hits/(hits+misses); 1.0 before any lookup.
frame_cache_hit_rate :: proc(c: ^Frame_Cache) -> f64 {
	total := c.hits + c.misses
	if total == 0 do return 1
	return f64(c.hits) / f64(total)
}

// frame_cache_evict_all drops every entry (window/patient switch).
frame_cache_evict_all :: proc(c: ^Frame_Cache) {
	for c.head != nil {
		n := c.head.next
		frame_cache_free_entry(c.head)
		c.head = n
	}
	clear(&c.entries)
	c.tail = nil
	c.bytes_used = 0
}
