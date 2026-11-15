package nautilus

// Task 6 (M1): application state for the single-file viewer.
//
// `App_State` is a plain value the runtime keeps in `run`'s loop; the
// pointers it holds (`frame`, the cache's internal storage) point at
// heap state that outlives any single copy. `view` snapshots what the
// painter needs, so the copies never alias each other's scratch.

import d "../vendor/dicom"

Viewport_Window :: struct {
	tex_name: string, // "nautilus://vp/0/full"
	tex_w:    u32,
	tex_h:    u32,
	has_tex:  bool, // a texture exists at tex_name with tex_w/tex_h

	img_w: int,
	img_h: int,

	window:         d.Render_Options, // live W/L (also the LUT input)
	default_window: d.Render_Options, // stored VOI or frame min/max

	zoom:   f32,
	pan:    [2]f32,
	flip_h: bool,
	flip_v: bool,
	rotate: int,

	probe_valid: bool,
	probe_xy:    [2]int,
	probe_raw:   f64,
	probe_real:  f64,
	probe_gray:  u8,

	// Drag bookkeeping; the painter mutates the snapshot it is given.
	wl_drag_origin: [2]f32,
	wl_origin_w:    f64,
	wl_origin_l:    f64,
	pan_origin:     [2]f32,
	pan_from:       [2]f32,

	// Measurement overlay (image-space endpoints, honest units).
	measure_active: bool,
	measure_from:   [2]f64,
	measure_to:     [2]f64,
	measure_shown:  bool,
	measure_value:  f64,
	measure_unit:   string,
}

Load_Status :: enum {
	Idle,
	Loading,
	Ready,
	Failed,
}

App_State :: struct {
	path:   string,
	status: Load_Status,
	err:    string,
	// last_dir is the directory of the most recent successful open; the
	// file dialog starts there instead of the home directory, which
	// usually holds no DICOM at all.
	last_dir: string,

	frame: ^Cached_Frame, // borrowed from `cache`
	info:  d.Pixel_Info,


	status_text: string,
	vframes: [MAX_VIEWPORTS]^Cached_Frame, // per-panel display frame (borrowed from cache)

	// cache owns every decoded frame for the session.
	cache: Frame_Cache,
	// load_gen increments per load request; a worker result from an older
	// generation is discarded (the user opened something else meanwhile).
	load_gen: u64,
	// pending is the worker payload waiting for `update` to install it.
	pending:     Load_Result,
	pending_set: bool,

	// Directory mode. `tree` owns the scan result; `rows` is the flat
	// list the sidebar renders (study / series headers and frames).
	tree: Study_Tree,
	has_tree: bool,
	rows: []Sidebar_Row,
	selected_row: int,
	// expanded holds the series cards whose frame list is open in the tree.
	// Keyed by scan-scoped indices and cleared on every new scan.
	expanded: map[Series_Key]bool,

	// Multi-viewport layout and the per-viewport paging state.
	layout: View_Layout,
	viewports: [MAX_VIEWPORTS]Viewport_Window,
	flips: [MAX_VIEWPORTS]Flip_State,
	active_vp: int,

	// M3 measurement: drag with Shift+Left to draw a length; the result
	// stays until the next drag. Points are image pixels.
	measure_active: bool,
	measure_from:   [2]f64,
	measure_to:     [2]f64,
	measure_shown:  bool,
	measure_value:  f64,
	measure_unit:   string,

	// M3 inspector: Tag list + decode diagnostics for the shown frame.
	inspector: Inspector_State,
	// inspector_frame is the frame the tag list was built from.
	inspector_needs_refresh: bool,

	// decode_pool owns the workers; `ext_seq` tracks the generation of
	// the frame the active viewport asked for.
	pool: Decode_Pool,
	pool_ready: bool,
}

// vp_active returns the window/transform state the toolbar, keyboard,
// and pointer act on: the active viewport of the current layout.
vp_active :: proc(s: ^App_State) -> ^Viewport_Window {
	return &s.viewports[s.active_vp]
}

// vp_tex_names are the fixed GPU texture keys, one per viewport slot.
vp_tex_names := [MAX_VIEWPORTS]string{
	"nautilus://vp/0/full", "nautilus://vp/1/full",
	"nautilus://vp/2/full", "nautilus://vp/3/full",
}

Load_Result :: struct {
	gen:     u64,
	vp:      int,
	frame:   ^Cached_Frame,
	err:     string,
	open_ms: f64,
}
