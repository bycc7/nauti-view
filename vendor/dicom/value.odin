package dicom

import "core:encoding/endian"
import "core:strconv"
import "core:strings"

// Step 5: value decoding. Contract C7: decoding never allocates and never returns a transformed
// copy -- every accessor either reads through (offset, length) in place or writes into memory the
// caller owns. A shared "decoded buffer" on the Document was rejected because two nested decodes
// would alias each other.
//
// Text accessors return views into the Document buffer with trailing padding (" " and NUL)
// removed, which is what PS3.5 6.2 requires a reader to ignore.

Value_Flags :: enum u8 {
	Not_Value,   // sequence or encapsulated element
	Not_Textual, // VR is not a character-string VR
	Out_Of_Range,
	Bad_Number,
	Wrong_Width, // VR has no fixed-width representation
}

// Bytes per value item for fixed-width VRs; 0 for character-string and byte-stream VRs.
vr_width :: proc "contextless" (vr: VR) -> int {
	#partial switch vr {
	case .US, .SS, .OW:
		return 2
	case .UL, .SL, .FL, .OF, .OL, .AT:
		return 4
	case .UV, .SV, .FD, .OD, .OV:
		return 8
	}
	return 0
}

vr_is_textual :: proc "contextless" (vr: VR) -> bool {
	#partial switch vr {
	case .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC, .UI, .UR, .UT:
		return true
	}
	return false
}

vr_is_integer :: proc "contextless" (vr: VR) -> bool {
	#partial switch vr {
	case .US, .SS, .UL, .SL, .UV, .SV, .OW, .OL, .OV, .AT:
		return true
	}
	return false
}

vr_is_float :: proc "contextless" (vr: VR) -> bool {
	#partial switch vr {
	case .FL, .FD, .OF, .OD:
		return true
	}
	return false
}

// PS3.5 6.2: the dictionary's ambiguous VRs are resolved from the dataset's pixel description.
// These helpers read the two attributes the standard names, from the top-level dataset.
pixel_representation :: proc (doc: ^Document) -> (value: int, ok: bool) {
	e, found := document_find(doc, Tag{0x0028, 0x0103})
	if !found do return 0, false
	u, uok := value_u64(doc, e)
	return int(u), uok
}

bits_allocated :: proc (doc: ^Document) -> (value: int, ok: bool) {
	e, found := document_find(doc, Tag{0x0028, 0x0100})
	if !found do return 0, false
	u, uok := value_u64(doc, e)
	return int(u), uok
}

// Effective VR for value decoding. Dictionary ambiguity is resolved as pydicom does:
//   US_SS / US_SS_OW -> SS when PixelRepresentation is 1, else US
//   OB_OW            -> OB when BitsAllocated <= 8, else OW
//   US_OW            -> left unresolved, because it depends on whether the value is LUT Data
//                       or Waveform Data; callers get US as the conservative reading.
resolve_vr :: proc (doc: ^Document, e: Element) -> VR {
	#partial switch e.vr {
	case .US_SS, .US_SS_OW:
		if pr, ok := pixel_representation(doc); ok && pr == 1 do return .SS
		return .US
	case .OB_OW:
		if ba, ok := bits_allocated(doc); ok && ba > 8 do return .OW
		return .OB
	case .US_OW:
		return .US
	}
	return e.vr
}

// Number of values in an element: fixed width for binary VRs, backslash-separated for text.
value_count :: proc (doc: ^Document, e: Element) -> int {
	vr := resolve_vr(doc, e)
	if .Sequence in e.flags || .Encapsulated in e.flags do return 0
	w := vr_width(vr)
	if w > 0 {
		return int(u64(e.length) / u64(w))
	}
	if !vr_is_textual(vr) do return 0
	v := document_value(doc, e)
	if len(v) == 0 do return 0
	n := 1
	for b in v do if b == '\\' do n += 1
	return n
}

