package dicom

import "core:compress"
import "core:compress/deflate"

// Contract C4: the inflated dataset buffer is owned by the caller (in Step 3, by the Document),
// so element value slices never outlive their backing storage.
//
// Returns the buffer holding the dataset body plus the offset where parsing starts:
//   - not deflated : (raw, meta.data_offset)  -- parsed in place, zero copy
//   - deflated     : (inflated[:], 0)         -- the dataset was a raw DEFLATE stream
prepare_dataset_body :: proc(
	raw:       []u8,
	meta:      Meta_Info,
	inflated:  ^[dynamic]u8,
	max_bytes: int,
	allocator := context.allocator,
) -> (buf: []u8, start: int, err: Parse_Error) {
	if !meta.ts.deflated {
		return raw, meta.data_offset, .None
	}
	if meta.data_offset >= len(raw) {
		return nil, 0, .Unexpected_EOF
	}

	// core:compress/deflate writes from index 0 of the output buffer, so capacity is reused.
	clear(inflated)
	// T3: the inflation budget replaces the previous fixed 1 GiB cap. core:compress/deflate
	// reports "output exceeds the cap" through the same error union as corrupt streams, so
	// a buffer that reached exactly the budget is classified as a limit, not as bad data.
	if derr := deflate.inflate_raw(inflated, raw[meta.data_offset:], -1, max_bytes, allocator); derr != nil {
		// Output_Too_Short is how core:compress/deflate reports "the budget stopped the
		// stream mid-block"; every other error is genuinely corrupt input.
		if ge, is_ge := derr.(compress.General_Error); is_ge && ge == .Output_Too_Short {
			return nil, 0, .Limit_Exceeded
		}
		return nil, 0, .Deflate_Error
	}
	if len(inflated) > max_bytes do return nil, 0, .Limit_Exceeded
	return inflated[:], 0, .None
}
