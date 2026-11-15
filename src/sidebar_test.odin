package nautilus

// Tests for the sidebar upgrade (design g2-a): patient grouping, per-series
// metadata, stable row identity, and the frame cursor the progress bar reads.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "base:runtime"
import rl "../vendor/skald"

@(private)
write_synth :: proc(t: ^testing.T, dir, name: string, data: []u8) {
	path, _ := filepath.join({dir, name}, allocator = context.temp_allocator)
	if err := os.write_entire_file(path, data); err != nil {
		testing.fail_now(t, "cannot write synthetic file")
	}
}

// sidebar_scan_groups_patients_and_extracts_series_metadata covers the
// data the sidebar card needs: patient layer, per-series (not per-study)
// modality/description/geometry, and the per-frame cursor position.
@(test)
sidebar_scan_groups_patients_and_extracts_series_metadata :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", "nautilus_sidebar_meta", tmp)
	if derr != nil do testing.fail_now(t, "cannot make temp dir")
	defer os.remove_all(dir)

	// Two patients; one study whose series UID is reused by another
	// study; one file with no StudyInstanceUID at all.
	write_synth(t, dir, "a1.dcm", synth_dicom_series(1, "1.2.3", "1.2.3.1", "WATER AX", "0000000499", "LUO^SHANHENG", "MR", 512, 512, 16))
	write_synth(t, dir, "a2.dcm", synth_dicom_series(2, "1.2.3", "1.2.3.1", "WATER AX", "0000000499", "LUO^SHANHENG", "MR", 512, 512, 16))
	write_synth(t, dir, "a3.dcm", synth_dicom_series(3, "1.2.3", "1.2.3.1", "WATER AX", "0000000499", "LUO^SHANHENG", "MR", 512, 512, 16))
	write_synth(t, dir, "b1.dcm", synth_dicom_series(1, "1.2.4", "1.2.3.1", "FAT AX", "0000000499", "LUO^SHANHENG", "CT", 256, 256, 12))
	write_synth(t, dir, "c1.dcm", synth_dicom_series(1, "9.9.9", "9.9.9.1", "RCC BREAST", "3955198", "LI CHUN", "MG", 3328, 4096, 16))
	write_synth(t, dir, "d1.dcm", synth_dicom_series(1, "", "5.5.5.1", "LEGACY", "", "", "DX", 1024, 1024, 16))

	tree := scan_directory(dir, allocator = context.allocator)
	defer study_tree_destroy(&tree)

	testing.expect_value(t, len(tree.entries), 6)
	// 1.2.3, 1.2.4, 9.9.9, and the synthetic study for the empty UID.
	testing.expect_value(t, len(tree.studies), 4)
	// LUO, LI CHUN, and the unknown-patient bucket.
	testing.expect_value(t, len(tree.patients), 3)

	found := false
	for &st in tree.studies {
		for &ser in st.series {
			if ser.description != "WATER AX" do continue
			found = true
			testing.expect_value(t, ser.modality, "MR")
			testing.expect_value(t, ser.rows, 512)
			testing.expect_value(t, ser.cols, 512)
			testing.expect_value(t, ser.bits, 16)
			testing.expect_value(t, len(ser.frames), 3)
			for k in 0 ..< len(ser.frames) {
				testing.expect_value(t, tree.entries[ser.frames[k]].pos, k)
			}
		}
	}
	testing.expect(t, found, "WATER AX series missing")

	// The same SeriesInstanceUID under two studies must stay two cards.
	shared := 0
	for &st in tree.studies {
		for &ser in st.series do if ser.uid == "1.2.3.1" do shared += 1
	}
	testing.expect_value(t, shared, 2)

	luo := -1
	li := -1
	for &p, i in tree.patients {
		if p.name == "LUO^SHANHENG" do luo = i
		if p.name == "LI CHUN" do li = i
	}
	testing.expect(t, luo >= 0, "LUO patient missing")
	testing.expect(t, li >= 0, "LI CHUN patient missing")
	if luo >= 0 do testing.expect_value(t, len(tree.patients[luo].studies), 2)
	if li >= 0 do testing.expect_value(t, tree.patients[li].id, "3955198")

	// A file without StudyInstanceUID is kept, not silently dropped.
	legacy := false
	for &st in tree.studies {
		for &ser in st.series do if ser.description == "LEGACY" do legacy = true
	}
	testing.expect(t, legacy, "study without StudyInstanceUID was dropped")
}

