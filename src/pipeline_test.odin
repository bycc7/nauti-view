package nautilus

// Task 4 tests: the 16-bit 64K LUT must be byte-exact with
// dicom.render_gray8's per-pixel math across every combination that
// matters clinically, and must pack RGBA8 with opaque alpha.

import "core:testing"
import d "../vendor/dicom"

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
