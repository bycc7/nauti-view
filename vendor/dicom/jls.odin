package dicom

// Step 10: JPEG-LS decoding for encapsulated DICOM pixel data.
//
//   1.2.840.10008.1.2.4.80  JPEG-LS Lossless
//   1.2.840.10008.1.2.4.81  JPEG-LS Near-Lossless
//
// Ported from CharLS 2.4.2 (BSD-3-Clause): scan.h, context_regular_mode.h,
// context_run_mode.h, lossless_traits.h / default_traits.h, jpeg_stream_reader.cpp.
// LOCO-I gradient contexts, Golomb-Rice coding, run mode, near-lossless
// quantization and all three interleave modes (none / line / sample).

import "core:encoding/endian"

JPEG_LS_LOSSLESS_UID :: "1.2.840.10008.1.2.4.80"
JPEG_LS_NEAR_UID :: "1.2.840.10008.1.2.4.81"

JLS_Error :: enum u8 {
	None = 0,
	Not_JPEG_LS_Transfer_Syntax,
	Not_Encapsulated,
	Missing_Image_Attributes,
	Invalid_Image_Parameters,
	Bad_Codestream,
	Unsupported_Feature,
	Out_Of_Memory,
	Output_Too_Small,
}

JLS_Image :: struct {
	rows:             int,
	cols:             int,
	samples:          int,
	bits:             int,
	frames:           int,
	bytes_per_sample: int,
	frame_bytes:      int,
}

@(private) JLS_MAX_COMPONENTS :: 4
@(private) JLS_MAX_K :: 16

// ---------------------------------------------------------------------------------------------
// Bit reader (ISO/IEC 14495-1 A.1): after 0xFF the following bit is ignored.
// ---------------------------------------------------------------------------------------------

@(private)
JLS_Bits :: struct {
	data:       []u8,
	pos:        int,
	cache:      u64,
	valid_bits: int,
}

@(private) JLS_CACHE_BITS :: 64
@(private) JLS_MAX_READABLE :: 56

@(private)
jls_bits_init :: proc "contextless" (b: ^JLS_Bits, data: []u8, pos: int) {
	b.data = data
	b.pos = pos
	b.cache = 0
	b.valid_bits = 0
}

@(private)
jls_fill :: proc "contextless" (b: ^JLS_Bits) -> bool {
	for b.valid_bits < JLS_MAX_READABLE {
		if b.pos >= len(b.data) {
			return b.valid_bits > 0
		}
		next: u8 = 0
		if b.pos + 1 < len(b.data) do next = b.data[b.pos + 1]
		if b.data[b.pos] == 0xFF && (b.pos + 1 >= len(b.data) || (next & 0x80) != 0) {
			// Marker: no more entropy-coded bytes.
			return b.valid_bits > 0
		}
		v := b.data[b.pos]
		b.cache |= u64(v) << u32(JLS_MAX_READABLE - b.valid_bits)
		b.valid_bits += 8
		b.pos += 1
		if v == 0xFF {
			// Ignore the bit after a 0xFF padding byte.
			b.valid_bits -= 1
		}
	}
	return true
}

@(private)
jls_skip :: proc "contextless" (b: ^JLS_Bits, n: int) {
	b.valid_bits -= n
	b.cache <<= u32(n)
}

@(private)
jls_read_value :: proc (b: ^JLS_Bits, n: int) -> (int, bool) {
	if n == 0 do return 0, true
	if b.valid_bits < n {
		if !jls_fill(b) && b.valid_bits < n do return 0, false
	}
	if b.valid_bits < n do return 0, false
	v := int(b.cache >> u32(JLS_CACHE_BITS - n))
	jls_skip(b, n)
	return v, true
}

@(private)
jls_read_bit :: proc (b: ^JLS_Bits) -> (int, bool) {
	if b.valid_bits <= 0 {
		if !jls_fill(b) && b.valid_bits <= 0 do return 0, false
	}
	if b.valid_bits <= 0 do return 0, false
	v := int(b.cache >> (JLS_CACHE_BITS - 1))
	jls_skip(b, 1)
	return v, true
}

