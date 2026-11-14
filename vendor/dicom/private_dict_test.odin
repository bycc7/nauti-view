package dicom

import "core:mem"
import "core:testing"

// 1. Exhaustive verification of all 10,534 private dictionary entries against pydicom's
//    private_dictionary_VR(), plus strict ascending hash order required by binary search.
@(test)
test_private_dictionary_exhaustive_checksum :: proc (t: ^testing.T) {
	testing.expect_value(t, len(DICOM_PRIVATE_HASHES), PRIV_DICT_COUNT)
	testing.expect_value(t, len(DICOM_PRIVATE_VRS), PRIV_DICT_COUNT)
	testing.expect(t, len(DICOM_PRIVATE_HASHES) > 10000)

	for i in 1 ..< len(DICOM_PRIVATE_HASHES) {
		if DICOM_PRIVATE_HASHES[i - 1] >= DICOM_PRIVATE_HASHES[i] {
			testing.fail_now(t, "DICOM_PRIVATE_HASHES is not strictly sorted")
		}
	}

	FNV_OFFSET :: u64(0xCBF29CE484222325)
	FNV_PRIME  :: u64(0x100000001B3)

	h := FNV_OFFSET
	for i in 0 ..< len(DICOM_PRIVATE_HASHES) {
		eh := DICOM_PRIVATE_HASHES[i]
		vr := DICOM_PRIVATE_VRS[i]
		bytes := [8]u8{
			u8(eh >> 56), u8(eh >> 48), u8(eh >> 40), u8(eh >> 32),
			u8(eh >> 24), u8(eh >> 16), u8(eh >> 8),  u8(eh),
		}
		for b in bytes {
			h = (h ~ u64(b)) * FNV_PRIME
		}
		h = (h ~ u64(vr)) * FNV_PRIME
	}

	testing.expectf(
		t,
		h == PRIV_DICT_FNV,
		"private dictionary mismatch vs pydicom: fnv=0x%016X expected=0x%016X",
		h,
		PRIV_DICT_FNV,
	)
}

// 2. Direct lookup across all three pydicom pattern kinds (GGGGEEEE, GGGGxxEE, GGxxxxEE)
//    and padding/NUL trimming on the creator string.
@(test)
test_private_dictionary_lookup_patterns :: proc (t: ^testing.T) {
	// Kind 1: GGGGxxEE (block-agnostic) -- same creator works across blocks 0x10, 0x11, 0xFF
	vr1, ok1 := lookup_private_vr("GEMS_IDEN_01", Tag{0x0009, 0x1001})
	testing.expect(t, ok1)
	testing.expect_value(t, vr1, VR.LO)

	vr2, ok2 := lookup_private_vr("  GEMS_IDEN_01 \x00", Tag{0x0009, 0xFF27})
	testing.expect(t, ok2)
	testing.expect_value(t, vr2, VR.SL)

	// Kind 0: GGGGEEEE (exact)
	vr0, ok0 := lookup_private_vr("CANON_MEC_MR3", Tag{0x0029, 0x0089})
	testing.expect(t, ok0)
	testing.expect_value(t, vr0, VR.LO)

	// Kind 2: GGxxxxEE (odd-group low byte + block agnostic)
	vr_gg, ok_gg := lookup_private_vr("DLX_ANNOT_01", Tag{0x7005, 0x1004})
	testing.expect(t, ok_gg)
	testing.expect_value(t, vr_gg, VR.ST)

	// Unknown creator / unknown element / empty creator must fail cleanly
	_, bad1 := lookup_private_vr("NO_SUCH_VENDOR", Tag{0x0009, 0x1001})
	testing.expect(t, !bad1)
	_, bad2 := lookup_private_vr("GEMS_IDEN_01", Tag{0x0009, 0x10FE})
	testing.expect(t, !bad2)
	_, bad3 := lookup_private_vr("   \x00", Tag{0x0009, 0x1001})
	testing.expect(t, !bad3)
}

add_implicit_elem :: proc (buf: ^[dynamic]u8, tag: Tag, val: []u8) {
	put_tag(buf, tag, .Little)
	put_u32(buf, u32(len(val)), .Little)
	append(buf, ..val)
}

add_implicit_str :: proc (buf: ^[dynamic]u8, tag: Tag, s: string) {
	put_tag(buf, tag, .Little)
	padded := len(s) + (len(s) & 1)
	put_u32(buf, u32(padded), .Little)
	append(buf, s)
	if (len(s) & 1) == 1 do append(buf, ' ')
}

