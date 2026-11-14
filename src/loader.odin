package nautilus

// Task 6 (M1): the CPU half of "open one file and get pixels".
//
// `load_frame_cpu` is the whole path short of the GPU upload: open the
// file, extract pixel metadata + VOI/rescale/spacing, decode frame 0,
// and run it through the 64K LUT into an RGBA8 buffer. It touches no
// Skald or Vulkan state, which is what makes `--self-test` able to
// exercise the real code instead of a parallel implementation.

import "core:encoding/endian"
import "core:fmt"
import "core:strings"
import d "../vendor/dicom"

TAG_RESCALE_SLOPE :: d.Tag{0x0028, 0x1053}
TAG_RESCALE_INTERCEPT :: d.Tag{0x0028, 0x1052}
TAG_WINDOW_CENTER :: d.Tag{0x0028, 0x1050}
TAG_WINDOW_WIDTH :: d.Tag{0x0028, 0x1051}
TAG_PIXEL_SPACING :: d.Tag{0x0028, 0x0030}

// dataset_window reads the stored VOI + rescale from the document.
// `valid_window` is false when the dataset carries no WindowCenter /
// WindowWidth, i.e. the caller must derive one from frame statistics.
dataset_window :: proc(doc: ^d.Document, info: d.Pixel_Info) -> d.Render_Options {
	opts: d.Render_Options
	if e, ok := d.document_find(doc, TAG_RESCALE_SLOPE); ok {
		if v, vok := d.value_ds(doc, e); vok {
			opts.slope = v
			opts.valid_window = opts.valid_window // intercept supplies the rest
		}
	}
	if e, ok := d.document_find(doc, TAG_RESCALE_INTERCEPT); ok {
		if v, vok := d.value_ds(doc, e); vok {
			opts.intercept = v
		}
	}
	e_c, ok_c := d.document_find(doc, TAG_WINDOW_CENTER)
	e_w, ok_w := d.document_find(doc, TAG_WINDOW_WIDTH)
	if ok_c && ok_w {
		c, cok := d.value_ds(doc, e_c)
		w, wok := d.value_ds(doc, e_w)
		if cok && wok {
			opts.center = c
			opts.width = w
			opts.valid_window = true
		}
	}
	opts.invert = info.photometric == .Monochrome1
	return opts
}

TAG_IMAGER_PIXEL_SPACING :: d.Tag{0x0018, 0x1164}

frame_spacing :: proc(doc: ^d.Document) -> (spacing: [2]f64, kind: Spacing_Kind) {
	if e, found := d.document_find(doc, TAG_PIXEL_SPACING); found {
		r, rok := d.value_ds(doc, e, 0)
		c, cok := d.value_ds(doc, e, 1)
		if rok && cok && r > 0 && c > 0 do return {r, c}, .Pixel_Spacing
	}
	if e, found := d.document_find(doc, TAG_IMAGER_PIXEL_SPACING); found {
		r, rok := d.value_ds(doc, e, 0)
		c, cok := d.value_ds(doc, e, 1)
		if rok && cok && r > 0 && c > 0 do return {r, c}, .Imager_Spacing
	}
	return {}, .None
}

