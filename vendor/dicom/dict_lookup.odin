package dicom

lookup_vr :: proc "contextless" (t: Tag) -> VR {
	if t.group == 0xFFFE do return .ITEM
	if t.element == 0x0000 do return .UL // Generic Group Length

	// Odd group = Private Tag (PS3.5 Sec 7.8)
	if (t.group & 1) == 1 {
		if t.element >= 0x0010 && t.element <= 0x00FF do return .LO // Private Creator
		return .UN
	}

	target := tag_to_u32(t)

	// 1. Binary search exact PS3.6 dictionary
	low, high := 0, len(DICOM_DICT) - 1
	for low <= high {
		mid := int(uint(low + high) >> 1)
		entry := DICOM_DICT[mid]
		if entry.tag == target {
			return entry.vr
		} else if entry.tag < target {
			low = mid + 1
		} else {
			high = mid - 1
		}
	}

	// 2. Scan PS3.6 repeating group/element masks (50xx, 60xx, 0020,31xx, 0028,04x0, 1000,xxx0, 7Fxx, ...)
	for r in DICOM_REPEATERS {
		if (target & r.mask) == r.val {
			return r.vr
		}
	}

	return .UN
}
