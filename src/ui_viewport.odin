package nautilus

// Task 6 (M1): the viewport canvas — upload, image draw, W/L drag, pan,
// zoom, and the hover probe.
//
// Skald keeps only a raw pointer to the canvas `user` and draws later in
// the same frame, so the payload is owned (allocated in the frame arena
// and shallow-copied from state).

import "core:fmt"
import "core:math"
import rl "../vendor/skald"
import d "../vendor/dicom"

Viewport_Payload :: struct {
	state: View_State,
	input: rl.Input,
	theme: ^rl.Theme,
}

// View_State is the read-only slice of App_State the painter needs.
View_State :: struct {
	status: Load_Status,
	path:   string,
	vp:     Viewport_Window,
	frame:  ^Cached_Frame,
	index:  int, // viewport slot this panel renders
	active: bool, // this panel receives keyboard / toolbar actions
}

// vp_hover / vp_pressed carry the panel the pointer is over (and last
// pressed) from the painters — which know their bounds — back to the
// next frame's `view`, which owns the Msg channel. Main thread only.
@(private)
vp_hover: int = -1
@(private)
vp_pressed: int = -1

// Viewport_Delta carries the interactive drag result the painter hands
// back: a W/L drag changes `window`, a middle-drag changes `pan`, a
// scroll changes `zoom`. The application folds these into real
// `App_State` on the next update, and caches the drag origins so a
// multi-frame gesture stays continuous. Filled by painters, consumed
// (and cleared) by update — both on the main thread.
Viewport_Delta :: struct {
	active: bool,
	vp:     int,
	// window is the live W/L; wl_origin_* are its pre-drag values.
	window:      d.Render_Options,
	wl_origin_w: f64,
	wl_origin_l: f64,
	// drag_from is the mouse position captured on the press frame; the
	// W/L and pan deltas are measured against it.
	drag_from: [2]f32,
	// pan is the live position; pan_base is the camera pan at press time.
	pan:      [2]f32,
	pan_base: [2]f32,
	zoomed:   bool,
	zoom:     f32,
}

@(private)
pending_delta: Viewport_Delta

// viewport_rect places the image in canvas-local pixels: contain-fit at
// zoom 1, then zoom and pan. The quarter-turn swaps the fit box.
viewport_rect :: proc(vp: ^Viewport_Window, bounds: rl.Rect) -> (rect: rl.Rect, scale: f32) {
	rotated := vp.rotate == 1 || vp.rotate == 3
	iw := f32(rotated ? vp.img_h : vp.img_w)
	ih := f32(rotated ? vp.img_w : vp.img_h)
	if iw <= 0 || ih <= 0 do return bounds, 1
	fit := min(bounds.w / iw, bounds.h / ih)
	scale = fit * vp.zoom
	w := iw * scale
	h := ih * scale
	cx := bounds.x + bounds.w * 0.5 + vp.pan.x
	cy := bounds.y + bounds.h * 0.5 + vp.pan.y
	return {cx - w * 0.5, cy - h * 0.5, w, h}, scale
}

// canvas_point_to_image maps a canvas-local point to image coordinates,
// undoing the on-screen rotation and flips.
canvas_point_to_image :: proc(vp: ^Viewport_Window, bounds: rl.Rect, pt: [2]f32) -> (x, y: int, ok: bool) {
	rect, _ := viewport_rect(vp, bounds)
	if pt.x < rect.x || pt.y < rect.y || pt.x >= rect.x + rect.w || pt.y >= rect.y + rect.h {
		return 0, 0, false
	}
	u := (pt.x - rect.x) / max(rect.w, 0.0001)
	v := (pt.y - rect.y) / max(rect.h, 0.0001)

	switch vp.rotate {
	case 1: u, v = v, 1 - u
	case 2: u, v = 1 - u, 1 - v
	case 3: u, v = 1 - v, u
	}
	if vp.flip_h do u = 1 - u
	if vp.flip_v do v = 1 - v

	iw := f32(vp.img_w)
	ih := f32(vp.img_h)
	x = clamp(int(u * iw), 0, vp.img_w - 1)
	y = clamp(int(v * ih), 0, vp.img_h - 1)
	return x, y, true
}

