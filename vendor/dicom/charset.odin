package dicom

import "core:strings"

// Step 5: Specific Character Set (0008,0005). Only the three encodings that need no
// state machine are handled; anything else is reported as .Unsupported so a caller can decide
// instead of silently producing mojibake.
Charset :: enum u8 {
	Ascii,       // ISO_IR 6, or no (0008,0005) at all
	Utf8,        // ISO_IR 192
	Latin1,      // ISO_IR 100
	Gb18030,     // GB18030 (superset of GBK/GB2312; also accepts those non-standard terms)
	Unsupported, // ISO 2022 code extensions, ISO_IR 13/166, ...
}

// PS3.5 Table 6.2-1: only these VRs are affected by Specific Character Set; every other
// character-string VR is ASCII by definition and must never be transcoded.
vr_uses_charset :: proc "contextless" (vr: VR) -> bool {
	#partial switch vr {
	case .PN, .LO, .SH, .ST, .LT, .UC, .UT:
		return true
	}
	return false
}

charset_from_term :: proc (term: string) -> Charset {
	s := strings.trim(term, " \x00")
	// Strip the leading marker of an ISO 2022 extension list ("\ISO 2022 IR 100").
	for len(s) > 0 && s[0] == '\\' do s = s[1:]
	if i := strings.index_byte(s, '\\'); i >= 0 do s = s[:i]
	switch s {
	case "", "ISO_IR 6", "ISO 2022 IR 6", "ISO-IR 6":
		return .Ascii
	case "ISO_IR 192", "ISO 2022 IR 192", "ISO-IR 192":
		return .Utf8
	case "ISO_IR 100", "ISO 2022 IR 100", "ISO-IR 100":
		return .Latin1
	case "GB18030", "GBK", "GB2312", "CP936", "GB_2312-80":
		// PS3.5 defines GB18030; the other names are common mislabels whose bytes are a
		// subset of GB18030, so decoding them with the same table is lossless.
		return .Gb18030
	}
	return .Unsupported
}

document_charset :: proc (doc: ^Document) -> Charset {
	e, ok := document_find(doc, Tag{0x0008, 0x0005})
	if !ok do return .Ascii
	return charset_from_term(value_text(doc, e))
}

// Zero-allocation Latin-1 -> UTF-8, for callers that need real UTF-8 text (loggers, JSON).
// Returns the bytes written and false when dst is too small.
latin1_to_utf8 :: proc (dst: []u8, src: []u8) -> (n: int, ok: bool) {
	for b in src {
		if b < 0x80 {
			if n + 1 > len(dst) do return n, false
			dst[n] = b
			n += 1
		} else {
			if n + 2 > len(dst) do return n, false
			dst[n] = 0xC0 | (b >> 6)
			dst[n + 1] = 0x80 | (b & 0x3F)
			n += 2
		}
	}
	return n, true
}

// Decodes a text element into UTF-8 in caller-owned storage for the supported charsets.
// ASCII and UTF-8 are copied verbatim; Latin-1 is widened; Unsupported is rejected rather than
// guessed. Returns the number of bytes written, or -1 when the value does not fit.
text_to_utf8 :: proc (doc: ^Document, e: Element, dst: []u8) -> int {
	v := document_value(doc, e)
	n := len(v)
	if !vr_uses_charset(e.vr) {
		// ASCII-only VR: copy through untouched, whatever the dataset declares.
		for n > 0 && (v[n - 1] == ' ' || v[n - 1] == 0) do n -= 1
		if n > len(dst) do return -1
		copy(dst, v[:n])
		return n
	}
	for n > 0 && (v[n - 1] == ' ' || v[n - 1] == 0) do n -= 1
	v = v[:n]

	#partial switch document_charset(doc) {
	case .Ascii:
		// ISO-IR 6 is 7-bit: non-ASCII bytes mean the producer ignored (0008,0005) (some PACS
		// write GBK without declaring it). Reject rather than hand out invalid UTF-8.
		for b in v do if b > 0x7F do return -1
		if n > len(dst) do return -1
		copy(dst, v)
		return n
	case .Utf8:
		if n > len(dst) do return -1
		copy(dst, v)
		return n
	case .Latin1:
		m, ok := latin1_to_utf8(dst, v)
		return -1 if !ok else m
	case .Gb18030:
		m, ok := gb18030_to_utf8(dst, v)
		return -1 if !ok else m
	}
	return -1
}

