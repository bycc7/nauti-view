package dicom

import "core:testing"

// T1: GB18030 / GBK. Terms come from PS3.5 Table 6.2-1 ("GB18030"); "GBK", "GB2312" and
// "CP936" are non-standard but appear in the field and decode identically for the GBK subset.

@(test)
test_charset_gb18030_terms :: proc (t: ^testing.T) {
	testing.expect_value(t, charset_from_term("GB18030"), Charset.Gb18030)
	testing.expect_value(t, charset_from_term("GBK"), Charset.Gb18030)
	testing.expect_value(t, charset_from_term("GB2312"), Charset.Gb18030)
	testing.expect_value(t, charset_from_term("CP936"), Charset.Gb18030)
}

@(test)
test_charset_gb18030_2byte_decode :: proc (t: ^testing.T) {
	// 测试医院 in GBK: 4 characters, 8 bytes.
	raw := "\xB2\xE2\xCA\xD4\xD2\xBD\xD4\xBA"
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0008, 0x0005}, "CS", "GB18030", .Little)
	add_text_elem(&buf, Tag{0x0008, 0x0080}, "LO", string(raw), .Little)

	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)
	testing.expect_value(t, document_charset(doc), Charset.Gb18030)

	e, found := document_find(doc, Tag{0x0008, 0x0080})
	testing.expect(t, found)
	out: [64]u8
	n := text_to_utf8(doc, e, out[:])
	testing.expect_value(t, string(out[:n]), "测试医院")
}

@(test)
test_charset_gb18030_4byte_decode :: proc (t: ^testing.T) {
	// U+1F600 GRINNING FACE is a supplementary-plane character -> GB18030 4-byte form.
	raw := "\x94\x39\xFC\x36"
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0008, 0x0005}, "CS", "GB18030", .Little)
	add_text_elem(&buf, Tag{0x0008, 0x0080}, "LO", string(raw), .Little)

	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)
	e, _ := document_find(doc, Tag{0x0008, 0x0080})
	out: [16]u8
	n := text_to_utf8(doc, e, out[:])
	testing.expect_value(t, string(out[:n]), "\xF0\x9F\x98\x80")
}

@(test)
test_charset_gb18030_rejects_invalid :: proc (t: ^testing.T) {
	// 0xFF is not a valid GB18030 lead byte; 0x81 0x20 is not a valid two-byte sequence.
	bad := "\x81\x20"
	buf := init_dicom_preamble("1.2.840.10008.1.2.1")
	defer delete(buf)
	add_text_elem(&buf, Tag{0x0008, 0x0005}, "CS", "GB18030", .Little)
	add_text_elem(&buf, Tag{0x0008, 0x0080}, "LO", string(bad), .Little)

	doc, ok := parse_doc(t, buf[:])
	defer { document_destroy(doc); free(doc) }
	testing.expect(t, ok)
	e, _ := document_find(doc, Tag{0x0008, 0x0080})
	out: [16]u8
	testing.expect_value(t, text_to_utf8(doc, e, out[:]), -1)

	// A destination that would truncate a character must fail, not split it.
	raw := "\xD3\xC8"
	doc2 := init_dicom_preamble("1.2.840.10008.1.2.1")
	add_text_elem(&doc2, Tag{0x0008, 0x0005}, "CS", "GB18030", .Little)
	add_text_elem(&doc2, Tag{0x0008, 0x0080}, "LO", string(raw), .Little)
	d, ok2 := parse_doc(t, doc2[:])
	defer { document_destroy(d); free(d); delete(doc2) }
	testing.expect(t, ok2)
	e2, _ := document_find(d, Tag{0x0008, 0x0080})
	tiny: [2]u8
	testing.expect_value(t, text_to_utf8(d, e2, tiny[:]), -1)
}
