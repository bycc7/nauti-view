package nautilus

// Nautilus — 本地 DICOM 阅片器.
//
// `--self-test <file>...` runs the real open → decode → LUT → RGBA path
// headlessly and exits; otherwise the Skald window starts.

import "core:fmt"
import "core:os"
import "core:strings"
import rl "../vendor/skald"
import d "../vendor/dicom"

view :: proc(s: App_State, ctx: ^rl.Ctx(Msg)) -> rl.View {
	th := ctx.theme

	// One-shot: a path from the command line loads on the first frame.
	// Done here (not in update) because update cannot start a thread
	// without a Command, and the frame that owns `start_path`.
	if start_path != "" {
		rl.send(ctx, Msg{kind = .Start_Initial})
	}

	// Run a parked picker. The modal common dialog blocks this frame, so
	// it must happen here where the window handle is reachable; the
	// result is stashed and picked up by update on the next frame.
	switch dialog_request {
	case .File:
		dialog_request = .None
		if path := modern_open_file(ctx.window.window); path != "" {
			queue_dropped(path)
			delete(path)
		}
	case .Folder:
		dialog_request = .None
		if path := modern_open_folder(ctx.window.window); path != "" {
			queue_dropped_dir(path)
			delete(path)
		}
	case .None:
	}

	// Dropped files: ctx.input owns a temp slice, so copy the first path
	// out before returning.
	if len(ctx.input.dropped_files) > 0 {
		// Park the path, then wake update: without a Msg it never runs,
		// so the drop would sit in the slot forever.
		queue_dropped(ctx.input.dropped_files[0])
		rl.send(ctx, Msg{kind = .Handle_Drop})
	}

	ensure_cjk_font(ctx.renderer)

	// Each panel and each Quad row must claim its share with flex:
	// intrinsic-sized children leave the row's claimed space unused (the
	// canvases would sit at their minimum size instead of filling).
	c0 := rl.flex(1, vp_canvas(ctx, s, 0))
	grid := c0
	if s.layout == .Two {
		grid = rl.row(c0, rl.flex(1, vp_canvas(ctx, s, 1)),
			width = 0, height = 0, cross_align = .Stretch)
	} else if s.layout == .Quad {
		grid = rl.col(
			rl.flex(1, rl.row(c0, rl.flex(1, vp_canvas(ctx, s, 1)),
				width = 0, height = 0, cross_align = .Stretch)),
			rl.flex(1, rl.row(rl.flex(1, vp_canvas(ctx, s, 2)), rl.flex(1, vp_canvas(ctx, s, 3)),
				width = 0, height = 0, cross_align = .Stretch)),
			width = 0, height = 0, cross_align = .Stretch,
		)
	}

	// Pool results arrive asynchronously and do not create Msgs, so a
	// frame with a finished decode must wake `update` itself or the image
	// never lands.
	if pool_pending_count() > 0 {
		rl.send(ctx, Msg{kind = .Pool_Drained})
	}

	// Panel routing: the painters stamp which panel the pointer is over
	// (and last pressed); view owns the Msg channel. A press activates
	// that panel, and the wheel pages the hovered panel's own series.
	if vp_pressed >= 0 {
		rl.send(ctx, Msg{kind = .Set_Active_Vp, vp = vp_pressed})
		vp_pressed = -1
	}
	if ctx.input.scroll.y != 0 && vp_hover >= 0 {
		dir := ctx.input.scroll.y < 0 ? Msg_Kind.Page_Next : Msg_Kind.Page_Prev
		rl.send(ctx, Msg{kind = dir, vp = vp_hover})
		rl.send(ctx, Msg{kind = .Set_Active_Vp, vp = vp_hover})
	}
	vp_hover = -1 // painters re-stamp it during this frame's draw

	viewport := rl.flex(1, grid)

	// Root stack must span the whole window: `width`/`height` 0 means
	// "intrinsic", which collapses to the canvas's min size.
	panels: [dynamic]rl.View
	append(&panels, sidebar(ctx, s))
	append(&panels, viewport)
	if s.inspector.open {
		append(&panels, inspector(ctx, s))
	}
	body := rl.row(..panels[:],
		width = 0,
		height = 0,
		cross_align = .Stretch,
		spacing = th.spacing.sm,
	)
	toolbar_state := s // params are not addressable; topbar wants a pointer
	return rl.col(
		topbar(ctx, &toolbar_state),
		rl.flex(1, body),
		status_bar(ctx, s),
		width = 0,
		height = 0,
		padding = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// vp_canvas builds one viewport panel of the layout grid. Every
// viewport shows the loaded frame with its own transform state; the
// active one is flagged so the painter can outline it.
vp_canvas :: proc(ctx: ^rl.Ctx(Msg), s: App_State, i: int) -> rl.View {
	payload := new(Viewport_Payload, context.temp_allocator)
	payload^ = Viewport_Payload{
		state = View_State{
			status = s.status,
			path = s.path,
			vp = s.viewports[i],
			frame = s.vframes[i],
			index = i,
			active = i == s.active_vp,
		},
		input = ctx.input^,
		theme = ctx.theme,
	}
	return rl.canvas(ctx, payload, paint_viewport, min_w = 160, min_h = 120)
}

// status_bar is the bottom diagnostic line: path, geometry, W/L, probe.
status_bar :: proc(ctx: ^rl.Ctx(Msg), s: App_State) -> rl.View {
	th := ctx.theme
	snap := new(App_State, context.temp_allocator)
	snap^ = s
	text := describe_state(snap)
	return rl.col(
		rl.text(text, th.color.fg_muted, th.font.size_sm),
		padding = th.spacing.md,
	)
}

main :: proc() {
	args := os.args
	defer delete(args)

	// --self-test --dir <root>: scan a directory and report the tree.
	if len(args) >= 4 && args[1] == "--self-test" && args[2] == "--dir" {
		os.exit(self_test_dir(args[3]))
	}

	if len(args) >= 2 && args[1] == "--self-test" {
		if len(args) < 3 {
			fmt.eprintln("usage: nautilus --self-test <file>...")
			os.exit(2)
		}
		os.exit(self_test(args[2:]))
	}

	// --dump-rgba <file> <out> writes the rendered RGBA8 buffer, so the
	// pixel pipeline can be diffed against pydicom frame by frame.
	if len(args) >= 4 && args[1] == "--dump-rgba" {
		os.exit(dump_rgba(args[2], args[3]))
	}

	g_start = state_init()
	g_start.inspector.open = true
	if len(args) >= 2 && !strings.has_prefix(args[1], "--") {
		// Deferred: the worker command must be dispatched by the runtime,
		// so the first frame issues it from init's state.
		start_path = fmt.aprintf("%s", args[1])
	}
	defer state_destroy(&g_start)

	rl.run(rl.App(App_State, Msg){
		title         = "Nautilus",
		size          = {1280, 800},
		theme         = rl.theme_dark(),
		always_redraw = true, // the probe and W/L drag are per-frame
		init          = proc() -> App_State { return g_start },
		update        = update,
		view          = view,
		on_key        = handle_key,
	})
}

// g_start is the initial state; `App.init` is a bare proc so the state
// cannot be a local captured by a closure.
@(private)
g_start: App_State

// start_path is consumed once by update to kick the initial load.
@(private)
start_path: string

// handle_key maps the M1 shortcut set. Ctrl+O is the dialog; the rest are
// bare letters so they cannot collide with a modifier chord.
handle_key :: proc(ev: rl.Key_Event) -> Msg {
	if !ev.pressed do return Msg{kind = .Noop}
	#partial switch ev.key {
	case .O: if .Ctrl in ev.mods do return Msg{kind = .Open_Dialog}
	case .I:
		if .Ctrl in ev.mods do return Msg{kind = .Toggle_Inspector}
		if ev.mods == {} do return Msg{kind = .Invert}
	case .R: if ev.mods == {} do return Msg{kind = .Rotate}
	case .H: if ev.mods == {} do return Msg{kind = .Flip_H}
	case .V: if ev.mods == {} do return Msg{kind = .Flip_V}
	case .N0: if ev.mods == {} do return Msg{kind = .Reset_Window}
	case .F: if ev.mods == {} do return Msg{kind = .Zoom_Fit}
	case .D: if .Ctrl in ev.mods do return Msg{kind = .Open_Directory}
	case .L: if .Ctrl in ev.mods do return Msg{kind = .Layout_Cycle}
	case .Tab: if ev.mods == {} do return Msg{kind = .Next_Viewport}
	case:
	}
	return Msg{kind = .Noop}
}


// cjk_ttf holds the system CJK font bytes. Skald's bundled Inter has no
// Han glyphs, so Chinese labels (面板标题, 帧) render as tofu without a
// fallback. The bytes must outlive the renderer, so they are kept here
// rather than in a frame arena.
@(private)
cjk_ttf: []byte
@(private)
cjk_ready: bool

ensure_cjk_font :: proc(renderer: ^rl.Renderer) {
	if cjk_ready || renderer == nil do return
	cjk_ready = true

	// simhei.ttf first: msyh.ttc is a collection whose face 0 has no Han
	// glyphs, and AddFontMem cannot select a face index. The same rule
	// orders the macOS candidates: single-face Arial Unicode before the
	// .ttc system fonts (Hiragino Sans GB / STHeiti), whose face 0 also
	// cannot be selected.
	for path in ([]string{
		"C:/Windows/Fonts/simhei.ttf",
		"C:/Windows/Fonts/msyh.ttc",
		"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
		"/System/Library/Fonts/Hiragino Sans GB.ttc",
		"/System/Library/Fonts/STHeiti Light.ttc",
	}) {
		data, rerr := os.read_entire_file(path, context.allocator)
		if rerr != nil do continue
		cjk_ttf = data
		font := rl.font_load(renderer, "cjk", data)
		if font == 0 do continue
		rl.font_add_fallback(renderer, rl.font_default(renderer), font)
		fmt.eprintfln("cjk: loaded %s", path)
		return
	}
}
