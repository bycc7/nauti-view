package dicom

import "core:testing"

// T4: parse failures must carry where they happened, not just a kind.

@(test)
test_error_context_truncated_value :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0010, 0x0010}, "PN", "Doe^", .Little)
	// (0010,0020) LO declares 100 bytes but the buffer ends after 4.
	put_tag(&buf, Tag{0x0010, 0x0020}, .Little)
	append(&buf, 'L', 'O')
	put_u16(&buf, 100, .Little)
	append(&buf, 'x', 'x', 'x', 'x')

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.Unexpected_EOF)

	d := document_error(&doc)
	testing.expect_value(t, d.kind, Parse_Error.Unexpected_EOF)
	testing.expect_value(t, d.tag, Tag{0x0010, 0x0020})
	testing.expect_value(t, d.depth, u8(0))
	testing.expect_value(t, d.offset, u32(doc.meta.data_offset + 12))
}

@(test)
test_error_context_bad_delimiter :: proc (t: ^testing.T) {
	// An undefined-length SQ whose first content tag is not (FFFE,E000).
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	put_tag(&buf, Tag{0x0008, 0x1030}, .Little)
	append(&buf, 'S', 'Q')
	put_u16(&buf, 0, .Little)
	put_u32(&buf, UNDEFINED_LENGTH, .Little)
	add_text_elem(&buf, Tag{0x0010, 0x0010}, "LO", "not an item", .Little)

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.Bad_Delimiter)

	d := document_error(&doc)
	testing.expect_value(t, d.kind, Parse_Error.Bad_Delimiter)
	testing.expect_value(t, d.tag, Tag{0x0010, 0x0010})
	testing.expect_value(t, d.depth, u8(1))
}

@(test)
test_error_context_cleared_on_success :: proc (t: ^testing.T) {
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0010, 0x0010}, "PN", "Doe^", .Little)

	bad := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(bad)
	put_tag(&bad, Tag{0x0010, 0x0010}, .Little)
	append(&bad, 'P', 'N')
	put_u16(&bad, 100, .Little)
	append(&bad, 'x')

	doc: Document
	document_init(&doc)
	defer document_destroy(&doc)
	testing.expect_value(t, document_parse_buffer(&doc, bad[:]), Parse_Error.Unexpected_EOF)
	testing.expect_value(t, document_error(&doc).kind, Parse_Error.Unexpected_EOF)

	// A successful re-parse must clear the stale diagnostic.
	testing.expect_value(t, document_parse_buffer(&doc, buf[:]), Parse_Error.None)
	d := document_error(&doc)
	testing.expect_value(t, d.kind, Parse_Error.None)
	testing.expect_value(t, d.tag, Tag{})
}
