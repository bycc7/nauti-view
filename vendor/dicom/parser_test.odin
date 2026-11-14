package dicom

import "core:encoding/endian"
import "core:testing"

Test_Stats :: struct {
	elements:  int,
	sequences: int,
	items:     int,
	fragments: int,
	max_depth: int,
	last_tag:  Tag,
	last_vr:   VR,
	last_len:  u32,
}

stats_handler :: proc(s: ^Test_Stats) -> Handler {
	return Handler{
		user = s,
		on_event = proc(ev: Event, user: rawptr) {
			s := (^Test_Stats)(user)
			if ev.depth > s.max_depth do s.max_depth = ev.depth
			#partial switch ev.kind {
			case .Element:
				s.elements += 1
				s.last_tag = ev.tag
				s.last_vr  = ev.vr
				s.last_len = ev.length
			case .Sequence_Begin:
				s.sequences += 1
			case .Item_Begin:
				s.items += 1
			case .Fragment:
				s.fragments += 1
			}
		},
	}
}

put_u16 :: proc(buf: ^[dynamic]u8, v: u16, order: Byte_Order) {
	b: [2]u8
	endian.put_u16(b[:], order, v)
	append(buf, b[0], b[1])
}

put_u32 :: proc(buf: ^[dynamic]u8, v: u32, order: Byte_Order) {
	b: [4]u8
	endian.put_u32(b[:], order, v)
	append(buf, b[0], b[1], b[2], b[3])
}

put_tag :: proc(buf: ^[dynamic]u8, t: Tag, order: Byte_Order) {
	put_u16(buf, t.group, order)
	put_u16(buf, t.element, order)
}

init_dicom_preamble :: proc(ts_uid: string) -> [dynamic]u8 {
	buf := make([dynamic]u8, 128)
	append(&buf, "DICM")
	put_tag(&buf, TAG_TRANSFER_SYNTAX_UID, .Little)
	append(&buf, 'U', 'I')
	padded := len(ts_uid) + (len(ts_uid) & 1)
	put_u16(&buf, u16(padded), .Little)
	append(&buf, ts_uid)
	if (len(ts_uid) & 1) == 1 do append(&buf, 0)
	return buf
}

// 1. Regression test for A3.1: multiple undefined-length items must not accumulate depth.
@(test)
test_undefined_sequence_and_item_depth :: proc(t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)

	// (0008,1115) SQ, length = UNDEFINED
	put_tag(&buf, Tag{0x0008, 0x1115}, .Little)
	append(&buf, 'S', 'Q', 0, 0)
	put_u32(&buf, UNDEFINED_LENGTH, .Little)

	for _ in 0..<5 {
		put_tag(&buf, TAG_ITEM, .Little)
		put_u32(&buf, UNDEFINED_LENGTH, .Little)
		// (0010,0010) PN len=4 "DOE "
		put_tag(&buf, Tag{0x0010, 0x0010}, .Little)
		append(&buf, 'P', 'N')
		put_u16(&buf, 4, .Little)
		append(&buf, "DOE ")
		// (FFFE,E00D) Item Delimitation
		put_tag(&buf, TAG_ITEM_DELIMITATION, .Little)
		put_u32(&buf, 0, .Little)
	}
	// (FFFE,E0DD) Sequence Delimitation
	put_tag(&buf, TAG_SEQ_DELIMITATION, .Little)
	put_u32(&buf, 0, .Little)

	stats: Test_Stats
	c := Cursor{buf = buf[:]}
	meta, merr := parse_meta(&c, stats_handler(&stats))
	testing.expect_value(t, merr, Parse_Error.None)
	end_pos, _, berr := parse_body(buf[:], meta.data_offset, meta.ts, stats_handler(&stats))
	testing.expect_value(t, berr, Parse_Error.None)
	testing.expect_value(t, end_pos, len(buf))
	testing.expect_value(t, stats.items, 5)
	testing.expect_value(t, stats.max_depth, 1)
}

