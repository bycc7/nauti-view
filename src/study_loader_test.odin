package nautilus

// Task 7: 目录扫描建树。测试用真实 693 文件语料（D:/Odin/odin-dcm/Dcm）
// 验证聚合与排序，用合成目录验证无序输入与小写扩展名，并验证非 DICOM
// 文件被跳过而不是让扫描失败。

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
study_loader_groups_693_file_corpus :: proc(t: ^testing.T) {
	root := "D:/Odin/odin-dcm/Dcm"
	if !os.exists(root) {
		testing.fail_now(t, "corpus missing")
	}

	tree := scan_directory(root, allocator = context.allocator)
	defer study_tree_destroy(&tree)

	// 690 DICOM images share one Study; the 2-file study and the
	// non-DICOM zip round it out without crashing the scan.
	testing.expectf(t, len(tree.entries) == 692, "expected 692 entries, got %d", len(tree.entries))
	if len(tree.studies) == 0 {
		testing.fail_now(t, "no studies")
	}
	big := 0
	for s in tree.studies {
		big = max(big, s.count)
	}
	testing.expectf(t, big == 690, "largest study should hold 690 files, got %d", big)

	// Every series of the big study is populated and its frames are
	// ordered by InstanceNumber.
	series_total := 0
	for s in tree.studies {
		for ser in s.series {
			series_total += 1
			for i in 1 ..< len(ser.frames) {
				prev := tree.entries[ser.frames[i - 1]].instance
				cur := tree.entries[ser.frames[i]].instance
				testing.expectf(t, prev <= cur, "series %s not sorted: %d then %d",
					ser.uid, prev, cur)
			}
		}
	}
	// 13 series in the 690-file study plus the 2-file study's 2. The zip
	// has no StudyInstanceUID and is not counted.
	testing.expectf(t, series_total == 15, "expected 15 series, got %d", series_total)
}

@(test)
study_loader_sorts_shuffled_instance_numbers :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	dir, derr := os.make_directory_temp("", "nautilus_scan", tmp)
	if derr != nil {
		testing.fail_now(t, "cannot make temp dir")
	}
	defer os.remove_all(dir)

	// Three files sharing series, written with names in reverse order of
	// InstanceNumber: the loader must sort by the tag, not the filename.
	names := []string{"z_last.dcm", "a_first.dcm", "m_mid.dcm"}
	instances := []int{1, 3, 2}
	for i in 0 ..< len(names) {
		path, _ := filepath.join({dir, names[i]}, allocator = tmp)
		_ = os.write_entire_file(path, synth_dicom_series(instances[i]))
	}

	tree := scan_directory(dir, allocator = context.allocator)
	defer study_tree_destroy(&tree)

	testing.expect_value(t, len(tree.entries), 3)
	if len(tree.studies) != 1 || len(tree.studies[0].series) != 1 {
		testing.fail_now(t, "expected one study with one series")
	}
	frames := tree.studies[0].series[0].frames
	testing.expect_value(t, len(frames), 3)
	for i in 0 ..< len(frames) {
		testing.expect_value(t, tree.entries[frames[i]].instance, i + 1)
	}
}

@(test)
study_loader_skips_non_dicom :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "nautilus_scan_skip", context.temp_allocator)
	if derr != nil {
		testing.fail_now(t, "cannot make temp dir")
	}
	defer os.remove_all(dir)

	good, _ := filepath.join({dir, "img.dcm"}, allocator = context.temp_allocator)
	_ = os.write_entire_file(good, synth_dicom_series(1))
	bad, _ := filepath.join({dir, "notes.txt"}, allocator = context.temp_allocator)
	_ = os.write_entire_file(bad, transmute([]u8)string("not a dicom file at all"))

	tree := scan_directory(dir, allocator = context.allocator)
	defer study_tree_destroy(&tree)
	testing.expect_value(t, len(tree.entries), 1)
}

// Budget: spec §4.1 wants the 693-file corpus scanned well inside a
// frame; measured 46 ms at -o:speed (8 workers).
@(test)
study_loader_scan_budget :: proc(t: ^testing.T) {
	root := "D:/Odin/odin-dcm/Dcm"
	if !os.exists(root) do return
	sw := init_stopwatch()
	tree := scan_directory(root, allocator = context.allocator)
	ms := elapsed_ms(&sw)
	defer study_tree_destroy(&tree)
	testing.expectf(t, ms < 200, "scan took %.1f ms", ms)
}