@(private)
raw_at :: proc (doc: ^Document, e: Element, index, width: int) -> (b: []u8, ok: bool) {
	if index < 0 do return nil, false
	v := document_value(doc, e)
	off := u64(index) * u64(width)
	if off + u64(width) > u64(len(v)) do return nil, false
	return v[off:off + u64(width)], true
}

// Unsigned scalar. Signed VRs are zero-extended, AT is packed as (group << 16) | element.
value_u64 :: proc (doc: ^Document, e: Element, index := 0) -> (val: u64, ok: bool) {
	vr := resolve_vr(doc, e)
	order := doc.ts.order
	#partial switch vr {
	case .US, .OW:
		b, a := raw_at(doc, e, index, 2)
		if !a do return 0, false
		x, _ := endian.get_u16(b, order)
		return u64(x), true
	case .UL, .OL, .AT:
		b, a := raw_at(doc, e, index, 4)
		if !a do return 0, false
		x, _ := endian.get_u32(b, order)
		return u64(x), true
	case .UV, .OV:
		b, a := raw_at(doc, e, index, 8)
		if !a do return 0, false
		x, _ := endian.get_u64(b, order)
		return x, true
	case .SS:
		b, a := raw_at(doc, e, index, 2)
		if !a do return 0, false
		x, _ := endian.get_u16(b, order)
		return u64(x), true
	case .SL:
		b, a := raw_at(doc, e, index, 4)
		if !a do return 0, false
		x, _ := endian.get_u32(b, order)
		return u64(x), true
	case .SV:
		b, a := raw_at(doc, e, index, 8)
		if !a do return 0, false
		x, _ := endian.get_u64(b, order)
		return x, true
	}
	return 0, false
}

// Signed scalar for the value VRs that carry a sign. FL/FD are floats, use value_f64.
value_i64 :: proc (doc: ^Document, e: Element, index := 0) -> (val: i64, ok: bool) {
	vr := resolve_vr(doc, e)
	order := doc.ts.order
	#partial switch vr {
	case .SS:
		b, a := raw_at(doc, e, index, 2)
		if !a do return 0, false
		x, _ := endian.get_i16(b, order)
		return i64(x), true
	case .SL:
		b, a := raw_at(doc, e, index, 4)
		if !a do return 0, false
		x, _ := endian.get_i32(b, order)
		return i64(x), true
	case .SV:
		b, a := raw_at(doc, e, index, 8)
		if !a do return 0, false
		x, _ := endian.get_i64(b, order)
		return x, true
	case .US, .UL, .UV:
		u, uok := value_u64(doc, e, index)
		return i64(u), uok
	}
	return 0, false
}

// Float scalar. FL/OF values are widened from f32 so callers never see a float32/float64 split.
value_f64 :: proc (doc: ^Document, e: Element, index := 0) -> (val: f64, ok: bool) {
	vr := resolve_vr(doc, e)
	order := doc.ts.order
	#partial switch vr {
	case .FL, .OF:
		b, a := raw_at(doc, e, index, 4)
		if !a do return 0, false
		bits, _ := endian.get_u32(b, order)
		return f64(transmute(f32)bits), true
	case .FD, .OD:
		b, a := raw_at(doc, e, index, 8)
		if !a do return 0, false
		bits, _ := endian.get_u64(b, order)
		return transmute(f64)bits, true
	}
	return 0, false
}

// Whole value as text with trailing padding removed. Multi-valued text keeps its backslashes;
// use value_split to iterate the values.
value_text :: proc (doc: ^Document, e: Element) -> string {
	vr := resolve_vr(doc, e)
	if .Sequence in e.flags || .Encapsulated in e.flags do return ""
	if !vr_is_textual(vr) do return ""
	return strings.trim_right(string(document_value(doc, e)), " \x00")
}

