package dicom



// Step 9: JPEG decoding for encapsulated DICOM pixel data.
//
// Syntaxes:
//   1.2.840.10008.1.2.4.50  JPEG Baseline (Process 1), 8-bit        SOF0
//   1.2.840.10008.1.2.4.51  JPEG Extended (Process 2/4), 8/12-bit   SOF0/SOF1
//   1.2.840.10008.1.2.4.57  JPEG Lossless (Process 14)              SOF3
//   1.2.840.10008.1.2.4.70  JPEG Lossless SV1 (Process 14 SV1)      SOF3
//
// Ported from libjpeg-turbo 3.0.4 (jdhuff.c, jdlhuff.c, jdlossls.c, jidctint.c,
// jdsample.c; BSD-style IJG/zlib licences): canonical Huffman decoding, sequential
// DCT and lossless predictor reconstruction, integer "islow" IDCT, libjpeg's fancy
// h2v1/h2v2 upsampling. Progressive (SOF2) and arithmetic coding are rejected.

JPEG_BASELINE_UID :: "1.2.840.10008.1.2.4.50"
JPEG_EXTENDED_UID :: "1.2.840.10008.1.2.4.51"
JPEG_LOSSLESS_UID :: "1.2.840.10008.1.2.4.57"
JPEG_LOSSLESS_SV1_UID :: "1.2.840.10008.1.2.4.70"

JPEG_Error :: enum u8 {
	None = 0,
	Not_JPEG_Transfer_Syntax,
	Not_Encapsulated,
	Missing_Image_Attributes,
	Invalid_Image_Parameters,
	Bad_Codestream,
	Unsupported_Feature,
	Out_Of_Memory,
	Output_Too_Small,
}

JPEG_Image :: struct {
	rows:             int,
	cols:             int,
	samples:          int,
	bits:             int,
	signed:           bool,
	frames:           int,
	bytes_per_sample: int,
	frame_bytes:      int,
}

@(private) JPEG_MAX_COMPONENTS :: 4
@(private) JPEG_MAX_HUFF_TABLES :: 4

// ---------------------------------------------------------------------------------------------
// Bit reader with JPEG byte stuffing (0xFF 0x00) and marker detection.
// ---------------------------------------------------------------------------------------------

@(private)
JPEG_Bits :: struct {
	data:        []u8,
	pos:         int,
	buf:         u32,
	nbits:       int, // bits left in buf
	marker:      int, // 0, or 0xFF00|code when a marker stopped the stream
	at_marker:   bool,
}

@(private)
jbits_init :: proc "contextless" (b: ^JPEG_Bits, data: []u8, pos: int) {
	b.data = data
	b.pos = pos
	b.buf = 0
	b.nbits = 0
	b.marker = 0
	b.at_marker = false
}

// Reads one byte, honouring 0xFF00 stuffing. Returns -1 at EOF or at a real marker,
// recording the marker (the cursor is left at the marker's 0xFF).
@(private)
jbits_next_byte :: proc "contextless" (b: ^JPEG_Bits) -> int {
	if b.at_marker do return -1
	if b.pos >= len(b.data) {
		b.at_marker = true
		return -1
	}
	v := int(b.data[b.pos])
	b.pos += 1
	if v == 0xFF {
		if b.pos >= len(b.data) {
			b.at_marker = true
			return -1
		}
		nxt := int(b.data[b.pos])
		if nxt == 0x00 {
			b.pos += 1
			return 0xFF
		}
		// Real marker: leave the cursor on the 0xFF so the caller can parse it.
		b.pos -= 1
		b.marker = 0xFF00 | nxt
		b.at_marker = true
		return -1
	}
	return v
}

// Returns n (<= 16) bits MSB-first, or -1 when the stream is exhausted.
@(private)
jbits_get :: proc "contextless" (b: ^JPEG_Bits, n: int) -> int {
	for b.nbits < n {
		v := jbits_next_byte(b)
		if v < 0 do return -1
		b.buf = (b.buf << 8) | u32(v)
		b.nbits += 8
	}
	b.nbits -= n
	return int((b.buf >> u32(b.nbits)) & ((1 << u32(n)) - 1))
}

// Discards the partial byte and consumes one restart marker (RST0..RST7).
@(private)
jbits_restart :: proc "contextless" (b: ^JPEG_Bits) -> bool {
	b.nbits = 0
	b.buf = 0
	b.at_marker = false
	b.marker = 0
	// Skip fill bytes, then require FF D0..D7.
	for b.pos + 1 < len(b.data) && b.data[b.pos] != 0xFF {
		b.pos += 1
	}
	if b.pos + 1 >= len(b.data) do return false
	if b.data[b.pos] != 0xFF do return false
	if b.data[b.pos + 1] < 0xD0 || b.data[b.pos + 1] > 0xD7 do return false
	b.pos += 2
	return true
}

// ---------------------------------------------------------------------------------------------
// Canonical Huffman tables (T.81 F.2.2.3).
// ---------------------------------------------------------------------------------------------

@(private)
JPEG_Huff :: struct {
	valid:    bool,
	mincode:  [17]i32,
	maxcode:  [18]i32,
	valptr:   [17]i32,
	values:   [256]u8,
	nvalues:  int,
}

