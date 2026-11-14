package dicom

// Step 8 (part 1): Tier-1 EBCOT bit-plane decoder and its MQ/raw entropy backends,
// ported from OpenJPEG 2.5.3 t1.c / mqc.c / mqc_inl.h (BSD-2-Clause, UCLouvain).
//
// Flag word layout (t1.h): one u32 per code-block column covers 4 rows; each sample ci
// owns a 3-bit-shifted window with sigma at bit 4+3ci, its sign (CHI) at 19+3ci
// (18/19/22/25 for ci=0..3), PI at 21+3ci and MU at 20+3ci. Code-block samples are
// stored column-major: sample (x, y) lives at data[y*w + x].

@(private)
MQC_STATES := mqc_states
@(private)
LUT_ZC  := lut_ctxno_zc
@(private)
LUT_SC  := lut_ctxno_sc
@(private)
LUT_SPB := lut_spb

@(private)
T1 :: struct {
	mq:     MQ,
	data:   [dynamic]i32,
	flags:  [dynamic]u32,
	w:      int,
	h:      int,
	orient: int, // subband: 0 LL, 1 HL, 2 LH, 3 HH
}

@(private)
sigma_this :: proc "contextless" (ci: int) -> u32 { return 1 << u32(4 + ci * 3) }
@(private)
pi_this    :: proc "contextless" (ci: int) -> u32 { return 1 << u32(21 + ci * 3) }
@(private)
mu_this    :: proc "contextless" (ci: int) -> u32 { return 1 << u32(20 + ci * 3) }


PI_ALL :: u32(0x49200000) // pi_this(0..3) = bits 21,24,27,30

// Neighbour sigma mask within a sample's shifted window: bits 0..3,5..8 (0x1EF).
@(private)
SN_MASK :: u32(0x1EF)

@(private)
t1_ctxno_zc :: proc "contextless" (orient: int, f: u32) -> int {
	return int(LUT_ZC[orient * 512 + int(f & SN_MASK)])
}

@(private)
t1_ctxno_mag :: proc "contextless" (f: u32) -> u32 {
	// f is the shifted window of sample ci.
	tmp: u32 = CTX_MAG
	if (f & SN_MASK) != 0 do tmp = CTX_MAG + 1
	if (f & (1 << 20)) != 0 do tmp = CTX_MAG + 2
	return tmp
}

// Sign-coding LUT index; ports opj_t1_getctxtno_sc_or_spb_index verbatim.
@(private)
t1_lu_sc :: proc "contextless" (fx, pfx, nfx: u32, ci: int) -> u32 {
	lu := (fx >> u32(ci * 3)) & u32(SN_MASK & (1<<1 | 1<<3 | 1<<5 | 1<<7))
	lu |= (pfx >> u32(19 + ci * 3)) & 1                       // SGN_W
	lu |= (nfx >> u32(19 - 2 + ci * 3)) & (1 << 2)            // SGN_E
	if ci == 0 {
		lu |= (fx >> 14) & (1 << 4) // SGN_N: (CHI_0_I - 4) = 14
	} else {
		lu |= (fx >> u32(15 + (ci - 1) * 3)) & (1 << 4) // (CHI_1_I - 4 + (ci-1)*3)
	}
	lu |= (fx >> u32(16 + ci * 3)) & (1 << 6) // SGN_S: (CHI_2_I - 6) = 16
	return lu
}

// Marks sample ci significant with sign s. fp is the column index in the flags array;
// neighbour columns are updated in place, the sample's own word through `local`.
@(private)
t1_update_sig :: proc "contextless" (f: []u32, fp: int, ci: int, s: u32, stride: int, vsc: bool, local: ^u32) {
	f[fp - 1] |= 1 << u32(5 + ci * 3) // E neighbour of previous column
	local^ |= (s << u32(19 + ci * 3)) | (1 << u32(4 + ci * 3))
	f[fp + 1] |= 1 << u32(3 + ci * 3) // W neighbour of next column
	if ci == 0 && !vsc {
		north := fp - stride
		f[north] |= (s << 31) | (1 << 16) // CHI_5 + SIGMA_16
		f[north - 1] |= 1 << 17
		f[north + 1] |= 1 << 15
	}
	if ci == 3 {
		south := fp + stride
		f[south] |= (s << 18) | (1 << 1) // CHI_0 + SIGMA_1
		f[south - 1] |= 1 << 2
		f[south + 1] |= 1
	}
}