// 3. End-to-end Implicit VR LE parse + value decode + Item-level Private Creator scoping
//    + defined-length private SQ expansion + zero steady-state allocations.
@(test)
test_private_creator_parse_scoping_and_zero_alloc :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2") // Implicit VR Little Endian
	defer delete(buf)

	// Top-level creator: (0009,0010) = "GEMS_IDEN_01"
	add_implicit_str(&buf, Tag{0x0009, 0x0010}, "GEMS_IDEN_01")
	// (0009,1001) -> LO "GE_GENESIS_FF"
	add_implicit_str(&buf, Tag{0x0009, 0x1001}, "GE_GENESIS_FF")
	// (0009,1027) -> SL 1700000000
	sl_bytes := [4]u8{0x00, 0x3C, 0x56, 0x65} // 0x65563C00 = 1700148224
	add_implicit_elem(&buf, Tag{0x0009, 0x1027}, sl_bytes[:])

	// Defined-length private SQ: (0071,0010) = "AGFA-AG_HPState", (0071,1018) -> SQ
	add_implicit_str(&buf, Tag{0x0071, 0x0010}, "AGFA-AG_HPState")

	// Build two items inside (0071,1018):
	//   Item 0 defines its own (0009,0010) = "UNKNOWN_VENDOR", so (0009,1027) inside Item 0 stays .UN.
	//   Item 1 defines (0009,0010) = "GEMS_IDEN_01", so (0009,1027) inside Item 1 resolves to .SL.
	item0: [dynamic]u8
	defer delete(item0)
	add_implicit_str(&item0, Tag{0x0009, 0x0010}, "UNKNOWN_VENDOR")
	add_implicit_elem(&item0, Tag{0x0009, 0x1027}, sl_bytes[:])

	item1: [dynamic]u8
	defer delete(item1)
	add_implicit_str(&item1, Tag{0x0009, 0x0010}, "GEMS_IDEN_01")
	add_implicit_elem(&item1, Tag{0x0009, 0x1027}, sl_bytes[:])

	seq_payload_len := u32(8 + len(item0) + 8 + len(item1))
	put_tag(&buf, Tag{0x0071, 0x1018}, .Little)
	put_u32(&buf, seq_payload_len, .Little)
	put_tag(&buf, TAG_ITEM, .Little)
	put_u32(&buf, u32(len(item0)), .Little)
	append(&buf, ..item0[:])
	put_tag(&buf, TAG_ITEM, .Little)
	put_u32(&buf, u32(len(item1)), .Little)
	append(&buf, ..item1[:])

	// After the sequence closes, top-level block 0x10 in group 0009 must still be "GEMS_IDEN_01":
	// (0009,10E9) -> SL
	add_implicit_elem(&buf, Tag{0x0009, 0x10E9}, sl_bytes[:])

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	outer := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = outer

	doc: Document
	document_init(&doc)

	for _ in 0 ..< 3 {
		testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	}
	warm := len(track.allocation_map)
	for _ in 0 ..< 100 {
		testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	}
	testing.expect_value(t, len(track.allocation_map), warm)

	// Verify top-level private elements resolved and decode properly
	e_lo, ok_lo := document_find(&doc, Tag{0x0009, 0x1001})
	testing.expect(t, ok_lo)
	testing.expect_value(t, e_lo.vr, VR.LO)
	testing.expect_value(t, value_text(&doc, e_lo), "GE_GENESIS_FF")

	e_sl, ok_sl := document_find(&doc, Tag{0x0009, 0x1027})
	testing.expect(t, ok_sl)
	testing.expect_value(t, e_sl.vr, VR.SL)
	v_sl, vok := value_i64(&doc, e_sl)
	testing.expect(t, vok)
	testing.expect_value(t, v_sl, i64(0x65563C00))

	// Verify document_private_creator and document_private_vr helpers
	cr, crok := document_private_creator(&doc, doc.root, Tag{0x0009, 0x1027})
	testing.expect(t, crok)
	testing.expect_value(t, cr, "GEMS_IDEN_01")
	testing.expect_value(t, document_private_vr(&doc, doc.root, e_sl), VR.SL)

	// Verify defined-length private SQ expanded into 2 items with independent creator scopes
	e_sq, ok_sq := document_find(&doc, Tag{0x0071, 0x1018})
	testing.expect(t, ok_sq)
	testing.expect_value(t, e_sq.vr, VR.SQ)
	testing.expect(t, .Sequence in e_sq.flags)
	items := document_items(&doc, e_sq)
	testing.expect_value(t, len(items), 2)

	it0_elems := document_elements(&doc, items[0].span)
	testing.expect_value(t, len(it0_elems), 2)
	testing.expect_value(t, it0_elems[1].vr, VR.UN) // UNKNOWN_VENDOR -> stays UN

	it1_elems := document_elements(&doc, items[1].span)
	testing.expect_value(t, len(it1_elems), 2)
	testing.expect_value(t, it1_elems[1].vr, VR.SL) // GEMS_IDEN_01 -> resolved to SL

	// Verify top-level creator survived Item 0's override
	e_after, ok_after := document_find(&doc, Tag{0x0009, 0x10E9})
	testing.expect(t, ok_after)
	testing.expect_value(t, e_after.vr, VR.SL)

	document_destroy(&doc)
	testing.expect_value(t, len(track.allocation_map), 0)
}