@(private)
jpeg_build_huff :: proc (h: ^JPEG_Huff, counts: []u8, values: []u8) -> bool {
	h.valid = true
	h.nvalues = 0
	code: i32 = 0
	k: i32 = 0
	for l in 1 ..= 16 {
		n := i32(counts[l - 1])
		if n > 0 {
			h.valptr[l] = k
			h.mincode[l] = code
			for i in 0 ..< int(n) {
				if k + i32(i) >= 256 do return false
				h.values[k + i32(i)] = values[k + i32(i)]
			}
			k += n
			code += n
			h.maxcode[l] = code - 1
		} else {
			h.maxcode[l] = -1
		}
		if code > (1 << u32(l)) do return false
		code <<= 1
	}
	h.maxcode[17] = 0xFFFFF
	h.nvalues = int(k)
	return int(k) == len(values)
}

// Decodes one symbol; returns -1 on stream end or an invalid code.
@(private)
jpeg_huff_decode :: proc "contextless" (h: ^JPEG_Huff, b: ^JPEG_Bits) -> int {
	code: i32 = 0
	for l in 1 ..= 16 {
		bit := jbits_get(b, 1)
		if bit < 0 do return -1
		code = (code << 1) | i32(bit)
		if code <= h.maxcode[l] {
			idx := h.valptr[l] + (code - h.mincode[l])
			if idx < 0 || int(idx) >= h.nvalues do return -1
			return int(h.values[idx])
		}
	}
	return -1
}

@(private)
jpeg_extend :: proc "contextless" (v: int, s: int) -> int {
	if s <= 0 do return 0
	if v < (1 << u32(s - 1)) {
		return v - ((1 << u32(s)) - 1)
	}
	return v
}

// ---------------------------------------------------------------------------------------------
// Frame / component state.
// ---------------------------------------------------------------------------------------------

@(private)
JPEG_Comp :: struct {
	id:       int,
	h:        int,
	v:        int,
	tq:       int,
	td:       int,
	ta:       int,
	width:    int,
	height:   int,
	plane:      []u8, // component samples at component resolution, 16-bit LE
	diff_plane: []i32, // lossless sample differences
	first_row:  []bool, // lossless: row starts a prediction interval
}

@(private)
JPEG_Frame :: struct {
	sof:        int, // marker code of the frame header (0xC0, 0xC1, 0xC3)
	precision:  int,
	width:      int,
	height:     int,
	ncomp:      int,
	comps:      [JPEG_MAX_COMPONENTS]JPEG_Comp,
	max_h:      int,
	max_v:      int,
	lossless:   bool,
	quant:      [4][64]i32,
	quant_ok:   [4]bool,
	dc_tables:  [JPEG_MAX_HUFF_TABLES]JPEG_Huff,
	ac_tables:  [JPEG_MAX_HUFF_TABLES]JPEG_Huff,
	restart_interval: int,
	last_predictor: int, // SOF3: Ss from the most recent SOS
	last_al:        int,
}

@(private)
jpeg_component_index :: proc "contextless" (f: ^JPEG_Frame, id: int) -> int {
	for i in 0 ..< f.ncomp {
		if f.comps[i].id == id do return i
	}
	return -1
}

@(private)
jpeg_alloc_planes :: proc (f: ^JPEG_Frame) -> JPEG_Error {
	for i in 0 ..< f.ncomp {
		c := &f.comps[i]
		c.width = (f.width * c.h + f.max_h - 1) / f.max_h
		c.height = (f.height * c.v + f.max_v - 1) / f.max_v
		c.plane = make([]u8, c.width * c.height * 2) // 16-bit samples
		c.first_row = make([]bool, c.height)
	}
	return .None
}

@(private)
jpeg_frame_destroy :: proc (f: ^JPEG_Frame) {
	for i in 0 ..< f.ncomp {
		c := &f.comps[i]
		if c.plane != nil do delete(c.plane)
		if c.diff_plane != nil do delete(c.diff_plane)
		if c.first_row != nil do delete(c.first_row)
		c.plane = nil
		c.diff_plane = nil
		c.first_row = nil
	}
}

@(private)
jpeg_get_sample :: proc "contextless" (c: ^JPEG_Comp, x, y: int) -> int {
	i := (y * c.width + x) * 2
	return int(c.plane[i]) | (int(c.plane[i + 1]) << 8)
}

@(private)
jpeg_put_sample :: proc "contextless" (c: ^JPEG_Comp, x, y, v: int) {
	i := (y * c.width + x) * 2
	c.plane[i] = u8(v & 0xFF)
	c.plane[i + 1] = u8((v >> 8) & 0xFF)
}

// ---------------------------------------------------------------------------------------------
// Integer IDCT ("islow"), ported from jidctint.c.
// ---------------------------------------------------------------------------------------------

@(private) FIX_0_298631336 :: i64(2446)
@(private) FIX_0_390180644 :: i64(3196)
@(private) FIX_0_541196100 :: i64(4433)
@(private) FIX_0_765366865 :: i64(6270)
@(private) FIX_0_899976223 :: i64(7373)
@(private) FIX_1_175875602 :: i64(9633)
@(private) FIX_1_501321110 :: i64(12299)
@(private) FIX_1_847759065 :: i64(15137)
@(private) FIX_1_961570560 :: i64(16069)
@(private) FIX_2_053119869 :: i64(16819)
@(private) FIX_2_562915447 :: i64(20995)
@(private) FIX_3_072711026 :: i64(25172)

@(private)
JPEG_ZIGZAG := [64]u8{
	0,  1,  8,  16, 9,  2,  3,  10,
	17, 24, 32, 25, 18, 11, 4,  5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13, 6,  7,  14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63,
}

// Dequantizes and inverse-DCTs one block into `out` (8x8, row-major), porting
// libjpeg's "islow" integer path (jidctint.c). MULTIPLY here is a plain 32-bit
// product; the CONST_BITS descale happens only in the final stage.
@(private)
idct_mult :: proc "contextless" (x, c: i64) -> i64 {
	return x * c
}

