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
	if s.expanded == nil do s.expanded = make(map[Series_Key]bool)
	clear(&s.expanded) // indices are scan-scoped
	s.rows = sidebar_build_rows(&s.tree, &s.expanded)
	s.selected_row = 0
	// Panels follow the series list order; slot 0 is the first series.
	assign_slots(s, &s.tree)
	for vp in 0 ..< layout_count(s.layout) do show_slot(s, vp)

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
		// A frame row can belong to a series other than the one currently
		// bound to this panel; rebind so the wheel continues in that series.
		entry := s.tree.entries[r.entry]
		ser := &s.tree.studies[entry.study].series[entry.series]
		s.flips[s.active_vp] = flip_init(ser.frames)
		s.flips[s.active_vp].cursor = entry.pos
		show_entry(s, r.entry)
	case .Series:
		// Select and show the series at its own cursor. Expansion belongs
		// to the chevron (toggle_series): a click must not destroy the
		// frame list the user is reading, nor force a decode on collapse.
		series := &s.tree.studies[r.study].series[r.series]
		if len(series.frames) == 0 do return
		pos := clamp(series.cursor, 0, len(series.frames) - 1)
		s.flips[s.active_vp] = flip_init(series.frames)
		s.flips[s.active_vp].cursor = pos
		show_entry(s, series.frames[pos])
	case .Study:
		study := &s.tree.studies[r.study]
		if len(study.series) == 0 || len(study.series[0].frames) == 0 do return
		ser := &study.series[0]
		pos := clamp(ser.cursor, 0, len(ser.frames) - 1)
		s.flips[s.active_vp] = flip_init(ser.frames)
		s.flips[s.active_vp].cursor = pos
		show_entry(s, ser.frames[pos])
	case .Patient:
		patient := &s.tree.patients[r.patient]
		if len(patient.studies) == 0 do return
		study := &s.tree.studies[patient.studies[0]]
		if len(study.series) == 0 || len(study.series[0].frames) == 0 do return
		ser := &study.series[0]
		pos := clamp(ser.cursor, 0, len(ser.frames) - 1)
		s.flips[s.active_vp] = flip_init(ser.frames)
		s.flips[s.active_vp].cursor = pos
		show_entry(s, ser.frames[pos])
	}
}

// toggle_series opens or closes one series card without changing the
// displayed frame or the panel bindings.
toggle_series :: proc(s: ^App_State, row: int) {
	if !s.has_tree || row < 0 || row >= len(s.rows) do return
	r := s.rows[row]
	if r.kind != .Series do return

	if s.expanded == nil do s.expanded = make(map[Series_Key]bool)
	key := Series_Key{study = r.study, series = r.series}
	s.expanded[key] = !s.expanded[key]

	// Inserting or removing the frame block reindexes every later row, so
	// re-find the selected item by identity instead of keeping the index.
	ident := row_ident(s.rows[clamp(s.selected_row, 0, len(s.rows) - 1)])
	sidebar_destroy_rows(s.rows)
	s.rows = sidebar_build_rows(&s.tree, &s.expanded)
	next := find_row(s.rows, ident)
	if next < 0 do next = min(row, len(s.rows) - 1)
	s.selected_row = next
}

// assign_slots binds each layout panel to a series in sidebar (tree)
// order: panel 0 shows the first series, panel 1 the second, and panels
// beyond the series count stay empty. `tree` outlives the flips — the
// frame lists are borrowed, not copied.
assign_slots :: proc(s: ^App_State, tree: ^Study_Tree) {
	n := 0
	total := layout_count(s.layout)
	outer: for si in 0 ..< len(tree.studies) {
		for ni in 0 ..< len(tree.studies[si].series) {
			if n >= total do break outer
			ser := &tree.studies[si].series[ni]
			s.flips[n] = flip_init(ser.frames)
			if len(ser.frames) > 0 {
				s.flips[n].cursor = clamp(ser.cursor, 0, len(ser.frames) - 1)
			}
			n += 1
		}
	}
	for i in n ..< MAX_VIEWPORTS {
		s.flips[i] = Flip_State{}
	}
}

