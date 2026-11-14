package nautilus

import "core:fmt"
import "core:testing"
import "core:time"
import d "../vendor/dicom"

// Not a correctness test: pins the budget the sync M1 path relies on.
@(test)
lut_perf_budget :: proc(t: ^testing.T) {
	info := d.Pixel_Info{bits_allocated = 16, bits_stored = 12, signed = true, bytes_per_sample = 2}
	opts := d.Render_Options{center = 2000, width = 4000, valid_window = true, slope = 1, intercept = -1024, invert = false}

	start := time.now()
	lut := build_lut(info, opts)
	build_ms := f64(time.duration_milliseconds(time.since(start)))

	SIDE :: 3692 // 13.6 MP, a 2560x3328 CR frame
	src := make([]u8, SIDE * SIDE * 2)
	defer delete(src)
	dst := make([]u8, SIDE * SIDE * 4)
	defer delete(dst)
	for i in 0 ..< len(src) / 2 {
		src[i * 2] = u8(i & 0xFF)
		src[i * 2 + 1] = u8((i >> 4) & 0xFF)
	}

	start = time.now()
	ok := apply_lut_u16(&lut, src, dst)
	apply_ms := f64(time.duration_milliseconds(time.since(start)))

	fmt.printfln("LUT build: %.3f ms | apply %d px: %.2f ms (%.0f MP/s)",
		build_ms, SIDE * SIDE, apply_ms, f64(SIDE * SIDE) / max(apply_ms, 0.001) / 1000)
	testing.expect(t, ok)
	// Budgets are for release builds (-o:speed); an unoptimized `odin test
	// src` runs apply ~19x slower. `odin test src -o:speed` must pass.
	testing.expect(t, build_ms < 2.0, "build under 2 ms")
	testing.expect(t, apply_ms < 30.0, "apply a 13.6 MP frame under 30 ms")
}
