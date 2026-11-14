package dicom

import "core:testing"

@(private)
render_info :: proc (rows, cols, samples, bits: int) -> Pixel_Info {
	return Pixel_Info{rows = rows, cols = cols, samples = samples, frames = 1,
		bits_allocated = bits, bits_stored = bits, high_bit = bits - 1,
		bytes_per_sample = bits / 8, frame_bytes = rows * cols * samples * (bits / 8), native = true}
}

@(test)
test_render_gray8_window :: proc (t: ^testing.T) {
	values := [4]u16{0, 33, 66, 100}
	src: [8]u8
	for v, i in values {
		src[i * 2] = u8(v)
		src[i * 2 + 1] = u8(v >> 8)
	}
	dst: [4]u8
	ok := render_gray8(render_info(1, 4, 1, 16), src[:], dst[:], Render_Options{center = 50, width = 100, valid_window = true})
	testing.expect(t, ok)
	testing.expect(t, dst == [4]u8{0, 85, 170, 255})
}

@(test)
test_render_gray8_minmax_stretch :: proc (t: ^testing.T) {
	values := [4]u16{0, 33, 66, 100}
	src: [8]u8
	for v, i in values {
		src[i * 2] = u8(v)
		src[i * 2 + 1] = u8(v >> 8)
	}
	dst: [4]u8
	ok := render_gray8(render_info(1, 4, 1, 16), src[:], dst[:], Render_Options{})
	testing.expect(t, ok)
	testing.expect(t, dst == [4]u8{1, 85, 170, 255})
}

@(test)
test_render_gray8_bits_stored_sign_and_invert :: proc (t: ^testing.T) {
	// 12 bits stored in 16: 0x0FFF is -1 as a signed 12-bit sample.
	src := [2]u8{0xFF, 0x0F}
	dst: [1]u8
	info := render_info(1, 1, 1, 16)
	info.bits_stored = 12
	info.high_bit = 11
	info.signed = true
	opts := Render_Options{center = 0, width = 4096, valid_window = true}
	testing.expect(t, render_gray8(info, src[:], dst[:], opts))
	testing.expect_value(t, dst[0], u8(127))

	opts.invert = true
	testing.expect(t, render_gray8(info, src[:], dst[:], opts))
	testing.expect_value(t, dst[0], u8(128))
}

@(test)
test_render_gray8_rescale :: proc (t: ^testing.T) {
	// Stored 0..3, slope 2, intercept -4 -> -4..2, window C=-1 W=6.
	values := [4]u16{0, 1, 2, 3}
	src: [8]u8
	for v, i in values {
		src[i * 2] = u8(v)
		src[i * 2 + 1] = u8(v >> 8)
	}
	dst: [4]u8
	ok := render_gray8(render_info(1, 4, 1, 16), src[:], dst[:],
		Render_Options{center = -1, width = 6, valid_window = true, slope = 2, intercept = -4})
	testing.expect(t, ok)
	// v: -4,-2,0,2 -> y: 0 ; 0.4*255=102 ; 0.8*255=204 ; clamped 255
	testing.expect(t, dst == [4]u8{0, 102, 204, 255})
}

@(test)
test_render_rgb8_passthrough :: proc (t: ^testing.T) {
	src := [6]u8{1, 2, 3, 4, 5, 6}
	dst: [6]u8
	testing.expect(t, render_rgb8(render_info(1, 2, 3, 8), src[:], dst[:], Render_Options{}))
	testing.expect(t, dst == src)
}

@(test)
test_render_ybr422_expand_neutral_chroma :: proc (t: ^testing.T) {
	// Y0=100 Y1=100, Cb=Cr=128 -> both pixels are (100,100,100).
	src := [4]u8{100, 100, 128, 128}
	dst: [6]u8
	testing.expect(t, render_expand_ybr422(src[:], dst[:], 2))
	testing.expect(t, dst == [6]u8{100, 100, 100, 100, 100, 100})
}

@(test)
test_render_palette_lut :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	desc: [6]u8 // US, 3 values: 4 entries, first mapped value 0, 8 bits per entry
	desc[0] = 4 // entries
	desc[4] = 8 // bits per entry
	add_binary_elem(&buf, Tag{0x0028, 0x1101}, "US", desc[:], .Little)
	add_binary_elem(&buf, Tag{0x0028, 0x1102}, "US", desc[:], .Little)
	add_binary_elem(&buf, Tag{0x0028, 0x1103}, "US", desc[:], .Little)
	add_binary_elem(&buf, Tag{0x0028, 0x1201}, "OW", []u8{10, 20, 30, 40}, .Little)
	add_binary_elem(&buf, Tag{0x0028, 0x1202}, "OW", []u8{11, 21, 31, 41}, .Little)
	add_binary_elem(&buf, Tag{0x0028, 0x1203}, "OW", []u8{12, 22, 32, 42}, .Little)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)

	p := palette_lut(&doc)
	testing.expect(t, p.valid)
	testing.expect_value(t, p.entries, 4)
	testing.expect_value(t, p.entry_bytes, 1)
	testing.expect_value(t, len(p.red), 4)

	dst: [6]u8
	testing.expect(t, render_palette8(p, []u8{2, 0}, dst[:], 2))
	testing.expect(t, dst == [6]u8{30, 31, 32, 10, 11, 12})
}

@(test)
test_render_dataset_window :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0028, 0x1050}, "DS", "50 ", .Little)
	add_text_elem(&buf, Tag{0x0028, 0x1051}, "DS", "100 ", .Little)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	c, w, ok := dataset_window(&doc)
	testing.expect(t, ok)
	testing.expect_value(t, c, f64(50))
	testing.expect_value(t, w, f64(100))
}