@(private)
t1_allocate :: proc(t1: ^T1, w, h: int) -> J2K_Error {
	t1.w = w
	t1.h = h
	clear(&t1.data)
	resize(&t1.data, w * h)

	stride := w + 2
	rows := (h + 3) / 4
	clear(&t1.flags)
	resize(&t1.flags, (rows + 2) * stride)
	for i in 0 ..< len(t1.flags) {
		t1.flags[i] = 0
	}
	for x in 0 ..< stride {
		t1.flags[x] = PI_ALL
		t1.flags[(rows + 1) * stride + x] = PI_ALL
	}
	if h % 4 != 0 {
		v: u32 = PI_ALL
		if h % 4 == 1 {
			v = pi_this(1) | pi_this(2) | pi_this(3)
		} else if h % 4 == 2 {
			v = pi_this(2) | pi_this(3)
		} else {
			v = pi_this(3)
		}
		for x in 0 ..< stride {
			t1.flags[rows * stride + x] = v
		}
	}
	return .None
}

@(private)
t1_dec_sigpass :: proc(t1: ^T1, bpno: int, cblksty: u32, raw_mode: bool) {
	w := t1.w
	h := t1.h
	stride := w + 2
	oneplushalf: i32 = i32((1 << u32(bpno)) | ((1 << u32(bpno)) >> 1))
	mq := &t1.mq
	data := t1.data[:]
	flags := t1.flags[:]
	vsc := (cblksty & 0x08) != 0

	fp := stride + 1
	dp := 0
	k := 0
	for ; k < (h & ~int(3)); k += 4 {
		for i in 0 ..< w {
			fl := flags[fp]
			if fl != 0 {
				for ci in 0 ..< 4 {
					if (fl & (sigma_this(ci) | pi_this(ci))) == 0 && (fl & (SN_MASK << u32(ci * 3))) != 0 {
						if raw_mode {
							if mq_raw_decode(mq) != 0 {
								v := mq_raw_decode(mq)
								data[dp + ci * w] = -oneplushalf if v != 0 else oneplushalf
								t1_update_sig(flags, fp, ci, v, stride, vsc && ci == 0, &fl)
							}
							fl |= pi_this(ci)
							flags[fp] = fl
						} else {
							mq.curctx = t1_ctxno_zc(t1.orient, fl >> u32(ci * 3))
							v := mq_decode(mq)
							if v != 0 {
								lu := t1_lu_sc(fl, flags[fp - 1], flags[fp + 1], ci)
								mq.curctx = int(LUT_SC[lu])
								v = mq_decode(mq) ~ u32(LUT_SPB[lu])
								data[dp + ci * w] = -oneplushalf if v != 0 else oneplushalf
								t1_update_sig(flags, fp, ci, v, stride, vsc && ci == 0, &fl)
							}
							fl |= pi_this(ci)
							flags[fp] = fl
						}
					}
				}
			}
			fp += 1
			dp += 1
		}
		fp += 2
		dp += 3 * w
	}
	if k < h {
		for i in 0 ..< w {
			for j in 0 ..< h - k {
				fl := flags[fp]
				if (fl & (sigma_this(j) | pi_this(j))) == 0 && (fl & (SN_MASK << u32(j * 3))) != 0 {
					if raw_mode {
						if mq_raw_decode(mq) != 0 {
							v := mq_raw_decode(mq)
							data[dp + j * w] = -oneplushalf if v != 0 else oneplushalf
							t1_update_sig(flags, fp, j, v, stride, vsc, &fl)
						}
						flags[fp] = fl | pi_this(j)
					} else {
						mq.curctx = t1_ctxno_zc(t1.orient, fl >> u32(j * 3))
						v := mq_decode(mq)
						if v != 0 {
							lu := t1_lu_sc(fl, flags[fp - 1], flags[fp + 1], j)
							mq.curctx = int(LUT_SC[lu])
							v = mq_decode(mq) ~ u32(LUT_SPB[lu])
							data[dp + j * w] = -oneplushalf if v != 0 else oneplushalf
							t1_update_sig(flags, fp, j, v, stride, vsc, &fl)
						}
						flags[fp] = fl | pi_this(j)
					}
				}
			}
			fp += 1
			dp += 1
		}
	}
}

