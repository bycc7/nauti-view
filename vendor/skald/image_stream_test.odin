package skald

// Task 3 tests: no-mip streaming textures (image_load_pixels_opts) and the
// persistent staging pool's pure decision logic. The GPU upload path itself
// needs a live Vulkan device and is covered end-to-end by Nautilus's
// --self-test pipeline; these tests pin the headless-decidable contract.

import "core:testing"

// mip_count must collapse to exactly 1 when mipmapped=false, whatever the
// extent — that is what lets image_update_pixels skip all CPU box-filtering.
@(test)
image_mip_count_no_mip_always_one :: proc(t: ^testing.T) {
	testing.expect_value(t, image_mip_count(1024, 768, false), u32(1))
	testing.expect_value(t, image_mip_count(4096, 4096, false), u32(1))
	testing.expect_value(t, image_mip_count(1, 1, false), u32(1))
}

// mipmapped=true keeps the legacy full chain: ceil(log2(max))+1 levels.
@(test)
image_mip_count_full_chain :: proc(t: ^testing.T) {
	testing.expect_value(t, image_mip_count(1024, 1024, true), u32(11))
	testing.expect_value(t, image_mip_count(1, 1, true), u32(1))
	testing.expect_value(t, image_mip_count(1000, 100, true), u32(10)) // max axis drives: 10 levels
}
// The opts entry validates its arguments the same way image_load_pixels
// does, before any GPU object is touched: nil device, zero extent, and
// byte-length mismatch must all return false without crashing.
@(test)
image_load_pixels_opts_validates :: proc(t: ^testing.T) {
	r := new(Renderer) // no device: headless
	defer free(r)
	rgba := make([]u8, 4 * 4 * 4)
	defer delete(rgba)

	testing.expect(t, image_load_pixels_opts(r, "nautilus://vp/0/full", 4, 4, rgba, false) == false,
		"nil device must refuse")
	testing.expect(t, image_load_pixels_opts(r, "k", 0, 4, rgba, false) == false,
		"zero width must refuse")
	testing.expect(t, image_load_pixels_opts(r, "k", 4, 4, rgba[:10], false) == false,
		"length mismatch must refuse")
}
