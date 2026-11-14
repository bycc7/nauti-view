package dicom

VR :: enum u8 {
	UN  = 0,
	AE  = 1,
	AS  = 2,
	AT  = 3,
	CS  = 4,
	DA  = 5,
	DS  = 6,
	DT  = 7,
	FL  = 8,
	FD  = 9,
	IS  = 10,
	LO  = 11,
	LT  = 12,
	OB  = 13,
	OD  = 14,
	OF  = 15,
	OL  = 16,
	OV  = 17,
	OW  = 18,
	PN  = 19,
	SH  = 20,
	SL  = 21,
	SQ  = 22,
	SS  = 23,
	ST  = 24,
	SV  = 25,
	TM  = 26,
	UC  = 27,
	UI  = 28,
	UL  = 29,
	UR  = 30,
	US  = 31,
	UT  = 32,
	UV  = 33,
	// Internal pseudo-VR for FFFE,E000 / FFFE,E00D / FFFE,E0DD
	ITEM     = 34,
	// Polymorphic dictionary VRs, aligned 1:1 with PS3.6 / pydicom
	OB_OW    = 35,
	US_SS    = 36,
	US_OW    = 37,
	US_SS_OW = 38,
}

#assert(size_of(VR) == 1)
#assert(int(VR.US_SS_OW) == 38)

vr_has_explicit_32bit_length :: #force_inline proc "contextless" (vr: VR) -> bool {
	#partial switch vr {
	case .OB, .OD, .OF, .OL, .OV, .OW, .SQ, .SV, .UC, .UN, .UR, .UT, .UV:
		return true
	}
	return false
}

vr_name :: proc "contextless" (vr: VR) -> string {
	#partial switch vr {
	case .OB_OW:    return "OB or OW"
	case .US_SS:    return "US or SS"
	case .US_OW:    return "US or OW"
	case .US_SS_OW: return "US or SS or OW"
	}
	return "UN"
}

vr_from_bytes :: proc "contextless" (b: []u8) -> (VR, bool) {
	if len(b) != 2 do return .UN, false
	switch string(b) {
	case "AE": return .AE, true
	case "AS": return .AS, true
	case "AT": return .AT, true
	case "CS": return .CS, true
	case "DA": return .DA, true
	case "DS": return .DS, true
	case "DT": return .DT, true
	case "FL": return .FL, true
	case "FD": return .FD, true
	case "IS": return .IS, true
	case "LO": return .LO, true
	case "LT": return .LT, true
	case "OB": return .OB, true
	case "OD": return .OD, true
	case "OF": return .OF, true
	case "OL": return .OL, true
	case "OV": return .OV, true
	case "OW": return .OW, true
	case "PN": return .PN, true
	case "SH": return .SH, true
	case "SL": return .SL, true
	case "SQ": return .SQ, true
	case "SS": return .SS, true
	case "ST": return .ST, true
	case "SV": return .SV, true
	case "TM": return .TM, true
	case "UC": return .UC, true
	case "UI": return .UI, true
	case "UL": return .UL, true
	case "UN": return .UN, true
	case "UR": return .UR, true
	case "US": return .US, true
	case "UT": return .UT, true
	case "UV": return .UV, true
	}
	return .UN, false
}