// Counts leading zero bits (up to 16) or returns -1 when at least 16 zeros.
@(private)
jls_peek_zero_bits :: proc "contextless" (b: ^JLS_Bits) -> int {
	for i in 0 ..< 16 {
		if (b.cache & (u64(1) << u32(JLS_CACHE_BITS - 1 - i))) != 0 do return i
	}
	return -1
}

@(private)
jls_read_high_bits :: proc (b: ^JLS_Bits) -> (int, bool) {
	if b.valid_bits < 16 {
		if !jls_fill(b) && b.valid_bits < 1 do return 0, false
	}
	count := jls_peek_zero_bits(b)
	if count >= 0 && count < b.valid_bits {
		jls_skip(b, count + 1)
		return count, true
	}
	jls_skip(b, 15)
	for high := 15; ; high += 1 {
		bit, ok := jls_read_bit(b)
		if !ok do return 0, false
		if bit != 0 do return high, true
	}
}

// ---------------------------------------------------------------------------------------------
// Context models (CharLS context_regular_mode / context_run_mode).
// ---------------------------------------------------------------------------------------------

@(private)
JLS_Context :: struct {
	a: i32,
	b: i32,
	c: i32,
	n: i32,
}

@(private)
JLS_Run_Context :: struct {
	type: i32, // run interruption type (0 or 1)
	a:    i32,
	n:    i32,
	nn:   i32,
}

@(private)
jls_init_a :: proc "contextless" (range: i32) -> i32 {
	return max(2, (range + 32) / 64)
}

@(private)
jls_ctx_golomb_k :: proc "contextless" (ctx: ^JLS_Context) -> (int, bool) {
	k := 0
	for (ctx.n << u32(k)) < ctx.a {
		k += 1
		if k == JLS_MAX_K do return 0, false
	}
	return k, true
}

@(private)
jls_ctx_error_correction :: proc "contextless" (ctx: ^JLS_Context, k: int) -> i32 {
	if k != 0 do return 0
	v := 2 * ctx.b + ctx.n - 1
	return v >> 31 // -1 or 0
}

@(private)
jls_ctx_update :: proc "contextless" (ctx: ^JLS_Context, error, near, reset_threshold: i32) -> bool {
	ctx.a += abs(error)
	ctx.b += error * (2 * near + 1)
	limit := i32(65536 * 256)
	if ctx.a >= limit || abs(ctx.b) >= limit do return false
	if ctx.n == reset_threshold {
		ctx.a >>= 1
		ctx.b >>= 1
		ctx.n >>= 1
	}
	ctx.n += 1
	if ctx.b + ctx.n <= 0 {
		ctx.b += ctx.n
		if ctx.b <= -ctx.n do ctx.b = -ctx.n + 1
		if ctx.c > -128 do ctx.c -= 1
	} else if ctx.b > 0 {
		ctx.b -= ctx.n
		if ctx.b > 0 do ctx.b = 0
		if ctx.c < 127 do ctx.c += 1
	}
	return true
}

@(private)
jls_run_golomb_k :: proc "contextless" (ctx: ^JLS_Run_Context) -> (int, bool) {
	temp := ctx.a + (ctx.n >> 1) * ctx.type
	n_test := ctx.n
	k := 0
	for n_test < temp {
		n_test <<= 1
		k += 1
		if k > 32 do return 0, false
	}
	return k, true
}

@(private)
jls_run_compute_error :: proc "contextless" (ctx: ^JLS_Run_Context, temp: i32, k: int) -> i32 {
	is_odd := (temp & 1) != 0
	abs_err := (temp + (1 if is_odd else 0)) / 2
	negate := ((k != 0 || 2 * ctx.nn >= ctx.n) == is_odd)
	return -abs_err if negate else abs_err
}

@(private)
jls_run_update :: proc "contextless" (ctx: ^JLS_Run_Context, error: i32, e_mapped: i32, reset_threshold: i32) {
	if error < 0 do ctx.nn += 1
	ctx.a += (e_mapped + 1 - ctx.type) >> 1
	if ctx.n == reset_threshold {
		ctx.a >>= 1
		ctx.n >>= 1
		ctx.nn >>= 1
	}
	ctx.n += 1
}

// ---------------------------------------------------------------------------------------------
// Scan decoding.
// ---------------------------------------------------------------------------------------------

@(private)
JLS_Comp :: struct {
	id:    int,
	plane: []u16,
}