// GB18030 -> UTF-8 (PS3.5 Table 6.2-1). Two-byte codes come from the generated table; four-byte
// codes index a range table where the codepoint increases linearly. Rejects any malformed or
// unassigned sequence instead of substituting U+FFFD, matching the rest of this file.
gb18030_to_utf8 :: proc (dst: []u8, src: []u8) -> (n: int, ok: bool) {
	i := 0
	for i < len(src) {
		b := src[i]
		if b < 0x80 {
			if n + 1 > len(dst) do return n, false
			dst[n] = b
			n += 1
			i += 1
			continue
		}
		if b == 0x80 || b == 0xFF do return n, false // 0x80 is not a lead byte, 0xFF is unused
		if i + 1 >= len(src) do return n, false
		b2 := src[i + 1]
		cp: u32
		if b2 >= 0x30 && b2 <= 0x39 {
			// Four-byte form: lead 81-FE, 30-39, 81-FE, 30-39.
			if i + 3 >= len(src) do return n, false
			b3 := src[i + 2]
			b4 := src[i + 3]
			if b3 < 0x81 || b3 > 0xFE || b4 < 0x30 || b4 > 0x39 do return n, false
			idx := (((u32(b) - 0x81) * 10 + (u32(b2) - 0x30)) * 126 + (u32(b3) - 0x81)) * 10 + (u32(b4) - 0x30)
			cp, ok = gb18030_4byte_lookup(idx)
			if !ok do return n, false
			i += 4
		} else {
			// Two-byte form: trail 40-FE without 7F.
			if b2 < 0x40 || b2 > 0xFE || b2 == 0x7F do return n, false
			trail := int(b2) - 0x40
			if b2 > 0x7F do trail -= 1
			v := GB18030_2BYTE[(int(b) - 0x81) * 190 + trail]
			if v == 0 do return n, false
			cp = v & 0xFFFF
			i += 2
		}
		m, wok := utf8_encode(dst[n:], cp)
		if !wok do return n, false
		n += m
	}
	return n, true
}

@(private)
utf8_encode :: proc (dst: []u8, cp: u32) -> (n: int, ok: bool) {
	switch {
	case cp < 0x80:
		if len(dst) < 1 do return 0, false
		dst[0] = u8(cp)
		return 1, true
	case cp < 0x800:
		if len(dst) < 2 do return 0, false
		dst[0] = 0xC0 | u8(cp >> 6)
		dst[1] = 0x80 | u8(cp & 0x3F)
		return 2, true
	case cp < 0x10000:
		if len(dst) < 3 do return 0, false
		dst[0] = 0xE0 | u8(cp >> 12)
		dst[1] = 0x80 | u8((cp >> 6) & 0x3F)
		dst[2] = 0x80 | u8(cp & 0x3F)
		return 3, true
	case cp <= 0x10FFFF:
		if len(dst) < 4 do return 0, false
		dst[0] = 0xF0 | u8(cp >> 18)
		dst[1] = 0x80 | u8((cp >> 12) & 0x3F)
		dst[2] = 0x80 | u8((cp >> 6) & 0x3F)
		dst[3] = 0x80 | u8(cp & 0x3F)
		return 4, true
	}
	return 0, false
}

@(private)
gb18030_4byte_lookup :: proc (idx: u32) -> (cp: u32, ok: bool) {
	lo, hi := 0, len(GB18030_4BYTE)
	for lo < hi {
		mid := (lo + hi) / 2
		r := GB18030_4BYTE[mid]
		switch {
		case idx < r.first:
			hi = mid
		case idx > r.last:
			lo = mid + 1
		case:
			return r.unicode + (idx - r.first), true
		}
	}
	return 0, false
}
