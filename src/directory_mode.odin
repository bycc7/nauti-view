package nautilus

// Task 9 (M2): 目录模式、多视口、翻页与预取接线。

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import d "../vendor/dicom"
import rl "../vendor/skald"

// ---------------------------------------------------------------------------
// scan hand-off (dialog thread -> update -> scan worker)

@(private)
Scan_Slot :: struct {
	lock:  sync.Mutex,
	path:  string,
	ready: bool,
	tree:  Study_Tree,
	done:  bool,
}

@(private)
scan_slot: Scan_Slot

@(private)
scan_slot_set :: proc(path: string) {
	sync.lock(&scan_slot.lock)
	if scan_slot.path != "" do delete(scan_slot.path)
	// The caller frees its own copy; the slot must own its own.
	scan_slot.path = strings.clone(path)
	scan_slot.ready = true
	sync.unlock(&scan_slot.lock)
}

@(private)
scan_slot_take :: proc() -> (path: string, ok: bool) {
	sync.lock(&scan_slot.lock)
	defer sync.unlock(&scan_slot.lock)
	if !scan_slot.ready do return "", false
	path = scan_slot.path
	scan_slot.path = ""
	scan_slot.ready = false
	return path, true
}

// begin_scan runs the directory scan on a worker; the tree comes back
// through the same slot.
begin_scan :: proc(s: ^App_State, root: string) -> rl.Command(Msg) {
	set_status(s, fmt.aprintf("scanning %s ...", short_name(root)))
	return rl.cmd_thread(Msg, Scan_Job{root = strings.clone(root)}, scan_run)
}

Scan_Job :: struct {
	root: string,
}

@(private)
scan_run :: proc(job: Scan_Job) -> Msg {
	// The worker's context is not the main thread's, so the scan gets its
	// own arena and the finished tree is moved onto the process heap.
	tree := scan_directory(job.root, allocator = context.allocator)
	sync.lock(&scan_slot.lock)
	if scan_slot.tree.entries != nil do study_tree_destroy(&scan_slot.tree)
	scan_slot.tree = tree
	scan_slot.done = true
	sync.unlock(&scan_slot.lock)
	delete(job.root)
	return Msg{kind = .Noop}
}

// install_scan adopts a finished scan. Called from update's drain.
install_scan :: proc(s: ^App_State) -> bool {
	sync.lock(&scan_slot.lock)
	if !scan_slot.done {
		sync.unlock(&scan_slot.lock)
		return false
	}
	tree := scan_slot.tree
	scan_slot.tree = {}
	scan_slot.done = false
	sync.unlock(&scan_slot.lock)

	if s.has_tree {
		sidebar_destroy_rows(s.rows)
		study_tree_destroy(&s.tree)
	}
	s.tree = tree
	s.has_tree = true
	if s.expanded == nil do s.expanded = make(map[string]bool)
	s.rows = sidebar_build_rows(&s.tree, &s.expanded)
	s.selected_row = 0
	if len(s.tree.studies) > 0 && len(s.tree.studies[0].series) > 0 {
		ser := &s.tree.studies[0].series[0]
		s.flips[s.active_vp] = flip_init(ser.frames)
		if len(ser.frames) > 0 do show_entry(s, ser.frames[0])
	}

	set_status(s, fmt.aprintf("%d files, %d studies, %d series",
		len(s.tree.entries), len(s.tree.studies), count_series(&s.tree)))
	return true
}

@(private)
count_series :: proc(tree: ^Study_Tree) -> int {
	n := 0
	for st in tree.studies do n += len(st.series)
	return n
}

// ---------------------------------------------------------------------------
// selection, paging, layout

select_row :: proc(s: ^App_State, row: int) {
	if !s.has_tree || row < 0 || row >= len(s.rows) do return
	s.selected_row = row
	r := s.rows[row]

	switch r.kind {
	case .Frame:
		show_entry(s, r.entry)
	case .Series:
		series := &s.tree.studies[r.study].series[r.series]
		// Clicking a series card selects its first frame and toggles the
		// frame list; rebuild rows because the flat list changed.
		if len(series.frames) > 0 do show_entry(s, series.frames[0])
		s.flips[s.active_vp] = flip_init(series.frames)
		s.expanded[series.uid] = !s.expanded[series.uid]
		sidebar_destroy_rows(s.rows)
		s.rows = sidebar_build_rows(&s.tree, &s.expanded)
	case .Study:
		study := &s.tree.studies[r.study]
		if len(study.series) > 0 && len(study.series[0].frames) > 0 {
			show_entry(s, study.series[0].frames[0])
		}
	}
}

