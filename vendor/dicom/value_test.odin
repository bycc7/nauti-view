package dicom

import "core:mem"
import "core:testing"

add_text_elem :: proc (buf: ^[dynamic]u8, tag: Tag, vr_tag: string, value: string, order: Byte_Order) {
	put_tag(buf, tag, order)
	append(buf, vr_tag[0], vr_tag[1])
	put_u16(buf, u16(len(value)), order)
	append(buf, value)
}

// Chooses the 8-byte or 12-byte element header from the VR itself, like a real writer does.
add_binary_elem :: proc (buf: ^[dynamic]u8, tag: Tag, vr_tag: string, value: []u8, order: Byte_Order) {
	put_tag(buf, tag, order)
	append(buf, vr_tag[0], vr_tag[1])
	vr, _ := vr_from_bytes(transmute([]u8)string(vr_tag))
	if vr_has_explicit_32bit_length(vr) {
		put_u16(buf, 0, order)
		put_u32(buf, u32(len(value)), order)
	} else {
		put_u16(buf, u16(len(value)), order)
	}
	append(buf, ..value)
}

// Explicit VR LE with one element of each interesting VR.
build_values_file :: proc (order: Byte_Order = .Little) -> [dynamic]u8 {
	uid := "1.2.840.10008.1.2.1" if order == .Little else "1.2.840.10008.1.2.2"
	buf := init_dicom_preamble(uid)

	// (0010,0010) PN "Doe^John^Q" (10, even)
	add_text_elem(&buf, Tag{0x0010, 0x0010}, "PN", "Doe^John^Q", order)
	// (0010,0020) LO "ABC " (padded, will be trimmed)
	add_text_elem(&buf, Tag{0x0010, 0x0020}, "LO", "ABC ", order)
	// (0008,0008) CS multi-valued "ORIGINAL\\PRIMARY"
	add_text_elem(&buf, Tag{0x0008, 0x0008}, "CS", "ORIGINAL\\PRIMARY", order)
	// (0018,0060) DS "1.5\\2.25 "
	add_text_elem(&buf, Tag{0x0018, 0x0060}, "DS", "1.5\\2.25 ", order)
	// (0020,0013) IS "42 "
	add_text_elem(&buf, Tag{0x0020, 0x0013}, "IS", "42 ", order)

	// (0028,0010) US 512
	us: [2]u8
	us[0] = 0x00 if order == .Little else 0x02
	us[1] = 0x02 if order == .Little else 0x00
	add_binary_elem(&buf, Tag{0x0028, 0x0010}, "US", us[:], order)

	// (0028,1052) DS "-1024.5" (10, even)
	add_text_elem(&buf, Tag{0x0028, 0x1052}, "DS", "-1024.5 ", order)

	// (0028,0103) US 0
	us0: [2]u8
	add_binary_elem(&buf, Tag{0x0028, 0x0103}, "US", us0[:], order)

	// (0028,0106) SS -3 (3 values: -1, -2, -3)
	ss: [6]u8
	v := i16(-1)
	for k in 0 ..< 3 {
		x := v - i16(k)
		b := transmute(u16)x
		if order == .Little {
			ss[k * 2 + 0] = u8(b & 0xFF)
			ss[k * 2 + 1] = u8(b >> 8)
		} else {
			ss[k * 2 + 0] = u8(b >> 8)
			ss[k * 2 + 1] = u8(b & 0xFF)
		}
	}
	add_binary_elem(&buf, Tag{0x0028, 0x0106}, "SS", ss[:], order)

	// (0028,1051) FD 2.5
	fd: [8]u8
	bits := transmute(u64)f64(2.5)
	for k in 0 ..< 8 {
		shift := u32(k * 8) if order == .Little else u32((7 - k) * 8)
		fd[k] = u8(bits >> shift)
	}
	add_binary_elem(&buf, Tag{0x0028, 0x1051}, "FD", fd[:], order)

	// (0020,9161) UI "1.2.3\x00" (6, even)
	add_text_elem(&buf, Tag{0x0020, 0x9161}, "UI", "1.2.3\x00", order)
	return buf
}

parse_doc :: proc (t: ^testing.T, buf: []u8) -> (doc: ^Document, ok: bool) {
	doc = new(Document)
	document_init(doc)
	err := document_parse_buffer(doc, buf)
	testing.expect_value(t, err, Parse_Error.None)
	return doc, err == .None
}

@(test)
test_value_numeric_scalars :: proc (t: ^testing.T) {
	orders := [2]Byte_Order{.Little, .Big}
	for order in orders {
		buf := build_values_file(order)
		doc, ok := parse_doc(t, buf[:])
		testing.expect(t, ok)
		if !ok do continue

		us, _ := document_find(doc, Tag{0x0028, 0x0010})
		x, xok := value_u64(doc, us)
		testing.expect(t, xok)
		testing.expect_value(t, x, u64(512))

		ss, _ := document_find(doc, Tag{0x0028, 0x0106})
		testing.expect_value(t, value_count(doc, ss), 3)
		for k in 0 ..< 3 {
			want := i64(-1 - i64(k)) if order == .Little else i64(-1 - i64(k))
			got, gok := value_i64(doc, ss, k)
			testing.expect(t, gok)
			testing.expect_value(t, got, want)
		}
		// Out of range index must fail, not read past the value.
		_, oor := value_i64(doc, ss, 3)
		testing.expect(t, !oor)

		fdv, _ := document_find(doc, Tag{0x0028, 0x1051})
		f, fok := value_f64(doc, fdv)
		testing.expect(t, fok)
		testing.expect_value(t, f, f64(2.5))

		document_destroy(doc)
		free(doc)
		delete(buf)
	}
}