@(private)
idct_descare :: proc "contextless" (x: i64, n: int) -> i64 {
	return (x + (1 << u32(n - 1))) >> u32(n)
}

@(private)
jpeg_idct_islow :: proc "contextless" (
	coef: ^[64]i32,
	quant: ^[64]i32,
	maxval: int,
	center: int,
	pass1_bits: int,
	out: ^[64]i32,
) {
	// Pass 1: columns (results scaled by sqrt(8) * 2^PASS1_BITS).
	const_bits := i64(13)
	ws: [64]i64
	for ctr in 0 ..< 8 {
		base := ctr
		if coef[base + 8 * 1] == 0 && coef[base + 8 * 2] == 0 && coef[base + 8 * 3] == 0 &&
		   coef[base + 8 * 4] == 0 && coef[base + 8 * 5] == 0 && coef[base + 8 * 6] == 0 &&
		   coef[base + 8 * 7] == 0 {
			dc := i64(coef[base]) * i64(quant[base]) << u32(pass1_bits)
			for r in 0 ..< 8 do ws[r * 8 + ctr] = dc
			continue
		}
		z2 := i64(coef[base + 8 * 2]) * i64(quant[base + 8 * 2])
		z3 := i64(coef[base + 8 * 6]) * i64(quant[base + 8 * 6])
		z1 := idct_mult(z2 + z3, FIX_0_541196100)
		tmp2 := z1 + idct_mult(z3, -FIX_1_847759065)
		tmp3 := z1 + idct_mult(z2, FIX_0_765366865)
		z2 = i64(coef[base]) * i64(quant[base])
		z3 = i64(coef[base + 8 * 4]) * i64(quant[base + 8 * 4])
		tmp0 := (z2 + z3) << u32(const_bits)
		tmp1 := (z2 - z3) << u32(const_bits)
		tmp10 := tmp0 + tmp3
		tmp13 := tmp0 - tmp3
		tmp11 := tmp1 + tmp2
		tmp12 := tmp1 - tmp2

		t0 := i64(coef[base + 8 * 7]) * i64(quant[base + 8 * 7])
		t1 := i64(coef[base + 8 * 5]) * i64(quant[base + 8 * 5])
		t2 := i64(coef[base + 8 * 3]) * i64(quant[base + 8 * 3])
		t3 := i64(coef[base + 8 * 1]) * i64(quant[base + 8 * 1])
		z1 = t0 + t3
		z2 = t1 + t2
		z3 = t0 + t2
		z4 := t1 + t3
		z5 := idct_mult(z3 + z4, FIX_1_175875602)
		t0 = idct_mult(t0, FIX_0_298631336)
		t1 = idct_mult(t1, FIX_2_053119869)
		t2 = idct_mult(t2, FIX_3_072711026)
		t3 = idct_mult(t3, FIX_1_501321110)
		z1 = idct_mult(z1, -FIX_0_899976223)
		z2 = idct_mult(z2, -FIX_2_562915447)
		z3 = idct_mult(z3, -FIX_1_961570560)
		z4 = idct_mult(z4, -FIX_0_390180644)
		z3 += z5
		z4 += z5
		t0 += z1 + z3
		t1 += z2 + z4
		t2 += z2 + z3
		t3 += z1 + z4
		shift := int(const_bits) - pass1_bits
		ws[0 * 8 + ctr] = idct_descare(tmp10 + t3, shift)
		ws[7 * 8 + ctr] = idct_descare(tmp10 - t3, shift)
		ws[1 * 8 + ctr] = idct_descare(tmp11 + t2, shift)
		ws[6 * 8 + ctr] = idct_descare(tmp11 - t2, shift)
		ws[2 * 8 + ctr] = idct_descare(tmp12 + t1, shift)
		ws[5 * 8 + ctr] = idct_descare(tmp12 - t1, shift)
		ws[3 * 8 + ctr] = idct_descare(tmp13 + t0, shift)
		ws[4 * 8 + ctr] = idct_descare(tmp13 - t0, shift)
	}

	// Pass 2: rows (descale to samples, add the DC centre, clip).
	for r in 0 ..< 8 {
		b := r * 8
		if ws[b + 1] == 0 && ws[b + 2] == 0 && ws[b + 3] == 0 && ws[b + 4] == 0 &&
		   ws[b + 5] == 0 && ws[b + 6] == 0 && ws[b + 7] == 0 {
			dc := idct_descare(ws[b], pass1_bits + 3) + i64(center)
			for x in 0 ..< 8 do out[b + x] = clamp_i32_val(dc, maxval)
			continue
		}
		z2 := ws[b + 2]
		z3 := ws[b + 6]
		z1 := idct_mult(z2 + z3, FIX_0_541196100)
		tmp2 := z1 + idct_mult(z3, -FIX_1_847759065)
		tmp3 := z1 + idct_mult(z2, FIX_0_765366865)
		tmp0 := (ws[b] + ws[b + 4]) << u32(const_bits)
		tmp1 := (ws[b] - ws[b + 4]) << u32(const_bits)
		tmp10 := tmp0 + tmp3
		tmp13 := tmp0 - tmp3
		tmp11 := tmp1 + tmp2
		tmp12 := tmp1 - tmp2
		t0 := ws[b + 7]
		t1 := ws[b + 5]
		t2 := ws[b + 3]
		t3 := ws[b + 1]
		z1 = t0 + t3
		z2 = t1 + t2
		z3 = t0 + t2
		z4 := t1 + t3
		z5 := idct_mult(z3 + z4, FIX_1_175875602)
		t0 = idct_mult(t0, FIX_0_298631336)
		t1 = idct_mult(t1, FIX_2_053119869)
		t2 = idct_mult(t2, FIX_3_072711026)
		t3 = idct_mult(t3, FIX_1_501321110)
		z1 = idct_mult(z1, -FIX_0_899976223)
		z2 = idct_mult(z2, -FIX_2_562915447)
		z3 = idct_mult(z3, -FIX_1_961570560)
		z4 = idct_mult(z4, -FIX_0_390180644)
		z3 += z5
		z4 += z5
		t0 += z1 + z3
		t1 += z2 + z4
		t2 += z2 + z3
		t3 += z1 + z4
		shift := int(const_bits) + pass1_bits + 3
		out[b + 0] = clamp_i32_val(idct_descare(tmp10 + t3, shift) + i64(center), maxval)
		out[b + 7] = clamp_i32_val(idct_descare(tmp10 - t3, shift) + i64(center), maxval)
		out[b + 1] = clamp_i32_val(idct_descare(tmp11 + t2, shift) + i64(center), maxval)
		out[b + 6] = clamp_i32_val(idct_descare(tmp11 - t2, shift) + i64(center), maxval)
		out[b + 2] = clamp_i32_val(idct_descare(tmp12 + t1, shift) + i64(center), maxval)
		out[b + 5] = clamp_i32_val(idct_descare(tmp12 - t1, shift) + i64(center), maxval)
		out[b + 3] = clamp_i32_val(idct_descare(tmp13 + t0, shift) + i64(center), maxval)
		out[b + 4] = clamp_i32_val(idct_descare(tmp13 - t0, shift) + i64(center), maxval)
	}
}