@(test)
sidebar_labels_format_dates_geometry_and_cursor :: proc(t: ^testing.T) {
	testing.expect_value(t, study_date_label("20260519"), "2026-05-19")
	testing.expect_value(t, study_date_label(""), "")
	testing.expect_value(t, study_date_label("2026"), "2026")

	testing.expect_value(t, series_geom_label(512, 512, 16), "512×512 · 16 位")
	testing.expect_value(t, series_geom_label(3328, 4096, 12), "3328×4096 · 12 位")
	testing.expect_value(t, series_geom_label(0, 0, 0), "")

	testing.expect_value(t, series_cursor_text(35, 172), "36/172")
	testing.expect_value(t, series_cursor_text(0, 1), "1/1")
	testing.expect_value(t, series_cursor_text(0, 0), "")

	testing.expect_value(t, series_progress(0, 172), f32(0))
	testing.expect_value(t, series_progress(171, 172), f32(1))
}

// sidebar_build_rows keeps frame rows pointer-thin: a 690-frame series
// must not allocate a label for every frame, and every frame row carries
// the entry index the cursor update and selection need.
@(test)
sidebar_build_rows_defers_frame_labels :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", "nautilus_sidebar_rows", tmp)
	if derr != nil do testing.fail_now(t, "cannot make temp dir")
	defer os.remove_all(dir)

	for i in 0 ..< 5 {
		write_synth(t, dir, fmt.tprintf("img_%d.dcm", i), synth_dicom_series(i + 1, "1.2.3", "1.2.3.1", "SERIES ONE", "P1", "DOE^JANE"))
	}

	tree := scan_directory(dir, allocator = context.allocator)
	defer study_tree_destroy(&tree)
	if len(tree.studies) != 1 || len(tree.studies[0].series) != 1 {
		testing.fail_now(t, "expected one series")
	}

	expanded := make(map[Series_Key]bool)
	defer delete(expanded)
	key := Series_Key{study = 0, series = 0}
	expanded[key] = true

	rows := sidebar_build_rows(&tree, &expanded)
	defer sidebar_destroy_rows(rows)

	// patient + study + series + 5 frames
	testing.expect_value(t, len(rows), 8)
	testing.expect_value(t, rows[0].kind, Sidebar_Row_Kind.Patient)
	testing.expect_value(t, rows[1].kind, Sidebar_Row_Kind.Study)
	testing.expect_value(t, rows[2].kind, Sidebar_Row_Kind.Series)
	testing.expect(t, rows[2].expanded, "series row should report expansion")
	testing.expect(t, rows[0].label != "", "patient row needs a label")

	seen_entry: [5]bool
	seen_pos: [5]bool
	for r in rows[3:] {
		testing.expect_value(t, r.kind, Sidebar_Row_Kind.Frame)
		testing.expect_value(t, r.label, "")
		testing.expect(t, r.entry < u32(len(tree.entries)), "frame row entry out of range")
		pos := tree.entries[r.entry].pos
		testing.expect(t, pos >= 0 && pos < 5, "frame cursor out of range")
		testing.expect(t, !seen_pos[pos], "duplicate frame cursor")
		seen_pos[pos] = true
		seen_entry[r.entry] = true
	}
	for seen in seen_entry do testing.expect(t, seen, "frame row missing")
	for seen in seen_pos do testing.expect(t, seen, "frame cursor missing")
}

// Row identity must not ride on the list index: expanding an earlier
// series shifts every later row, and widget state (hover/press) has to
// follow the item, not the slot.
@(test)
sidebar_row_keys_stay_stable_across_expansion :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", "nautilus_sidebar_keys", tmp)
	if derr != nil do testing.fail_now(t, "cannot make temp dir")
	defer os.remove_all(dir)

	for i in 0 ..< 4 do write_synth(t, dir, fmt.tprintf("a_%d.dcm", i), synth_dicom_series(i + 1, "1.2.3", "1.2.3.1", "A", "P", "N"))
	for i in 0 ..< 2 do write_synth(t, dir, fmt.tprintf("b_%d.dcm", i), synth_dicom_series(i + 1, "1.2.3", "1.2.3.2", "B", "P", "N"))

	tree := scan_directory(dir, allocator = context.allocator)
	defer study_tree_destroy(&tree)

	expanded := make(map[Series_Key]bool)
	defer delete(expanded)
	rows_a := sidebar_build_rows(&tree, &expanded)
	key_b_before: u64
	for r in rows_a {
		if r.kind == .Series && r.series == 1 do key_b_before = sidebar_row_key(r)
	}
	sidebar_destroy_rows(rows_a)

	// Expand series 0: every row of series 1 moves down by 4.
	expanded[Series_Key{study = 0, series = 0}] = true
	rows_b := sidebar_build_rows(&tree, &expanded)
	defer sidebar_destroy_rows(rows_b)
	found := false
	for r in rows_b {
		if r.kind == .Series && r.series == 1 {
			found = true
			testing.expect_value(t, sidebar_row_key(r), key_b_before)
		}
	}
	testing.expect(t, found, "series 1 row missing after expansion")
}

