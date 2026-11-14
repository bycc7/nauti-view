package dicom

import "core:encoding/endian"

// Unified pixel access. Every codec in this package has its own info/error types and its own
// decode entry point; this layer is the single call site an application needs, and it also
// covers the uncompressed transfer syntaxes (raw PixelData), which the codecs deliberately do
// not own.
//
// Contract:
// - pixel_decode writes little-endian, interleaved samples into the caller's buffer, whatever
//   the transfer syntax byte order or PlanarConfiguration was. 16- and 32-bit samples are
//   therefore readable as u16/u32 without further handling.
// - 1-bit native data is copied as packed bytes; callers unpack with (0028,0101) bits stored.
// - PixelData length shorter than Rows*Columns*Samples*Frames*bps is rejected rather than
//   zero-filled.
// - Encapsulated data is delegated to the codec for the transfer syntax; unsupported UIDs fail
//   with .Unsupported_Transfer_Syntax.

Pixel_Error :: enum u8 {
	None,
	Missing_Image_Attributes,
	Invalid_Image_Parameters,
	Limit_Exceeded,
	Unsupported_Planar_Configuration,
	Unsupported_Transfer_Syntax,
	Missing_Pixel_Data,
	Output_Too_Small,
	Decode_Failed,
}

Photometric :: enum u8 {
	Unknown,
	Monochrome1,
	Monochrome2,
	Palette_Color,
	RGB,
	YBR_FULL,
	YBR_FULL_422,
	YBR_PARTIAL_422,
	YBR_PARTIAL_420,
	YBR_ICT,
	YBR_RCT,
}

Pixel_Info :: struct {
	rows:                 int,
	cols:                 int,
	samples:              int,
	frames:               int,
	bits_allocated:       int,
	bits_stored:          int,
	high_bit:             int,
	signed:               bool,
	planar_configuration: int,
	photometric:          Photometric,
	photometric_raw:      string, // as stored, trimmed; "" when absent
	bytes_per_sample:     int,
	frame_bytes:          int,
	subsampled_422:       bool, // native YBR_FULL_422: 3 samples in 2 stored bytes per pixel
	native:               bool, // uncompressed PixelData owned by the document
}

pixel_attribute :: proc (doc: ^Document, tag: Tag) -> (v: int, ok: bool) {
	e, found := document_find(doc, tag)
	if !found do return 0, false
	if e.vr == .IS {
		n, nok := value_is(doc, e)
		return int(n), nok
	}
	u, uok := value_u64(doc, e)
	return int(u), uok
}

pixel_photometric :: proc (s: string) -> Photometric {
	switch s {
	case "MONOCHROME1":
		return .Monochrome1
	case "MONOCHROME2":
		return .Monochrome2
	case "PALETTE COLOR":
		return .Palette_Color
	case "RGB":
		return .RGB
	case "YBR_FULL":
		return .YBR_FULL
	case "YBR_FULL_422":
		return .YBR_FULL_422
	case "YBR_PARTIAL_422":
		return .YBR_PARTIAL_422
	case "YBR_PARTIAL_420":
		return .YBR_PARTIAL_420
	case "YBR_ICT":
		return .YBR_ICT
	case "YBR_RCT":
		return .YBR_RCT
	}
	return .Unknown
}