@(private)
clamp_i32_val :: proc "contextless" (v: i64, maxval: int) -> i32 {
	if v < 0 do return 0
	if v > i64(maxval) do return i32(maxval)
	return i32(v)
}

// ---------------------------------------------------------------------------------------------
// libjpeg fancy upsampling (jdsample.c).
// ---------------------------------------------------------------------------------------------

@(private)
upsample_h2v1 :: proc (in_row: []u16, out_row: []u16, in_w: int) {
	if in_w <= 0 do return
	if in_w == 1 {
		for i in 0 ..< len(out_row) do out_row[i] = in_row[0]
		return
	}
	out_row[0] = in_row[0]
	out_row[1] = u16((int(in_row[0]) * 3 + int(in_row[1]) + 2) >> 2)
	for i in 1 ..< in_w - 1 {
		v := int(in_row[i]) * 3
		out_row[2 * i] = u16((v + int(in_row[i - 1]) + 1) >> 2)
		out_row[2 * i + 1] = u16((v + int(in_row[i + 1]) + 2) >> 2)
	}
	last := in_w - 1
	out_row[2 * last] = u16((int(in_row[last]) * 3 + int(in_row[last - 1]) + 1) >> 2)
	out_row[2 * last + 1] = in_row[last]
}

// Computes one output row of h2v2 fancy upsampling from a "nearest" row and a
// "further" row (`in0` nearest, `in1` further), matching jdsample.c's column sums.
@(private)
jpeg_colsum :: proc "contextless" (a, b: u16) -> int {
	return int(a) * 3 + int(b)
}

@(private)
upsample_h2v2_row :: proc (in0: []u16, in1: []u16, out_row: []u16, in_w: int) {
	if in_w <= 0 do return
	if in_w == 1 {
		v := (int(in0[0]) * 3 + int(in1[0])) * 4
		out_row[0] = u16((v + 8) >> 4)
		if len(out_row) > 1 do out_row[1] = u16((v + 7) >> 4)
		return
	}
	this := jpeg_colsum(in0[0], in1[0])
	next := jpeg_colsum(in0[1], in1[1])
	out_row[0] = u16((this * 4 + 8) >> 4)
	out_row[1] = u16((this * 3 + next + 7) >> 4)
	last := this
	this = next
	for i in 1 ..< in_w - 1 {
		next = jpeg_colsum(in0[i + 1], in1[i + 1])
		out_row[2 * i] = u16((this * 3 + last + 8) >> 4)
		out_row[2 * i + 1] = u16((this * 3 + next + 7) >> 4)
		last = this
		this = next
	}
	last_i := in_w - 1
	out_row[2 * last_i] = u16((this * 3 + last + 8) >> 4)
	out_row[2 * last_i + 1] = u16((this * 4 + 7) >> 4)
}

// Upsamples a component plane by (hf, vf) to (out_w, out_h). Uses libjpeg's fancy
// interpolation for the h2v1/h2v2 cases (the only ones DICOM JPEG requires) and box
// replication otherwise. Context rows at the image edges are duplicated, as in libjpeg.
@(private)
jpeg_upsample :: proc (
	c: ^JPEG_Comp,
	hf, vf, out_w, out_h: int,
	out: []u16,
) {
	in_row := make([]u16, c.width)
	defer delete(in_row)
	row0 := make([]u16, c.width)
	defer delete(row0)
	row1 := make([]u16, c.width)
	defer delete(row1)
	out_row := make([]u16, out_w)
	defer delete(out_row)

	for y in 0 ..< out_h {
		iy := y / vf
		if iy >= c.height do iy = c.height - 1
		if hf == 1 && vf == 1 {
			for x in 0 ..< out_w {
				ix := min(x, c.width - 1)
				out[y * out_w + x] = u16(jpeg_get_sample(c, ix, iy))
			}
			continue
		}
		if hf == 2 && vf == 1 {
			for x in 0 ..< c.width do in_row[x] = u16(jpeg_get_sample(c, x, iy))
			upsample_h2v1(in_row, out_row, c.width)
			for x in 0 ..< out_w do out[y * out_w + x] = out_row[x]
			continue
		}
		if hf == 2 && vf == 2 {
			// libjpeg processes output row pairs per input row; the "further" row
			// alternates above/below and is clamped at the image edges.
			v := y % 2
			ny := iy + (v == 0 ? -1 : 1)
			ny = clamp(ny, 0, c.height - 1)
			for x in 0 ..< c.width {
				row0[x] = u16(jpeg_get_sample(c, x, iy))
				row1[x] = u16(jpeg_get_sample(c, x, ny))
			}
			upsample_h2v2_row(row0, row1, out_row, c.width)
			for x in 0 ..< out_w do out[y * out_w + x] = out_row[x]
			continue
		}
		// Generic box replication for other integral factors.
		for x in 0 ..< out_w {
			ix := min(x / hf, c.width - 1)
			out[y * out_w + x] = u16(jpeg_get_sample(c, ix, iy))
		}
	}
}