// show_slot kicks the current frame of a filled slot onto its panel;
// an empty slot clears the panel.
show_slot :: proc(s: ^App_State, vp: int) {
	if e, ok := flip_current(&s.flips[vp]); ok {
		show_entry_in(s, e, vp)
	} else {
		s.vframes[vp] = nil
	}
}

// show_entry_in displays `entry` on viewport `vp` immediately on cache
// hit, or dispatches a .Current decode plus directional .Prefetch
// requests through the pool. show_entry targets the active viewport.
show_entry :: proc(s: ^App_State, entry: u32) {
	show_entry_in(s, entry, s.active_vp)
}

show_entry_in :: proc(s: ^App_State, entry: u32, vp: int) {
	fmt.eprintfln("SHOW vp=%d entry=%d pool=%v has_tree=%v", vp, entry, s.pool_ready, s.has_tree)
	if !s.has_tree || entry >= u32(len(s.tree.entries)) do return
	// Record where this series is now, so its card can show "36/172".
	mark_cursor(&s.tree, entry)
	path := s.tree.entries[entry].path

	f := &s.flips[vp]
	seq := f.request_seq
	if seq == 0 do seq = 1

	key := Frame_Key{file = path, frame = 0}
	if cached := frame_cache_get(&s.cache, key); cached != nil {
		install_cached(s, cached, vp)
	} else if s.pool_ready {
		_ = decode_pool_submit(pool_ref(), {key = key, priority = .Current, generation = seq, viewport = vp})
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
				// it for the frame a viewport asked for.
				_ = decode_pool_submit(pool_ref(), {key = pk, priority = .Prefetch, generation = 0, viewport = vp})
			}
		}
	}
}

// page steps the series bound to viewport `vp`.
page :: proc(s: ^App_State, dir: Flip_Direction, vp: int) {
	f := &s.flips[vp]
	if len(f.frames) == 0 do return
	entry, ok, changed := flip_step(f, dir)
	if !ok do return
	if changed {
		show_entry_in(s, entry, vp)
	}
}

cycle_layout :: proc(s: ^App_State) {
	switch s.layout {
	case .Single: s.layout = .Two
	case .Two: s.layout = .Quad
	case .Quad: s.layout = .Single
	}
	s.active_vp = min(s.active_vp, layout_count(s.layout) - 1)
	// Panels follow the series list, so a new layout re-binds them.
	if s.has_tree {
		assign_slots(s, &s.tree)
		for vp in 0 ..< layout_count(s.layout) do show_slot(s, vp)
	}
}

// drain_pool moves finished decodes into the cache, and shows one only
// on the viewport that asked, when its generation is still the newest.
drain_pool :: proc(s: ^App_State) {
	if !s.pool_ready do return
	results := decode_pool_drain(pool_ref())
	defer delete(results)

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
		// Only the newest request may reach its panel; stale results
		// stay cached for the next visit.
		vp := clamp(r.vp, 0, MAX_VIEWPORTS - 1)
		if r.gen != 0 && flip_accept(&s.flips[vp], r.gen) {
			install_cached(s, frame, vp)
		}
	}
}

// install_cached points viewport `vp` at a frame already in the cache.
// The cache keeps ownership; panels borrow the pointer.
install_cached :: proc(s: ^App_State, f: ^Cached_Frame, vp: int) {
	s.vframes[vp] = f
	vw := &s.viewports[vp]
	vw.img_w = f.info.cols
	vw.img_h = f.info.rows
	vw.tex_w = u32(f.info.cols)
	vw.tex_h = u32(f.info.rows)
	vw.has_tex = false
	window_reset(vw, f)
	if vp != s.active_vp do return
	s.frame = f
	s.info = f.info
	s.status = .Ready
	// Refresh tags once per shown frame, not per UI frame: the refresh
	// re-opens the file, which is far too expensive for the hot path.
	// Defer the tag refresh: this runs inside the pool drain, and opening
	// the document here races the decode workers.
	s.inspector_needs_refresh = true
	set_status(s, fmt.aprintf("%s  %dx%d  W %.0f / L %.0f",
		short_name(f.key.file), f.info.cols, f.info.rows,
		vw.window.width, vw.window.center))
}