@(private)
JLS_State :: struct {
	width:       int,
	height:      int,
	ncomp:       int,
	precision:   int,
	maxval:      int,
	near:        int,
	range:       int,
	qbpp:        int,
	bits_pp:     int,
	limit:       int,
	reset_thr:   int,
	t1:          int,
	t2:          int,
	t3:          int,
	interleave:  int, // 0 none, 1 line, 2 sample
	comps:       [JLS_MAX_COMPONENTS]JLS_Comp,
	ctx:         [365]JLS_Context,
	run_ctx:     [2]JLS_Run_Context,
	run_index:   int,
	run_index_comp: [JLS_MAX_COMPONENTS]int, // ILV line: run index persists per component
	prev:        [JLS_MAX_COMPONENTS][]i32,
	cur:         [JLS_MAX_COMPONENTS][]i32,
	stride:      int,
	bits:        JLS_Bits,
}

@(private) JLS_J := [32]int{0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15}

@(private)
jls_quantize :: proc "contextless" (s: ^JLS_State, di: i32) -> i32 {
	if di <= -i32(s.t3) do return -4
	if di <= -i32(s.t2) do return -3
	if di <= -i32(s.t1) do return -2
	if di < -i32(s.near) do return -1
	if di <= i32(s.near) do return 0
	if di < i32(s.t1) do return 1
	if di < i32(s.t2) do return 2
	if di < i32(s.t3) do return 3
	return 4
}

@(private)
jls_predicted :: proc "contextless" (ra, rb, rc: i32) -> i32 {
	sign := (rb - ra) >> 31
	if ((sign ~ (rc - ra)) < 0) do return rb
	if ((sign ~ (rb - rc)) < 0) do return ra
	return ra + rb - rc
}

@(private)
jls_apply_sign :: proc "contextless" (v, sign: i32) -> i32 {
	return (sign ~ v) - sign
}

@(private)
jls_correct_prediction :: proc "contextless" (s: ^JLS_State, predicted: i32) -> i32 {
	if (predicted & i32(s.maxval)) == predicted do return predicted
	return (~(predicted >> 31)) & i32(s.maxval)
}

@(private)
jls_modulo_range :: proc "contextless" (s: ^JLS_State, error: i32) -> i32 {
	e := error
	if e < 0 do e += i32(s.range)
	if e >= (i32(s.range) + 1) / 2 do e -= i32(s.range)
	return e
}

@(private)
jls_reconstruct :: proc "contextless" (s: ^JLS_State, predicted: i32, error: i32) -> i32 {
	value := predicted + error * i32(2 * s.near + 1)
	if value < -i32(s.near) {
		value = value + i32(s.range) * i32(2 * s.near + 1)
	} else if value > i32(s.maxval) + i32(s.near) {
		value = value - i32(s.range) * i32(2 * s.near + 1)
	}
	return jls_correct_prediction(s, value)
}

// Decodes one Golomb-coded value (code segment A.11 / A.5.2).
@(private)
jls_decode_value :: proc (s: ^JLS_State, k, limit: int, qbpp: int) -> (i32, bool) {
	high, ok := jls_read_high_bits(&s.bits)
	if !ok do return 0, false
	if high >= limit - (qbpp + 1) {
		v, vok := jls_read_value(&s.bits, qbpp)
		if !vok do return 0, false
		return i32(v + 1), true
	}
	if k == 0 do return i32(high), true
	low, lok := jls_read_value(&s.bits, k)
	if !lok do return 0, false
	return i32((high << u32(k)) + low), true
}

@(private)
jls_unmap_error :: proc "contextless" (mapped: i32) -> i32 {
	// CharLS unmap_error_value: the sign comes from the LSB (map stores it there).
	sign := (mapped << 31) >> 31
	return sign ~ (mapped >> 1)
}