// ---------------------------------------------------------------------------------------------
// Marker parsing and scan decoding.
// ---------------------------------------------------------------------------------------------

@(private)
jpeg_skip_fill :: proc "contextless" (data: []u8, p: ^int) {
	for p^ + 1 < len(data) && data[p^] == 0xFF && data[p^ + 1] == 0xFF {
		p^ += 1
	}
}

// Reads one block's coefficients (sequential DCT) and writes the IDCT result.
@(private)
jpeg_decode_block :: proc (
	f: ^JPEG_Frame,
	comp: ^JPEG_Comp,
	b: ^JPEG_Bits,
	dc_pred: ^i32,
	block_x, block_y: int,
	maxval: int,
	center: int,
	pass1_bits: int,
) -> JPEG_Error {
	coef: [64]i32
	if !f.dc_tables[comp.td].valid || !f.ac_tables[comp.ta].valid {
		return .Bad_Codestream
	}
	// DC
	s := jpeg_huff_decode(&f.dc_tables[comp.td], b)
	if s < 0 {
		return .Bad_Codestream
	}
	if s > 16 do return .Bad_Codestream
	diff: i32 = 0
	if s > 0 {
		v := jbits_get(b, s)
		if v < 0 do return .Bad_Codestream
		diff = i32(jpeg_extend(v, s))
	}
	dc_pred^ += diff
	coef[0] = dc_pred^
	// AC
	k := 1
	for k < 64 {
		rs := jpeg_huff_decode(&f.ac_tables[comp.ta], b)
		if rs < 0 {
			return .Bad_Codestream
		}
		r := rs >> 4
		sz := rs & 15
		if sz == 0 {
			if r == 15 {
				k += 16
				continue
			}
			break // EOB
		}
		k += r
		if k > 63 do return .Bad_Codestream
		v := jbits_get(b, sz)
		if v < 0 do return .Bad_Codestream
		coef[JPEG_ZIGZAG[k]] = i32(jpeg_extend(v, sz))
		k += 1
	}
	// Natural-order quantization table.
	out: [64]i32
	jpeg_idct_islow(&coef, &f.quant[comp.tq], maxval, center, pass1_bits, &out)
	for yy in 0 ..< 8 {
		y := block_y + yy
		if y >= comp.height do break
		for xx in 0 ..< 8 {
			x := block_x + xx
			if x >= comp.width do break
			jpeg_put_sample(comp, x, y, int(out[yy * 8 + xx]))
		}
	}
	return .None
}

// Sequential DCT scan (SOF0/SOF1). `scan_comps` are frame component indices.
@(private)
jpeg_decode_scan_dct :: proc (
	f: ^JPEG_Frame,
	scan_comps: []int,
	ss, se, ah, al: int,
	b: ^JPEG_Bits,
) -> JPEG_Error {
	if ah != 0 || al != 0 || ss != 0 || se != 63 do return .Unsupported_Feature
	maxval := (1 << u32(f.precision)) - 1
	pass1_bits := 2 if f.precision <= 8 else 1
	center := 1 << u32(f.precision - 1)
	dc_pred: [JPEG_MAX_COMPONENTS]i32
	interval := f.restart_interval
	units := 0

	interleaved := len(scan_comps) > 1
	if interleaved {
		mcus_x := (f.width + 8 * f.max_h - 1) / (8 * f.max_h)
		mcus_y := (f.height + 8 * f.max_v - 1) / (8 * f.max_v)
		for my in 0 ..< mcus_y {
			for mx in 0 ..< mcus_x {
				if interval > 0 && units > 0 && units % interval == 0 {
					if !jbits_restart(b) do return .Bad_Codestream
					for i in 0 ..< JPEG_MAX_COMPONENTS do dc_pred[i] = 0
				}
				units += 1
				for ci in scan_comps {
					comp := &f.comps[ci]
					for by in 0 ..< comp.v {
						for bx in 0 ..< comp.h {
							err := jpeg_decode_block(
								f, comp, b, &dc_pred[ci],
								(mx * comp.h + bx) * 8, (my * comp.v + by) * 8,
								maxval, center, pass1_bits,
							)
							if err != .None do return err
						}
					}
				}
			}
		}
	} else {
		ci := scan_comps[0]
		comp := &f.comps[ci]
		blocks_x := (comp.width + 7) / 8
		blocks_y := (comp.height + 7) / 8
		for by in 0 ..< blocks_y {
			for bx in 0 ..< blocks_x {
				if interval > 0 && units > 0 && units % interval == 0 {
					if !jbits_restart(b) do return .Bad_Codestream
					dc_pred[ci] = 0
				}
				units += 1
				err := jpeg_decode_block(f, comp, b, &dc_pred[ci], bx * 8, by * 8, maxval, center, pass1_bits)
				if err != .None do return err
			}
		}
	}
	return .None
}

