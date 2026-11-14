package dicom

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

// Explicit VR LE file: (0008,1115) SQ undefined, three undefined-length items, each holding
// PatientName plus a defined-length nested (0008,1140) SQ with one item.
build_nested_file :: proc() -> [dynamic]u8 {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")

	put_tag(&buf, Tag{0x0008, 0x1115}, .Little)
	append(&buf, 'S', 'Q', 0, 0)
	put_u32(&buf, UNDEFINED_LENGTH, .Little)

	for i in 0 ..< 3 {
		put_tag(&buf, TAG_ITEM, .Little)
		put_u32(&buf, UNDEFINED_LENGTH, .Little)

		name := fmt.tprintf("ITEM^%d", i)
		put_tag(&buf, Tag{0x0010, 0x0010}, .Little)
		append(&buf, 'P', 'N')
		put_u16(&buf, u16(len(name)), .Little)
		append(&buf, name)

		// nested defined-length sequence
		inner_start := len(buf)
		put_tag(&buf, Tag{0x0008, 0x1140}, .Little)
		append(&buf, 'S', 'Q', 0, 0)
		put_u32(&buf, 0, .Little) // patched below
		inner_len_pos := len(buf) - 4

		put_tag(&buf, TAG_ITEM, .Little)
		put_u32(&buf, 28, .Little) // item payload: 8B element header + 20B UI value
		put_tag(&buf, Tag{0x0008, 0x1150}, .Little)
		append(&buf, 'U', 'I')
		put_u16(&buf, 20, .Little)
		append(&buf, "1.2.840.10008.1.2.1\x00")

		inner_len := u32(len(buf) - (inner_len_pos + 4))
		buf[inner_len_pos + 0] = u8(inner_len)
		buf[inner_len_pos + 1] = u8(inner_len >> 8)
		buf[inner_len_pos + 2] = u8(inner_len >> 16)
		buf[inner_len_pos + 3] = u8(inner_len >> 24)
		_ = inner_start

		put_tag(&buf, TAG_ITEM_DELIMITATION, .Little)
		put_u32(&buf, 0, .Little)
	}

	put_tag(&buf, TAG_SEQ_DELIMITATION, .Little)
	put_u32(&buf, 0, .Little)
	return buf
}

@(test)
test_document_structure_and_spans :: proc(t: ^testing.T) {
	buf := build_nested_file()
	defer delete(buf)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)

	err := document_parse_buffer(&doc, buf[:])
	testing.expect_value(t, err, Parse_Error.None)

	root := document_root(&doc)
	testing.expect_value(t, len(root), 1)
	seq := root[0]
	testing.expect_value(t, seq.tag, Tag{0x0008, 0x1115})
	testing.expect(t, .Sequence in seq.flags)
	testing.expect(t, .Undefined in seq.flags)

	items := document_items(&doc, seq)
	testing.expect_value(t, len(items), 3)
	for item, i in items {
		testing.expect(t, item.undefined)
		// each item holds PatientName + the nested sequence element
		testing.expect_value(t, int(item.span.count), 2)

		kids := document_elements(&doc, item.span)
		testing.expect_value(t, kids[0].tag, Tag{0x0010, 0x0010})
		want := fmt.tprintf("ITEM^%d", i)
		testing.expect_value(t, string(document_value(&doc, kids[0])), want)

		nested := kids[1]
		testing.expect_value(t, nested.tag, Tag{0x0008, 0x1140})
		testing.expect(t, .Sequence in nested.flags)
		testing.expect(t, .Undefined not_in nested.flags)
		testing.expect_value(t, int(nested.length), 36) // 8B item header + 28B element

		inner_items := document_items(&doc, nested)
		testing.expect_value(t, len(inner_items), 1)
		inner := document_elements(&doc, inner_items[0].span)
		testing.expect_value(t, len(inner), 1)
		testing.expect_value(t, string(document_value(&doc, inner[0])), "1.2.840.10008.1.2.1\x00")
	}

	// C5: every item span must be a contiguous slice of the element pool
	for item in items {
		kids := document_elements(&doc, item.span)
		testing.expect_value(t, len(kids), int(item.span.count))
	}
}

@(test)
test_document_encapsulated_fragments :: proc(t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.4.90")
	defer delete(buf)

	put_tag(&buf, TAG_PIXEL_DATA, .Little)
	append(&buf, 'O', 'B', 0, 0)
	put_u32(&buf, UNDEFINED_LENGTH, .Little)
	put_tag(&buf, TAG_ITEM, .Little) // Basic Offset Table
	put_u32(&buf, 0, .Little)
	for n in 0 ..< 3 {
		put_tag(&buf, TAG_ITEM, .Little)
		put_u32(&buf, u32(4 + n), .Little)
		for _ in 0 ..< 4 + n do append(&buf, 0xFF)
	}
	put_tag(&buf, TAG_SEQ_DELIMITATION, .Little)
	put_u32(&buf, 0, .Little)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)

	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	pixel, ok := document_find(&doc, TAG_PIXEL_DATA)
	testing.expect(t, ok)
	testing.expect(t, .Encapsulated in pixel.flags)
	testing.expect(t, .Undefined in pixel.flags)

	frags := document_fragments(&doc, pixel)
	testing.expect_value(t, len(frags), 4) // BOT + 3 fragments
	for frag, i in frags {
		want := 0 if i == 0 else 4 + i - 1
		testing.expect_value(t, int(frag.length), want)
	}
}

