package nautilus

// Multi-viewport slot assignment: layout panels map 1:1 to the series
// list in sidebar (tree) order — viewport 0 shows the first series,
// viewport 1 the second, and slots beyond the series count stay empty.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import d "../vendor/dicom"

@(test)
inspector_diag_transfer_syntax_outlives_document :: proc(t: ^testing.T) {
	// The Diagnostic copies Transfer_Syntax.uid, which points into the
	// parse buffer the vendor Document releases on reset/destroy. It
	// must be cloned so it survives — else it renders as garbled text.
	buf := synth_dicom_series(1, "1.2.9", "2.0")
	dir, derr := os.make_directory_temp("", "nautilus_diag", context.temp_allocator)
	if derr != nil {
		testing.fail_now(t, "cannot make temp dir")
	}
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "img.dcm"}, allocator = context.temp_allocator)
	_ = os.write_entire_file(path, buf)

	diag := inspect_file_diagnostic(path)
	defer if diag.transfer_syntax != "" do delete(diag.transfer_syntax)

	// The synthetic file has no TransferSyntaxUID element, so the parser
	// defaults to Implicit VR Little Endian (prefix 1.2.840.10008.1.2).
	// Assert the prefix survives — a dangling pointer would read garbage
	// here, not a clean UID.
	uid := "1.2.840.10008.1.2"
	testing.expectf(t, len(diag.transfer_syntax) >= len(uid),
		"transfer_syntax too short: %q", diag.transfer_syntax)
	if len(diag.transfer_syntax) >= len(uid) {
		for i in 0 ..< len(uid) {
			testing.expectf(t, diag.transfer_syntax[i] == uid[i],
				"transfer_syntax damaged at byte %d: %q", i, diag.transfer_syntax)
		}
	}
}

// scan_synth_series writes `per_series` files per synthetic series and
// scans the directory into a tree. Study "9.1" sorts before "1.1" (same
// date, uid desc tie-break), making the expected order deterministic.
scan_synth_series :: proc(t: ^testing.T, tag: string, series_count: int, per_series: int) -> Study_Tree {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", tag, tmp)
	if derr != nil {
		testing.fail_now(t, "cannot make temp dir")
	}
	defer os.remove_all(dir)

	for ser in 0 ..< series_count {
		study := ser < series_count / 2 ? "9.1" : "1.1"
		series_uid := fmt.aprintf("2.%d", ser)
		for i in 1 ..= per_series {
			name := fmt.aprintf("s%02d_%02d.dcm", ser, i)
			path, _ := filepath.join({dir, name}, allocator = tmp)
			_ = os.write_entire_file(path, synth_dicom_series(i, study, series_uid))
		}
	}
	return scan_directory(dir, allocator = context.allocator)
}

@(test)
multi_viewport_slots_follow_series_order :: proc(t: ^testing.T) {
	// 3 series of 2 frames each across two studies: quad layout has one
	// empty slot.
	tree := scan_synth_series(t, "nautilus_vp_assign", 3, 2)
	defer study_tree_destroy(&tree)

	s: App_State
	s.layout = .Quad
	assign_slots(&s, &tree)

	// Tree order: study "9.1" (series 2.0, 2.1) then study "1.1" (2.2).
	testing.expect_value(t, len(s.flips[0].frames), 2)
	testing.expect_value(t, len(s.flips[1].frames), 2)
	testing.expect_value(t, len(s.flips[2].frames), 2)
	testing.expect_value(t, len(s.flips[3].frames), 0)

	// Slot 0 is series 2.0: its entries must page in InstanceNumber order.
	e := s.flips[0].frames
	testing.expectf(t, tree.entries[e[0]].instance == 1 && tree.entries[e[1]].instance == 2,
		"slot 0 pages in instance order, got %d then %d",
		tree.entries[e[0]].instance, tree.entries[e[1]].instance)

	// Slot 1 must be a different series than slot 0.
	testing.expect(t, s.flips[1].frames[0] != s.flips[0].frames[0], "slots share a series")

	// Two-panel layout only fills two slots.
	s2: App_State
	s2.layout = .Two
	assign_slots(&s2, &tree)
	testing.expect_value(t, len(s2.flips[1].frames), 2)
	testing.expect_value(t, len(s2.flips[2].frames), 0)
}

@(test)
apply_viewport_delta_persists_drag_state :: proc(t: ^testing.T) {
	// W/L / pan / zoom drags happen in the painter, which only sees a
	// copy. apply_viewport_delta folds the painter's result back into the
	// real state so the next frame sees it — and keeps the drag origins
	// so the gesture stays continuous across frames.
	s: App_State
	s.active_vp = 0
	s.viewports[0].window = {center = 40, width = 400, valid_window = true}
	s.viewports[0].has_tex = false

	dv := Viewport_Delta{
		vp = 0, active = true,
		window = {center = 120, width = 260, valid_window = true},
		wl_origin_w = 400, wl_origin_l = 40,
		pan = {50, -30}, zoomed = true, zoom = 2,
	}
	applied := apply_viewport_delta(&s, dv)
	testing.expect(t, applied, "delta for live viewport applies")
	vp := &s.viewports[0]
	testing.expect_value(t, vp.window.center, 120.0)
	testing.expect_value(t, vp.window.width, 260.0)
	testing.expect_value(t, vp.wl_origin_w, 400.0)
	testing.expect_value(t, vp.wl_origin_l, 40.0)
	testing.expect_value(t, vp.pan, [2]f32{50, -30})
	testing.expect_value(t, vp.zoom, 2.0)
	testing.expectf(t, !vp.has_tex, "window change invalidates texture")

	// An inactive/stale delta, or one for an out-of-range panel, is
	// dropped instead of corrupting state.
	s2: App_State
	dv2 := Viewport_Delta{active = false, vp = 0, window = {center = 5, width = 10}}
	testing.expect(t, !apply_viewport_delta(&s2, dv2), "inactive delta rejected")
	dv3 := Viewport_Delta{active = true, vp = 99, window = {center = 5, width = 10}}
	testing.expect(t, !apply_viewport_delta(&s2, dv3), "out-of-range vp rejected")
}