// Lossless scan (SOF3): decode sample differences into each component's diff plane.
@(private)
jpeg_decode_scan_lossless :: proc (
	f: ^JPEG_Frame,
	scan_comps: []int,
	predictor: int,
	al: int,
	b: ^JPEG_Bits,
) -> JPEG_Error {
	if predictor < 1 || predictor > 7 do return .Unsupported_Feature
	if al < 0 || al > 15 do return .Unsupported_Feature
	interval := f.restart_interval
	units := 0
	// Clear previous prediction-interval marks.
	for i in 0 ..< f.ncomp {
		c := &f.comps[i]
		for y in 0 ..< c.height do c.first_row[y] = false
	}
	mark_first :: proc (c: ^JPEG_Comp, row: int) {
		if row >= 0 && row < len(c.first_row) do c.first_row[row] = true
	}

	interleaved := len(scan_comps) > 1
	if interleaved {
		mcus_x := (f.width + f.max_h - 1) / f.max_h
		mcus_y := (f.height + f.max_v - 1) / f.max_v
		for my in 0 ..< mcus_y {
			for mx in 0 ..< mcus_x {
				if interval > 0 && units > 0 && units % interval == 0 {
					if !jbits_restart(b) do return .Bad_Codestream
					for ci in scan_comps do mark_first(&f.comps[ci], my * f.comps[ci].v)
				}
				units += 1
				for ci in scan_comps {
					comp := &f.comps[ci]
					for yo in 0 ..< comp.v {
						for xo in 0 ..< comp.h {
							s := jpeg_huff_decode(&f.dc_tables[comp.td], b)
							if s < 0 do return .Bad_Codestream
							diff: i32 = 0
							if s == 16 {
								diff = 32768
							} else if s > 0 {
								v := jbits_get(b, s)
								if v < 0 do return .Bad_Codestream
								diff = i32(jpeg_extend(v, s))
							}
							x := mx * comp.h + xo
							y := my * comp.v + yo
							if x < comp.width && y < comp.height {
								comp.diff_plane[y * comp.width + x] = diff
							}
						}
					}
				}
			}
		}
	} else {
		ci := scan_comps[0]
		comp := &f.comps[ci]
		for y in 0 ..< comp.height {
			for x in 0 ..< comp.width {
				if interval > 0 && units > 0 && units % interval == 0 {
					if !jbits_restart(b) do return .Bad_Codestream
					mark_first(comp, y)
				}
				units += 1
				s := jpeg_huff_decode(&f.dc_tables[comp.td], b)
				if s < 0 do return .Bad_Codestream
				diff: i32 = 0
				if s == 16 {
					diff = 32768
				} else if s > 0 {
					v := jbits_get(b, s)
					if v < 0 do return .Bad_Codestream
					diff = i32(jpeg_extend(v, s))
				}
				comp.diff_plane[y * comp.width + x] = diff
			}
		}
	}
	_ = predictor
	return .None
}

// Reconstructs lossless samples from differences, applying the predictor and the
// point transform (libjpeg jdlossls.c: INITIAL_PREDICTORx for the first sample of a
// row interval, horizontal predictor for the rest of that row, the selected 2-D
// predictor otherwise).
@(private)
jpeg_undifference :: proc (f: ^JPEG_Frame, comp: ^JPEG_Comp, predictor: int, al: int, sample_mask: int) {
	initial := 1 << u32(f.precision - al - 1)
	for y in 0 ..< comp.height {
		first := y == 0 || (len(comp.first_row) > y && comp.first_row[y])
		ra: int = 0
		for x in 0 ..< comp.width {
			diff := int(comp.diff_plane[y * comp.width + x])
			pred: int = 0
			if first {
				if x == 0 {
					pred = initial
				} else {
					pred = ra
				}
			} else {
				rb := jpeg_get_sample(comp, x, y - 1)
				rc := jpeg_get_sample(comp, max(x - 1, 0), y - 1)
				ra_prev := ra
				if x == 0 {
					pred = rb
				} else {
					switch predictor {
					case 1: pred = ra_prev
					case 2: pred = rb
					case 3: pred = rc
					case 4: pred = ra_prev + rb - rc
					case 5: pred = ra_prev + ((rb - rc) >> 1)
					case 6: pred = rb + ((ra_prev - rc) >> 1)
					case: pred = (ra_prev + rb) >> 1
					}
				}
			}
			ra = (diff + pred) & 0xFFFF
			v := (ra << u32(al)) & sample_mask
			jpeg_put_sample(comp, x, y, v)
		}
	}
}