@(private)
text_at :: proc (doc: ^Document, e: Element, index: int) -> (s: string, ok: bool) {
	raw := value_text(doc, e)
	if raw == "" && index != 0 do return "", false
	remaining := index
	start := 0
	for i in 0 ..< len(raw) {
		if raw[i] == '\\' {
			if remaining == 0 {
				return strings.trim(raw[start:i], " \x00"), true
			}
			remaining -= 1
			start = i + 1
		}
	}
	if remaining != 0 do return "", false
	return strings.trim(raw[start:], " \x00"), true
}

// Splits a multi-valued text element on '\'. Writes at most len(out) entries and returns the
// total number of values, so a small buffer still reports the real count.
value_split :: proc (doc: ^Document, e: Element, out: []string) -> int {
	if !vr_is_textual(resolve_vr(doc, e)) do return 0
	raw := value_text(doc, e)
	if len(raw) == 0 do return 0
	n := 0
	start := 0
	for i in 0 ..< len(raw) {
		if raw[i] == '\\' {
			if n < len(out) do out[n] = strings.trim(raw[start:i], " \x00")
			n += 1
			start = i + 1
		}
	}
	if n < len(out) do out[n] = strings.trim(raw[start:], " \x00")
	return n + 1
}

// DS (decimal string) and IS (integer string) are textual VRs whose values are numbers.
value_ds :: proc (doc: ^Document, e: Element, index := 0) -> (val: f64, ok: bool) {
	s, sok := text_at(doc, e, index)
	if !sok || len(s) == 0 do return 0, false
	return strconv.parse_f64(s)
}

value_is :: proc (doc: ^Document, e: Element, index := 0) -> (val: int, ok: bool) {
	s, sok := text_at(doc, e, index)
	if !sok || len(s) == 0 do return 0, false
	return strconv.parse_int(s, 10)
}

// Person Name: value 0 split on '=' into up to three groups (alphabetic, ideographic, phonetic),
// each split on '^' into up to three components. Every field is a view into the Document buffer.
Person_Name :: struct {
	alphabetic:  [3]string,
	ideographic: [3]string,
	phonetic:    [3]string,
}

@(private)
split_components :: proc (s: string) -> (parts: [3]string, n: int) {
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == '^' {
			if n < 3 do parts[n] = s[start:i]
			n += 1
			start = i + 1
		}
	}
	return parts, min(n, 3)
}

value_pn :: proc (doc: ^Document, e: Element, index := 0) -> (pn: Person_Name, ok: bool) {
	vr := resolve_vr(doc, e)
	if vr != .PN do return {}, false
	s, sok := text_at(doc, e, index)
	if !sok do return {}, false

	groups: [3]string
	n := 0
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == '=' {
			if n < 3 do groups[n] = s[start:i]
			n += 1
			start = i + 1
		}
	}
	if n > 0 do pn.alphabetic, _ = split_components(groups[0])
	if n > 1 do pn.ideographic, _ = split_components(groups[1])
	if n > 2 do pn.phonetic, _ = split_components(groups[2])
	return pn, true
}

// Bulk conversion of a fixed-width integer VR into caller-owned storage. Returns the number of
// values written, which is 0 when the VR is not fixed width or the buffer is too small.
decode_integers :: proc (doc: ^Document, e: Element, dst: []i64) -> int {
	vr := resolve_vr(doc, e)
	if !vr_is_integer(vr) do return 0
	n := value_count(doc, e)
	if n > len(dst) do return 0
	for i in 0 ..< n {
		v, ok := value_i64(doc, e, i)
		if !ok do return 0
		dst[i] = v
	}
	return n
}

decode_floats :: proc (doc: ^Document, e: Element, dst: []f64) -> int {
	vr := resolve_vr(doc, e)
	if !vr_is_float(vr) do return 0
	n := value_count(doc, e)
	if n > len(dst) do return 0
	for i in 0 ..< n {
		v, ok := value_f64(doc, e, i)
		if !ok do return 0
		dst[i] = v
	}
	return n
}
