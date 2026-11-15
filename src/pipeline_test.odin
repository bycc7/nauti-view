package nautilus

// Task 4 tests: the 16-bit 64K LUT must be byte-exact with
// dicom.render_gray8's per-pixel math across every combination that
// matters clinically, and must pack RGBA8 with opaque alpha.

import "core:testing"
import d "../vendor/dicom"
import rl "../vendor/skald"
@(test)
lut_matches_render_gray8 :: proc(t: ^testing.T) {
	// 16-bit signed, 12 bits stored, rescale on, MONOCHROME1 invert,
	// explicit window — the nastiest common combination.
	info := d.Pixel_Info{
		rows = 4, cols = 4, samples = 1, frames = 1,
		bits_allocated = 16, bits_stored = 12, high_bit = 11,
		signed = true, bytes_per_sample = 2,
		photometric = .Monochrome1, frame_bytes = 4 * 4 * 2,
	}
	raw := make([]u8, 32)
	defer delete(raw)
	// Store biased values covering 0..3855 (masked to 12 bits by the
	// pipeline), so the signed/sign-extension and mask paths both run.
	for i in 0 ..< 16 {
		v := i * 257 + 2048
		raw[i * 2] = u8(v & 0xFF)
		raw[i * 2 + 1] = u8((v >> 8) & 0xFF)
	}
	combos := []d.Render_Options{
		{center = 40, width = 400, valid_window = true, slope = 1, intercept = -1024, invert = true},
		{center = -600, width = 1500, valid_window = true, slope = 1, intercept = -1024, invert = false},
		{center = 2048, width = 4096, valid_window = true, slope = 0, intercept = 0, invert = true}, // 8..12-bit unsigned, no rescale
		{center = 0.5, width = 0.5, valid_window = true, slope = 1, intercept = 0, invert = false},  // width<1 threshold branch
	}
	want := make([]u8, 16)
	defer delete(want)
	rgba := make([]u8, 16 * 4)
	defer delete(rgba)

	for opts in combos {
		if !d.render_gray8(info, raw, want, opts) {
			testing.fail_now(t, "render_gray8 refused opts")
		}

		lut := build_lut(info, opts)
		if !apply_lut_u16(&lut, raw, rgba) {
			testing.fail_now(t, "apply_lut_u16 refused")
		}
		for p in 0 ..< 16 {
			testing.expectf(t, rgba[p * 4] == want[p],
				"px %d opts(center=%v width=%v inv=%v slope=%v icept=%v): LUT %v != gray8 %v",
				p, opts.center, opts.width, opts.invert, opts.slope, opts.intercept,
				rgba[p * 4], want[p])
			testing.expect_value(t, rgba[p * 4 + 1], want[p]) // G mirrors gray
			testing.expect_value(t, rgba[p * 4 + 2], want[p]) // B mirrors gray
			testing.expect_value(t, rgba[p * 4 + 3], u8(255)) // opaque alpha
		}
	}
}

@(test)
lut_auto_window_from_frame_stats :: proc(t: ^testing.T) {
	// 8-bit unsigned no-window case: auto window must equal what
	// render_gray8 computes internally (min/max stretch).
	info := d.Pixel_Info{
		rows = 4, cols = 4, samples = 1, frames = 1,
		bits_allocated = 8, bits_stored = 8, high_bit = 7,
		signed = false, bytes_per_sample = 1,
		photometric = .Monochrome2, frame_bytes = 16,
	}
	raw := []u8{10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 200}

	auto := d.Render_Options{slope = 1}
	c, w := lut_auto_window(info, raw)
	auto.center, auto.width, auto.valid_window = c, w, true

	want := make([]u8, 16)
	defer delete(want)
	testing.expect(t, d.render_gray8(info, raw, want, auto))

	lut := build_lut(info, auto)
	rgba := make([]u8, 16 * 4)
	defer delete(rgba)
	testing.expect(t, apply_lut_u8(&lut, raw, rgba))
	for p in 0 ..< 16 {
		testing.expectf(t, rgba[p * 4] == want[p], "auto px %d: %v != %v", p, rgba[p * 4], want[p])
	}
	// DICOM maps min to ~1 and max to ~254 (y = (i/(W-1)+0.5)*255 with
	// W = max-min+1); the LUT must reproduce that exactly, not the naive
	// 0/255 stretch.
	testing.expect_value(t, c, 105.0)
	testing.expect_value(t, w, 191.0)
	testing.expect(t, rgba[0] <= 1 && rgba[15 * 4] >= 254, "min/max near endpoints")
}