// Decodes one raw JPEG codestream (SOI..EOI) into `dst`, which must hold
// info.frame_bytes bytes. Exposed for callers and for the fuzzer.
jpeg_decode_codestream :: proc (cs: []u8, dst: []u8, info: JPEG_Image) -> JPEG_Error {
	if len(dst) < info.frame_bytes do return .Output_Too_Small
	if len(cs) < 4 || cs[0] != 0xFF || cs[1] != 0xD8 do return .Bad_Codestream

	f: JPEG_Frame
	defer jpeg_frame_destroy(&f)
	bits: JPEG_Bits
	p := 2
	decoded := false
	for {
		jpeg_skip_fill(cs, &p)
		// A 0xFF 0x00 pair is byte stuffing, not a marker: the entropy reader may
		// stop between the two bytes of the final stuffed 0xFF.
		if p + 1 < len(cs) && cs[p] == 0xFF && cs[p + 1] == 0x00 {
			p += 2
			continue
		}
		if p + 2 > len(cs) do break
		if cs[p] != 0xFF do return .Bad_Codestream
		m := int(cs[p + 1])
		p += 2
		if m == 0xD9 do break // EOI
		if m == 0x01 || (m >= 0xD0 && m <= 0xD7) do continue
		if p + 2 > len(cs) do return .Bad_Codestream
		l := int(u16(cs[p]) << 8 | u16(cs[p + 1]))
		if l < 2 || p + l > len(cs) {
			return .Bad_Codestream
		}
		seg := cs[p + 2:p + l]
		switch m {
		case 0xDB: // DQT
			q := 0
			for q < len(seg) {
				pq := int(seg[q] >> 4)
				tq := int(seg[q] & 15)
				q += 1
				if tq >= 4 do return .Bad_Codestream
				for i in 0 ..< 64 {
					if pq == 0 {
						if q >= len(seg) do return .Bad_Codestream
						f.quant[tq][JPEG_ZIGZAG[i]] = i32(seg[q])
						q += 1
					} else {
						if q + 1 >= len(seg) do return .Bad_Codestream
						f.quant[tq][JPEG_ZIGZAG[i]] = i32(u16(seg[q]) << 8 | u16(seg[q + 1]))
						q += 2
					}
				}
				f.quant_ok[tq] = true
			}
		case 0xC4: // DHT
			q := 0
			for q + 17 <= len(seg) {
				tc := int(seg[q] >> 4)
				th := int(seg[q] & 15)
				q += 1
				if tc > 1 || th >= JPEG_MAX_HUFF_TABLES do return .Bad_Codestream
				counts := seg[q:q + 16]
				q += 16
				total := 0
				for c in counts do total += int(c)
				if q + total > len(seg) do return .Bad_Codestream
				values := seg[q:q + total]
				q += total
				table := &f.dc_tables[th] if tc == 0 else &f.ac_tables[th]
				if !jpeg_build_huff(table, counts, values) do return .Bad_Codestream
			}
		case 0xDD: // DRI
			if len(seg) < 2 do return .Bad_Codestream
			f.restart_interval = int(u16(seg[0]) << 8 | u16(seg[1]))
		case 0xC0, 0xC1, 0xC3: // SOF0, SOF1, SOF3
			if len(seg) < 6 do return .Bad_Codestream
			f.sof = m
			f.precision = int(seg[0])
			f.height = int(u16(seg[1]) << 8 | u16(seg[2]))
			f.width = int(u16(seg[3]) << 8 | u16(seg[4]))
			f.ncomp = int(seg[5])
			f.lossless = m == 0xC3
			if f.ncomp < 1 || f.ncomp > JPEG_MAX_COMPONENTS do return .Unsupported_Feature
			if f.precision < 8 || f.precision > 16 do return .Unsupported_Feature
			if f.width <= 0 || f.height <= 0 do return .Bad_Codestream
			if u64(f.width) * u64(f.height) > J2K_MAX_SAMPLES do return .Unsupported_Feature
			if len(seg) < 6 + 3 * f.ncomp do return .Bad_Codestream
			f.max_h = 1
			f.max_v = 1
			for i in 0 ..< f.ncomp {
				c := &f.comps[i]
				c.id = int(seg[6 + 3 * i])
				c.h = int(seg[7 + 3 * i] >> 4)
				c.v = int(seg[7 + 3 * i] & 15)
				c.tq = int(seg[8 + 3 * i])
				if c.h < 1 || c.v < 1 || c.h > 4 || c.v > 4 do return .Bad_Codestream
				if c.tq < 0 || c.tq >= 4 do return .Bad_Codestream
				f.max_h = max(f.max_h, c.h)
				f.max_v = max(f.max_v, c.v)
			}
			if err := jpeg_alloc_planes(&f); err != .None do return err
			for i in 0 ..< f.ncomp do f.comps[i].diff_plane = make([]i32, f.comps[i].width * f.comps[i].height)
		case 0xC2: // progressive
			return .Unsupported_Feature
		case 0xDA: // SOS
			if f.sof == 0 do return .Bad_Codestream
			if len(seg) < 1 do return .Bad_Codestream
			ns := int(seg[0])
			if ns < 1 || ns > f.ncomp do return .Bad_Codestream
			if len(seg) < 1 + 2 * ns + 3 do return .Bad_Codestream
			scan_comps := make([]int, ns)
			defer delete(scan_comps)
			for i in 0 ..< ns {
				id := int(seg[1 + 2 * i])
				td := int(seg[2 + 2 * i] >> 4)
				ta := int(seg[2 + 2 * i] & 15)
				ci := jpeg_component_index(&f, id)
				if ci < 0 do return .Bad_Codestream
				if td < 0 || td >= JPEG_MAX_HUFF_TABLES || ta < 0 || ta >= JPEG_MAX_HUFF_TABLES {
					return .Bad_Codestream
				}
				f.comps[ci].td = td
				f.comps[ci].ta = ta
				scan_comps[i] = ci
			}
			ss := int(seg[1 + 2 * ns])
			se := int(seg[2 + 2 * ns])
			ahal := int(seg[3 + 2 * ns])
			ah := ahal >> 4
			al := ahal & 15
			if f.lossless {
				if ah != 0 do return .Unsupported_Feature
				f.last_predictor = ss
				f.last_al = al
				jbits_init(&bits, cs, p + l)
				if err := jpeg_decode_scan_lossless(&f, scan_comps, ss, al, &bits); err != .None do return err
			} else {
				jbits_init(&bits, cs, p + l)
				if err := jpeg_decode_scan_dct(&f, scan_comps, ss, se, ah, al, &bits); err != .None do return err
			}
			decoded = true
			// Continue from the marker that stopped the entropy segment.
			p = bits.pos
			continue
		case:
			// APPn, COM and anything else: skip by length.
		}
		p += l
	}
	if !decoded || f.sof == 0 do return .Bad_Codestream

	// Post-processing: lossless undifferencing, then upsample and interleave.
	sample_mask := 0xFF if info.bytes_per_sample == 1 else 0xFFFF
	// The entropy bit reader is created lazily where the scan starts; declared here
	// because SOS handling above runs inside the parse loop.
	if f.lossless {
		for i in 0 ..< f.ncomp {
			jpeg_undifference(&f, &f.comps[i], f.last_predictor, f.last_al, sample_mask)
		}
	}
	frame_w := f.width
	frame_h := f.height
	comp_out := [JPEG_MAX_COMPONENTS][]u16{}
	for i in 0 ..< f.ncomp {
		comp_out[i] = make([]u16, frame_w * frame_h)
	}
	defer {
		for i in 0 ..< f.ncomp do delete(comp_out[i])
	}
	for i in 0 ..< f.ncomp {
		c := &f.comps[i]
		jpeg_upsample(c, f.max_h / c.h, f.max_v / c.v, frame_w, frame_h, comp_out[i])
	}
	samples := info.samples
	for y in 0 ..< frame_h {
		for x in 0 ..< frame_w {
			base := (y * frame_w + x) * samples
			for ci in 0 ..< min(samples, f.ncomp) {
				v := comp_out[ci][y * frame_w + x]
				if info.bytes_per_sample == 1 {
					dst[base + ci] = u8(v & 0xFF)
				} else {
					i := (base + ci) * 2
					dst[i] = u8(v & 0xFF)
					dst[i + 1] = u8((v >> 8) & 0xFF)
				}
			}
		}
	}
	return .None
}

