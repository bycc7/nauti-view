package nautilus

// Task 6 (M1): update + the worker hand-off.
//
// Skald delivers only Msg *values* to update, so anything bulky a
// worker or the file-dialog callback produces goes into `inflight`, a
// mutex-protected slot drained by update on the next frame. That keeps
// state a value type with no global app pointer.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import rl "../vendor/skald"

// Msg_Kind tags what update should do. Msg is a struct rather than an
// enum so list rows can carry their index (`row`) without a side channel.
Msg_Kind :: enum u8 {
	Open_Dialog,
	Load_Requested, // a path is waiting in `inflight.path`
	Load_Done, // a frame (or error) is waiting in `inflight.result`
	Start_Initial, // kick the command-line load once
	Reset_Window,
	Invert,
	Flip_H,
	Flip_V,
	Rotate,
	Zoom_Fit,
	// M2 directory mode.
	Open_Directory,
	Tree_Scanned, // a Study_Tree is waiting in `scan_slot`
	Select_Row,
	Page_Next,
	Page_Prev,
	Layout_Cycle,
	Next_Viewport,
	Pool_Drained,
	Toggle_Inspector,
	Handle_Drop,
	Noop,
}

Msg :: struct {
	kind: Msg_Kind,
	row:  int,
}

@(private)
Inflight :: struct {
	lock:   sync.Mutex,
	path:   string, // pending path from the dialog, owned
	has_path: bool,
	result: Load_Result,
	has_result: bool,
}

@(private)
inflight: Inflight

// ---------------------------------------------------------------------------
// lifecycle

state_init :: proc() -> App_State {
	s: App_State
	frame_cache_init(&s.cache, 256, 512 * 1024 * 1024)
	s.vp.zoom = 1
	s.vp.tex_name = "nautilus://vp/0/full"
	s.layout = .Single
	decode_pool_init(&g_pool)
	g_pool_ready = true
	s.pool_ready = true
	return s
}

state_destroy :: proc(s: ^App_State) {
	if s.path != "" do delete(s.path)
	if s.last_dir != "" do delete(s.last_dir)
	if s.err != "" do delete(s.err)
	if s.status_text != "" do delete(s.status_text)
	frame_cache_destroy(&s.cache)
	if g_pool_ready do decode_pool_shutdown(&g_pool)
	if s.has_tree {
		sidebar_destroy_rows(s.rows)
		study_tree_destroy(&s.tree)
	}
	inspector_free_rows(s)
	if s.inspector.query != "" do delete(s.inspector.query)
}

@(private)
set_status :: proc(s: ^App_State, msg: string) {
	if s.status_text != "" do delete(s.status_text)
	s.status_text = fmt.aprintf("%s", msg)
}

// begin_load records the request and returns the worker command.
begin_load :: proc(s: ^App_State, path: string) -> rl.Command(Msg) {
	if path == "" {
		return {}
	}
	if s.status == .Ready && path == s.path {
		return {}
	}

	if s.path != "" do delete(s.path)
	s.path = fmt.aprintf("%s", path)
	s.status = .Loading
	s.load_gen += 1
	s.vp.has_tex = false
	s.frame = nil
	set_status(s, fmt.aprintf("loading %s", short_name(path)))

	job: Worker_Job
	job.gen = s.load_gen
	job.path = s.path
	cmd := rl.cmd_thread(Msg, job, worker_run)
	return cmd
}

Worker_Job :: struct {
	gen:  u64,
	path: string, // heap string owned by the job
}

@(private)
worker_run :: proc(job: Worker_Job) -> Msg {
	sw := init_stopwatch()
	frame, err := load_frame_cpu(job.path)
	res := Load_Result{gen = job.gen, frame = frame, err = err, open_ms = elapsed_ms(&sw)}

	sync.lock(&inflight.lock)
	if inflight.has_result && inflight.result.frame != nil {
		free_uncached_frame(inflight.result.frame)
	}
	inflight.result = res
	inflight.has_result = true
	sync.unlock(&inflight.lock)
	return Msg{kind = .Load_Done}
}

@(private)
free_uncached_frame :: proc(f: ^Cached_Frame) {
	if f.key.file != "" do delete(f.key.file)
	delete(f.raw)
	if f.palette_rgb != nil do delete(f.palette_rgb)
	free(f)
}

// take_result drains the worker slot.
@(private)
take_result :: proc() -> (res: Load_Result, ok: bool) {
	sync.lock(&inflight.lock)
	defer sync.unlock(&inflight.lock)
	if !inflight.has_result do return {}, false
	res = inflight.result
	inflight.result = {}
	inflight.has_result = false
	return res, true
}