// load_frame_cpu runs the full open → decode → LUT path for one file and
// returns a heap-owned Cached_Frame. `ctx` is only used for the frame's
// stable key string. Returns nil plus a message on failure.
load_frame_cpu :: proc(file: string) -> (frame: ^Cached_Frame, err: string) {
	doc: d.Document
	d.document_init(&doc)
	defer d.document_destroy(&doc)

	// Full parse: pixel_info needs the PixelData element itself, and
	// stop_before_tag stops *before* it. odin-dcm parses a 690-file study
	// in 110 ms, so a single file's parse does not need early stopping.
	if perr := d.document_open_file(&doc, file); perr != .None {
		return nil, fmt.aprintf("open failed: %v", perr)
	}
	info, ierr := d.pixel_info(&doc)
	if ierr != .None {
		return nil, fmt.aprintf("pixel_info failed: %v", ierr)
	}
	if info.frame_bytes <= 0 || info.frames <= 0 {
		return nil, fmt.aprintf("no decodable frame")
	}

	raw := make([]u8, info.frame_bytes)
	written, derr := d.pixel_decode_frame(&doc, 0, raw)
	if derr != .None || written != info.frame_bytes {
		delete(raw)
		return nil, fmt.aprintf("decode failed: %v (%d/%d bytes)", derr, written, info.frame_bytes)
	}

	// 1-bit native data stays packed (dicom's docs say so outright), and no
	// renderer unpacks it. Expand to one byte per pixel here so the LUT path
	// and the probe both see ordinary 8-bit samples.
	if info.bits_allocated == 1 {
		unpacked := make([]u8, info.rows * info.cols)
		for i in 0 ..< len(unpacked) {
			if i / 8 < len(raw) {
				unpacked[i] = (raw[i / 8] >> u8(7 - i % 8)) & 1
			}
		}
		delete(raw)
		raw = unpacked
		info.bits_allocated = 8
		info.bits_stored = 1
		info.bytes_per_sample = 1
		info.frame_bytes = len(unpacked)
	}

	opts := dataset_window(&doc, info)
	if !opts.valid_window {
		c, w := lut_auto_window(info, raw)
		opts.center, opts.width = c, w
		opts.valid_window = true
	}

	f := new(Cached_Frame)
	f.key = Frame_Key{file = strings.clone(file), frame = 0}
	f.info = info
	f.raw = raw
	f.rescale = Rescale{slope = opts.slope, intercept = opts.intercept, valid = opts.slope != 0}
	f.window = opts
	// Palette LUT slices point into the document's mmap, which
	// document_destroy unmaps; copy them onto the heap.
	if info.photometric == .Palette_Color {
		pal := palette_lut_local(&doc)
		if pal.valid {
			f.palette = d.Palette{
				red   = make([]u8, len(pal.red)),
				green = make([]u8, len(pal.green)),
				blue  = make([]u8, len(pal.blue)),
				entries = pal.entries,
				first = pal.first,
				entry_bytes = pal.entry_bytes,
				valid = true,
			}
			copy(f.palette.red, pal.red)
			copy(f.palette.green, pal.green)
			copy(f.palette.blue, pal.blue)
		}
	}

	if sp, skind := frame_spacing(&doc); skind != .None {
		f.pixel_spacing = sp
		f.has_spacing = true
		f.spacing_kind = skind
	}
	return f, ""
}

// palette_lut_local reads the three palette descriptors and their LUTs.
// odin-dcm's palette_lut goes through value_u64, which has no US_SS case —
// and the descriptors are spelled US_SS by every real writer — so it
// returns an invalid palette for exactly the files that need it.
palette_lut_local :: proc(doc: ^d.Document) -> (p: d.Palette) {
	descriptors: [3][3]int
	for tag, k in ([3]d.Tag{{0x0028, 0x1101}, {0x0028, 0x1102}, {0x0028, 0x1103}}) {
		de, ok := d.document_find(doc, tag)
		if !ok do return
		raw := d.document_value(doc, de)
		if len(raw) < 6 do return
		for j in 0 ..< 3 {
			off := j * 2
			v, _ := endian.get_u16(raw[off:off + 2], doc.ts.order)
			descriptors[k][j] = int(v)
		}
	}
	entries := descriptors[0][0]
	first := descriptors[0][1]
	bits := descriptors[0][2]
	for k in 1 ..< 3 {
		if descriptors[k][0] != entries || descriptors[k][1] != first || descriptors[k][2] != bits do return
	}
	entry_bytes := 0
	switch bits {
	case 8: entry_bytes = 1
	case 16, 0: entry_bytes = 2
	case 32: entry_bytes = 4
	case: return
	}
	if entries <= 0 {
		// Segmented descriptors are often written as [0,0,16] with the real
		// count implied by the bit depth; 8-bit indices cap it at 256.
		if _, has_direct := d.document_find(doc, d.Tag{0x0028, 0x1201}); !has_direct {
			return palette_lut_segmented(doc, 256, first)
		}
		return
	}

	for tag, k in ([3]d.Tag{{0x0028, 0x1201}, {0x0028, 0x1202}, {0x0028, 0x1203}}) {
		e, ok := d.document_find(doc, tag)
		if !ok {
			// Fall back to the segmented encoding (0028,1221..1223), which
			// stores runs as [0, count, value] per PS3.3 C.7.6.3.1.4.
			return palette_lut_segmented(doc, entries, first)
		}
		v := d.document_value(doc, e)
		if len(v) < entries * entry_bytes do return
		switch k {
		case 0: p.red = v
		case 1: p.green = v
		case 2: p.blue = v
		}
	}
	p.entries, p.first, p.entry_bytes = entries, first, entry_bytes
	p.valid = true
	return
}