@(test)
sidebar_mark_cursor_follows_shown_frame :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", "nautilus_sidebar_cursor", tmp)
	if derr != nil do testing.fail_now(t, "cannot make temp dir")
	defer os.remove_all(dir)

	for i in 0 ..< 20 do write_synth(t, dir, fmt.tprintf("img_%d.dcm", i), synth_dicom_series(i + 1, "1.2.3", "1.2.3.1", "S", "P", "N"))
	tree := scan_directory(dir, allocator = context.allocator)
	defer study_tree_destroy(&tree)

	ser := &tree.studies[0].series[0]
	mark_cursor(&tree, ser.frames[17])
	testing.expect_value(t, tree.studies[0].series[0].cursor, 17)

	mark_cursor(&tree, 10_000)
	testing.expect_value(t, tree.studies[0].series[0].cursor, 17)
}

// The new tree strings (patient, description, synthetic study) must be
// freed by study_tree_destroy like the old ones.
@(test)
sidebar_tree_metadata_is_allocator_balanced :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", "nautilus_sidebar_balanced", tmp)
	if derr != nil do testing.fail_now(t, "cannot make temp dir")
	defer os.remove_all(dir)

	write_synth(t, dir, "a.dcm", synth_dicom_series(1, "1.2.3", "1.2.3.1", "WATER AX", "P1", "DOE^JANE"))
	write_synth(t, dir, "b.dcm", synth_dicom_series(2, "", "5.5.5.1", "LEGACY", "", ""))

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	ta.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	own := context.allocator
	context.allocator = mem.tracking_allocator(&ta)
	tree := scan_directory(dir)
	study_tree_destroy(&tree)
	context.allocator = own

	if len(ta.bad_free_array) != 0 {
		testing.expectf(t, false, "scan produced %d bad frees, first at %v",
			len(ta.bad_free_array), ta.bad_free_array[0].location)
	}
	testing.expectf(t, ta.current_memory_allocated == 0,
		"tree leaked %d bytes", ta.current_memory_allocated)
	mem.tracking_allocator_destroy(&ta)
}

@(private)
Alloc_Counter :: struct {
	inner: runtime.Allocator,
	count: ^int,
}

@(private)
alloc_counter_proc :: proc(
	data:        rawptr,
	mode:        runtime.Allocator_Mode,
	size, alignment: int,
	old_memory:  rawptr,
	old_size:    int,
	location:    runtime.Source_Code_Location = #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	c := cast(^Alloc_Counter)data
	if mode == .Alloc do c.count^ += 1
	return c.inner.procedure(c.inner.data, mode, size, alignment, old_memory, old_size, location)
}

// Expanding a 200-frame series must not allocate per frame: the card
// labels are header-only and frame rows format at draw time. A regression
// that reintroduces per-frame labels shows up as 200+ allocations here.
@(test)
sidebar_expanding_large_series_allocates_only_headers :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", "nautilus_sidebar_alloc", tmp)
	if derr != nil do testing.fail_now(t, "cannot make temp dir")
	defer os.remove_all(dir)

	for i in 0 ..< 200 {
		write_synth(t, dir, fmt.tprintf("img_%03d.dcm", i),
			synth_dicom_series(i + 1, "1.2.3", "1.2.3.1", "SERIES ONE", "P1", "DOE^JANE"))
	}
	tree := scan_directory(dir, allocator = context.allocator)
	defer study_tree_destroy(&tree)

	expanded := make(map[Series_Key]bool)
	defer delete(expanded)
	expanded[Series_Key{study = 0, series = 0}] = true

	n := 0
	counter := Alloc_Counter{inner = context.allocator, count = &n}
	allocator := runtime.Allocator{procedure = alloc_counter_proc, data = &counter}
	rows := sidebar_build_rows(&tree, &expanded, allocator)
	defer sidebar_destroy_rows(rows)

	testing.expect_value(t, len(rows), 203)
	frames := 0
	for r in rows do if r.kind == .Frame do frames += 1
	testing.expect_value(t, frames, 200)
	testing.expectf(t, n < 40, "expanding 200 frames took %d allocations", n)
}

// A path tail must never cut a multi-byte character in half: the status
// bar and the frame rows render the result directly, and a mid-sequence
// byte shows up as mojibake.
@(test)
sidebar_short_name_is_rune_safe :: proc(t: ^testing.T) {
	// 15 CJK runes (45 B) + ".dicom": the old 46-byte cut lands inside
	// the third rune, which is exactly the mojibake case.
	name := fmt.tprintf("%s.dicom", strings.repeat("乳", 15))
	got := short_name(fmt.tprintf("/tmp/%s", name))
	testing.expect(t, utf8.valid_string(got), "short_name split a UTF-8 sequence")
	testing.expectf(t, strings.has_suffix(name, got), "short_name lost the tail: %q", got)
}