// image_point_to_canvas is the exact forward counterpart of
// canvas_point_to_image: maps image-space (x, y) in [0..img_w, 0..img_h]
// to canvas-local logical pixels under flip, quarter-turn, zoom, and pan.
image_point_to_canvas :: proc(vp: ^Viewport_Window, bounds: rl.Rect, img_pt: [2]f32) -> [2]f32 {
	rect, _ := viewport_rect(vp, bounds)
	u := img_pt.x / max(f32(vp.img_w), 1)
	v := img_pt.y / max(f32(vp.img_h), 1)

	if vp.flip_h do u = 1 - u
	if vp.flip_v do v = 1 - v

	switch vp.rotate {
	case 1: u, v = 1 - v, u
	case 2: u, v = 1 - u, 1 - v
	case 3: u, v = v, 1 - u
	}
	return {rect.x + u * rect.w, rect.y + v * rect.h}
}

// measure_distance computes Euclidean length between two image-pixel
// points with honest DICOM spacing semantics:
//   - .Pixel_Spacing  -> calibrated "mm"
//   - .Imager_Spacing -> detector-plane "mm (Imager)"
//   - .None           -> uncalibrated "px"
measure_distance :: proc(a, b: [2]f64, spacing: [2]f64, kind: Spacing_Kind) -> (val: f64, unit: string) {
	if (kind == .Pixel_Spacing || kind == .Imager_Spacing) && spacing[0] > 0 && spacing[1] > 0 {
		// DICOM PixelSpacing is [row_spacing_mm (dy), col_spacing_mm (dx)].
		dx := (b.x - a.x) * spacing[1]
		dy := (b.y - a.y) * spacing[0]
		return math.sqrt(dx * dx + dy * dy), (kind == .Pixel_Spacing ? "mm" : "mm (Imager)")
	}
	dx := b.x - a.x
	dy := b.y - a.y
	return math.sqrt(dx * dx + dy * dy), "px"
}

// measure_angle_deg returns the angle at `vertex` (in degrees, 0..180)
// formed by rays vertex->a and vertex->c.
measure_angle_deg :: proc(a, vertex, c: [2]f64) -> f64 {
	ux, uy := a.x - vertex.x, a.y - vertex.y
	vx, vy := c.x - vertex.x, c.y - vertex.y
	nu := math.sqrt(ux * ux + uy * uy)
	nv := math.sqrt(vx * vx + vy * vy)
	if nu <= 1e-9 || nv <= 1e-9 do return 0
	cos_t := clamp((ux * vx + uy * vy) / (nu * nv), -1.0, 1.0)
	return math.acos(cos_t) * (180.0 / math.PI)
}

// probe_pixel fills the probe fields from the cached frame's raw bytes.
probe_pixel :: proc(vp: ^Viewport_Window, frame: ^Cached_Frame, x, y: int) {
	info := frame.info
	idx := y * info.cols + x
	raw: i64
	switch info.bytes_per_sample {
	case 1:
		if idx < len(frame.raw) do raw = i64(frame.raw[idx])
	case 2:
		off := idx * 2
		if off + 1 < len(frame.raw) do raw = i64(u16(frame.raw[off]) | u16(frame.raw[off + 1]) << 8)
	case:
		return
	}
	real := lut_normalize(raw, info)
	vp.probe_raw = real
	if vp.window.slope != 0 do real = real * vp.window.slope + vp.window.intercept
	vp.probe_real = real
	g := lut_map(real, vp.window.center, vp.window.width)
	if vp.window.invert do g = 255 - g
	vp.probe_gray = g
}

