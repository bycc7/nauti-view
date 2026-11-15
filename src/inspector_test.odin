package nautilus

// Task 10 (M3) tests:
//   (a) 坐标正逆变换 roundtrip + 长度/角度测量（mm / Imager mm / px 诚实标注）
//   (b) Tag 静态关键字表 + Tag 行提取 + 搜索过滤（Tag 号 / Keyword / 值）
//   (c) corpus_ext 163 文件（含无 Preamble 裸数据集）全量诊断回归 0 崩溃

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import d "../vendor/dicom"
import rl "../vendor/skald"

@(test)
viewport_transform_roundtrip_all_orientations :: proc(t: ^testing.T) {
	bounds := rl.Rect{x = 40, y = 20, w = 800, h = 600}
	for rot in 0 ..< 4 {
		for fh in ([2]bool{false, true}) {
			for fv in ([2]bool{false, true}) {
				vp := Viewport_Window{
					img_w  = 512,
					img_h  = 384,
					zoom   = 1.75,
					pan    = {32, -18},
					rotate = rot,
					flip_h = fh,
					flip_v = fv,
				}
				samples := [][2]int{{0, 0}, {255, 192}, {511, 383}, {120, 300}}
				for pt in samples {
					c := image_point_to_canvas(&vp, bounds, {f32(pt.x) + 0.5, f32(pt.y) + 0.5})
					ix, iy, ok := canvas_point_to_image(&vp, bounds, c)
					testing.expectf(t, ok, "rot=%d fh=%v fv=%v pt=%v mapped outside", rot, fh, fv, pt)
					testing.expect_value(t, ix, pt.x)
					testing.expect_value(t, iy, pt.y)
				}
			}
		}
	}
}

@(test)
measurement_distance_and_angle_honest_units :: proc(t: ^testing.T) {
	// 1. Calibrated PixelSpacing [row_mm=0.5, col_mm=0.5]: 3-4-5 triangle (60 px, 80 px) = 50.0 mm
	val_mm, unit_mm := measure_distance({10, 10}, {70, 90}, {0.5, 0.5}, .Pixel_Spacing)
	testing.expect(t, math.abs(val_mm - 50.0) < 1e-4)
	testing.expect_value(t, unit_mm, "mm")

	// 2. ImagerPixelSpacing only: honest "(Imager)" suffix
	val_im, unit_im := measure_distance({0, 0}, {100, 0}, {0.2, 0.2}, .Imager_Spacing)
	testing.expect(t, math.abs(val_im - 20.0) < 1e-4)
	testing.expect_value(t, unit_im, "mm (Imager)")

	// 3. No spacing: honest "px"
	val_px, unit_px := measure_distance({0, 0}, {3, 4}, {0, 0}, .None)
	testing.expect(t, math.abs(val_px - 5.0) < 1e-4)
	testing.expect_value(t, unit_px, "px")

	// 4. Right angle (90 deg)
	deg := measure_angle_deg({10, 0}, {0, 0}, {0, 10})
	testing.expect(t, math.abs(deg - 90.0) < 1e-3)
}

@(test)
tag_keywords_and_search_filter :: proc(t: ^testing.T) {
	testing.expect_value(t, tag_keyword(d.Tag{0x0010, 0x0010}), "PatientName")
	testing.expect_value(t, tag_keyword(d.Tag{0x0028, 0x1050}), "WindowCenter")
	testing.expect_value(t, tag_keyword(d.Tag{0x7FE0, 0x0010}), "PixelData")

	buf := synth_dicom_series(7, "1.2.840.1", "1.2.840.2")
	doc: d.Document
	d.document_init(&doc)
	defer d.document_destroy(&doc)
	testing.expect_value(t, d.document_parse_buffer(&doc, buf), d.Parse_Error.None)

	rows := extract_tag_rows(&doc, context.temp_allocator)
	testing.expect(t, len(rows) >= 8)

	// Filter by tag hex, keyword, and value.
	by_tag := filter_tag_rows(rows, "0020,0013", context.temp_allocator)
	testing.expect_value(t, len(by_tag), 1)
	testing.expect_value(t, rows[by_tag[0]].keyword, "InstanceNumber")

	by_kw := filter_tag_rows(rows, "Modality", context.temp_allocator)
	testing.expect_value(t, len(by_kw), 1)
	testing.expect_value(t, rows[by_kw[0]].value, "CT")

	by_val := filter_tag_rows(rows, "MONOCHROME2", context.temp_allocator)
	testing.expect_value(t, len(by_val), 1)
}

@(test)
corpus_ext_163_files_diagnostic_regression :: proc(t: ^testing.T) {
	dir := "D:/Odin/corpus_ext"
	if !os.exists(dir) do return

	fis, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	testing.expect(t, err == nil)

	total := 0
	decoded_ok := 0
	preamble_less_ok := 0
	for fi in fis {
		if fi.type != .Regular do continue
		if !strings.has_suffix(strings.to_lower(fi.name, context.temp_allocator), ".dcm") do continue
		full, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		total += 1
		diag := inspect_file_diagnostic(full, context.temp_allocator)
		if diag.decode_ok do decoded_ok += 1
		if !diag.has_preamble && diag.open_err == .None do preamble_less_ok += 1
	}
	testing.expect_value(t, total, 163)
	testing.expectf(t, decoded_ok >= 120, "expected >=120 decoded in corpus_ext, got %d", decoded_ok)
	testing.expectf(t, preamble_less_ok >= 5, "expected preamble-less files to parse, got %d", preamble_less_ok)
}

// The tag table renders patient/series text directly: a GB18030 value
// must arrive as UTF-8, and the display truncation must not split a rune.
@(test)
inspector_decodes_gb18030_tag_values :: proc(t: ^testing.T) {
	patient := []u8{0xC0, 0xEE, 0xB4, 0xBA} // 李春 (GBK)
	buf := synth_chinese_series(patient, []u8{0xC8, 0xE9, 0xCF, 0xD9}, true)
	doc: d.Document
	d.document_init(&doc)
	defer d.document_destroy(&doc)
	testing.expect_value(t, d.document_parse_buffer(&doc, buf), d.Parse_Error.None)

	rows := extract_tag_rows(&doc, context.temp_allocator)
	for row in rows {
		if row.keyword != "PatientName" do continue
		testing.expect_value(t, row.value, "李春")
		return
	}
	testing.expect(t, false, "PatientName row missing")
}
