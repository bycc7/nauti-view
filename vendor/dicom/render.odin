package dicom

import "core:encoding/endian"
import "core:math"

// T7: display transform. Decoding produces stored samples; this layer applies the DICOM
// display pipeline (bits-stored mask, sign extension, rescale, VOI window, MONOCHROME1
// inversion) so every consumer renders the same bytes.

Render_Options :: struct {
	center:       f64,
	width:        f64,
	valid_window: bool, // false -> min/max stretch over the frame
	invert:       bool,
	slope:        f64, // 0 means "no rescale"
	intercept:    f64,
}

// Reads one sample as stored (little-endian, as produced by pixel_decode).
@(private)
render_sample :: proc (src: []u8, index, bps: int) -> i64 {
	off := index * bps
	if off + bps > len(src) do return 0
	switch bps {
	case 1:
		return i64(src[off])
	case 2:
		return i64(u16(src[off]) | u16(src[off + 1]) << 8)
	case 4:
		return i64(u32(src[off]) | u32(src[off + 1]) << 8 | u32(src[off + 2]) << 16 | u32(src[off + 3]) << 24)
	}
	return 0
}

@(private)
render_normalize :: proc (raw: i64, info: Pixel_Info) -> f64 {
	v := raw
	if info.bits_stored > 0 && info.bits_stored < 64 {
		v &= i64((u64(1) << u32(info.bits_stored)) - 1)
		if info.signed {
			sign := i64(u64(1) << u32(info.bits_stored - 1))
			if v & sign != 0 do v -= i64(u64(1) << u32(info.bits_stored))
		}
	}
	return f64(v)
}

@(private)
render_map :: proc (v, center, width: f64) -> u8 {
	if width < 1 do return u8(255) if v > center else u8(0)
	y := ((v - (center - 0.5)) / (width - 1) + 0.5) * 255
	if y <= 0 do return 0
	if y >= 255 do return 255
	return u8(y + 0.5)
}

// Renders one MONOCHROME frame into 8-bit gray. `src` is a decoded frame (little-endian,
// interleaved); `dst` must hold rows*cols bytes.
render_gray8 :: proc (info: Pixel_Info, src: []u8, dst: []u8, opts: Render_Options) -> bool {
	pixels := info.rows * info.cols
	if pixels <= 0 || len(dst) < pixels do return false
	bps := info.bytes_per_sample

	slope, intercept := 1.0, 0.0
	if opts.slope != 0 do slope = opts.slope
	intercept = opts.intercept

	center, width := opts.center, opts.width
	valid := opts.valid_window
	if !valid {
		lo, hi := math.INF_F64, -math.INF_F64
		for i in 0 ..< pixels {
			v := render_normalize(render_sample(src, i, bps), info) * slope + intercept
			if v < lo do lo = v
			if v > hi do hi = v
		}
		if hi <= lo {
			center, width = lo, 1
		} else {
			center, width = (lo + hi) / 2, hi - lo + 1
		}
	}

	for i in 0 ..< pixels {
		v := render_normalize(render_sample(src, i, bps), info) * slope + intercept
		y := render_map(v, center, width)
		if opts.invert do y = 255 - y
		dst[i] = y
	}
	return true
}

// Renders an RGB frame. 8-bit samples pass through; wider samples are reduced by the same
// VOI window, applied per channel.
render_rgb8 :: proc (info: Pixel_Info, src: []u8, dst: []u8, opts: Render_Options) -> bool {
	pixels := info.rows * info.cols
	bps := info.bytes_per_sample
	if pixels <= 0 || len(dst) < pixels * 3 do return false
	if bps == 1 && !opts.valid_window && opts.slope == 0 {
		copy(dst[:pixels * 3], src[:pixels * 3])
		return true
	}
	for i in 0 ..< pixels * 3 {
		v := render_normalize(render_sample(src, i, bps), info)
		dst[i] = render_map(v, opts.center, opts.width) if opts.valid_window else u8(clamp(v, 0, 255))
	}
	return true
}

