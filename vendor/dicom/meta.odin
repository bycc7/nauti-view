package dicom

import "core:encoding/endian"
import "core:strings"

Transfer_Syntax :: struct {
	uid:          string,
	implicit_vr:  bool,
	order:        Byte_Order,
	deflated:     bool,
	encapsulated: bool,
}

Warning_Kind :: enum u8 {
	Missing_Preamble,
	Missing_Transfer_Syntax,
	Transfer_Syntax_VR_Mismatch,
}

Warning :: struct {
	kind:   Warning_Kind,
	offset: u32,
}

Meta_Info :: struct {
	has_preamble: bool,
	has_meta:     bool,
	ts:           Transfer_Syntax,
	data_offset:  int,
	warnings:     [4]Warning,
	warning_len:  int,
}

push_warning :: proc "contextless" (m: ^Meta_Info, kind: Warning_Kind, offset: int) {
	if m.warning_len < len(m.warnings) {
		m.warnings[m.warning_len] = Warning{kind = kind, offset = u32(offset)}
		m.warning_len += 1
	}
}

decode_transfer_syntax :: proc "contextless" (uid: string) -> Transfer_Syntax {
	switch uid {
	case "1.2.840.10008.1.2":
		return {uid, true, .Little, false, false}
	case "1.2.840.10008.1.2.1":
		return {uid, false, .Little, false, false}
	case "1.2.840.10008.1.2.2":
		return {uid, false, .Big, false, false}
	case "1.2.840.10008.1.2.1.99":
		return {uid, false, .Little, true, false}
	case:
		return {uid, false, .Little, false, true}
	}
}

read_element_header :: proc "contextless" (
	c:           ^Cursor,
	implicit_vr: bool,
	order:       Byte_Order,
) -> (tag: Tag, vr: VR, length: u32, err: Parse_Error) {
	tag = read_tag(c, order) or_return

	if tag.group == 0xFFFE {
		length = read_u32(c, order) or_return
		return tag, .ITEM, length, .None
	}

	if implicit_vr {
		vr = lookup_vr(tag)
		length = read_u32(c, order) or_return
		return tag, vr, length, .None
	}

	vr_bytes := read_bytes(c, 2) or_return
	ok: bool
	vr, ok = vr_from_bytes(vr_bytes)
	if !ok do return tag, .UN, 0, .Invalid_VR

	if vr_has_explicit_32bit_length(vr) {
		_ = read_u16(c, order) or_return // 2B Reserved
		length = read_u32(c, order) or_return
	} else {
		len16 := read_u16(c, order) or_return
		length = u32(len16)
	}
	return tag, vr, length, .None
}

// Parse optional 128B+"DICM" preamble and Group 0002 (always Explicit VR LE).
parse_meta :: proc(c: ^Cursor, h: Handler) -> (info: Meta_Info, err: Parse_Error) {
	if len(c.buf) < 8 do return {}, .Not_DICOM

	if len(c.buf) >= 132 && string(c.buf[128:132]) == "DICM" {
		info.has_preamble = true
		c.pos = 132
	} else {
		c.pos = 0
	}

	ts_uid := ""
	for c.pos < len(c.buf) {
		next_t, perr := peek_tag(c, .Little)
		if perr != .None || next_t.group != 0x0002 do break
		// Without DICM magic, verify bytes 4..6 are a valid Explicit VR before treating as Group 0002
		if !info.has_preamble && !info.has_meta {
			if c.pos + 6 > len(c.buf) do break
			if _, ok := vr_from_bytes(c.buf[c.pos + 4 : c.pos + 6]); !ok do break
		}
		info.has_meta = true
		offset := c.pos
		tag, vr, length := read_element_header(c, false, .Little) or_return
		val := read_bytes(c, u64(length)) or_return
		if tag == TAG_TRANSFER_SYNTAX_UID {
			ts_uid = strings.trim_right(string(val), "\x00 ")
		}
		if h.on_event != nil {
			h.on_event(Event{
				kind         = .Element,
				depth        = 0,
				tag          = tag,
				vr           = vr,
				offset       = offset,
				length       = length,
				value_offset = c.pos - int(length),
			}, h.user)
		}
	}

	if !info.has_preamble {
		push_warning(&info, .Missing_Preamble, 0)
	}
	info.data_offset = c.pos
	if ts_uid != "" {
		info.ts = decode_transfer_syntax(ts_uid)
	} else {
		push_warning(&info, .Missing_Transfer_Syntax, info.data_offset)
		info.ts = Transfer_Syntax{uid = "", implicit_vr = true, order = .Little}
	}
	return info, .None
}

// Inspect first dataset element to detect Implicit/Explicit VR and endianness when missing or mismatched.
resolve_dataset_encoding :: proc "contextless" (buf: []u8, pos: int, info: ^Meta_Info) -> Parse_Error {
	rem := buf[pos:]
	if len(rem) == 0 {
		if !info.has_preamble && !info.has_meta do return .Not_DICOM
		return .None
	}
	if len(rem) < 8 do return .Unexpected_EOF

	_, has_explicit_vr := vr_from_bytes(rem[4:6])
	g_le, _ := endian.get_u16(rem[0:2], .Little)
	g_be, _ := endian.get_u16(rem[0:2], .Big)

	if info.ts.uid == "" {
		if has_explicit_vr {
			info.ts.implicit_vr = false
			info.ts.order = .Big if (g_le > 0x00FF && g_be <= 0x00FF && g_be >= 0x0008) else .Little
			info.ts.uid = "1.2.840.10008.1.2.2" if info.ts.order == .Big else "1.2.840.10008.1.2.1"
		} else {
			info.ts.implicit_vr = true
			info.ts.order = .Little
			info.ts.uid = "1.2.840.10008.1.2"
		}
	} else if !info.ts.implicit_vr && !has_explicit_vr && info.ts.order == .Little {
		// e.g. SC_rgb_jpeg.dcm: Meta says JPEG Baseline (Explicit) but dataset is Implicit VR.
		info.ts.implicit_vr = true
		push_warning(info, .Transfer_Syntax_VR_Mismatch, pos)
	}

	if !info.has_preamble && !info.has_meta {
		g := g_be if info.ts.order == .Big else g_le
		e, _ := endian.get_u16(rem[2:4], info.ts.order)
		if g < 0x0008 || g > 0x00FF || (g & 1) != 0 {
			return .Not_DICOM
		}
		if info.ts.implicit_vr {
			vlen, _ := endian.get_u32(rem[4:8], .Little)
			if e == 0x0000 && vlen != 4 do return .Not_DICOM
			if vlen != UNDEFINED_LENGTH && u64(vlen) > u64(len(rem) - 8) do return .Not_DICOM
		}
	}
	return .None
}