// Regular mode for one sample. Returns the reconstructed sample.
@(private)
jls_decode_regular :: proc (s: ^JLS_State, qs: i32, predicted: i32) -> (i32, bool) {
	sign := qs >> 31
	idx := int(jls_apply_sign(qs, sign))
	ctx := &s.ctx[idx]
	k, kok := jls_ctx_golomb_k(ctx)
	if !kok do return 0, false
	predicted_value := jls_correct_prediction(s, predicted + jls_apply_sign(ctx.c, sign))
	mapped, ok := jls_decode_value(s, k, s.limit, s.qbpp)
	if !ok do return 0, false
	error := jls_unmap_error(mapped)
	if k == 0 {
		error = error ~ jls_ctx_error_correction(ctx, s.near)
	}
	if !jls_ctx_update(ctx, error, i32(s.near), i32(s.reset_thr)) do return 0, false
	error = jls_apply_sign(error, sign)
	return jls_reconstruct(s, predicted_value, error), true
}

// Decodes the run-interruption error for one component.
@(private)
jls_decode_run_interruption_error :: proc (s: ^JLS_State, ctx: ^JLS_Run_Context) -> (i32, bool) {
	k, kok := jls_run_golomb_k(ctx)
	if !kok do return 0, false
	mapped, ok := jls_decode_value(s, k, s.limit - JLS_J[s.run_index] - 1, s.qbpp)
	if !ok do return 0, false
	error := jls_run_compute_error(ctx, mapped + ctx.type, k)
	jls_run_update(ctx, error, mapped, i32(s.reset_thr))
	return error, true
}

// Decodes `count` run pixels of value `ra` for one component line.
@(private)
jls_decode_run_pixels_at :: proc (s: ^JLS_State, ra: i32, line: []i32, offset, count: int) -> (int, bool) {
	index := 0
	for {
		bit, ok := jls_read_bit(&s.bits)
		if !ok do return 0, false
		if bit == 0 do break
		n := 1 << u32(JLS_J[s.run_index])
		if n > count - index do n = count - index
		index += n
		if n == (1 << u32(JLS_J[s.run_index])) do s.run_index = min(31, s.run_index + 1)
		if index == count do break
	}
	if index != count && JLS_J[s.run_index] > 0 {
		extra, ok := jls_read_value(&s.bits, JLS_J[s.run_index])
		if !ok do return 0, false
		index += extra
	}
	if index > count do return 0, false
	for i in 0 ..< index do line[offset + i] = ra
	return index, true
}

// Run mode for one component line; returns the number of samples consumed.
// Buffers are `stride = width + 4` long; sample x lives at buf[1 + x], so buf[0]
// holds the left edge and buf[1 + width] the replicated right edge.
@(private)
jls_decode_run :: proc (s: ^JLS_State, ci, start: int) -> (int, bool) {
	cur := s.cur[ci]
	prev := s.prev[ci]
	ra := cur[start]
	count, ok := jls_decode_run_pixels_at(s, ra, cur, 1 + start, s.width - start)
	if !ok do return 0, false
	end := start + count
	if end == s.width do return end - start, true
	rb := prev[1 + end]
	value: i32 = 0
	if abs(ra - rb) <= i32(s.near) {
		e, eok := jls_decode_run_interruption_error(s, &s.run_ctx[1])
		if !eok do return 0, false
		value = jls_reconstruct(s, ra, e)
	} else {
		e, eok := jls_decode_run_interruption_error(s, &s.run_ctx[0])
		if !eok do return 0, false
		value = jls_reconstruct(s, rb, e * ((rb - ra) >> 31 | 1))
	}
	cur[1 + end] = value
	s.run_index = max(0, s.run_index - 1)
	return end - start + 1, true
}

// Decodes one scan line for one component (ILV none / line).
@(private)
jls_decode_line_comp :: proc (s: ^JLS_State, ci: int) -> bool {
	cur := s.cur[ci]
	prev := s.prev[ci]
	index := 0
	for index < s.width {
		ra := cur[index]          // sample index-1 (buf offset 1)
		rb := prev[1 + index]
		rc := prev[index]
		rd := prev[2 + index]
		qs := (jls_quantize(s, rd - rb) * 9 + jls_quantize(s, rb - rc)) * 9 + jls_quantize(s, rc - ra)
		if qs != 0 {
			predicted := jls_predicted(ra, rb, rc)
			v, ok := jls_decode_regular(s, qs, predicted)
			if !ok {
				return false
			}
			cur[1 + index] = v
			index += 1
		} else {
			n, ok := jls_decode_run(s, ci, index)
			if !ok {
				return false
			}
			index += n
		}
	}
	return true
}

