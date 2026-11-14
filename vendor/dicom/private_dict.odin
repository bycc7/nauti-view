package dicom

// Step 6: PS3.5 Section 7.8.1 Private Data Elements dictionary lookup.
// Unlike standard tags, a private tag (odd group, element >= 0x1000) has no fixed meaning on its
// own: its high element byte `bb = u8(element >> 8)` references the Private Creator element
// `(group, 0x00bb)` in the SAME dataset (top-level or enclosing Item).
//
// `lookup_private_vr` is a contextless pure function over `(creator, tag)` that binary-searches
// the 10,534-entry FNV-1a/64 table generated from pydicom._private_dict, testing the same three
// key forms in the same priority order as pydicom.datadict.get_private_entry:
//   kind 0: GGGGEEEE  (exact tag)
//   kind 1: GGGGxxEE  (block-agnostic, bits 8..15 zeroed)
//   kind 2: GGxxxxEE  (odd-group low byte + block agnostic, bits 8..23 zeroed)

trim_private_creator :: #force_inline proc "contextless" (s: string) -> string {
	b := transmute([]u8)s
	start := 0
	for start < len(b) && (b[start] == ' ' || b[start] == 0) {
		start += 1
	}
	end := len(b)
	for end > start && (b[end - 1] == ' ' || b[end - 1] == 0) {
		end -= 1
	}
	return string(b[start:end])
}

fnv1a_private :: #force_inline proc "contextless" (creator: string, kind: u8, norm_tag: u32) -> u64 {
	FNV_OFFSET :: u64(0xCBF29CE484222325)
	FNV_PRIME  :: u64(0x100000001B3)

	h := FNV_OFFSET
	for i in 0 ..< len(creator) {
		h = (h ~ u64(creator[i])) * FNV_PRIME
	}
	h = (h ~ 0xFF) * FNV_PRIME
	h = (h ~ u64(kind)) * FNV_PRIME
	h = (h ~ u64(u8(norm_tag >> 24))) * FNV_PRIME
	h = (h ~ u64(u8(norm_tag >> 16))) * FNV_PRIME
	h = (h ~ u64(u8(norm_tag >> 8))) * FNV_PRIME
	h = (h ~ u64(u8(norm_tag))) * FNV_PRIME
	return h
}

lookup_private_vr :: proc "contextless" (creator: string, t: Tag) -> (vr: VR, ok: bool) {
	c := trim_private_creator(creator)
	if len(c) == 0 do return .UN, false

	u := tag_to_u32(t)
	candidates := [3]struct {
		kind: u8,
		norm: u32,
	}{
		{0, u},
		{1, u & 0xFFFF_00FF},
		{2, u & 0xFF00_00FF},
	}

	for cand in candidates {
		target := fnv1a_private(c, cand.kind, cand.norm)
		low, high := 0, len(DICOM_PRIVATE_HASHES) - 1
		for low <= high {
			mid := int(uint(low + high) >> 1)
			entry_h := DICOM_PRIVATE_HASHES[mid]
			if entry_h == target {
				return DICOM_PRIVATE_VRS[mid], true
			} else if entry_h < target {
				low = mid + 1
			} else {
				high = mid - 1
			}
		}
	}
	return .UN, false
}

// Finds the Private Creator string governing `t` within the given dataset `span` (e.g. `doc.root`
// or an `Item.span`). Returns false if `t` is not a private data element or no creator is present.
document_private_creator :: proc (doc: ^Document, span: Span, t: Tag) -> (creator: string, ok: bool) {
	if (t.group & 1) == 0 || t.element < 0x1000 do return "", false
	creator_tag := Tag{t.group, u16(t.element >> 8)}
	for e in document_elements(doc, span) {
		if e.tag == creator_tag {
			raw := string(document_value(doc, e))
			trimmed := trim_private_creator(raw)
			return trimmed, len(trimmed) > 0
		}
	}
	return "", false
}

// Resolves a private element's VR within `span` using its dataset's Private Creator when the
// element's VR is still `.UN`. Note that `Parser` already resolves private VRs during the single
// pass whenever the Private Creator precedes the data element (as PS3.5 requires).
document_private_vr :: proc (doc: ^Document, span: Span, e: Element) -> VR {
	if e.vr != .UN do return e.vr
	creator, ok := document_private_creator(doc, span, e.tag)
	if !ok do return .UN
	if vr, vok := lookup_private_vr(creator, e.tag); vok {
		return vr
	}
	return .UN
}