@(private)
t1_dec_refpass :: proc(t1: ^T1, bpno: int, raw_mode: bool) {
	w := t1.w
	h := t1.h
	stride := w + 2
	poshalf: i32 = i32((1 << u32(bpno)) >> 1)
	mq := &t1.mq
	data := t1.data[:]
	flags := t1.flags[:]

	fp := stride + 1
	dp := 0
	k := 0
	for ; k < (h & ~int(3)); k += 4 {
		for i in 0 ..< w {
			fl := flags[fp]
			if fl != 0 {
				for ci in 0 ..< 4 {
					if (fl & (sigma_this(ci) | pi_this(ci))) == sigma_this(ci) {
						if raw_mode {
							v := mq_raw_decode(mq)
							d := data[dp + ci * w]
							d += poshalf if (v != 0) != (d < 0) else -poshalf
							data[dp + ci * w] = d
						} else {
							mq.curctx = int(t1_ctxno_mag(fl >> u32(ci * 3)))
							v := mq_decode(mq)
							d := data[dp + ci * w]
							d += poshalf if (v != 0) != (d < 0) else -poshalf
							data[dp + ci * w] = d
						}
						fl |= mu_this(ci)
						flags[fp] = fl
					}
				}
			}
			fp += 1
			dp += 1
		}
		fp += 2
		dp += 3 * w
	}
	if k < h {
		for i in 0 ..< w {
			for j in 0 ..< h - k {
				fl := flags[fp]
				if (fl & (sigma_this(j) | pi_this(j))) == sigma_this(j) {
					if raw_mode {
						v := mq_raw_decode(mq)
						d := data[dp + j * w]
						d += poshalf if (v != 0) != (d < 0) else -poshalf
						data[dp + j * w] = d
					} else {
						mq.curctx = int(t1_ctxno_mag(fl >> u32(j * 3)))
						v := mq_decode(mq)
						d := data[dp + j * w]
						d += poshalf if (v != 0) != (d < 0) else -poshalf
						data[dp + j * w] = d
					}
					flags[fp] = fl | mu_this(j)
				}
			}
			fp += 1
			dp += 1
		}
	}
}

