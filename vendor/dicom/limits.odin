package dicom

// T3: per-Document resource budgets. Untrusted input can otherwise stage unbounded memory
// through three channels: element pools (32 bytes per node from ~8 input bytes each), a small
// DEFLATE stream expanding into a giant dataset, and image attributes declaring a frame the
// file never contained. Defaults are generous for real studies and tight against bombs.
Limits :: struct {
	max_inflated_bytes:  int, // DEFLATE dataset budget (1.2.840.10008.1.2.1.99)
	max_elements:        int, // elements + items + fragments per Document
	max_pixels_per_frame: int, // Rows*Columns*Samples accepted by pixel_info
}

DEFAULT_LIMITS :: Limits{
	max_inflated_bytes   = 256 << 20,
	max_elements         = 2_000_000,
	max_pixels_per_frame = 1 << 27,
}

document_set_limits :: proc (doc: ^Document, limits: Limits) {
	doc.limits = limits
}