// Expands native YBR_FULL_422 (two bytes per pixel: Y0 Y1 Cb Cr) to interleaved RGB using
// the full-range BT.601 matrix, matching what pydicom shows for the same file.
render_expand_ybr422 :: proc (src: []u8, dst: []u8, pixels: int) -> bool {
	if pixels <= 0 || len(src) < pixels * 2 || len(dst) < pixels * 3 do return false
	i := 0
	for p := 0; p < pixels; p += 2 {
		y0 := f64(src[i])
		y1 := f64(src[i + 1])
		cb := f64(src[i + 2]) - 128
		cr := f64(src[i + 3]) - 128
		i += 4
		r := 1.402 * cr
		g := -0.344136 * cb - 0.714136 * cr
		b := 1.772 * cb
		for k in 0 ..< 2 {
			y := y0 if k == 0 else y1
			dst[(p + k) * 3 + 0] = u8(clamp(y + r + 0.5, 0, 255))
			dst[(p + k) * 3 + 1] = u8(clamp(y + g + 0.5, 0, 255))
			dst[(p + k) * 3 + 2] = u8(clamp(y + b + 0.5, 0, 255))
		}
	}
	return true
}

// Palette lookup tables for PALETTE COLOR images, as slices into the document.
Palette :: struct {
	red, green, blue: []u8,
	entries:          int, // descriptor value 0
	first:            int, // descriptor value 1: first mapped pixel value
	entry_bytes:      int, // 1, 2 or 4 (16- and 32-bit LUTs are reduced to 8 bits)
	valid:            bool,
}

@(private)
palette_entry :: proc (data: []u8, index, entry_bytes: int) -> u8 {
	off := index * entry_bytes
	if off < 0 || off + entry_bytes > len(data) do return 0
	switch entry_bytes {
	case 1:
		return data[off]
	case 2:
		// LUT entries are little-endian; the 8-bit display value is the high byte.
		v, _ := endian.get_u16(data[off:][:2], .Little)
		return u8(v >> 8)
	case 4:
		v, _ := endian.get_u32(data[off:][:4], .Little)
		return u8(v >> 24)
	}
	return 0
}

palette_lut :: proc (doc: ^Document) -> (p: Palette) {
	descriptors: [3][3]int
	for tag, k in ([3]Tag{{0x0028, 0x1101}, {0x0028, 0x1102}, {0x0028, 0x1103}}) {
		de, ok := document_find(doc, tag)
		if !ok do return
		for j in 0 ..< 3 {
			u, uok := value_u64(doc, de, j)
			if !uok do return
			descriptors[k][j] = int(u)
		}
	}
	// (NumberOfEntries, FirstMappedPixelValue, BitsPerEntry); 0 is a legacy spelling of 16.
	entries := descriptors[0][0]
	first := descriptors[0][1]
	bits := descriptors[0][2]
	for k in 1 ..< 3 {
		if descriptors[k][0] != entries || descriptors[k][1] != first || descriptors[k][2] != bits do return
	}
	entry_bytes := 0
	switch bits {
	case 8:
		entry_bytes = 1
	case 16, 0:
		entry_bytes = 2
	case 32:
		entry_bytes = 4
	case:
		return
	}
	if entries <= 0 do return

	for tag, k in ([3]Tag{{0x0028, 0x1201}, {0x0028, 0x1202}, {0x0028, 0x1203}}) {
		e, ok := document_find(doc, tag)
		if !ok do return
		v := document_value(doc, e)
		if len(v) < entries * entry_bytes do return
		switch k {
		case 0:
			p.red = v
		case 1:
			p.green = v
		case 2:
			p.blue = v
		}
	}
	p.entries, p.first, p.entry_bytes = entries, first, entry_bytes
	p.valid = true
	return
}

// Maps 8-bit palette indices to RGB. `dst` must hold pixels*3 bytes.
render_palette8 :: proc (p: Palette, src: []u8, dst: []u8, pixels: int) -> bool {
	if !p.valid || len(src) < pixels || len(dst) < pixels * 3 do return false
	for i in 0 ..< pixels {
		idx := int(src[i]) - p.first
		if idx < 0 || idx >= p.entries {
			dst[i * 3 + 0] = 0
			dst[i * 3 + 1] = 0
			dst[i * 3 + 2] = 0
			continue
		}
		dst[i * 3 + 0] = palette_entry(p.red, idx, p.entry_bytes)
		dst[i * 3 + 1] = palette_entry(p.green, idx, p.entry_bytes)
		dst[i * 3 + 2] = palette_entry(p.blue, idx, p.entry_bytes)
	}
	return true
}

// Reads (0028,1050)/(0028,1051) when present; first value wins for multi-valued attributes.
dataset_window :: proc (doc: ^Document) -> (center, width: f64, ok: bool) {
	ce, cok := document_find(doc, Tag{0x0028, 0x1050})
	we, wok := document_find(doc, Tag{0x0028, 0x1051})
	if !cok || !wok do return 0, 0, false
	c, cparse := value_ds(doc, ce, 0)
	w, wparse := value_ds(doc, we, 0)
	if !cparse || !wparse do return 0, 0, false
	return c, w, true
}