@(test)
reset_restores_default_viewport_state :: proc(t: ^testing.T) {
	// “重置” means back to the frame's initial display state — the same
	// defaults install_result lays down. It must undo rotate / flips /
	// zoom / pan as well as any window/level drag, not just the window.
	s: App_State
	s.status = .Ready
	s.viewports[0] = Viewport_Window{
		flip_h = true, flip_v = true, rotate = 2,
		zoom = 3, pan = {10, 20}, has_tex = true,
		window = {center = 500, width = 50, valid_window = true},
		default_window = {center = 40, width = 400, valid_window = true},
	}
	s.active_vp = 0
	window_apply_preset(&s, .Reset)
	vp := &s.viewports[0]
	testing.expect(t, !vp.flip_h && !vp.flip_v, "flips restored")
	testing.expect_value(t, vp.rotate, 0)
	testing.expect_value(t, vp.zoom, 1)
	testing.expect_value(t, vp.pan, [2]f32{0, 0})
	testing.expect_value(t, vp.window.center, 40.0)
	testing.expect_value(t, vp.window.width, 400.0)
	testing.expect_value(t, vp.has_tex, false)
}

@(test)
inspector_tab_switch_updates_active_tab :: proc(t: ^testing.T) {
	// g4-a: the right pane's tab strip must actually switch which
	// substrip is shown. Set_Inspector_Tab drives Inspector_State.active
	// via update; a bogus index is rejected.
	s: App_State
	s.inspector.open = true
	s.inspector.active_tab = .Tags

	s2, _ := update(s, Msg{kind = .Set_Inspector_Tab, row = int(Inspector_Tab.Diagnostics)})
	testing.expect_value(t, s2.inspector.active_tab, Inspector_Tab.Diagnostics)

	s3, _ := update(s2, Msg{kind = .Set_Inspector_Tab, row = int(Inspector_Tab.Tags)})
	testing.expect_value(t, s3.inspector.active_tab, Inspector_Tab.Tags)

	// Out-of-range must not clobber the active tab.
	s4, _ := update(s3, Msg{kind = .Set_Inspector_Tab, row = 99})
	testing.expect_value(t, s4.inspector.active_tab, Inspector_Tab.Tags)
}

@(test)
orient_rgba_agrees_with_pointer_mapping :: proc(t: ^testing.T) {
	// The painter uploads an oriented texture; canvas_point_to_image is
	// the contract the probe and measurement math already assumes. Every
	// displayed pixel of orient_rgba's output must be the source pixel
	// the pointer map reports at that position, across all 16
	// orientation combinations, on a non-square image so a silent
	// transpose error cannot pass.
	w, h := 4, 3
	src := make([]u8, w * h * 4)
	defer delete(src)
	for i in 0 ..< w * h {
		src[i * 4] = u8(i) // unique gray per source pixel
		src[i * 4 + 3] = 255
	}

	bools := []bool{false, true}
	for rotate in 0 ..< 4 {
		for fh in bools {
			for fv in bools {
				out, ow, oh := orient_rgba(src, w, h, rotate, fh, fv, context.temp_allocator)
				testing.expectf(t, ow == (rotate % 2 == 1 ? h : w) && oh == (rotate % 2 == 1 ? w : h),
					"rotate %d fh %v fv %v: got %dx%d", rotate, fh, fv, ow, oh)

				vp := Viewport_Window{img_w = w, img_h = h, rotate = rotate, flip_h = fh, flip_v = fv, zoom = 1}
				// Exact-aspect bounds: the contain fit is the identity.
				bounds := rl.Rect{x = 0, y = 0, w = f32(ow) * 10, h = f32(oh) * 10}
				for dy in 0 ..< oh {
					for dx in 0 ..< ow {
						pt := [2]f32{(f32(dx) + 0.5) * 10, (f32(dy) + 0.5) * 10}
						ix, iy, ok := canvas_point_to_image(&vp, bounds, pt)
						testing.expectf(t, ok, "rotate %d fh %v fv %v: (%d,%d) outside", rotate, fh, fv, dx, dy)
						if !ok do continue
						want := src[(iy * w + ix) * 4]
						got := out[(dy * ow + dx) * 4]
						testing.expectf(t, got == want,
							"rotate %d fh %v fv %v: displayed (%d,%d) is %v, pointer map says src (%d,%d) = %v",
							rotate, fh, fv, dx, dy, got, ix, iy, want)
						testing.expectf(t, out[(dy * ow + dx) * 4 + 3] == 255,
							"rotate %d fh %v fv %v: alpha lost at (%d,%d)", rotate, fh, fv, dx, dy)
					}
				}
			}
		}
	}
}