// ---------------------------------------------------------------------------------------------
// DICOM wrapper.
// ---------------------------------------------------------------------------------------------

@(private)
jpeg_is_supported_uid :: proc "contextless" (uid: string) -> bool {
	return uid == JPEG_BASELINE_UID || uid == JPEG_EXTENDED_UID ||
		uid == JPEG_LOSSLESS_UID || uid == JPEG_LOSSLESS_SV1_UID
}

@(private)
jpeg_attribute :: proc (doc: ^Document, tag: Tag) -> (v: int, ok: bool) {
	e, found := document_find(doc, tag)
	if !found do return 0, false
	if e.vr == .IS {
		n, nok := value_is(doc, e)
		return n, nok
	}
	u, uok := value_u64(doc, e)
	return int(u), uok
}

jpeg_image_info :: proc(doc: ^Document, pixel: Element) -> (info: JPEG_Image, err: JPEG_Error) {
	if !jpeg_is_supported_uid(doc.ts.uid) do return {}, .Not_JPEG_Transfer_Syntax
	if .Encapsulated not_in pixel.flags do return {}, .Not_Encapsulated
	rows, ok_rows := jpeg_attribute(doc, Tag{0x0028, 0x0010})
	cols, ok_cols := jpeg_attribute(doc, Tag{0x0028, 0x0011})
	bits, ok_bits := jpeg_attribute(doc, Tag{0x0028, 0x0100})
	if !ok_rows || !ok_cols || !ok_bits do return {}, .Missing_Image_Attributes
	samples, ok_samples := jpeg_attribute(doc, Tag{0x0028, 0x0002})
	if !ok_samples do samples = 1
	frames, ok_frames := jpeg_attribute(doc, Tag{0x0028, 0x0008})
	if !ok_frames do frames = 1
	signed := false
	if pr, ok := jpeg_attribute(doc, Tag{0x0028, 0x0103}); ok do signed = pr != 0
	if rows <= 0 || cols <= 0 || bits <= 0 || (bits % 8) != 0 || bits > 16 ||
	   samples <= 0 || samples > JPEG_MAX_COMPONENTS || frames <= 0 {
		return {}, .Invalid_Image_Parameters
	}
	bps := bits / 8
	info = JPEG_Image{
		rows = rows, cols = cols, samples = samples, bits = bits, signed = signed,
		frames = frames, bytes_per_sample = bps, frame_bytes = rows * cols * samples * bps,
	}
	return info, .None
}

jpeg_decode_frame :: proc(
	doc:         ^Document,
	pixel:       Element,
	frame_index: int,
	dst:         []u8,
	info:        JPEG_Image,
) -> JPEG_Error {
	if frame_index < 0 || frame_index >= info.frames do return .Invalid_Image_Parameters
	cs, owned, ok := encapsulated_frame_codestream(doc, pixel, frame_index, info.frames)
	if !ok do return .Bad_Codestream
	// defer is block-scoped in Odin: the conditional must live at proc scope, or the buffer
	// would be freed before the codestream is decoded.
	defer if owned do delete(cs)
	return jpeg_decode_codestream(cs, dst, info)
}

jpeg_decode :: proc(doc: ^Document, pixel: Element, dst: []u8) -> (written: int, err: JPEG_Error) {
	info, ierr := jpeg_image_info(doc, pixel)
	if ierr != .None do return 0, ierr
	if len(dst) < info.frame_bytes * info.frames do return 0, .Output_Too_Small
	for f in 0 ..< info.frames {
		frame := dst[f * info.frame_bytes:(f + 1) * info.frame_bytes]
		e := jpeg_decode_frame(doc, pixel, f, frame, info)
		if e != .None do return f * info.frame_bytes, e
	}
	return info.frame_bytes * info.frames, .None
}