@(private)
t1_dec_clnpass :: proc(t1: ^T1, bpno: int, cblksty: u32) {
	w := t1.w
	h := t1.h
	stride := w + 2
	oneplushalf: i32 = i32((1 << u32(bpno)) | ((1 << u32(bpno)) >> 1))
	mq := &t1.mq
	data := t1.data[:]
	flags := t1.flags[:]
	vsc := (cblksty & 0x08) != 0
	orient := t1.orient

	cln_step :: proc "contextless" (
		check: bool, partial: bool,
		flags: []u32, fp: int, ci: int, dp: int, w: int, stride: int,
		mq: ^MQ, orient: int, data: []i32, oneplushalf: i32, vsc: bool,
	) {
		if !check || (flags[fp] & (sigma_this(ci) | pi_this(ci))) == 0 {
			do_sign := partial
			if !do_sign {
				mq.curctx = t1_ctxno_zc(orient, flags[fp] >> u32(ci * 3))
				if mq_decode(mq) != 0 {
					do_sign = true
				}
			}
			if do_sign {
				fl := flags[fp]
				lu := t1_lu_sc(fl, flags[fp - 1], flags[fp + 1], ci)
				mq.curctx = int(LUT_SC[lu])
				v := mq_decode(mq) ~ u32(LUT_SPB[lu])
				data[dp + ci * w] = -oneplushalf if v != 0 else oneplushalf
				t1_update_sig(flags, fp, ci, v, stride, vsc, &fl)
				flags[fp] = fl
			}
		}
	}

	fp := stride + 1
	dp := 0
	k := 0
	for ; k < (h & ~int(3)); k += 4 {
		for i in 0 ..< w {
			if flags[fp] == 0 {
				mq.curctx = CTX_AGG
				if mq_decode(mq) != 0 {
					mq.curctx = CTX_UNI
					runlen := mq_decode(mq) << 1
					runlen |= mq_decode(mq)
					partial := true
					for ci in 0 ..< 4 {
						if ci >= int(runlen) {
							cln_step(false, partial, flags, fp, ci, dp, w, stride, mq, orient, data, oneplushalf, vsc && ci == 0)
							partial = false
						}
					}
				}
			} else {
				for ci in 0 ..< 4 {
					cln_step(true, false, flags, fp, ci, dp, w, stride, mq, orient, data, oneplushalf, vsc && ci == 0)
				}
			}
			flags[fp] &= ~PI_ALL
			fp += 1
			dp += 1
		}
		fp += 2
		dp += 3 * w
	}
	if k < h {
		for i in 0 ..< w {
			for j in 0 ..< h - k {
				cln_step(true, false, flags, fp, j, dp, w, stride, mq, orient, data, oneplushalf, vsc)
			}
			flags[fp] &= ~PI_ALL
			fp += 1
			dp += 1
		}
	}
}

// Decodes one code-block: `src` is the concatenated segment data, segs the pass/length
// segmentation built by Tier-2. Port of opj_t1_decode_cblk (reversible, roishift 0).

@(private)
t1_decode_cblk :: proc(t1: ^T1, src: []u8, segs: []J2K_Seg, numbps: int, cblksty: u32) {
	err := t1_allocate(t1, t1.w, t1.h)
	_ = err

	bpno_plus_one := numbps
	passtype := 2
	mq_reset(&t1.mq)

	data_index := 0
	for segno in 0 ..< len(segs) {
		seg := &segs[segno]
		raw := (cblksty & 0x01) != 0 && passtype < 2 && bpno_plus_one <= numbps - 4
		seg_src := src[data_index:data_index + int(seg.len)]
		if raw {
			mq_init_raw(&t1.mq, seg_src)
		} else {
			mq_init_dec(&t1.mq, seg_src)
		}
		data_index += int(seg.len)

		for passno := u32(0); passno < seg.real_num_passes && bpno_plus_one >= 1; passno += 1 {
			switch passtype {
			case 0: t1_dec_sigpass(t1, bpno_plus_one, cblksty, raw)
			case 1: t1_dec_refpass(t1, bpno_plus_one, raw)
			case:   t1_dec_clnpass(t1, bpno_plus_one, cblksty)
			}
			if (cblksty & 0x02) != 0 && !raw {
				mq_reset(&t1.mq)
			}
			passtype += 1
			if passtype == 3 {
				passtype = 0
				bpno_plus_one -= 1
			}
		}
	}

	// SEGSYM check (informational; mismatch tolerated like OpenJPEG warnings).
	if (cblksty & 0x20) != 0 && len(segs) > 0 {
		t1.mq.curctx = CTX_UNI
		v := mq_decode(&t1.mq)
		v = (v << 1) | mq_decode(&t1.mq)
		v = (v << 1) | mq_decode(&t1.mq)
		v = (v << 1) | mq_decode(&t1.mq)
		_ = v
	}
}

// ---------------------------------------------------------------------------------------------
// MQ arithmetic decoder (ISO 15444-1 Annex C) + raw (bypass) mode. Read-only buffer:
// bytein synthesizes a terminating 0xFF instead of overwriting the codestream.
// ---------------------------------------------------------------------------------------------

MQ :: struct {
	c:      u32,
	a:      u32,
	ct:     u32,
	eofcnt: u32,
	buf:    []u8,
	bp:     int,
	ctx:    [19]int,
	curctx: int,
}

