package dicom

import "core:encoding/endian"

// Step 7: RLE Lossless (PS3.5 Annex G, TS UID 1.2.840.10008.1.2.5).
// One encapsulated fragment per frame, each starting with a 64-byte header:
//   u32 number_of_segments, then 15 x u32 segment offsets
// Every segment is PackBits and decodes to exactly Rows * Columns bytes, interleaved into the
// caller-owned output with the standard sample/byte order. Decoding is strided and write-through:
// no segment buffer, no copy, no allocation.

RLE_Error :: enum u8 {
	None = 0,
	Not_RLE_Transfer_Syntax,
	Not_Encapsulated,
	Missing_Image_Attributes,
	Invalid_Image_Parameters,
	Bad_Fragment_Count,
	Bad_Header,
	Bad_Segment,
	Output_Too_Small,
}

RLE_UID :: "1.2.840.10008.1.2.5"

RLE_Image :: struct {
	rows:        int,
	cols:        int,
	samples:     int,
	bits:        int,
	frames:      int,
	bytes_per_sample: int,
	pixels_per_frame: int,
	frame_bytes:      int,
	segments:         int,
}

rle_attribute :: proc (doc: ^Document, tag: Tag) -> (v: int, ok: bool) {
	e, found := document_find(doc, tag)
	if !found do return 0, false
	if e.vr == .IS {
		n, nok := value_is(doc, e)
		return n, nok
	}
	u, uok := value_u64(doc, e)
	return int(u), uok
}

// Derives the decoding geometry from the top-level image attributes and validates the pixel
// element is an encapsulated RLE value. Caller-owned `dst` is filled by rle_decode.
rle_image_info :: proc (doc: ^Document, pixel: Element) -> (info: RLE_Image, err: RLE_Error) {
	if doc.ts.uid != RLE_UID do return {}, .Not_RLE_Transfer_Syntax
	if .Encapsulated not_in pixel.flags do return {}, .Not_Encapsulated

	rows, ok_rows := rle_attribute(doc, Tag{0x0028, 0x0010})
	cols, ok_cols := rle_attribute(doc, Tag{0x0028, 0x0011})
	bits, ok_bits := rle_attribute(doc, Tag{0x0028, 0x0100})
	if !ok_rows || !ok_cols || !ok_bits do return {}, .Missing_Image_Attributes

	samples, ok_samples := rle_attribute(doc, Tag{0x0028, 0x0002})
	if !ok_samples do samples = 1
	frames, ok_frames := rle_attribute(doc, Tag{0x0028, 0x0008})
	if !ok_frames do frames = 1

	if rows <= 0 || cols <= 0 || bits <= 0 || (bits % 8) != 0 || bits > 32 ||
	   samples <= 0 || samples > 4 || frames <= 0 {
		return {}, .Invalid_Image_Parameters
	}

	bps := bits / 8
	n_pixels := rows * cols
	info = RLE_Image{
		rows              = rows,
		cols              = cols,
		samples           = samples,
		bits              = bits,
		frames            = frames,
		bytes_per_sample  = bps,
		pixels_per_frame  = n_pixels,
		frame_bytes       = n_pixels * samples * bps,
		segments          = samples * bps,
	}
	return info, .None
}

@(private)
fragment_bytes :: proc (doc: ^Document, pixel: Element, f: Fragment) -> (b: []u8, ok: bool) {
	buf := doc.body if .In_Body in pixel.flags else doc.src
	end := f.offset + u64(f.length)
	if end > u64(len(buf)) do return nil, false
	return buf[f.offset:end], true
}

// Decodes one frame. `dst` must hold at least info.frame_bytes bytes; the BOT fragment and any
// trailing padding fragments are the caller's concern (rle_decode handles them).
rle_decode_frame :: proc (
	doc:         ^Document,
	pixel:       Element,
	f:           Fragment,
	dst:         []u8,
	info:        RLE_Image,
) -> RLE_Error {
	if len(dst) < info.frame_bytes do return .Output_Too_Small
	raw, ok := fragment_bytes(doc, pixel, f)
	if !ok do return .Bad_Header
	if len(raw) < 64 do return .Bad_Header

	order := doc.ts.order
	num_segments, _ := endian.get_u32(raw[0:4], order)
	if int(num_segments) != info.segments || num_segments > 15 do return .Bad_Header

	offsets: [16]u32
	for i in 0 ..< int(num_segments) {
		offsets[i], _ = endian.get_u32(raw[4 * (i + 1):4 * (i + 2)], order)
	}

	bps := info.bytes_per_sample
	stride := info.samples * bps
	n_pixels := info.pixels_per_frame
	frame_bytes := info.frame_bytes

	for s in 0 ..< int(num_segments) {
		start := int(offsets[s])
		end := int(offsets[s + 1]) if s + 1 < int(num_segments) else len(raw)
		if start < 64 || end > len(raw) || end < start do return .Bad_Segment

		// PS3.5 G.3: segments are ordered by sample, then by byte from MSB to LSB. RLE data is
		// little-endian, so byte b of sample c lands at c*bps + (bps-1-b) within each pixel.
		c := s / bps
		b := s % bps
		w := c * bps + (bps - 1 - b)
		pos := start
		written := 0

		for pos < end && written < n_pixels {
			n := int(raw[pos])
			pos += 1
			switch {
			case n <= 127: // literal run: n+1 bytes copied verbatim
				count := n + 1
				if written + count > n_pixels do return .Bad_Segment
				if pos + count > end do return .Bad_Segment
				for k in 0 ..< count {
					if w >= frame_bytes do return .Bad_Segment
					dst[w] = raw[pos + k]
					w += stride
				}
				pos += count
				written += count
			case n >= 129: // replicate run: one byte repeated 257-n times
				count := 257 - n
				if written + count > n_pixels do return .Bad_Segment
				if pos + 1 > end do return .Bad_Segment
				value := raw[pos]
				pos += 1
				for _ in 0 ..< count {
					if w >= frame_bytes do return .Bad_Segment
					dst[w] = value
					w += stride
				}
				written += count
			// n == 128 is a no-op
			}
		}
		if written != n_pixels do return .Bad_Segment
	}
	return .None
}

// Decodes every frame into the caller-owned `dst`. The first fragment(s) before the frame
// fragments are the Basic Offset Table and are skipped.
rle_decode :: proc (doc: ^Document, pixel: Element, dst: []u8) -> (written: int, err: RLE_Error) {
	info, ierr := rle_image_info(doc, pixel)
	if ierr != .None do return 0, ierr

	frags := document_fragments(doc, pixel)
	// Basic Offset Table is item 0 when present; pydicom's corpus always has it.
	bot_count := len(frags) - info.frames
	if bot_count < 0 || bot_count > 1 do return 0, .Bad_Fragment_Count

	total := info.frame_bytes * info.frames
	if len(dst) < total do return 0, .Output_Too_Small

	for frame in 0 ..< info.frames {
		frame_dst := dst[frame * info.frame_bytes:(frame + 1) * info.frame_bytes]
		if ferr := rle_decode_frame(doc, pixel, frags[bot_count + frame], frame_dst, info); ferr != .None {
			return frame * info.frame_bytes, ferr
		}
	}
	return total, .None
}