// Derives geometry from the top-level image attributes. Independent of the transfer syntax, so
// the same info describes native and encapsulated values.
pixel_info :: proc (doc: ^Document) -> (info: Pixel_Info, err: Pixel_Error) {
	pixel, found := document_find(doc, TAG_PIXEL_DATA)
	if !found do return {}, .Missing_Pixel_Data

	rows, ok_rows := pixel_attribute(doc, Tag{0x0028, 0x0010})
	cols, ok_cols := pixel_attribute(doc, Tag{0x0028, 0x0011})
	bits, ok_bits := pixel_attribute(doc, Tag{0x0028, 0x0100})
	if !ok_rows || !ok_cols || !ok_bits do return {}, .Missing_Image_Attributes

	samples := 1
	if v, ok := pixel_attribute(doc, Tag{0x0028, 0x0002}); ok do samples = v
	frames := 1
	if v, ok := pixel_attribute(doc, Tag{0x0028, 0x0008}); ok do frames = v
	planar := 0
	if v, ok := pixel_attribute(doc, Tag{0x0028, 0x0006}); ok do planar = v
	bits_stored := bits
	if v, ok := pixel_attribute(doc, Tag{0x0028, 0x0101}); ok do bits_stored = v
	high_bit := bits_stored - 1
	if v, ok := pixel_attribute(doc, Tag{0x0028, 0x0102}); ok do high_bit = v
	signed := false
	if v, ok := pixel_attribute(doc, Tag{0x0028, 0x0103}); ok do signed = v != 0

	if rows <= 0 || cols <= 0 || frames <= 0 || samples <= 0 || samples > 4 {
		return {}, .Invalid_Image_Parameters
	}
	if bits != 1 && bits != 8 && bits != 16 && bits != 32 {
		return {}, .Invalid_Image_Parameters
	}
	if planar != 0 && planar != 1 do return {}, .Unsupported_Planar_Configuration
	if planar == 1 && bits == 1 do return {}, .Unsupported_Planar_Configuration
	if u64(rows) * u64(cols) * u64(samples) > u64(doc.limits.max_pixels_per_frame) {
		return {}, .Limit_Exceeded
	}

	bps := 1 if bits == 1 else bits / 8
	photometric_raw := ""
	if e, ok := document_find(doc, Tag{0x0028, 0x0004}); ok {
		photometric_raw = value_text(doc, e)
	}
	photometric := pixel_photometric(photometric_raw)
	subsampled_422 := false
	frame_bytes := 0
	if bits == 1 {
		frame_bytes = (rows*cols*samples + 7) / 8
	} else if photometric == .YBR_FULL_422 && samples == 3 && .Encapsulated not_in pixel.flags {
		// PS3.5 8.2: native YBR_FULL_422 stores one CbCr pair per two pixels, i.e. two
		// bytes per pixel, not three. The decode output preserves that packed layout.
		subsampled_422 = true
		frame_bytes = rows * cols * 2
	} else {
		frame_bytes = rows * cols * samples * bps
	}
	if planar == 1 && subsampled_422 do return {}, .Unsupported_Planar_Configuration

	info = Pixel_Info{
		rows = rows,
		cols = cols,
		samples = samples,
		frames = frames,
		bits_allocated = bits,
		bits_stored = bits_stored,
		high_bit = high_bit,
		signed = signed,
		planar_configuration = planar,
		photometric = photometric,
		photometric_raw = photometric_raw,
		bytes_per_sample = bps,
		frame_bytes = frame_bytes,
		subsampled_422 = subsampled_422,
		native = .Encapsulated not_in pixel.flags,
	}
	return info, .None
}

@(private)
pixel_swap_in_place :: proc (dst: []u8, bps: int) {
	if bps != 2 && bps != 4 do return
	for i := 0; i + bps <= len(dst); i += bps {
		for a, b := i, i + bps - 1; a < b; a, b = a + 1, b - 1 {
			dst[a], dst[b] = dst[b], dst[a]
		}
	}
}

// Copies one native frame into `dst`, normalising byte order and PlanarConfiguration.
@(private)
pixel_native_frame :: proc (doc: ^Document, pixel: Element, info: Pixel_Info, frame: int, dst: []u8) -> Pixel_Error {
	raw := document_value(doc, pixel)
	need := info.frame_bytes * info.frames
	if len(raw) < need do return .Invalid_Image_Parameters
	src := raw[frame * info.frame_bytes:][:info.frame_bytes]
	if len(dst) < info.frame_bytes do return .Output_Too_Small

	big_endian := doc.ts.order == .Big
	if info.planar_configuration == 1 && info.samples > 1 {
		plane_bytes := info.frame_bytes / info.samples
		bps := info.bytes_per_sample
		for p in 0 ..< info.rows * info.cols {
			for s in 0 ..< info.samples {
				from := s * plane_bytes + p * bps
				to := (p * info.samples + s) * bps
				copy(dst[to:to + bps], src[from:from + bps])
				if big_endian && bps > 1 do pixel_swap_in_place(dst[to:to + bps], bps)
			}
		}
		return .None
	}

	copy(dst[:info.frame_bytes], src)
	if big_endian do pixel_swap_in_place(dst[:info.frame_bytes], info.bytes_per_sample)
	return .None
}