CTX_ZC  :: 0
CTX_SC  :: 9
CTX_MAG :: 14
CTX_AGG :: 17
CTX_UNI :: 18

@(private)
mq_bytein :: proc "contextless" (m: ^MQ) {
	if m.bp + 1 >= len(m.buf) {
		m.c += 0xFF00
		m.ct = 8
		m.eofcnt += 1
	} else if m.buf[m.bp] == 0xFF {
		if m.buf[m.bp + 1] > 0x8F {
			m.c += 0xFF00
			m.ct = 8
			m.eofcnt += 1
		} else {
			m.bp += 1
			m.c += u32(m.buf[m.bp]) << 9
			m.ct = 7
		}
	} else {
		m.bp += 1
		m.c += u32(m.buf[m.bp]) << 8
		m.ct = 8
	}
}

@(private)
mq_renorm :: proc "contextless" (m: ^MQ) {
	for m.a < 0x8000 {
		if m.ct == 0 {
			mq_bytein(m)
		}
		m.a <<= 1
		m.c <<= 1
		m.ct -= 1
	}
}

@(private)
mq_decode :: proc "contextless" (m: ^MQ) -> u32 {
	st := MQC_STATES[m.ctx[m.curctx]]
	qe := u32(st.qeval)
	mps := u32(st.mps)
	m.a -= qe
	d: u32 = 0
	if (m.c >> 16) < qe {
		if m.a < qe {
			m.a = qe
			d = mps
			m.ctx[m.curctx] = int(st.nmps)
		} else {
			m.a = qe
			d = 1 - mps
			m.ctx[m.curctx] = int(st.nlps)
		}
		mq_renorm(m)
	} else {
		m.c -= qe << 16
		if (m.a & 0x8000) == 0 {
			if m.a < qe {
				d = 1 - mps
				m.ctx[m.curctx] = int(st.nlps)
			} else {
				d = mps
				m.ctx[m.curctx] = int(st.nmps)
			}
			mq_renorm(m)
		} else {
			d = mps
		}
	}
	return d
}

@(private)
mq_init_dec :: proc "contextless" (m: ^MQ, src: []u8) {
	m.buf = src
	m.bp = 0
	m.eofcnt = 0
	if len(src) > 0 {
		m.c = u32(src[0]) << 16
	} else {
		m.c = u32(0xFF) << 16
	}
	mq_bytein(m)
	m.c <<= 7
	m.ct -= 7
	m.a = 0x8000
}

@(private)
mq_init_raw :: proc "contextless" (m: ^MQ, src: []u8) {
	m.buf = src
	m.bp = 0
	m.c = 0
	m.ct = 0
	m.eofcnt = 0
}

@(private)
mq_raw_decode :: proc "contextless" (m: ^MQ) -> u32 {
	if m.ct == 0 {
		next: u32 = 0xFF
		if m.bp + 1 < len(m.buf) {
			next = u32(m.buf[m.bp + 1])
		}
		if m.c == 0xFF {
			if next > 0x8F {
				m.c = 0xFF
				m.ct = 8
			} else {
				m.bp += 1
				m.c = next
				m.ct = 7
			}
		} else {
			m.bp += 1
			m.c = next
			m.ct = 8
		}
	}
	m.ct -= 1
	return (m.c >> m.ct) & 1
}

@(private)
mq_reset :: proc "contextless" (m: ^MQ) {
	for i in 0 ..< 19 {
		m.ctx[i] = 0
	}
	m.ctx[CTX_UNI] = 46 << 1 // state index = msb + (prob << 1)
	m.ctx[CTX_AGG] = 3 << 1
	m.ctx[CTX_ZC] = 4 << 1 // only context 0, as in opj_t1_decode_cblk
	m.curctx = 0
}

// ---------------------------------------------------------------------------------------------
// Packet-header bit reader (bio) with 0xFF bit stuffing.
// ---------------------------------------------------------------------------------------------