// Frame rows show the file name's beginning and let the layout elide the
// end; cutting the tail at scan time hides the part that identifies it.
@(test)
sidebar_base_name_keeps_the_whole_name :: proc(t: ^testing.T) {
	name := fmt.tprintf("%s.dcm", strings.repeat("检", 30))
	testing.expect_value(t, base_name(fmt.tprintf("/a/b/%s", name)), name)
	testing.expect_value(t, base_name("no_slash.dcm"), "no_slash.dcm")
}

// Elision only runs for single-line text with max_width == 0 inside a
// width-constrained cell. Setting max_width turns the label into a
// wrapped paragraph, which is what made long names overlap.
@(test)
sidebar_clipped_label_elides_in_a_fixed_cell :: proc(t: ^testing.T) {
	view := clipped_label("a_very_long_file_name_that_will_not_fit.dcm", rl.Color{}, 11, 120)
	stack := view.(rl.View_Stack)
	testing.expect_value(t, stack.width, f32(120))
	if len(stack.children) != 1 do testing.fail_now(t, "expected one child")
	text := stack.children[0].(rl.View_Text)
	testing.expect_value(t, text.max_width, f32(0))
	testing.expect_value(t, text.overflow, rl.Text_Overflow.Ellipsis)
}

// Chinese patient names and series descriptions arrive in GB18030 far more
// often than in UTF-8, and some PACS write GBK bytes without declaring
// (0008,0005) at all. Both must render as valid UTF-8, not mojibake.
@(private)
synth_chinese_series :: proc(patient_gbk, description_gbk: []u8, declare_charset: bool) -> []u8 {
	w: Synth_Writer
	w.buf = make([dynamic]u8, 0, 512, context.temp_allocator)
	if declare_charset do synth_str(&w, 0x0008, 0x0005, "CS", "GB18030")
	synth_str(&w, 0x0008, 0x0020, "DA", "20240101")
	synth_bytes(&w, 0x0008, 0x103E, "LO", description_gbk) // 乳腺
	synth_bytes(&w, 0x0010, 0x0010, "PN", patient_gbk) // 李春
	synth_str(&w, 0x0020, 0x000D, "UI", "1.2.3")
	synth_str(&w, 0x0020, 0x000E, "UI", "1.2.3.1")
	synth_str(&w, 0x0020, 0x0013, "IS", "1")
	synth_us(&w, 0x0028, 0x0010, 2)
	synth_us(&w, 0x0028, 0x0011, 2)
	synth_us(&w, 0x0028, 0x0100, 16)
	pix := make([]u8, 8, context.temp_allocator)
	synth_bytes(&w, 0x7FE0, 0x0010, "OB", pix[:])
	return w.buf[:]
}

@(private)
scan_chinese_fixture :: proc(t: ^testing.T, tag: string, declare_charset: bool) -> Study_Tree {
	dir, derr := os.make_directory_temp("", tag, context.temp_allocator)
	if derr != nil do testing.fail_now(t, "cannot make temp dir")
	defer os.remove_all(dir)
	patient := []u8{0xC0, 0xEE, 0xB4, 0xBA} // 李春 (GBK)
	description := []u8{0xC8, 0xE9, 0xCF, 0xD9} // 乳腺 (GBK)
	write_synth(t, dir, "a.dcm", synth_chinese_series(patient, description, declare_charset))
	return scan_directory(dir, allocator = context.allocator)
}

@(test)
sidebar_decodes_declared_gb18030_names :: proc(t: ^testing.T) {
	tree := scan_chinese_fixture(t, "nautilus_gb18030", true)
	defer study_tree_destroy(&tree)
	testing.expect_value(t, len(tree.patients), 1)
	if len(tree.patients) != 1 do return
	testing.expect_value(t, tree.patients[0].name, "李春")
	testing.expect(t, utf8.valid_string(tree.patients[0].name), "patient name is not UTF-8")
	testing.expect_value(t, tree.studies[0].series[0].description, "乳腺")
}

@(test)
sidebar_decodes_undeclared_gbk_names :: proc(t: ^testing.T) {
	tree := scan_chinese_fixture(t, "nautilus_gbk_nodecl", false)
	defer study_tree_destroy(&tree)
	testing.expect_value(t, len(tree.patients), 1)
	if len(tree.patients) != 1 do return
	testing.expect_value(t, tree.patients[0].name, "李春")
	testing.expect(t, utf8.valid_string(tree.patients[0].name), "patient name is not UTF-8")
}