// 2. Regression test for A3.2: encapsulated PixelData fragments with arbitrary bytes.
@(test)
test_encapsulated_pixel_data_fragments :: proc(t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.4.90")
	defer delete(buf)

	// (7FE0,0010) OB, length = UNDEFINED
	put_tag(&buf, TAG_PIXEL_DATA, .Little)
	append(&buf, 'O', 'B', 0, 0)
	put_u32(&buf, UNDEFINED_LENGTH, .Little)
	// Fragment 0: empty BOT
	put_tag(&buf, TAG_ITEM, .Little)
	put_u32(&buf, 0, .Little)
	// Fragment 1: 4 raw bytes that are NOT valid Explicit VR
	put_tag(&buf, TAG_ITEM, .Little)
	put_u32(&buf, 4, .Little)
	append(&buf, 0xFF, 0x4F, 0xFF, 0x51)
	// Sequence Delimitation
	put_tag(&buf, TAG_SEQ_DELIMITATION, .Little)
	put_u32(&buf, 0, .Little)

	stats: Test_Stats
	c := Cursor{buf = buf[:]}
	meta, _ := parse_meta(&c, stats_handler(&stats))
	end_pos, _, err := parse_body(buf[:], meta.data_offset, meta.ts, stats_handler(&stats))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, end_pos, len(buf))
	testing.expect_value(t, stats.fragments, 2)
}

// 3. Contract C3: Explicit VR with VR=UN and UNDEFINED_LENGTH switches inner items to Implicit VR LE.
@(test)
test_un_undefined_length_switches_to_implicit_le :: proc(t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)

	// Private sequence (0009,1001) VR=UN, length=UNDEFINED
	put_tag(&buf, Tag{0x0009, 0x1001}, .Little)
	append(&buf, 'U', 'N', 0, 0)
	put_u32(&buf, UNDEFINED_LENGTH, .Little)
	// Item of defined length 12 containing Implicit VR element (0010,0020) len=4 "1234"
	put_tag(&buf, TAG_ITEM, .Little)
	put_u32(&buf, 12, .Little)
	put_tag(&buf, Tag{0x0010, 0x0020}, .Little)
	put_u32(&buf, 4, .Little)
	append(&buf, "1234")
	// Sequence Delimitation
	put_tag(&buf, TAG_SEQ_DELIMITATION, .Little)
	put_u32(&buf, 0, .Little)

	stats: Test_Stats
	c := Cursor{buf = buf[:]}
	meta, _ := parse_meta(&c, stats_handler(&stats))
	end_pos, _, err := parse_body(buf[:], meta.data_offset, meta.ts, stats_handler(&stats))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, end_pos, len(buf))
	testing.expect_value(t, stats.last_tag, Tag{0x0010, 0x0020})
	testing.expect_value(t, stats.last_len, u32(4))
}

// 4. Contract C1 & C2: Big Endian dataset + every byte-truncation prefix must fail cleanly without panic.
@(test)
test_big_endian_and_every_truncation_prefix :: proc(t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.2")
	defer delete(buf)

	put_tag(&buf, Tag{0x0010, 0x0010}, .Big)
	append(&buf, 'P', 'N')
	put_u16(&buf, 8, .Big)
	append(&buf, "DOE^JOHN")
	put_tag(&buf, TAG_PIXEL_DATA, .Big)
	append(&buf, 'O', 'W', 0, 0)
	put_u32(&buf, 4, .Big)
	append(&buf, 0x00, 0x01, 0x00, 0x02)

	// Full buffer must succeed
	stats: Test_Stats
	c := Cursor{buf = buf[:]}
	meta, merr := parse_meta(&c, stats_handler(&stats))
	testing.expect_value(t, merr, Parse_Error.None)
	testing.expect_value(t, meta.ts.order, Byte_Order.Big)
	end_pos, _, berr := parse_body(buf[:], meta.data_offset, meta.ts, stats_handler(&stats))
	testing.expect_value(t, berr, Parse_Error.None)
	testing.expect_value(t, end_pos, len(buf))

	// Every truncated prefix 0 ..< len(buf) must return an error or stop cleanly without panic
	for cut in 0 ..< len(buf) {
		slice := buf[:cut]
		tc := Cursor{buf = slice}
		tmeta, tmerr := parse_meta(&tc, {})
		if tmerr != .None do continue
		if rerr := resolve_dataset_encoding(slice, tmeta.data_offset, &tmeta); rerr != .None do continue
		_, _, _ = parse_body(slice, tmeta.data_offset, tmeta.ts, {})
	}
}