// paint_viewport is the canvas draw callback. The GPU upload happens
// here because this is the only place with a renderer in scope.
paint_viewport :: proc(payload: ^Viewport_Payload, painter: rl.Canvas_Painter) {
	p := payload
	b := painter.bounds
	th := p.theme
	vp := &p.state.vp
	frame := p.state.frame

	rl.draw_rect(painter.r, b, rl.rgb(0x000000))

	if frame == nil || p.state.status != .Ready {
		msg := "Drop a DICOM file or folder here    Ctrl+O: file    Ctrl+D: folder"
		if p.state.status == .Loading do msg = "Loading ..."
		if p.state.status == .Failed do msg = "Cannot open file"
		rl.draw_text(painter.r, msg, b.x + 24, b.y + 48, th.color.fg_muted, th.font.size_md)
		return
	}

	// Upload-on-demand: a fresh frame (or a W/L change) invalidates the
	// texture. Build the RGBA buffer here, then push it to the GPU.
	if !vp.has_tex {
		rgba := make([]u8, len(frame.raw) / max(frame.info.bytes_per_sample, 1) * 4,
			context.temp_allocator)
		if frame_to_rgba(frame, vp.window, rgba) {
			// The GPU quad is axis-aligned, so rotation and flips are
			// baked into the uploaded pixels (orient_rgba mirrors
			// canvas_point_to_image exactly).
			tex, ow, oh := orient_rgba(rgba, frame.info.cols, frame.info.rows,
				vp.rotate, vp.flip_h, vp.flip_v, context.temp_allocator)

			uw, uh := u32(ow), u32(oh)
			ok := false
			if vp.tex_w == uw && vp.tex_h == uh {
				ok = rl.image_update_pixels(painter.r, vp.tex_name, uw, uh, tex)
			}
			if !ok {
				ok = rl.image_load_pixels_opts(painter.r, vp.tex_name, uw, uh, tex, false)
			}
			if ok {
				vp.tex_w = uw
				vp.tex_h = uh
				vp.has_tex = true
			}
		}
	}

	if vp.has_tex {
		rect, _ := viewport_rect(vp, b)
		if !rl.draw_image(painter.r, vp.tex_name, rect, .Fill) {
			rl.draw_rect(painter.r, rect, rl.rgb(0x331111))
		}
	}

	// Outline the panel that keyboard and toolbar actions target.
	if p.state.active {
		edge := f32(2)
		rl.draw_rect(painter.r, {b.x, b.y, b.w, edge}, th.color.primary)
		rl.draw_rect(painter.r, {b.x, b.y + b.h - edge, b.w, edge}, th.color.primary)
		rl.draw_rect(painter.r, {b.x, b.y, edge, b.h}, th.color.primary)
		rl.draw_rect(painter.r, {b.x + b.w - edge, b.y, edge, b.h}, th.color.primary)
	}

	// Hover probe.
	inside := p.input.mouse_pos.x >= b.x && p.input.mouse_pos.y >= b.y &&
		p.input.mouse_pos.x < b.x + b.w && p.input.mouse_pos.y < b.y + b.h
	if inside {
		vp_hover = p.state.index
		if p.input.mouse_pressed[.Left] { vp_pressed = p.state.index }
		if ix, iy, ok := canvas_point_to_image(vp, b, p.input.mouse_pos); ok {
			vp.probe_valid = true
			vp.probe_xy = {ix, iy}
			probe_pixel(vp, frame, ix, iy)
		} else {
			vp.probe_valid = false
		}
	} else {
		vp.probe_valid = false
	}

	// Shift+Left measures. The drag is tracked in image coordinates so the
	// result survives zoom and pan.
	if inside && p.input.mouse_pressed[.Left] && .Shift in p.input.modifiers && frame != nil {
		if ix, iy, ok := canvas_point_to_image(vp, b, p.input.mouse_pos); ok {
			vp.measure_active = true
			vp.measure_shown = false
			vp.measure_from = {f64(ix) + 0.5, f64(iy) + 0.5}
			vp.measure_to = vp.measure_from
		}
	}
	if vp.measure_active && !p.input.mouse_buttons[.Left] {
		vp.measure_active = false
		if frame != nil {
			vp.measure_value, vp.measure_unit = measure_distance(
				vp.measure_from, vp.measure_to, frame.pixel_spacing, frame.spacing_kind)
			vp.measure_shown = true
		}
	}
	if vp.measure_active {
		if ix, iy, ok := canvas_point_to_image(vp, b, p.input.mouse_pos); ok {
			vp.measure_to = {f64(ix) + 0.5, f64(iy) + 0.5}
			vp.measure_shown = true
			vp.measure_value, vp.measure_unit = measure_distance(
				vp.measure_from, vp.measure_to, frame.pixel_spacing, frame.spacing_kind)
		}
	}

	// W/L and pan drags fold into pending_delta (this `vp` is a per-frame
	// copy — mutating it would be thrown away); update applies the result
	// to the real viewport next frame.
	if p.input.mouse_pressed[.Right] && inside {
		pending_delta.active = true
		pending_delta.vp = p.state.index
		pending_delta.window = vp.window
		pending_delta.wl_origin_w = vp.window.width
		pending_delta.wl_origin_l = vp.window.center
		pending_delta.drag_from = p.input.mouse_pos
	}
	if p.input.mouse_buttons[.Right] && pending_delta.active && pending_delta.vp == p.state.index && pending_delta.wl_origin_w != 0 {
		dx := p.input.mouse_pos.x - pending_delta.drag_from.x
		dy := p.input.mouse_pos.y - pending_delta.drag_from.y
		w := max(pending_delta.wl_origin_w * math.pow(f64(2), f64(dx) / 256.0), 1)
		l := pending_delta.wl_origin_l + f64(dy) * pending_delta.wl_origin_w / 512.0
		pending_delta.window.width = w
		pending_delta.window.center = l
	}
	if p.input.mouse_pressed[.Middle] && inside {
		pending_delta.active = true
		pending_delta.vp = p.state.index
		pending_delta.pan = vp.pan
		pending_delta.pan_base = vp.pan
		pending_delta.drag_from = p.input.mouse_pos
	}
	if p.input.mouse_buttons[.Middle] && pending_delta.active && pending_delta.vp == p.state.index {
		pending_delta.pan = pending_delta.pan_base + (p.input.mouse_pos - pending_delta.drag_from)
	}

	if inside && p.input.scroll.y != 0 {
		pending_delta.active = true
		pending_delta.vp = p.state.index
		pending_delta.zoomed = true
		pending_delta.zoom = clamp(vp.zoom * math.pow(f32(1.1), p.input.scroll.y), 0.05, 64)
	}

	// Measurement overlay: line + value at its midpoint.
	if vp.measure_shown {
		a := image_point_to_canvas(vp, b, {f32(vp.measure_from.x) - 0.5, f32(vp.measure_from.y) - 0.5})
		c := image_point_to_canvas(vp, b, {f32(vp.measure_to.x) - 0.5, f32(vp.measure_to.y) - 0.5})
		rl.draw_line(painter.r, a, c, 1.5, th.color.primary, true)
		label := fmt.tprintf("%.1f %s", vp.measure_value, vp.measure_unit)
		rl.draw_text(painter.r, label, (a.x + c.x) * 0.5 + 6, (a.y + c.y) * 0.5 - 6,
			th.color.primary, th.font.size_sm)
	}

	// 4-corner clinical HUD (g3-a) + bottom-right scale bar. Right-side
	// texts are measured and anchored to the pane's right edge so they
	// hug the corner at any pane size (2x2 panes are narrow).
	pad := f32(12)
	tl := short_name(p.state.path)
	rl.draw_text(painter.r, tl, b.x + pad, b.y + 20, th.color.fg, th.font.size_sm)
	tr := fmt.tprintf("%dx%d  %d-bit %v", frame.info.cols, frame.info.rows,
		frame.info.bits_stored, frame.info.photometric)
	trw, _ := rl.measure_text(painter.r, tr, th.font.size_sm)
	rl.draw_text(painter.r, tr, b.x + b.w - trw - pad, b.y + 20, th.color.fg_muted, th.font.size_sm)

	bl := fmt.tprintf("W %.0f / L %.0f   %.2fx", vp.window.width, vp.window.center, vp.zoom)
	if vp.probe_valid {
		bl = fmt.tprintf("%s   (%d, %d) %.0f", bl, vp.probe_xy.x, vp.probe_xy.y, vp.probe_real)
	}
	rl.draw_text(painter.r, bl, b.x + pad, b.y + b.h - 14, th.color.fg_muted, th.font.size_sm)

	_, unit := measure_distance({0, 0}, {100, 0}, frame.pixel_spacing, frame.spacing_kind)
	br := fmt.tprintf("100 px = %.1f %s",
		(frame.spacing_kind != .None && frame.pixel_spacing[1] > 0) ? 100.0 * frame.pixel_spacing[1] : 100.0,
		unit)
	brw, _ := rl.measure_text(painter.r, br, th.font.size_sm)
	rl.draw_text(painter.r, br, b.x + b.w - brw - pad, b.y + b.h - 14, th.color.fg_muted, th.font.size_sm)
}