@(test)
test_document_zero_alloc_after_warmup :: proc(t: ^testing.T) {
	buf := build_nested_file()
	defer delete(buf)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	outer := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = outer

	doc: Document
	document_init(&doc)

	// Warm the pools so their capacity covers the steady-state parse.
	for _ in 0 ..< 3 {
		testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	}
	warm_allocations := len(track.allocation_map)

	// Steady state: 100 further parses must not allocate at all.
	for _ in 0 ..< 100 {
		testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	}
	testing.expect_value(t, len(track.allocation_map), warm_allocations)
	testing.expect_value(t, len(track.bad_free_array), 0)

	document_destroy(&doc)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_document_open_file_and_empty_file :: proc(t: ^testing.T) {
	buf := build_nested_file()
	defer delete(buf)

	dir, dir_err := os.temp_dir(context.allocator)
	testing.expect_value(t, dir_err, os.Error(nil))
	defer delete(dir)
	path := fmt.aprintf("%s/odin_dicom_mmap_test.dcm", dir)
	defer delete(path)

	testing.expect_value(t, os.write_entire_file(path, buf[:]), os.Error(nil))

	doc: Document
	document_init(&doc)

	testing.expect_value(t, document_open_file(&doc, path), Parse_Error.None)
	testing.expect(t, len(doc.mapped.data) > 0, "file should be memory mapped")

	// PatientName lives inside the first item of the root sequence.
	seq, ok := document_find(&doc, Tag{0x0008, 0x1115})
	testing.expect(t, ok)
	items := document_items(&doc, seq)
	testing.expect_value(t, len(items), 3)
	kids := document_elements(&doc, items[0].span)
	testing.expect_value(t, string(document_value(&doc, kids[0])), "ITEM^0")

	// Contract C4: the value must be a view into the mapping, not a copy.
	v := document_value(&doc, kids[0])
	testing.expect(t, raw_data(v) >= raw_data(doc.mapped.data))
	testing.expect(t, uintptr(raw_data(v)) < uintptr(raw_data(doc.mapped.data)) + uintptr(len(doc.mapped.data)))

	empty := fmt.aprintf("%s/odin_dicom_empty_test.dcm", dir)
	defer delete(empty)
	testing.expect_value(t, os.write_entire_file(empty, []u8{}), os.Error(nil))
	testing.expect_value(t, document_open_file(&doc, empty), Parse_Error.Not_DICOM)

	document_destroy(&doc)
	_ = os.remove(path)
	_ = os.remove(empty)
}

@(test)
test_document_open_opts_stops_before_pixel_data :: proc(t: ^testing.T) {
	// Encapsulated buffer: PatientName-ish simple element first, then PixelData
	// with an undefined-length fragment sequence (reuses the helpers above).
	buf := init_dicom_preamble("1.2.840.10008.1.2.4.90")
	defer delete(buf)
	put_tag(&buf, Tag{0x0010, 0x0010}, .Little)
	append(&buf, 'P', 'N', 8, 0)
	append(&buf, "DOE^JOHN")
	put_tag(&buf, TAG_PIXEL_DATA, .Little)
	append(&buf, 'O', 'B', 0, 0)
	put_u32(&buf, UNDEFINED_LENGTH, .Little)
	put_tag(&buf, TAG_ITEM, .Little)
	put_u32(&buf, 4, .Little)
	for _ in 0 ..< 4 do append(&buf, 0xFF)
	put_tag(&buf, TAG_SEQ_DELIMITATION, .Little)
	put_u32(&buf, 0, .Little)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)

	// Early stop at PixelData: parse succeeds, PixelData element is absent,
	// elements before it remain reachable, and no fragments were staged.
	err := document_parse_buffer_opts(&doc, buf[:], TAG_PIXEL_DATA)
	testing.expect_value(t, err, Parse_Error.None)
	_, has_pixel := document_find(&doc, TAG_PIXEL_DATA)
	testing.expect(t, !has_pixel, "PixelData must not be registered when stopped early")
	name, has_name := document_find(&doc, Tag{0x0010, 0x0010})
	testing.expect(t, has_name, "elements before the stop tag stay reachable")
	testing.expect_value(t, string(document_value(&doc, name)), "DOE^JOHN")
	testing.expect_value(t, len(doc.fragments), 0)

	// Full parse of the same buffer through the plain entry point still
	// registers PixelData (no behavior change for existing callers).
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	pixel, has_pixel2 := document_find(&doc, TAG_PIXEL_DATA)
	testing.expect(t, has_pixel2)
	testing.expect(t, .Encapsulated in pixel.flags)
}