@(private)
install_result :: proc(s: ^App_State, res: Load_Result) {
	if res.gen != s.load_gen {
		if res.frame != nil do free_uncached_frame(res.frame)
		return
	}
	if res.err != "" || res.frame == nil {
		s.status = .Failed
		if s.err != "" do delete(s.err)
		s.err = fmt.aprintf("%s", res.err)
		set_status(s, fmt.aprintf("load failed: %s", res.err))
		return
	}
	f := res.frame
	s.frame = f
	s.info = f.info
	if s.last_dir != "" do delete(s.last_dir)
	s.last_dir = strings.clone(filepath.dir(s.path) if s.path != "" else "")

	s.status = .Ready
	if s.err != "" do delete(s.err)
	s.err = ""

	window_reset(s, f)
	// DICOM Rows is the height and Columns the width; the raw frame is
	// row-major with stride = Columns.
	s.vp.img_w = f.info.cols
	s.vp.img_h = f.info.rows
	s.vp.zoom = 1
	s.vp.pan = {0, 0}
	s.vp.flip_h = false
	s.vp.flip_v = false
	s.vp.rotate = 0
	s.vp.tex_w = u32(f.info.cols)
	s.vp.tex_h = u32(f.info.rows)
	s.vp.has_tex = false // next draw uploads a fresh texture

	set_status(s, fmt.aprintf("%s  %dx%d  %d frame(s)  W %.0f / L %.0f  (%.0f ms)",
		short_name(s.path), f.info.rows, f.info.cols, f.info.frames,
		f.window.width, f.window.center, res.open_ms))
}

// window_reset restores the frame's stored VOI (or its auto window).
window_reset :: proc(s: ^App_State, f: ^Cached_Frame) {
	w := f.window
	if !w.valid_window {
		c, width := lut_auto_window(f.info, f.raw)
		w.center, w.width, w.valid_window = c, width, true
	}
	w.invert = f.info.photometric == .Monochrome1
	s.vp.window = w
	s.vp.default_window = w
	f.window = w
}

// ---------------------------------------------------------------------------
// update

update :: proc(s: App_State, m: Msg) -> (App_State, rl.Command(Msg)) {
	ns := s
	// Adopt a finished scan before anything can return early: several
	// branches below return their own Command, which would otherwise
	// strand the tree in the slot forever.
	install_scan(&ns)

	switch m.kind {
	case .Open_Dialog:
		// The picker needs the window handle, which only `view` has, so
		// the request is parked and `view` runs the modal dialog. SDL's
		// own dialog is not used: its callback never fires on this
		// platform (see win32_dialog_windows.odin).
		dialog_request = .File
		return ns, rl.Command(Msg){}

	case .Load_Requested:
		sync.lock(&inflight.lock)
		path := inflight.path
		inflight.path = ""
		inflight.has_path = false
		sync.unlock(&inflight.lock)
		cmd := begin_load(&ns, path)
		delete(path)
		return ns, cmd

	case .Load_Done:
		if res, ok := take_result(); ok {
			install_result(&ns, res)
		}

	case .Start_Initial:
		if start_path != "" {
			p := start_path
			start_path = ""
			cmd := os.is_dir(p) ? begin_scan(&ns, p) : begin_load(&ns, p)
			delete(p)
			return ns, cmd
		}

	case .Reset_Window:
		window_apply_preset(&ns, .Reset)
	case .Invert:
		window_apply_preset(&ns, .Invert)
	case .Zoom_Fit:
		window_apply_preset(&ns, .Fit)
	case .Flip_H:
		ns.vp.flip_h = !ns.vp.flip_h
	case .Flip_V:
		ns.vp.flip_v = !ns.vp.flip_v
	case .Rotate:
		ns.vp.rotate = (ns.vp.rotate + 1) % 4

	case .Open_Directory:
		dialog_request = .Folder
		return ns, rl.Command(Msg){}

	case .Tree_Scanned:
		if path, ok := scan_slot_take(); ok {
			cmd := begin_scan(&ns, path)
			delete(path)
			return ns, cmd
		}

	case .Select_Row:
		select_row(&ns, m.row)

	case .Page_Next:
		page(&ns, .Forward)
	case .Page_Prev:
		page(&ns, .Backward)

	case .Layout_Cycle:
		cycle_layout(&ns)

	case .Next_Viewport:
		ns.active_vp = (ns.active_vp + 1) % layout_count(ns.layout)

	case .Pool_Drained:
		drain_pool(&ns)



	case .Toggle_Inspector:
		ns.inspector.open = !ns.inspector.open

	case .Handle_Drop:
		// The path itself is already parked in `dropped_slot`.
	case .Noop:
	}

	drain_pool(&ns)

	// Dropped files arrive through ctx.input; view turns them into a
	// pending path before calling this.
	if pending_scan {
		pending_scan = false
		if path, ok := scan_slot_take(); ok {
			cmd := begin_scan(&ns, path)
			delete(path)
			return ns, cmd
		}
	}
	if ns.inspector_needs_refresh && ns.inspector.open && ns.frame != nil {
		ns.inspector_needs_refresh = false
		inspector_load_for(&ns, ns.frame.key.file)
	}

	if p, ok := take_dropped(); ok {
		cmd := os.is_dir(p) ? begin_scan(&ns, p) : begin_load(&ns, p)
		delete(p)
		return ns, cmd
	}
	return ns, {}
}