// show_entry starts a decode for the frame at `entry`, through the pool
// show_entry displays `entry` immediately on cache hit, or dispatches
// a .Current decode plus directional .Prefetch requests through the pool.
show_entry :: proc(s: ^App_State, entry: u32) {
	fmt.eprintfln("SHOW entry=%d pool=%v has_tree=%v", entry, s.pool_ready, s.has_tree)
	if !s.has_tree || entry >= u32(len(s.tree.entries)) do return
	path := s.tree.entries[entry].path

	f := &s.flips[s.active_vp]
	seq := f.request_seq
	if seq == 0 do seq = 1
	s.load_gen = seq

	key := Frame_Key{file = path, frame = 0}
	if cached := frame_cache_get(&s.cache, key); cached != nil {
		install_cached(s, cached)
	} else if s.pool_ready {
		_ = decode_pool_submit(pool_ref(), {key = key, priority = .Current, generation = seq})
		set_status(s, fmt.aprintf("%s  (seq %d)", short_name(path), seq))
	} else {
		cmd := begin_load(s, path)
		_ = cmd
	}

	if s.pool_ready && len(f.frames) > 1 {
		pre: [PREFETCH_RADIUS * 2]u32
		n := flip_prefetch(f, pre[:])
		for i in 0 ..< n {
			pe := pre[i]
			if pe >= u32(len(s.tree.entries)) do continue
			pk := Frame_Key{file = s.tree.entries[pe].path, frame = 0}
			if frame_cache_peek(&s.cache, pk) == nil {
				// Prefetch carries generation 0 so a drain never mistakes
				// it for the frame the viewport asked for.
				_ = decode_pool_submit(pool_ref(), {key = pk, priority = .Prefetch, generation = 0})
			}
		}
	}
}

page :: proc(s: ^App_State, dir: Flip_Direction) {
	f := &s.flips[s.active_vp]
	if len(f.frames) == 0 do return
	entry, ok, changed := flip_step(f, dir)
	if !ok do return
	if changed {
		s.load_gen = f.request_seq
		show_entry(s, entry)
	}
}

cycle_layout :: proc(s: ^App_State) {
	switch s.layout {
	case .Single: s.layout = .Two
	case .Two: s.layout = .Quad
	case .Quad: s.layout = .Single
	}
	s.active_vp = min(s.active_vp, layout_count(s.layout) - 1)
}

// drain_pool moves finished decodes into the cache, and shows one only
// when its generation matches the active viewport's newest request.
drain_pool :: proc(s: ^App_State) {
	if !s.pool_ready do return
	results := decode_pool_drain(pool_ref())
	defer delete(results)

	f := &s.flips[s.active_vp]
	for r in results {
		if r.frame == nil {
			if r.err != "" do set_status(s, fmt.aprintf("decode failed: %s", r.err))
			continue
		}
		frame := r.frame
		// Cache holds a copy keyed by path; the cache takes ownership.
		if !frame_cache_put(&s.cache, frame) {
			free_uncached_frame(frame)
			continue
		}
		// Only the newest request may reach the viewport. `load_gen` is the
		// page the user asked for; results from an older one stay cached.
		if r.gen != 0 && r.gen == s.load_gen {
			install_cached(s, frame)
		}
	}
}

// install_cached points the active viewport at a frame already in the
// cache. The cache keeps ownership.
install_cached :: proc(s: ^App_State, f: ^Cached_Frame) {
	s.frame = f
	s.info = f.info
	s.status = .Ready
	s.vp.img_w = f.info.cols
	s.vp.img_h = f.info.rows
	s.vp.tex_w = u32(f.info.cols)
	s.vp.tex_h = u32(f.info.rows)
	s.vp.has_tex = false
	window_reset(s, f)
	// Refresh tags once per shown frame, not per UI frame: the refresh
	// re-opens the file, which is far too expensive for the hot path.
	// Defer the tag refresh: this runs inside the pool drain, and opening
	// the document here races the decode workers.
	s.inspector_needs_refresh = true

	set_status(s, fmt.aprintf("%s  %dx%d  W %.0f / L %.0f",
		short_name(f.key.file), f.info.cols, f.info.rows,
		s.vp.window.width, s.vp.window.center))
}