// Decodes one scan line for all components in sample-interleaved mode.
@(private)
jls_decode_line_sample :: proc (s: ^JLS_State) -> bool {
	index := 0
	for index < s.width {
		// Contexts for every component.
		qss: [JLS_MAX_COMPONENTS]i32
		ra: [JLS_MAX_COMPONENTS]i32
		rb: [JLS_MAX_COMPONENTS]i32
		rc: [JLS_MAX_COMPONENTS]i32
		rd: [JLS_MAX_COMPONENTS]i32
		all_zero := true
		for c in 0 ..< s.ncomp {
			ra[c] = s.cur[c][index]
			rb[c] = s.prev[c][index + 1]
			rc[c] = s.prev[c][index]
			rd[c] = s.prev[c][index + 2]
			qss[c] = (jls_quantize(s, rd[c] - rb[c]) * 9 + jls_quantize(s, rb[c] - rc[c])) * 9 +
				jls_quantize(s, rc[c] - ra[c])
			if qss[c] != 0 do all_zero = false
		}
		if all_zero {
			// Run mode: `ra` is the same tuple for all components.
			count := s.width - index
			run := 0
			for {
				bit, ok := jls_read_bit(&s.bits)
				if !ok do return false
				if bit == 0 do break
				n := 1 << u32(JLS_J[s.run_index])
				if n > count - run do n = count - run
				run += n
				if n == (1 << u32(JLS_J[s.run_index])) do s.run_index = min(31, s.run_index + 1)
				if run == count do break
			}
			if run != count && JLS_J[s.run_index] > 0 {
				extra, ok := jls_read_value(&s.bits, JLS_J[s.run_index])
				if !ok do return false
				run += extra
			}
			if run > count do return false
			for c in 0 ..< s.ncomp {
				for i in 0 ..< run do s.cur[c][index + 1 + i] = ra[c]
			}
			index += run
			if index == s.width do break
			// Run interruption: one error per component with context type 0.
			for c in 0 ..< s.ncomp {
				e, ok := jls_decode_run_interruption_error(s, &s.run_ctx[0])
				if !ok do return false
				s.cur[c][index + 1] = jls_reconstruct(s, rb[c], e * ((rb[c] - ra[c]) >> 31 | 1))
			}
			s.run_index = max(0, s.run_index - 1)
			index += 1
		} else {
			for c in 0 ..< s.ncomp {
				predicted := jls_predicted(ra[c], rb[c], rc[c])
				v, ok := jls_decode_regular(s, qss[c], predicted)
				if !ok do return false
				s.cur[c][index + 1] = v
			}
			index += 1
		}
	}
	return true
}

@(private)
jls_reset_contexts :: proc (s: ^JLS_State) {
	a := jls_init_a(i32(s.range))
	for i in 0 ..< 365 {
		s.ctx[i] = JLS_Context{a = a, n = 1}
	}
	s.run_ctx[0] = JLS_Run_Context{type = 0, a = a, n = 1}
	s.run_ctx[1] = JLS_Run_Context{type = 1, a = a, n = 1}
	s.run_index = 0
	for i in 0 ..< JLS_MAX_COMPONENTS do s.run_index_comp[i] = 0
}

@(private)
jls_clear_lines :: proc (s: ^JLS_State) {
	for c in 0 ..< s.ncomp {
		for i in 0 ..< len(s.prev[c]) do s.prev[c][i] = 0
		for i in 0 ..< len(s.cur[c]) do s.cur[c][i] = 0
	}
}

// ---------------------------------------------------------------------------------------------
// Marker parsing and frame decode.
// ---------------------------------------------------------------------------------------------

@(private)
jls_log2_ceil :: proc "contextless" (n: int) -> int {
	x := 0
	for n > (1 << u32(x)) do x += 1
	return x
}

@(private)
jls_default_thresholds :: proc "contextless" (maxval, near: int) -> (t1, t2, t3, reset: int) {
	reset = 64
	if maxval >= 128 {
		factor := (min(maxval, 4095) + 128) / 256
		t1 = clamp_int(factor*(3-2)+2+3*near, near+1, maxval)
		t2 = clamp_int(factor*(7-3)+3+5*near, t1, maxval)
		t3 = clamp_int(factor*(21-4)+4+7*near, t2, maxval)
		return
	}
	factor := 256 / (maxval + 1)
	t1 = clamp_int(max(2, 3/factor+3*near), near+1, maxval)
	t2 = clamp_int(max(3, 7/factor+5*near), t1, maxval)
	t3 = clamp_int(max(4, 21/factor+7*near), t2, maxval)
	return
}