Bio :: struct {
	buf: u32,
	ct:  int,
	pos: int,
	end: int,
	src: []u8,
}

@(private)
bio_init :: proc "contextless" (b: ^Bio, src: []u8, pos: int) {
	b.buf = 0
	b.ct = 0
	b.pos = pos
	b.end = len(src)
	b.src = src
}

@(private)
bio_bytein :: proc "contextless" (b: ^Bio) -> bool {
	b.buf = (b.buf << 8) & 0xFFFF
	b.ct = 7 if b.buf == 0xFF00 else 8
	if b.pos >= b.end do return false
	b.buf |= u32(b.src[b.pos])
	b.pos += 1
	return true
}

@(private)
bio_read :: proc "contextless" (b: ^Bio, n: int) -> u32 {
	v: u32 = 0
	for i := n - 1; i >= 0; i -= 1 {
		if b.ct == 0 && !bio_bytein(b) do break
		b.ct -= 1
		v |= u32((b.buf >> u32(b.ct)) & 1) << u32(i)
	}
	return v
}

@(private)
bio_inalign :: proc "contextless" (b: ^Bio) -> bool {
	if (b.buf & 0xFF) == 0xFF {
		return bio_bytein(b)
	}
	b.ct = 0
	return true
}

// ---------------------------------------------------------------------------------------------
// Tag tree (precinct inclusion / zero-bitplanes).
// ---------------------------------------------------------------------------------------------

Tag_Node :: struct {
	value:  i32,
	low:    i32,
	parent: int, // index of parent node, -1 for root
}

Tag_Tree :: struct {
	nodes: [dynamic]Tag_Node,
}

@(private)
tag_tree_create :: proc(t: ^Tag_Tree, numleafsh, numleafv: int) -> J2K_Error {
	nplh: [32]int
	nplv: [32]int
	numlvls := 0
	nplh[0] = numleafsh
	nplv[0] = numleafv
	total := 0
	for {
		n := nplh[numlvls] * nplv[numlvls]
		nplh[numlvls + 1] = (nplh[numlvls] + 1) / 2
		nplv[numlvls + 1] = (nplv[numlvls] + 1) / 2
		total += n
		numlvls += 1
		if n <= 1 do break
	}
	resize(&t.nodes, total)
	tag_tree_reset(t)

	node := 0
	parent := numleafsh * numleafv
	parent0 := parent
	for i in 0 ..< max(numlvls - 1, 0) {
		for j in 0 ..< nplv[i] {
			k := nplh[i]
			for k > 0 {
				k -= 1
				t.nodes[node].parent = parent
				node += 1
				if k > 0 {
					k -= 1
					t.nodes[node].parent = parent
					node += 1
				}
				parent += 1
			}
			if (j & 1) != 0 || j == nplv[i] - 1 {
				parent0 = parent
			} else {
				parent = parent0
				parent0 += nplh[i]
			}
		}
	}
	for i in node ..< len(t.nodes) {
		t.nodes[i].parent = -1
	}
	return .None
}

@(private)
tag_tree_reset :: proc "contextless" (t: ^Tag_Tree) {
	for i in 0 ..< len(t.nodes) {
		t.nodes[i].value = 999
		t.nodes[i].low = 0
	}
}

@(private)
tag_tree_decode :: proc "contextless" (b: ^Bio, t: ^Tag_Tree, leafno: int, threshold: i32) -> u32 {
	stk: [31]int
	sp := 0
	node := leafno
	for t.nodes[node].parent >= 0 {
		stk[sp] = node
		sp += 1
		node = t.nodes[node].parent
	}
	low: i32 = 0
	for {
		if low > t.nodes[node].low {
			t.nodes[node].low = low
		} else {
			low = t.nodes[node].low
		}
		for low < threshold && low < t.nodes[node].value {
			if bio_read(b, 1) != 0 {
				t.nodes[node].value = low
			} else {
				low += 1
			}
		}
		t.nodes[node].low = low
		if sp == 0 do break
		sp -= 1
		node = stk[sp]
	}
	return 1 if t.nodes[node].value < threshold else 0
}