@(test)
test_value_text_padding_and_split :: proc (t: ^testing.T) {
	buf := build_values_file()
	defer delete(buf)
	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)

	lo, _ := document_find(doc, Tag{0x0010, 0x0020})
	testing.expect_value(t, value_text(doc, lo), "ABC") // trailing space stripped
	testing.expect_value(t, value_count(doc, lo), 1)

	cs, _ := document_find(doc, Tag{0x0008, 0x0008})
	out: [8]string
	n := value_split(doc, cs, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0], "ORIGINAL")
	testing.expect_value(t, out[1], "PRIMARY")

	// A buffer smaller than the value count still reports the real count.
	small: [1]string
	testing.expect_value(t, value_split(doc, cs, small[:]), 2)
	testing.expect_value(t, small[0], "ORIGINAL")

	ui, _ := document_find(doc, Tag{0x0020, 0x9161})
	testing.expect_value(t, value_text(doc, ui), "1.2.3")
}

@(test)
test_value_ds_is_numbers :: proc (t: ^testing.T) {
	buf := build_values_file()
	defer delete(buf)
	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)

	ds, _ := document_find(doc, Tag{0x0018, 0x0060})
	d0, ok0 := value_ds(doc, ds, 0)
	d1, ok1 := value_ds(doc, ds, 1)
	testing.expect(t, ok0 && ok1)
	testing.expect_value(t, d0, f64(1.5))
	testing.expect_value(t, d1, f64(2.25))
	_, bad := value_ds(doc, ds, 5)
	testing.expect(t, !bad)

	is, _ := document_find(doc, Tag{0x0020, 0x0013})
	i0, iok := value_is(doc, is)
	testing.expect(t, iok)
	testing.expect_value(t, i0, 42)

	// DS is a textual VR: value_count counts backslash-separated values.
	testing.expect_value(t, value_count(doc, ds), 2)
}

@(test)
test_value_pn_components :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0010, 0x0010}, "PN", "Doe^John^Quincy=Ideo^Graphic", .Little)

	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)

	pn, pok := value_pn(doc, document_root(doc)[0])
	testing.expect(t, pok)
	testing.expect_value(t, pn.alphabetic[0], "Doe")
	testing.expect_value(t, pn.alphabetic[1], "John")
	testing.expect_value(t, pn.alphabetic[2], "Quincy")
	testing.expect_value(t, pn.ideographic[0], "Ideo")
	testing.expect_value(t, pn.ideographic[1], "Graphic")
	testing.expect_value(t, pn.phonetic[0], "")
}

@(test)
test_value_bulk_decode :: proc (t: ^testing.T) {
	buf := build_values_file()
	defer delete(buf)
	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)

	ss, _ := document_find(doc, Tag{0x0028, 0x0106})
	dst: [8]i64
	n := decode_integers(doc, ss, dst[:])
	testing.expect_value(t, n, 3)
	testing.expect_value(t, dst[0], i64(-1))
	testing.expect_value(t, dst[2], i64(-3))

	// Too small a destination returns 0 rather than a partial decode.
	tiny: [1]i64
	testing.expect_value(t, decode_integers(doc, ss, tiny[:]), 0)

	// FD is not an integer VR.
	fdv, _ := document_find(doc, Tag{0x0028, 0x1051})
	testing.expect_value(t, decode_integers(doc, fdv, dst[:]), 0)
	fl: [4]f64
	testing.expect_value(t, decode_floats(doc, fdv, fl[:]), 1)
	testing.expect_value(t, fl[0], f64(2.5))
}

@(test)
test_value_charset_transcoding :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0008, 0x0005}, "CS", "ISO_IR 100", .Little)
	// Latin-1 0xE9 is "é"
	add_text_elem(&buf, Tag{0x0010, 0x0020}, "LO", "caf\xE9 ", .Little)

	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)
	testing.expect_value(t, document_charset(doc), Charset.Latin1)

	lo, _ := document_find(doc, Tag{0x0010, 0x0020})
	out: [32]u8
	n := text_to_utf8(doc, lo, out[:])
	testing.expect_value(t, n, 5) // c a f + 2-byte é
	testing.expect_value(t, string(out[:n]), "caf\xC3\xA9")

	// A destination that is too small must fail instead of truncating mid-sequence.
	tiny: [4]u8
	testing.expect_value(t, text_to_utf8(doc, lo, tiny[:]), -1)

	testing.expect_value(t, charset_from_term("ISO_IR 192"), Charset.Utf8)
	testing.expect_value(t, charset_from_term("ISO_IR 6"), Charset.Ascii)
	testing.expect_value(t, charset_from_term(""), Charset.Ascii)
	testing.expect_value(t, charset_from_term("GB18030"), Charset.Gb18030)
	// Extension form: first term wins.
	testing.expect_value(t, charset_from_term("\\ISO 2022 IR 100"), Charset.Latin1)
}

// C7: decoding must not allocate. 100 rounds over every element of a non-trivial document.
@(test)
test_value_zero_alloc :: proc (t: ^testing.T) {
	buf := build_values_file()
	defer delete(buf)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	outer := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = outer

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)

	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	baseline := len(track.allocation_map)

	out: [8]string
	utf8_buf: [64]u8
	for _ in 0 ..< 100 {
		for e in document_root(&doc) {
			_ = value_count(&doc, e)
			_ = value_text(&doc, e)
			_ = value_split(&doc, e, out[:])
			_, _ = value_u64(&doc, e)
			_, _ = value_i64(&doc, e)
			_, _ = value_f64(&doc, e)
			_, _ = value_ds(&doc, e)
			_, _ = value_is(&doc, e)
			_, _ = value_pn(&doc, e)
			_ = text_to_utf8(&doc, e, utf8_buf[:])
		}
	}
	testing.expect_value(t, len(track.allocation_map), baseline)
}