@(private)
clamp_int :: proc "contextless" (v, lo, hi: int) -> int {
	return min(max(v, lo), hi)
}

@(private)
jls_component_index :: proc "contextless" (s: ^JLS_State, id: int) -> int {
	for i in 0 ..< s.ncomp {
		if s.comps[i].id == id do return i
	}
	return -1
}

@(private)
jls_alloc_lines :: proc (s: ^JLS_State) -> JLS_Error {
	s.stride = s.width + 4
	for c in 0 ..< s.ncomp {
		prev := make([]i32, s.stride)
		cur := make([]i32, s.stride)
		if prev == nil || cur == nil {
			delete(prev)
			delete(cur)
			return .Out_Of_Memory
		}
		s.prev[c] = prev
		s.cur[c] = cur
		s.comps[c].plane = make([]u16, s.width * s.height)
		if s.comps[c].plane == nil do return .Out_Of_Memory
	}
	return .None
}

@(private)
jls_free_lines :: proc (s: ^JLS_State) {
	for c in 0 ..< JLS_MAX_COMPONENTS {
		if s.prev[c] != nil do delete(s.prev[c])
		if s.cur[c] != nil do delete(s.cur[c])
		if s.comps[c].plane != nil do delete(s.comps[c].plane)
		s.prev[c] = nil
		s.cur[c] = nil
		s.comps[c].plane = nil
	}
}

// Decodes one scan (starting right after the SOS segment header) and stops at the marker
// that terminates the entropy data.
@(private)
jls_decode_scan :: proc (s: ^JLS_State, scan_comps: []int, near, ilv, pos: int, data: []u8) -> (JLS_Error, int) {
	s.near = near
	s.range = (s.maxval + 2 * near) / (2 * near + 1) + 1
	s.qbpp = jls_log2_ceil(s.range)
	s.bits_pp = jls_log2_ceil(s.maxval)
	s.limit = 2 * (s.bits_pp + max(8, s.bits_pp))
	s.interleave = ilv
	jls_reset_contexts(s)
	jls_clear_lines(s)
	jls_bits_init(&s.bits, data, pos)

	restart := 0
	_ = restart
	line := 0
	for line < s.height {
		for c in scan_comps {
			s.prev[c][1 + s.width] = s.prev[c][s.width]
			s.cur[c][0] = s.prev[c][1]
		}
		switch ilv {
		case 0, 1:
			for c in scan_comps {
				if ilv == 1 do s.run_index = s.run_index_comp[c]
				if !jls_decode_line_comp(s, c) do return .Bad_Codestream, s.bits.pos
				if ilv == 1 do s.run_index_comp[c] = s.run_index
			}
		case 2:
			if !jls_decode_line_sample(s) do return .Bad_Codestream, s.bits.pos
		case:
			return .Unsupported_Feature, s.bits.pos
		}
		// Commit the line to the component planes.
		if line < 2 {
		}
		for c in scan_comps {
			for x in 0 ..< s.width {
				s.comps[c].plane[line * s.width + x] = u16(s.cur[c][1 + x])
			}
		}
		// Swap previous/current.
		for c in scan_comps {
			tmp := s.prev[c]
			s.prev[c] = s.cur[c]
			s.cur[c] = tmp
		}
		line += 1
	}
	return .None, s.bits.pos
}