// Decodes every frame into `dst` (frame_bytes * frames bytes, caller-owned).
pixel_decode :: proc (doc: ^Document, dst: []u8) -> (written: int, err: Pixel_Error) {
	info, ierr := pixel_info(doc)
	if ierr != .None do return 0, ierr
	if len(dst) < info.frame_bytes * info.frames do return 0, .Output_Too_Small

	pixel, found := document_find(doc, TAG_PIXEL_DATA)
	if !found do return 0, .Missing_Pixel_Data

	if info.native {
		for f in 0 ..< info.frames {
			frame := dst[f * info.frame_bytes:][:info.frame_bytes]
			if e := pixel_native_frame(doc, pixel, info, f, frame); e != .None do return f * info.frame_bytes, e
		}
		return info.frame_bytes * info.frames, .None
	}

	uid := doc.ts.uid
	switch {
	case uid == RLE_UID:
		n, derr := rle_decode(doc, pixel, dst)
		if derr != RLE_Error.None do return n, .Decode_Failed
		return n, .None
	case uid == J2K_UID || uid == J2K_UID_J2K:
		n, derr := j2k_decode(doc, pixel, dst)
		if derr != .None do return n, .Decode_Failed
		return n, .None
	case uid == JPEG_LS_LOSSLESS_UID || uid == JPEG_LS_NEAR_UID:
		n, derr := jls_decode(doc, pixel, dst)
		if derr != .None do return n, .Decode_Failed
		return n, .None
	case jpeg_is_supported_uid(uid):
		n, derr := jpeg_decode(doc, pixel, dst)
		if derr != .None do return n, .Decode_Failed
		return n, .None
	}
	return 0, .Unsupported_Transfer_Syntax
}

// Decodes a single frame into `dst` (frame_bytes bytes). Works for native and encapsulated data
// so callers streaming a large series do not need a full-series buffer.
pixel_decode_frame :: proc (doc: ^Document, frame: int, dst: []u8) -> (written: int, err: Pixel_Error) {
	info, ierr := pixel_info(doc)
	if ierr != .None do return 0, ierr
	if frame < 0 || frame >= info.frames do return 0, .Invalid_Image_Parameters
	if len(dst) < info.frame_bytes do return 0, .Output_Too_Small

	pixel, found := document_find(doc, TAG_PIXEL_DATA)
	if !found do return 0, .Missing_Pixel_Data
	if info.native {
		if e := pixel_native_frame(doc, pixel, info, frame, dst); e != .None do return 0, e
		return info.frame_bytes, .None
	}

	uid := doc.ts.uid
	switch {
	case uid == RLE_UID:
		// RLE stores exactly one fragment per frame (PS3.5 Annex G); BOT item is fragments[0].
		frags := document_fragments(doc, pixel)
		if len(frags) < frame + 2 do return 0, .Invalid_Image_Parameters
		rinfo, rerr := rle_image_info(doc, pixel)
		if rerr != RLE_Error.None do return 0, .Decode_Failed
		if e := rle_decode_frame(doc, pixel, frags[frame + 1], dst, rinfo); e != RLE_Error.None {
			return 0, .Decode_Failed
		}
		return info.frame_bytes, .None
	case uid == J2K_UID || uid == J2K_UID_J2K:
		kinfo, kerr := j2k_image_info(doc, pixel)
		if kerr != .None do return 0, .Decode_Failed
		if e := j2k_decode_frame(doc, pixel, frame, dst, kinfo); e != .None do return 0, .Decode_Failed
		return info.frame_bytes, .None
	case uid == JPEG_LS_LOSSLESS_UID || uid == JPEG_LS_NEAR_UID:
		linfo, lerr := jls_image_info(doc, pixel)
		if lerr != .None do return 0, .Decode_Failed
		if e := jls_decode_frame(doc, pixel, frame, dst, linfo); e != .None do return 0, .Decode_Failed
		return info.frame_bytes, .None
	case jpeg_is_supported_uid(uid):
		pinfo, perr := jpeg_image_info(doc, pixel)
		if perr != .None do return 0, .Decode_Failed
		if e := jpeg_decode_frame(doc, pixel, frame, dst, pinfo); e != .None do return 0, .Decode_Failed
		return info.frame_bytes, .None
	}
	return 0, .Unsupported_Transfer_Syntax
}

// Convenience: big-endian host order is not what DICOM native pixel data uses, but callers on
// big-endian targets need the raw bytes; this reads one normalized sample back.
pixel_sample_u32 :: proc (dst: []u8, index, bps: int) -> u32 {
	if index < 0 do return 0
	off := index * bps
	if off < 0 || off + bps > len(dst) do return 0
	switch bps {
	case 1:
		return u32(dst[off])
	case 2:
		v, _ := endian.get_u16(dst[off:][:2], .Little)
		return u32(v)
	case 4:
		v, _ := endian.get_u32(dst[off:][:4], .Little)
		return v
	}
	return 0
}