// dialog_request tells `view` to open a picker on this frame. Only one
// can be up at a time, so a single slot is enough.
Dialog_Request :: enum u8 {
	None,
	File,
	Folder,
}

@(private)
dialog_request := Dialog_Request.None

// last_dir_snapshot copies the remembered directory for the dialog to
// seed itself with; "" lets Windows pick.
last_dir_snapshot :: proc(dir: string) -> string {
	return dir
}

// queue_dropped_dir marks the picked path as a directory to scan.
queue_dropped_dir :: proc(path: string) {
	scan_slot_set(path)
	pending_scan = true
}

@(private)
pending_scan: bool

// dropped_slot carries a path from view (which sees input) to update.
@(private)
dropped_slot: Inflight
@(private)
has_dropped: bool

@(private)
take_dropped :: proc() -> (string, bool) {
	sync.lock(&dropped_slot.lock)
	defer sync.unlock(&dropped_slot.lock)
	if !has_dropped do return "", false
	has_dropped = false
	p := dropped_slot.path
	dropped_slot.path = ""
	return p, true
}

// queue_dropped is called from view when input.dropped_files is non-empty.
queue_dropped :: proc(path: string) {
	sync.lock(&dropped_slot.lock)
	if has_dropped do delete(dropped_slot.path)
	dropped_slot.path = fmt.aprintf("%s", path)
	has_dropped = true
	sync.unlock(&dropped_slot.lock)
}

// ---------------------------------------------------------------------------
// helpers used by the UI

describe_state :: proc(s: ^App_State) -> string {
	switch s.status {
	case .Failed:
		return fmt.tprintf("load failed: %s", s.err)
	case .Loading:
		return fmt.tprintf("loading %s ...", short_name(s.path))
	case .Ready:
		return describe_frame(s)
	case .Idle:
	}
	// The viewport already carries the open-a-file hint; the status bar
	// stays quiet until there is something to report.
	return ""
}

describe_frame :: proc(s: ^App_State) -> string {
	if s.frame == nil do return ""
	text := fmt.tprintf("%s  %dx%d  W %.0f / L %.0f  zoom %.2fx",
		short_name(s.path), s.info.rows, s.info.cols,
		s.vp.window.width, s.vp.window.center, s.vp.zoom)
	if s.vp.probe_valid {
		text = fmt.tprintf("%s  |  (%d,%d) %.0f", text,
			s.vp.probe_xy.x, s.vp.probe_xy.y, s.vp.probe_real)
	}
	return text
}

window_apply_preset :: proc(s: ^App_State, which: enum { Reset, Invert, Fit }) {
	if s.status != .Ready do return
	switch which {
	case .Reset:
		s.vp.window = s.vp.default_window
		if s.frame != nil do s.frame.window = s.vp.window
	case .Invert:
		s.vp.window.invert = !s.vp.window.invert
		if s.frame != nil do s.frame.window = s.vp.window
	case .Fit:
		s.vp.zoom = 1
		s.vp.pan = {0, 0}
	}
}


// g_pool is the session's decode pool. It lives at package scope because
// `App_State` is copied by value into `view` and `update`, and workers
// produce no Msg of their own: `view` must be able to poll for finished
// work through a stable address.
@(private)
g_pool: Decode_Pool
@(private)
g_pool_ready: bool

pool_pending_count :: proc() -> int {
	if !g_pool_ready do return 0
	return decode_pool_pending(&g_pool)
}

pool_ref :: proc() -> ^Decode_Pool {
	return &g_pool
}