// Decodes one raw JPEG-LS codestream (SOI..EOI) into info.frame_bytes bytes.
jls_decode_codestream :: proc (cs: []u8, dst: []u8, info: JLS_Image) -> JLS_Error {
	if len(dst) < info.frame_bytes do return .Output_Too_Small
	if len(cs) < 4 || cs[0] != 0xFF || cs[1] != 0xD8 do return .Bad_Codestream

	s: JLS_State
	defer jls_free_lines(&s)
	frame_seen := false
	preset_maxval := 0
	preset_t1, preset_t2, preset_t3, preset_reset := 0, 0, 0, 0
	has_preset := false
	restart_interval := 0
	decoded_any := false

	p := 2
	for {
		for p + 1 < len(cs) && cs[p] == 0xFF && cs[p + 1] == 0xFF do p += 1
		if p + 2 > len(cs) do break
		if cs[p] != 0xFF do return .Bad_Codestream
		m := int(u16(cs[p]) << 8 | u16(cs[p + 1]))
		p += 2
		if m == 0xFFD9 do break // EOI
		if m == 0xFF01 || (m >= 0xFFD0 && m <= 0xFFD7) do continue
		if p + 2 > len(cs) do return .Bad_Codestream
		l := int(u16(cs[p]) << 8 | u16(cs[p + 1]))
		if l < 2 || p + l > len(cs) do return .Bad_Codestream
		seg := cs[p + 2:p + l]
		switch m {
		case 0xFFF7: // SOF55 (JPEG-LS)
			if len(seg) < 6 do return .Bad_Codestream
			s.precision = int(seg[0])
			s.height = int(u16(seg[1]) << 8 | u16(seg[2]))
			s.width = int(u16(seg[3]) << 8 | u16(seg[4]))
			s.ncomp = int(seg[5])
			if s.ncomp < 1 || s.ncomp > JLS_MAX_COMPONENTS do return .Unsupported_Feature
			if s.precision < 2 || s.precision > 16 do return .Unsupported_Feature
			if s.width <= 0 || s.height <= 0 do return .Bad_Codestream
			if len(seg) < 6 + 3 * s.ncomp do return .Bad_Codestream
			for i in 0 ..< s.ncomp {
				s.comps[i].id = int(seg[6 + 3 * i])
				hv := seg[7 + 3 * i]
				if hv != 0x11 do return .Unsupported_Feature // JPEG-LS forbids subsampling
			}
			s.maxval = (1 << u32(s.precision)) - 1
			if err := jls_alloc_lines(&s); err != .None do return err
			frame_seen = true
		case 0xFFF8: // LSE
			if len(seg) < 1 do return .Bad_Codestream
			lse_type := int(seg[0])
			if lse_type == 1 {
				if len(seg) < 11 do return .Bad_Codestream
				preset_maxval = int(u16(seg[1]) << 8 | u16(seg[2]))
				preset_t1 = int(u16(seg[3]) << 8 | u16(seg[4]))
				preset_t2 = int(u16(seg[5]) << 8 | u16(seg[6]))
				preset_t3 = int(u16(seg[7]) << 8 | u16(seg[8]))
				preset_reset = int(u16(seg[9]) << 8 | u16(seg[10]))
				has_preset = true
			} else {
				return .Unsupported_Feature // mapping tables / SPIFF
			}
		case 0xFFDD: // DRI
			if len(seg) < 2 do return .Bad_Codestream
			restart_interval = int(u16(seg[0]) << 8 | u16(seg[1]))
		case 0xFFDA: // SOS
			if !frame_seen do return .Bad_Codestream
			if len(seg) < 1 do return .Bad_Codestream
			ns := int(seg[0])
			if ns < 1 || ns > s.ncomp do return .Bad_Codestream
			if len(seg) < 1 + 2 * ns + 3 do return .Bad_Codestream
			scan_comps := make([]int, ns)
			defer delete(scan_comps)
			for i in 0 ..< ns {
				id := int(seg[1 + 2 * i])
				ci := jls_component_index(&s, id)
				if ci < 0 do return .Bad_Codestream
				scan_comps[i] = ci
			}
			near := int(seg[1 + 2 * ns])
			ilv := int(seg[2 + 2 * ns])
			ahal := int(seg[3 + 2 * ns])
			if ahal != 0 do return .Unsupported_Feature
			if ilv < 0 || ilv > 2 do return .Unsupported_Feature
			// Resolve coding parameters for this scan.
			s.maxval = preset_maxval if has_preset && preset_maxval != 0 else (1 << u32(s.precision)) - 1
			if near < 0 || near > s.maxval / 2 do return .Bad_Codestream
			if has_preset {
				s.t1, s.t2, s.t3, s.reset_thr = preset_t1, preset_t2, preset_t3, preset_reset
			} else {
				d1, d2, d3, dr := jls_default_thresholds(s.maxval, near)
				s.t1, s.t2, s.t3, s.reset_thr = d1, d2, d3, dr
			}
			err, new_pos := jls_decode_scan(&s, scan_comps, near, ilv, p + l, cs)
			if err != .None {
				return err
			}
			p = new_pos
			decoded_any = true
			continue
		case:
			// APPn, COM and anything else: skip by length.
		}
		p += l
	}
	if !frame_seen || !decoded_any do return .Bad_Codestream
	_ = restart_interval

	// Assemble interleaved samples in frame component order.
	samples := info.samples
	if samples != s.ncomp do return .Invalid_Image_Parameters
	if s.width != info.cols || s.height != info.rows do return .Invalid_Image_Parameters
	for y in 0 ..< s.height {
		for x in 0 ..< s.width {
			base := (y * s.width + x) * samples
			for c in 0 ..< samples {
				v := s.comps[c].plane[y * s.width + x]
				if info.bytes_per_sample == 1 {
					dst[base + c] = u8(v & 0xFF)
				} else {
					i := (base + c) * 2
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
jls_attribute :: proc (doc: ^Document, tag: Tag) -> (v: int, ok: bool) {
	e, found := document_find(doc, tag)
	if !found do return 0, false
	if e.vr == .IS {
		n, nok := value_is(doc, e)
		return n, nok
	}
	u, uok := value_u64(doc, e)
	return int(u), uok
}

jls_image_info :: proc(doc: ^Document, pixel: Element) -> (info: JLS_Image, err: JLS_Error) {
	if doc.ts.uid != JPEG_LS_LOSSLESS_UID && doc.ts.uid != JPEG_LS_NEAR_UID {
		return {}, .Not_JPEG_LS_Transfer_Syntax
	}
	if .Encapsulated not_in pixel.flags do return {}, .Not_Encapsulated
	rows, ok_rows := jls_attribute(doc, Tag{0x0028, 0x0010})
	cols, ok_cols := jls_attribute(doc, Tag{0x0028, 0x0011})
	bits, ok_bits := jls_attribute(doc, Tag{0x0028, 0x0100})
	if !ok_rows || !ok_cols || !ok_bits do return {}, .Missing_Image_Attributes
	samples, ok_samples := jls_attribute(doc, Tag{0x0028, 0x0002})
	if !ok_samples do samples = 1
	frames, ok_frames := jls_attribute(doc, Tag{0x0028, 0x0008})
	if !ok_frames do frames = 1
	if rows <= 0 || cols <= 0 || bits <= 0 || (bits % 8) != 0 || bits > 16 ||
	   samples <= 0 || samples > JLS_MAX_COMPONENTS || frames <= 0 {
		return {}, .Invalid_Image_Parameters
	}
	bps := bits / 8
	info = JLS_Image{
		rows = rows, cols = cols, samples = samples, bits = bits, frames = frames,
		bytes_per_sample = bps, frame_bytes = rows * cols * samples * bps,
	}
	return info, .None
}

jls_decode_frame :: proc(
	doc:         ^Document,
	pixel:       Element,
	frame_index: int,
	dst:         []u8,
	info:        JLS_Image,
) -> JLS_Error {
	if frame_index < 0 || frame_index >= info.frames do return .Invalid_Image_Parameters
	cs, owned, ok := encapsulated_frame_codestream(doc, pixel, frame_index, info.frames)
	if !ok do return .Bad_Codestream
	// defer is block-scoped in Odin: the conditional must live at proc scope, or the buffer
	// would be freed before the codestream is decoded.
	defer if owned do delete(cs)
	return jls_decode_codestream(cs, dst, info)
}

jls_decode :: proc(doc: ^Document, pixel: Element, dst: []u8) -> (written: int, err: JLS_Error) {
	info, ierr := jls_image_info(doc, pixel)
	if ierr != .None do return 0, ierr
	if len(dst) < info.frame_bytes * info.frames do return 0, .Output_Too_Small
	for f in 0 ..< info.frames {
		frame := dst[f * info.frame_bytes:(f + 1) * info.frame_bytes]
		e := jls_decode_frame(doc, pixel, f, frame, info)
		if e != .None do return f * info.frame_bytes, e
	}
	return info.frame_bytes * info.frames, .None
}