// palette_lut_segmented decodes the segmented palette encoding into the
// same one-byte-per-entry slices the direct encoding produces.
palette_lut_segmented :: proc(doc: ^d.Document, entries, first: int) -> (p: d.Palette) {
	red := make([]u8, entries)
	green := make([]u8, entries)
	blue := make([]u8, entries)
	for tag, k in ([3]d.Tag{{0x0028, 0x1221}, {0x0028, 0x1222}, {0x0028, 0x1223}}) {
		e, ok := d.document_find(doc, tag)
		if !ok {
			delete(red); delete(green); delete(blue)
			return
		}
		seg := d.document_value(doc, e)
		dst := red
		switch k {
		case 1: dst = green
		case 2: dst = blue
		}
		// Each segment is 6 bytes: [0, 0, count_u16, value, 0].
		out, i := 0, 0
		for i + 5 < len(seg) && out < entries {
			count := int(u16(seg[i + 2]) | u16(seg[i + 3]) << 8)
			value := seg[i + 4]
			for _ in 0 ..< max(count, 1) {
				if out >= entries do break
				dst[out] = value
				out += 1
			}
			i += 6
		}
	}
	p = d.Palette{red = red, green = green, blue = blue,
		entries = entries, first = first, entry_bytes = 1, valid = true}
	return
}

// frame_to_rgba renders a cached frame into RGBA8 `dst` (rows*cols*4).
//
// MONOCHROME 8/16-bit takes the 64K LUT fast path. Everything else —
// RGB, YBR, palette, 32-bit, 1-bit — falls back to odin-dcm's reference
// renderers per spec §4.3, so a colour file still displays.
frame_to_rgba :: proc(f: ^Cached_Frame, opts: d.Render_Options, dst: []u8) -> bool {
	info := f.info
	pixels := info.rows * info.cols
	if pixels <= 0 || len(dst) < pixels * 4 do return false

	#partial switch info.photometric {
	case .Monochrome1, .Monochrome2:
		if info.samples == 1 && info.bytes_per_sample <= 2 {
			lut := build_lut(info, opts)
			return apply_lut(&lut, info, f.raw, dst)
		}
	}

	// Reference path: render into a 3-byte RGB buffer, then expand.
	rgb := make([]u8, pixels * 3, context.temp_allocator)
	ok := false
	#partial switch info.photometric {
	case .Palette_Color:
		// render_palette8 takes one index byte per pixel. 16-bit palette
		// images exist (indices up to 64512 in the ALOKA sample), so map each
		// index to its LUT position rather than truncating the low byte.
		idx := f.raw
		if info.bytes_per_sample > 1 {
			narrow := make([]u8, pixels, context.temp_allocator)
			for i in 0 ..< pixels {
				off := i * info.bytes_per_sample
				v: u16 = 0
				if off + 1 < len(f.raw) do v = u16(f.raw[off]) | u16(f.raw[off + 1]) << 8
				// 16-bit palettes store the index scaled into a 16-bit word
				// (0, 1024, 2048, ... in the ALOKA sample), so the LUT slot
				// is the high byte.
				n := int(v)>>8 - f.palette.first
				narrow[i] = u8(clamp(n, 0, 255))
			}
			idx = narrow
		}
		ok = d.render_palette8(f.palette, idx, rgb, pixels)
	case:
		if info.samples >= 3 {
			ok = d.render_rgb8(info, f.raw, rgb, opts)
		} else {
			// 32-bit or 1-bit monochrome: render_gray8 handles the width.
			ok = d.render_gray8(info, f.raw, rgb[:pixels], opts)
		}
	}
	if !ok do return false

	for i in 0 ..< pixels {
		dst[i * 4 + 0] = rgb[i * 3 + 0]
		dst[i * 4 + 1] = rgb[i * 3 + 1]
		dst[i * 4 + 2] = rgb[i * 3 + 2]
		dst[i * 4 + 3] = 255
	}
	return true
}
