package dicom
// Step 8 (part 2): JPEG 2000 Lossless codestream driver — marker parsing, tile geometry,
// Tier-2 packet decoding, inverse 5/3 DWT, RCT/MCT and DC level shift, plus the DICOM
// encapsulation wrapper. Marker and geometry logic ports OpenJPEG 2.5.3 j2k.c / tcd.c /
// pi.c (BSD-2-Clause, UCLouvain); Tier-1 lives in j2k_t1.odin.
import "core:encoding/endian"
import "core:mem"
J2K_UID :: "1.2.840.10008.1.2.4.90"
J2K_UID_J2K :: "1.2.840.10008.1.2.4.91" // lossless-or-lossy; accepted only when the codestream is 5/3 reversible
J2K_Error :: enum u8 {
	None                       = 0,
	Not_J2K_Transfer_Syntax,
	Not_Encapsulated,
	Missing_Image_Attributes,
	Invalid_Image_Parameters,
	Bad_Codestream,
	Unsupported_Feature,
	Bad_Packet,
	Out_Of_Memory,
	Output_Too_Small,
}
J2K_Image :: struct {
	rows:             int,
	cols:             int,
	samples:          int,
	bits:             int,
	signed:           bool,
	frames:           int,
	bytes_per_sample: int,
	frame_bytes:      int,
}
@(private) J2K_MAX_COMPONENTS :: 4
@(private) J2K_MAX_RES_LEVELS :: 33
// Upper bound on decoded samples per codestream/tile-component: keeps crafted SIZ
// headers from forcing multi-gigabyte allocations during decode or fuzzing.
@(private) J2K_MAX_SAMPLES :: 1 << 27
@(private) MARKER_SOC :: 0xFF4F
@(private) MARKER_SIZ :: 0xFF51
@(private) MARKER_COD :: 0xFF52
@(private) MARKER_COC :: 0xFF53
@(private) MARKER_RGN :: 0xFF5E
@(private) MARKER_QCD :: 0xFF5C
@(private) MARKER_QCC :: 0xFF5D
@(private) MARKER_POC :: 0xFF5F
@(private) MARKER_PPM :: 0xFF60
@(private) MARKER_PPT :: 0xFF61
@(private) MARKER_SOT :: 0xFF90
@(private) MARKER_SOD :: 0xFF93
@(private) MARKER_EOC :: 0xFFD9
// ---------------------------------------------------------------------------------------------
// Codestream parameters.
// ---------------------------------------------------------------------------------------------
@(private)
J2K_Comp :: struct {
	prec: int,
	sgnd: bool,
	dx:   int,
	dy:   int,
}
@(private)
J2K_Coding :: struct {
	prg:       int, // 0 LRCP, 1 RLCP, 2 RPCL, 3 PCRL, 4 CPRL
	layers:    int,
	mct:       bool,
	sop:       bool,
	eph:       bool,
	levels:    int,
	cblkw:     int, // exponent
	cblkh:     int,
	cblksty:   u32,
	transform: int, // must be 1 (5/3 reversible)
	precincts: bool,
	prcw:      [J2K_MAX_RES_LEVELS]u8,
	prch:      [J2K_MAX_RES_LEVELS]u8,
	guard:     int,
	expn:      [J2K_MAX_RES_LEVELS * 3]u8,
}
@(private)
J2K_Params :: struct {
	xsiz:   u32,
	ysiz:   u32,
	xosiz:  u32,
	yosiz:  u32,
	xtsiz:  u32,
	ytsiz:  u32,
	xtosiz: u32,
	ytosiz: u32,
	tw:     int,
	th:     int,
	csiz:   int,
	comps:  [J2K_MAX_COMPONENTS]J2K_Comp,
	cod:    [J2K_MAX_COMPONENTS]J2K_Coding,
}
// Bounds-safe big-endian readers. A truncated codestream parks the cursor at the end
// and yields zero; the caller's marker checks then reject it instead of panicking.
@(private) rd_u8 :: proc "contextless" (b: []u8, p: ^int) -> u8 {
	if p^ < 0 || p^ >= len(b) {
		p^ = len(b)
		return 0
	}
	v := b[p^]
	p^ += 1
	return v
}
@(private) rd_u16 :: proc "contextless" (b: []u8, p: ^int) -> u16 {
	if p^ < 0 || p^ + 2 > len(b) {
		p^ = len(b)
		return 0
	}
	v, _ := endian.get_u16(b[p^:][:2], .Big)
	p^ += 2
	return v
}
@(private) rd_u32 :: proc "contextless" (b: []u8, p: ^int) -> u32 {
	if p^ < 0 || p^ + 4 > len(b) {
		p^ = len(b)
		return 0
	}
	v, _ := endian.get_u32(b[p^:][:4], .Big)
	p^ += 4
	return v
}
@(private) ceildiv_u32 :: proc "contextless" (a, b: u32) -> int {
	return int((u64(a) + u64(b) - 1) / u64(b))
}
@(private) ceildiv_i32 :: proc "contextless" (a, b: i32) -> i32 {
	return (a + b - 1) / b
}
@(private) ceildivpow2 :: proc "contextless" (a: i32, n: int) -> i32 {
	return (a + (1 << u32(n)) - 1) >> u32(n)
}
@(private) floordivpow2 :: proc "contextless" (a: i32, n: int) -> i32 {
	return a >> u32(n)
}
@(private) shl_i32 :: proc "contextless" (a: i32, n: int) -> i32 {
	return a << u32(n)
}
// Sets default precinct sizes (2^15) before optional SPcod precinct bytes.
@(private)
set_default_precincts :: proc "contextless" (cod: ^J2K_Coding) {
	for i in 0 ..< J2K_MAX_RES_LEVELS {
		cod.prch[i] = 15
		cod.prcw[i] = 15
	}
}
// Reads SGcod + SPcod of a COD segment; `p` starts right after Lcod.
@(private)
read_sp_cod :: proc "contextless" (cod: ^J2K_Coding, b: []u8, p: ^int) -> J2K_Error {
	scod := rd_u8(b, p)
	cod.prg = int(rd_u8(b, p))
	cod.layers = int(rd_u16(b, p))
	cod.mct = rd_u8(b, p) != 0
	cod.levels = int(rd_u8(b, p))
	if cod.levels >= J2K_MAX_RES_LEVELS do return .Unsupported_Feature
	cod.cblkw = int(rd_u8(b, p)) + 2
	cod.cblkh = int(rd_u8(b, p)) + 2
	cod.cblksty = u32(rd_u8(b, p))
	cod.transform = int(rd_u8(b, p))
	if cod.transform != 1 do return .Unsupported_Feature // 9/7 cannot appear in .90
	if (cod.cblksty & 0x40) != 0 do return .Unsupported_Feature // HT
	if cod.cblkw > 10 || cod.cblkh > 10 do return .Bad_Codestream
	cod.precincts = (scod & 1) != 0
	cod.sop = (scod & 2) != 0
	cod.eph = (scod & 4) != 0
	set_default_precincts(cod)
	if cod.precincts {
		for i in 0 ..< cod.levels + 1 {
			if p^ >= len(b) do return .Bad_Codestream
			v := rd_u8(b, p)
			cod.prch[i] = v >> 4
			cod.prcw[i] = v & 0x0F
		}
	}
	return .None
}
// Reads SPcod of a COC segment (no SGcod); `p` starts right after Lcoc+Ccoc+Scoc.
@(private)
read_sp_coc :: proc "contextless" (cod: ^J2K_Coding, b: []u8, p: ^int) -> J2K_Error {
	cod.levels = int(rd_u8(b, p))
	if cod.levels >= J2K_MAX_RES_LEVELS do return .Unsupported_Feature
	cod.cblkw = int(rd_u8(b, p)) + 2
	cod.cblkh = int(rd_u8(b, p)) + 2
	cod.cblksty = u32(rd_u8(b, p))
	cod.transform = int(rd_u8(b, p))
	if cod.transform != 1 do return .Unsupported_Feature
	if (cod.cblksty & 0x40) != 0 do return .Unsupported_Feature
	set_default_precincts(cod)
	if cod.precincts {
		for i in 0 ..< cod.levels + 1 {
			if p^ >= len(b) do return .Bad_Codestream
			v := rd_u8(b, p)
			cod.prch[i] = v >> 4
			cod.prcw[i] = v & 0x0F
		}
	}
	return .None
}
// Parses a QCD/QCC body into the per-band exponent table. `p0` points at Sqcd.
@(private)
read_q :: proc "contextless" (cod: ^J2K_Coding, b: []u8, p0: int, seg_end: int) -> J2K_Error {
	p := p0
	if p >= seg_end do return .Bad_Codestream
	sqcd := rd_u8(b, &p)
	style := sqcd & 0x1F
	cod.guard = int(sqcd >> 5)
	if style != 0 && style != 2 do return .Unsupported_Feature // no derived quantization
	nbands := 3 * cod.levels + 1
	i := 0
	for i < nbands {
		if style == 0 {
			if p >= seg_end do break
			cod.expn[i] = rd_u8(b, &p) >> 3
		} else {
			if p + 2 > seg_end do break
			cod.expn[i] = u8(rd_u16(b, &p) >> 11)
		}
		i += 1
	}
	// Truncated tables replicate the last exponent (OpenJPEG behaviour for derived style).
	last: u8 = cod.expn[i - 1] if i > 0 else 0
	for j in i ..< nbands {
		cod.expn[j] = last
	}
	return .None
}
// Band exponent index in resolution `res` (0-based), band `band` within it (res>0: 0..2).
@(private)
band_step_index :: proc "contextless" (res, band: int) -> int {
	if res == 0 do return 0
	return 1 + 3 * (res - 1) + band
}
// ---------------------------------------------------------------------------------------------
// Tile-part parsing: SOC..EOC into parameters plus one concatenated packet buffer per tile.
// ---------------------------------------------------------------------------------------------
// Parses a whole frame codestream (SOC..EOC) into `params`; `tile_data[isot]` is a
// view of the packet-data bytes of tile `isot` inside `cs`. COD/COC/QCD/QCC may also
// appear in a tile-part header (between SOT and SOD), as GDCM emits for RGB.
@(private)
parse_codestream :: proc(cs: []u8, params: ^J2K_Params, tiles: ^[dynamic]J2K_Tile_Data) -> J2K_Error {
	params^ = {}
	p := 0
	if p + 2 > len(cs) || rd_u16(cs, &p) != MARKER_SOC do return .Bad_Codestream

	read_siz := false
	sot_start := -1
	isot := 0
	psot := 0

	for {
		if p + 2 > len(cs) do return .Bad_Codestream
		marker_start := p
		m := rd_u16(cs, &p)
		if m == MARKER_EOC do break
		switch m {
		case MARKER_SIZ:
			if p + 38 > len(cs) do return .Bad_Codestream
			_ = rd_u16(cs, &p) // Lsiz
			_ = rd_u16(cs, &p) // Rsiz
			params.xsiz = rd_u32(cs, &p)
			params.ysiz = rd_u32(cs, &p)
			params.xosiz = rd_u32(cs, &p)
			params.yosiz = rd_u32(cs, &p)
			params.xtsiz = rd_u32(cs, &p)
			params.ytsiz = rd_u32(cs, &p)
			params.xtosiz = rd_u32(cs, &p)
			params.ytosiz = rd_u32(cs, &p)
			params.csiz = int(rd_u16(cs, &p))
			if params.csiz < 1 || params.csiz > J2K_MAX_COMPONENTS do return .Unsupported_Feature
			if params.xsiz <= params.xosiz || params.ysiz <= params.yosiz do return .Bad_Codestream
			if params.xtsiz == 0 || params.ytsiz == 0 do return .Bad_Codestream
			if u64(params.xsiz - params.xosiz) * u64(params.ysiz - params.yosiz) > J2K_MAX_SAMPLES {
				return .Unsupported_Feature
			}
			for c in 0 ..< params.csiz {
				ssiz := rd_u8(cs, &p)
				params.comps[c].prec = int(ssiz & 0x7F) + 1
				params.comps[c].sgnd = (ssiz & 0x80) != 0
				params.comps[c].dx = int(rd_u8(cs, &p))
				params.comps[c].dy = int(rd_u8(cs, &p))
				if params.comps[c].dx == 0 || params.comps[c].dy == 0 do return .Bad_Codestream
			}
			params.tw = ceildiv_u32(params.xsiz - params.xtosiz, params.xtsiz)
			params.th = ceildiv_u32(params.ysiz - params.ytosiz, params.ytsiz)
			if params.tw * params.th > 65535 do return .Bad_Codestream
			read_siz = true
		case MARKER_COD:
			if !read_siz do return .Bad_Codestream
			l := int(rd_u16(cs, &p))
			seg_end := p + l - 2
			err := read_sp_cod(&params.cod[0], cs, &p)
			if err != .None do return err
			for c in 1 ..< params.csiz {
				params.cod[c] = params.cod[0]
			}
			p = seg_end
		case MARKER_COC:
			if !read_siz do return .Bad_Codestream
			l := int(rd_u16(cs, &p))
			seg_end := p + l - 2
			ccoc := int(rd_u8(cs, &p))
			if ccoc >= params.csiz do return .Bad_Codestream
			scoc := rd_u8(cs, &p)
			params.cod[ccoc].precincts = (scoc & 1) != 0
			err := read_sp_coc(&params.cod[ccoc], cs, &p)
			if err != .None do return err
			p = seg_end
		case MARKER_QCD:
			if !read_siz do return .Bad_Codestream
			l := int(rd_u16(cs, &p))
			seg_end := p + l - 2
			err := read_q(&params.cod[0], cs, p, seg_end)
			if err != .None do return err
			// QCD is the default for every component: both guard bits and the
			// exponent table are shared (QCC may later override one component).
			for c in 1 ..< params.csiz {
				params.cod[c].guard = params.cod[0].guard
				params.cod[c].expn = params.cod[0].expn
			}
			p = seg_end
		case MARKER_QCC:
			if !read_siz do return .Bad_Codestream
			l := int(rd_u16(cs, &p))
			seg_end := p + l - 2
			cqcc := int(rd_u8(cs, &p))
			if cqcc >= params.csiz do return .Bad_Codestream
			err := read_q(&params.cod[cqcc], cs, p, seg_end)
			if err != .None do return err
			p = seg_end
		case MARKER_SOT:
			if !read_siz do return .Bad_Codestream
			if p + 10 > len(cs) do return .Bad_Codestream
			sot_start = p - 2 // marker start; Psot counts from here
			_ = rd_u16(cs, &p) // Lsot = 10
			isot = int(rd_u16(cs, &p))
			psot = int(rd_u32(cs, &p))
			tpsot := int(rd_u8(cs, &p))
			tnsot := int(rd_u8(cs, &p))
			if isot >= params.tw * params.th do return .Bad_Codestream
			// Multiple tile-parts per tile are allowed: their packet bytes are
			// concatenated in order (TPsot). TNsot is only a hint.
			_ = tpsot
			_ = tnsot
		case MARKER_SOD:
			if sot_start < 0 do return .Bad_Codestream
			end: int
			if psot > 0 {
				end = sot_start + psot
			} else {
				// Psot == 0: the tile-part runs to the next SOT or EOC. Neither
				// marker can occur inside packet data (0xFF bit stuffing keeps
				// following bytes <= 0x8F), so a linear scan is safe.
				end = len(cs)
				for q in p ..< len(cs) - 1 {
					if cs[q] == 0xFF && (cs[q + 1] == 0xD9 || cs[q + 1] == 0x90) {
						end = q
						break
					}
				}
			}
			if end > len(cs) do end = len(cs)
			if p > end do return .Bad_Codestream
			for len(tiles^) <= isot {
				append(tiles, J2K_Tile_Data{data = make([dynamic]u8, 0, 1 << 12)})
			}
			append(&tiles^[isot].data, ..cs[p:end])
			p = end
			sot_start = -1
		case MARKER_RGN, MARKER_POC, MARKER_PPM, MARKER_PPT:
			return .Unsupported_Feature
		case:
			// TLM, PLM, COM, CRG and other optional segments: skip by length.
			if p + 2 > len(cs) do return .Bad_Codestream
			l2 := int(rd_u16(cs, &p))
			if l2 < 2 do return .Bad_Codestream
			p += l2 - 2
			if p > len(cs) do return .Bad_Codestream
		}
		// Every marker segment must consume at least its own header; otherwise a
		// crafted zero-length segment would spin this loop forever.
		if p <= marker_start + 2 do return .Bad_Codestream
	}
	if !read_siz do return .Bad_Codestream
	for c in 0 ..< params.csiz {
		if params.cod[c].transform != 1 do return .Unsupported_Feature
		if params.cod[c].prg > 2 do return .Unsupported_Feature // PCRL/CPRL
	}
	return .None
}

// ---------------------------------------------------------------------------------------------
// Tile geometry (tcd.c port) and Tier-2 state.
// ---------------------------------------------------------------------------------------------
@(private)
J2K_Seg :: struct {
	numpasses:       u32,
	real_num_passes: u32,
	maxpasses:       u32,
	len:             u32,
	newlen:          u32,
	numnewpasses:    u32,
}
@(private)
J2K_Chunk :: struct {
	offset: int, // into the tile packet buffer
	length: int,
}
@(private)
J2K_Cblk :: struct {
	x0: i32, y0: i32, x1: i32, y1: i32,
	numsegs:          int,
	numbps:           int,
	numnewpasses:     u32,
	numlenbits:       u32,
	segs:             [128]J2K_Seg,
	chunks:           [dynamic]J2K_Chunk,
	decoded:          bool,
}
@(private)
J2K_Precinct :: struct {
	x0: i32, y0: i32, x1: i32, y1: i32,
	cw:      u32,
	ch:      u32,
	incltree: Tag_Tree,
	imsbtree: Tag_Tree,
	cblks:   [dynamic]J2K_Cblk,
}
@(private)
J2K_Band :: struct {
	bandno:   int,
	x0: i32, y0: i32, x1: i32, y1: i32,
	numbps:   int,
	precincts: [dynamic]J2K_Precinct,
}
@(private)
J2K_Res :: struct {
	x0: i32, y0: i32, x1: i32, y1: i32,
	pw:      u32,
	ph:      u32,
	numbands: int,
	bands:    [3]J2K_Band,
}
@(private)
J2K_Tilec :: struct {
	x0: i32, y0: i32, x1: i32, y1: i32,
	numres:    int,
	res:       [J2K_MAX_RES_LEVELS]J2K_Res,
	data:      [dynamic]i32,
	w:         int,
}
@(private)
J2K_Tile :: struct {
	x0: i32, y0: i32, x1: i32, y1: i32,
	comps: [J2K_MAX_COMPONENTS]J2K_Tilec,
}
@(private)
j2k_destroy_tile :: proc(t: ^J2K_Tile, csiz: int) {
	for c in 0 ..< csiz {
		tilec := &t.comps[c]
		for r in 0 ..< tilec.numres {
			res := &tilec.res[r]
			for b in 0 ..< res.numbands {
				band := &res.bands[b]
				for pi in 0 ..< len(band.precincts) {
					pre := &band.precincts[pi]
					for ci in 0 ..< len(pre.cblks) {
						delete(pre.cblks[ci].chunks)
					}
					delete(pre.cblks)
					delete(pre.incltree.nodes)
					delete(pre.imsbtree.nodes)
				}
				delete(band.precincts)
			}
		}
		delete(tilec.data)
	}
}
// Builds res/band/precinct/cblk geometry for tile `tileno` (opj_tcd_init_tile port).
@(private)
j2k_init_tile :: proc(params: ^J2K_Params, tile: ^J2K_Tile, tileno: int) -> J2K_Error {
	px := tileno % params.tw
	py := tileno / params.tw
	tx0 := i32(max(u64(params.xtosiz) + u64(px) * u64(params.xtsiz), u64(params.xosiz)))
	tx1 := i32(min(u64(params.xtosiz) + u64(px + 1) * u64(params.xtsiz), u64(params.xsiz)))
	ty0 := i32(max(u64(params.ytosiz) + u64(py) * u64(params.ytsiz), u64(params.yosiz)))
	ty1 := i32(min(u64(params.ytosiz) + u64(py + 1) * u64(params.ytsiz), u64(params.ysiz)))
	if tx1 <= tx0 || ty1 <= ty0 do return .Bad_Codestream
	tile.x0 = tx0
	tile.x1 = tx1
	tile.y0 = ty0
	tile.y1 = ty1
	for c in 0 ..< params.csiz {
		comp := &params.comps[c]
		cod := &params.cod[c]
		tilec := &tile.comps[c]
		tilec.x0 = ceildiv_i32(tx0, i32(comp.dx))
		tilec.y0 = ceildiv_i32(ty0, i32(comp.dy))
		tilec.x1 = ceildiv_i32(tx1, i32(comp.dx))
		tilec.y1 = ceildiv_i32(ty1, i32(comp.dy))
		tilec.numres = cod.levels + 1
		tilec.w = int(tilec.x1 - tilec.x0)
		if tilec.w <= 0 || tilec.y1 <= tilec.y0 do return .Bad_Codestream
		if u64(tilec.w) * u64(tilec.y1 - tilec.y0) > J2K_MAX_SAMPLES do return .Unsupported_Feature
		level_no := tilec.numres
		for resno := 0; resno < tilec.numres; resno += 1 {
			level_no -= 1
			res := &tilec.res[resno]
			res.x0 = ceildivpow2(tilec.x0, level_no)
			res.y0 = ceildivpow2(tilec.y0, level_no)
			res.x1 = ceildivpow2(tilec.x1, level_no)
			res.y1 = ceildivpow2(tilec.y1, level_no)
			pdx := int(cod.prcw[resno])
			pdy := int(cod.prch[resno])
			tl_prc_x := shl_i32(floordivpow2(res.x0, pdx), pdx)
			tl_prc_y := shl_i32(floordivpow2(res.y0, pdy), pdy)
			br_prc_x := shl_i32(ceildivpow2(res.x1, pdx), pdx)
			br_prc_y := shl_i32(ceildivpow2(res.y1, pdy), pdy)
			res.pw = 0 if res.x0 == res.x1 else u32((br_prc_x - tl_prc_x) >> u32(pdx))
			res.ph = 0 if res.y0 == res.y1 else u32((br_prc_y - tl_prc_y) >> u32(pdy))
			tlcbgx: i32
			tlcbgy: i32
			cbgw_expn: int
			cbgh_expn: int
			if resno == 0 {
				tlcbgx = tl_prc_x
				tlcbgy = tl_prc_y
				cbgw_expn = pdx
				cbgh_expn = pdy
				res.numbands = 1
			} else {
				tlcbgx = ceildivpow2(tl_prc_x, 1)
				tlcbgy = ceildivpow2(tl_prc_y, 1)
				cbgw_expn = pdx - 1
				cbgh_expn = pdy - 1
				res.numbands = 3
			}
			cblkw_expn := min(cod.cblkw, cbgw_expn)
			cblkh_expn := min(cod.cblkh, cbgh_expn)
			for bandno := 0; bandno < res.numbands; bandno += 1 {
				band := &res.bands[bandno]
				if resno == 0 {
					band.bandno = 0
					band.x0 = ceildivpow2(tilec.x0, level_no)
					band.y0 = ceildivpow2(tilec.y0, level_no)
					band.x1 = ceildivpow2(tilec.x1, level_no)
					band.y1 = ceildivpow2(tilec.y1, level_no)
				} else {
					band.bandno = bandno + 1
					x0b := i32(band.bandno & 1)
					y0b := i32(band.bandno >> 1)
					band.x0 = ceildivpow2(tilec.x0 - shl_i32(x0b, level_no), level_no + 1)
					band.y0 = ceildivpow2(tilec.y0 - shl_i32(y0b, level_no), level_no + 1)
					band.x1 = ceildivpow2(tilec.x1 - shl_i32(x0b, level_no), level_no + 1)
					band.y1 = ceildivpow2(tilec.y1 - shl_i32(y0b, level_no), level_no + 1)
				}
				band.numbps = int(cod.expn[band_step_index(resno, bandno)]) + cod.guard - 1
				clear(&band.precincts)
				resize(&band.precincts, int(res.pw * res.ph))
				for precno in 0 ..< int(res.pw * res.ph) {
					pre := &band.precincts[precno]
					cbgx0 := tlcbgx + i32(precno % int(res.pw)) * shl_i32(1, cbgw_expn)
					cbgy0 := tlcbgy + i32(precno / int(res.pw)) * shl_i32(1, cbgh_expn)
					cbgx1 := cbgx0 + shl_i32(1, cbgw_expn)
					cbgy1 := cbgy0 + shl_i32(1, cbgh_expn)
					pre.x0 = max(cbgx0, band.x0)
					pre.y0 = max(cbgy0, band.y0)
					pre.x1 = min(cbgx1, band.x1)
					pre.y1 = min(cbgy1, band.y1)
					if pre.x1 <= pre.x0 || pre.y1 <= pre.y0 {
						pre.cw = 0
						pre.ch = 0
						continue
					}
					tlcblkx := shl_i32(floordivpow2(pre.x0, cblkw_expn), cblkw_expn)
					tlcblky := shl_i32(floordivpow2(pre.y0, cblkh_expn), cblkh_expn)
					brcblkx := shl_i32(ceildivpow2(pre.x1, cblkw_expn), cblkw_expn)
					brcblky := shl_i32(ceildivpow2(pre.y1, cblkh_expn), cblkh_expn)
					pre.cw = u32((brcblkx - tlcblkx) >> u32(cblkw_expn))
					pre.ch = u32((brcblky - tlcblky) >> u32(cblkh_expn))
					err := tag_tree_create(&pre.incltree, int(pre.cw), int(pre.ch))
					if err != .None do return err
					err = tag_tree_create(&pre.imsbtree, int(pre.cw), int(pre.ch))
					if err != .None do return err
					clear(&pre.cblks)
					resize(&pre.cblks, int(pre.cw * pre.ch))
					for cblkno in 0 ..< int(pre.cw * pre.ch) {
						cblk := &pre.cblks[cblkno]
						cx0 := tlcblkx + i32(cblkno % int(pre.cw)) * shl_i32(1, cblkw_expn)
						cy0 := tlcblky + i32(cblkno / int(pre.cw)) * shl_i32(1, cblkh_expn)
						cx1 := cx0 + shl_i32(1, cblkw_expn)
						cy1 := cy0 + shl_i32(1, cblkh_expn)
						cblk.x0 = max(cx0, pre.x0)
						cblk.y0 = max(cy0, pre.y0)
						cblk.x1 = min(cx1, pre.x1)
						cblk.y1 = min(cy1, pre.y1)
					}
				}
			}
		}
	}
	return .None
}
// ---------------------------------------------------------------------------------------------
// Tier-2: packet decoding (t2.c port).
// ---------------------------------------------------------------------------------------------
// Packet data of one tile. A tile may be split into several tile-parts
// (TNsot > 1); their bytes are concatenated because JPEG 2000 packet streams are
// continuous across tile-part boundaries.
@(private)
J2K_Tile_Data :: struct {
	data: [dynamic]u8,
}

@(private)
J2K_T2 :: struct {
	tile:   ^J2K_Tile,
	params: ^J2K_Params,
	buf:    []u8, // tile packet data
	pos:    int,  // body cursor
	end:    int,
}
@(private)
getcommacode :: proc "contextless" (b: ^Bio) -> u32 {
	n: u32 = 0
	for bio_read(b, 1) != 0 {
		n += 1
	}
	return n
}
@(private)
getnumpasses :: proc "contextless" (b: ^Bio) -> u32 {
	if bio_read(b, 1) == 0 do return 1
	if bio_read(b, 1) == 0 do return 2
	n := bio_read(b, 2)
	if n != 3 do return 3 + n
	n = bio_read(b, 5)
	if n != 31 do return 6 + n
	return 37 + bio_read(b, 7)
}
@(private)
init_seg :: proc "contextless" (cblk: ^J2K_Cblk, index: int, cblksty: u32, first: bool) -> bool {
	if index >= 128 do return false
	seg := &cblk.segs[index]
	seg^ = {}
	if (cblksty & 0x04) != 0 { // TERMALL
		seg.maxpasses = 1
	} else if (cblksty & 0x01) != 0 { // LAZY
		if first {
			seg.maxpasses = 10
		} else {
			prev := cblk.segs[index - 1].maxpasses
			seg.maxpasses = 2 if (prev == 1 || prev == 10) else 1
		}
	} else {
		seg.maxpasses = 109
	}
	return true
}
// Decodes one packet header; returns (data_present, error).
@(private)
read_packet_header :: proc(t2: ^J2K_T2, compno, resno, precno, layno: int) -> (bool, J2K_Error) {
	params := t2.params
	cod := &params.cod[compno]
	tilec := &t2.tile.comps[compno]
	res := &tilec.res[resno]
	if cod.sop && t2.pos + 6 <= t2.end && t2.buf[t2.pos] == 0xFF && t2.buf[t2.pos + 1] == 0x91 {
		t2.pos += 6
	}
	b: Bio
	bio_init(&b, t2.buf, t2.pos)
	first: u32 = 0
	if t2.pos < t2.end do first = u32(t2.buf[t2.pos])
	present_bit := bio_read(&b, 1)
	if present_bit == 0 {
		if !bio_inalign(&b) do return false, .Bad_Packet
		t2.pos = b.pos
		if cod.eph {
			if t2.pos + 2 > t2.end || t2.buf[t2.pos] != 0xFF || t2.buf[t2.pos + 1] != 0x92 {
				return false, .Bad_Packet
			}
			t2.pos += 2
		}
		return false, .None
	}
	for bandno in 0 ..< res.numbands {
		band := &res.bands[bandno]
		if band.x1 <= band.x0 || band.y1 <= band.y0 do continue
		pre := &band.precincts[precno]
		for cblkno in 0 ..< int(pre.cw * pre.ch) {
			cblk := &pre.cblks[cblkno]
			included: u32
			if cblk.numsegs == 0 {
				included = tag_tree_decode(&b, &pre.incltree, cblkno, i32(layno + 1))
			} else {
				included = bio_read(&b, 1)
			}
			if included == 0 {
				cblk.numnewpasses = 0
				continue
			}
			if cblk.numsegs == 0 {
				i := 0
				for tag_tree_decode(&b, &pre.imsbtree, cblkno, i32(i)) == 0 {
					i += 1
				}
				if band.numbps+1 < i {
					cblk.numbps = band.numbps + 1 - i
				} else {
					cblk.numbps = band.numbps + 1 - i
				}
				cblk.numlenbits = 3
			}
			cblk.numnewpasses = getnumpasses(&b)
			cblk.numlenbits += getcommacode(&b)
			segno := 0
			if cblk.numsegs == 0 {
				if !init_seg(cblk, 0, cod.cblksty, true) do return false, .Bad_Packet
			} else {
				segno = cblk.numsegs - 1
				if cblk.segs[segno].numpasses == cblk.segs[segno].maxpasses {
					segno += 1
					if !init_seg(cblk, segno, cod.cblksty, false) do return false, .Bad_Packet
				}
			}
			n := int(cblk.numnewpasses)
			for n > 0 {
				seg := &cblk.segs[segno]
				seg.numnewpasses = u32(min(int(seg.maxpasses - seg.numpasses), n))
				bits := int(cblk.numlenbits + floor_log2(max(seg.numnewpasses, 1)))
				if bits > 32 || bits <= 0 do return false, .Bad_Packet
				seg.newlen = bio_read(&b, bits)
				n -= int(seg.numnewpasses)
				if n > 0 {
					segno += 1
					if !init_seg(cblk, segno, cod.cblksty, false) do return false, .Bad_Packet
				}
			}
		}
	}
	if !bio_inalign(&b) do return false, .Bad_Packet
	t2.pos = b.pos
	if cod.eph {
		if t2.pos + 2 > t2.end || t2.buf[t2.pos] != 0xFF || t2.buf[t2.pos + 1] != 0x92 {
			return false, .Bad_Packet
		}
		t2.pos += 2
	}
	return true, .None
}
@(private)
floor_log2 :: proc "contextless" (v0: u32) -> u32 {
	v := v0
	n: u32 = 0
	for v > 1 {
		v >>= 1
		n += 1
	}
	return n
}
// Appends the packet body bytes to each included code-block's chunk list.
@(private)
read_packet_data :: proc(t2: ^J2K_T2, compno, resno, precno: int) -> J2K_Error {
	res := &t2.tile.comps[compno].res[resno]
	for bandno in 0 ..< res.numbands {
		band := &res.bands[bandno]
		if band.x1 <= band.x0 || band.y1 <= band.y0 do continue
		pre := &band.precincts[precno]
		for cblkno in 0 ..< int(pre.cw * pre.ch) {
			cblk := &pre.cblks[cblkno]
			if cblk.numnewpasses == 0 do continue
			segno := 0
			if cblk.numsegs == 0 {
				segno = 0
				cblk.numsegs = 1
			} else {
				segno = cblk.numsegs - 1
				if cblk.segs[segno].numpasses == cblk.segs[segno].maxpasses {
					segno += 1
					cblk.numsegs = segno + 1
				}
			}
			for cblk.numnewpasses > 0 {
				seg := &cblk.segs[segno]
				if t2.pos + int(seg.newlen) > t2.end {
					return .Bad_Packet
				}
				append(&cblk.chunks, J2K_Chunk{t2.pos, int(seg.newlen)})
				t2.pos += int(seg.newlen)
				seg.len += seg.newlen
				seg.numpasses += seg.numnewpasses
				seg.real_num_passes = seg.numpasses
				cblk.numnewpasses -= seg.numnewpasses
				if cblk.numnewpasses > 0 {
					segno += 1
					cblk.numsegs = segno + 1
				}
			}
		}
	}
	return .None
}
// Iterates packets in the COD progression order and decodes them all.
@(private)
decode_packets :: proc(t2: ^J2K_T2) -> J2K_Error {
	params := t2.params
	cod0 := &params.cod[0]
	layers := cod0.layers
	total_packets := 0
	for c in 0 ..< params.csiz {
		tilec := &t2.tile.comps[c]
		for r in 1 ..< tilec.numres {
			total_packets += int(tilec.res[r].pw * tilec.res[r].ph)
		}
		total_packets += int(tilec.res[0].pw * tilec.res[0].ph)
	}
	decode_one :: proc(t2: ^J2K_T2, c, r, p, l: int) -> J2K_Error {
		present, err := read_packet_header(t2, c, r, p, l)
		if err != .None do return err
		if present {
			return read_packet_data(t2, c, r, p)
		}
		return .None
	}
	switch cod0.prg {
	case 0: // LRCP
		for l in 0 ..< layers {
			for r in 0 ..< params.cod[0].levels + 1 {
				for c in 0 ..< params.csiz {
					tilec := &t2.tile.comps[c]
					if r >= tilec.numres do continue
					n := int(tilec.res[r].pw * tilec.res[r].ph)
					for p in 0 ..< n {
						if err := decode_one(t2, c, r, p, l); err != .None do return err
					}
				}
			}
		}
	case 1: // RLCP
		for r in 0 ..< params.cod[0].levels + 1 {
			for l in 0 ..< layers {
				for c in 0 ..< params.csiz {
					tilec := &t2.tile.comps[c]
					if r >= tilec.numres do continue
					n := int(tilec.res[r].pw * tilec.res[r].ph)
					for p in 0 ..< n {
						if err := decode_one(t2, c, r, p, l); err != .None do return err
					}
				}
			}
		}
	case 2: // RPCL
		for r in 0 ..< params.cod[0].levels + 1 {
			for c in 0 ..< params.csiz {
				tilec := &t2.tile.comps[c]
				if r >= tilec.numres do continue
				for p in 0 ..< int(tilec.res[r].pw * tilec.res[r].ph) {
					for l in 0 ..< layers {
						if err := decode_one(t2, c, r, p, l); err != .None do return err
					}
				}
			}
		}
	case:
		return .Unsupported_Feature
	}
	return .None
}
// ---------------------------------------------------------------------------------------------
// Tier-1 dispatch + coefficient scatter into the tile-component buffer.
// ---------------------------------------------------------------------------------------------
@(private)
decode_cblks :: proc(tile: ^J2K_Tile, params: ^J2K_Params, t2: ^J2K_T2, tilec_index: int) -> J2K_Error {
	tilec := &tile.comps[tilec_index]
	cod := &params.cod[tilec_index]
	clear(&tilec.data)
	resize(&tilec.data, tilec.w * int(tilec.y1 - tilec.y0))
	for resno in 0 ..< tilec.numres {
		res := &tilec.res[resno]
		pres := &tilec.res[resno - 1] if resno > 0 else res
		for bandno in 0 ..< res.numbands {
			band := &res.bands[bandno]
			if band.x1 <= band.x0 || band.y1 <= band.y0 do continue
			for precno in 0 ..< int(res.pw * res.ph) {
				pre := &band.precincts[precno]
				for cblkno in 0 ..< int(pre.cw * pre.ch) {
					cblk := &pre.cblks[cblkno]
					// Concatenate chunks for the entropy decoder.
					total := 0
					for i in 0 ..< len(cblk.chunks) {
						total += cblk.chunks[i].length
					}
					if total == 0 do continue
					buf := make([]u8, total)
					defer delete(buf)
					at := 0
					for i in 0 ..< len(cblk.chunks) {
						ch := cblk.chunks[i]
						copy(buf[at:at + ch.length], t2.buf[ch.offset:ch.offset + ch.length])
						at += ch.length
					}
					t1: T1
					t1.orient = band.bandno
					t1.w = int(cblk.x1 - cblk.x0)
					t1.h = int(cblk.y1 - cblk.y0)
					if t1.w <= 0 || t1.h <= 0 do continue
					segs := cblk.segs[0:cblk.numsegs]
					t1_decode_cblk(&t1, buf, segs, cblk.numbps, cod.cblksty)
					if resno == 0 && bandno == 0 && precno == 0 && cblkno == 0 {
					}
					cblk.decoded = true
					defer delete(t1.data)
					defer delete(t1.flags)
					// Scatter dequantized coefficients (5/3: divide by 2) into the tile buffer,
					// porting the bandno-dependent offsets of opj_t1_clbl_decode_processor.
					x := cblk.x0 - band.x0
					y := cblk.y0 - band.y0
					if (band.bandno & 1) != 0 {
						x += pres.x1 - pres.x0
					}
					if (band.bandno & 2) != 0 {
						y += pres.y1 - pres.y0
					}
					cw := t1.w
					ch := t1.h
					for j in 0 ..< ch {
						for i in 0 ..< cw {
							val := t1.data[j * cw + i] / 2
							tilec.data[(int(y) + j) * tilec.w + (int(x) + i)] = val
						}
					}
				}
			}
		}
	}
	return .None
}
// ---------------------------------------------------------------------------------------------
// Inverse 5/3 DWT, scalar kernels ported from OpenJPEG dwt.c (opj_idwt53_h/v).
// ---------------------------------------------------------------------------------------------
@(private)
idwt53_h_cas0 :: proc "contextless" (tmp: []i32, sn: int, len: int, row: []i32) {
	in_even := row[:sn]
	in_odd := row[sn:len]
	s1n := in_even[0]
	d1n := in_odd[0]
	s0n := s1n - ((d1n + 1) >> 1)
	i := 0
	j := 1
	for i < len - 3 {
		d1c := d1n
		s0c := s0n
		s1n = in_even[j]
		d1n = in_odd[j]
		s0n = s1n - ((d1c + d1n + 2) >> 2)
		tmp[i] = s0c
		tmp[i + 1] = d1c + ((s0c + s0n) >> 1)
		i += 2
		j += 1
	}
	tmp[i] = s0n
	if (len & 1) != 0 {
		tmp[len - 1] = in_even[(len - 1) / 2] - ((d1n + 1) >> 1)
		tmp[len - 2] = d1n + ((s0n + tmp[len - 1]) >> 1)
	} else {
		tmp[len - 1] = d1n + s0n
	}
	copy(row, tmp[:len])
}
@(private)
idwt53_h_cas1 :: proc "contextless" (tmp: []i32, sn: int, len: int, row: []i32) {
	in_even := row[sn:len]
	in_odd := row[:sn]
	s1 := in_even[1]
	dc := in_odd[0] - ((in_even[0] + s1 + 2) >> 2)
	tmp[0] = in_even[0] + dc
	i := 1
	j := 1
	par := 0 if (len & 1) != 0 else 1
	for i < len - 2 - par {
		s2 := in_even[j + 1]
		dn := in_odd[j] - ((s1 + s2 + 2) >> 2)
		tmp[i] = dc
		tmp[i + 1] = s1 + ((dn + dc) >> 1)
		dc = dn
		s1 = s2
		i += 2
		j += 1
	}
	tmp[i] = dc
	if (len & 1) == 0 {
		dn := in_odd[len / 2 - 1] - ((s1 + 1) >> 1)
		tmp[len - 2] = s1 + ((dn + dc) >> 1)
		tmp[len - 1] = dn
	} else {
		tmp[len - 1] = s1 + dc
	}
	copy(row, tmp[:len])
}
@(private)
idwt53_h :: proc "contextless" (tmp: []i32, sn: int, len: int, cas: int, row: []i32) {
	if cas == 0 {
		if len > 1 do idwt53_h_cas0(tmp, sn, len, row)
	} else {
		if len == 1 {
			row[0] /= 2
		} else if len == 2 {
			tmp[1] = row[0] - ((row[sn] + 1) >> 1)
			tmp[0] = row[sn] + tmp[1]
			copy(row, tmp[:2])
		} else if len > 2 {
			idwt53_h_cas1(tmp, sn, len, row)
		}
	}
}
@(private)
idwt53_v_cas0 :: proc "contextless" (tmp: []i32, sn: int, len: int, stride: int, col: []i32) {
	// col is a strided view: col[k*stride] is row k of this column.
	get := proc "contextless" (c: []i32, s: int, k: int) -> i32 { return c[k * s] }
	set := proc "contextless" (c: []i32, s: int, k: int, v: i32) { c[k * s] = v }
	s1n := get(col, stride, 0)
	d1n := get(col, stride, sn)
	s0n := s1n - ((d1n + 1) >> 1)
	i := 0
	j := 0
	for i < len - 3 {
		d1c := d1n
		s0c := s0n
		s1n = get(col, stride, j + 1)
		d1n = get(col, stride, sn + j + 1)
		s0n = s1n - ((d1c + d1n + 2) >> 2)
		tmp[i] = s0c
		tmp[i + 1] = d1c + ((s0c + s0n) >> 1)
		i += 2
		j += 1
	}
	tmp[i] = s0n
	if (len & 1) != 0 {
		tmp[len - 1] = get(col, stride, (len - 1) / 2) - ((d1n + 1) >> 1)
		tmp[len - 2] = d1n + ((s0n + tmp[len - 1]) >> 1)
	} else {
		tmp[len - 1] = d1n + s0n
	}
	for k in 0 ..< len {
		set(col, stride, k, tmp[k])
	}
}
@(private)
idwt53_v_cas1 :: proc "contextless" (tmp: []i32, sn: int, len: int, stride: int, col: []i32) {
	get := proc "contextless" (c: []i32, s: int, k: int) -> i32 { return c[k * s] }
	set := proc "contextless" (c: []i32, s: int, k: int, v: i32) { c[k * s] = v }
	s1 := get(col, stride, sn + 1)
	dc := get(col, stride, 0) - ((get(col, stride, sn) + s1 + 2) >> 2)
	tmp[0] = get(col, stride, sn) + dc
	i := 1
	j := 1
	par := 0 if (len & 1) != 0 else 1
	for i < len - 2 - par {
		s2 := get(col, stride, sn + j + 1)
		dn := get(col, stride, j) - ((s1 + s2 + 2) >> 2)
		tmp[i] = dc
		tmp[i + 1] = s1 + ((dn + dc) >> 1)
		dc = dn
		s1 = s2
		i += 2
		j += 1
	}
	tmp[i] = dc
	if (len & 1) == 0 {
		dn := get(col, stride, len / 2 - 1) - ((s1 + 1) >> 1)
		tmp[len - 2] = s1 + ((dn + dc) >> 1)
		tmp[len - 1] = dn
	} else {
		tmp[len - 1] = s1 + dc
	}
	for k in 0 ..< len {
		set(col, stride, k, tmp[k])
	}
}
@(private)
idwt53_v :: proc "contextless" (tmp: []i32, sn: int, len: int, stride: int, cas: int, col: []i32) {
	get := proc "contextless" (c: []i32, s: int, k: int) -> i32 { return c[k * s] }
	set := proc "contextless" (c: []i32, s: int, k: int, v: i32) { c[k * s] = v }
	if cas == 0 {
		if len > 1 do idwt53_v_cas0(tmp, sn, len, stride, col)
	} else {
		if len == 1 {
			set(col, stride, 0, get(col, stride, 0) / 2)
		} else if len == 2 {
			tmp[1] = get(col, stride, 0) - ((get(col, stride, sn) + 1) >> 1)
			tmp[0] = get(col, stride, sn) + tmp[1]
			set(col, stride, 0, tmp[0])
			set(col, stride, 1, tmp[1])
		} else if len > 2 {
			idwt53_v_cas1(tmp, sn, len, stride, col)
		}
	}
}
@(private)
dwt_decode :: proc(tilec: ^J2K_Tilec) {
	w := tilec.w
	if tilec.numres <= 1 do return
	tmp := make([]i32, max(w, int(tilec.y1 - tilec.y0)) + 8)
	defer delete(tmp)
	tr0 := &tilec.res[0]
	rw := int(tr0.x1 - tr0.x0)
	rh := int(tr0.y1 - tr0.y0)
	// C: while (--numres) { ++tr; ... } — walk resolutions 1 .. numres-1.
	for r in 1 ..< tilec.numres {
		tr := &tilec.res[r]
		nrw := int(tr.x1 - tr.x0)
		nrh := int(tr.y1 - tr.y0)
		sn := rw
		cas := int(tr.x0 % 2)
		for j in 0 ..< nrh {
			row := tilec.data[j * w:j * w + nrw]
			idwt53_h(tmp, sn, nrw, cas, row)
		}
		snv := rh
		casv := int(tr.y0 % 2)
		for i in 0 ..< nrw {
			col := tilec.data[i:]
			idwt53_v(tmp, snv, nrh, w, casv, col)
		}
		rw = nrw
		rh = nrh
	}
}
// ---------------------------------------------------------------------------------------------
// Post-reconstruction: reversible RCT/MCT, DC level shift, output assembly.
// ---------------------------------------------------------------------------------------------
@(private)
mct_decode :: proc(tile: ^J2K_Tile, params: ^J2K_Params) {
	if !params.cod[0].mct || params.csiz < 3 do return
	// RCT port (mct.c): G = Y1 - ((Y0 + Y2) >> 2); R = Y0 + G; B = Y2 + G.
	// Only applied when the first three components share geometry (DICOM RGB).
	a := &tile.comps[0]
	b := &tile.comps[1]
	d := &tile.comps[2]
	if a.w != b.w || a.w != d.w do return
	if (a.x1 - a.x0) != (b.x1 - b.x0) || (a.x1 - a.x0) != (d.x1 - d.x0) do return
	if (a.y1 - a.y0) != (b.y1 - b.y0) || (a.y1 - a.y0) != (d.y1 - d.y0) do return
	n := len(a.data)
	for i in 0 ..< min(n, min(len(b.data), len(d.data))) {
		y := a.data[i]
		u := b.data[i]
		v := d.data[i]
		g := y - ((u + v) >> 2)
		a.data[i] = v + g
		b.data[i] = g
		d.data[i] = u + g
	}
}
@(private)
dc_level_shift :: proc(tile: ^J2K_Tile, params: ^J2K_Params) {
	for c in 0 ..< params.csiz {
		if params.comps[c].sgnd do continue
		shift: i32 = 1 << u32(params.comps[c].prec - 1)
		data := tile.comps[c].data[:]
		for i in 0 ..< len(data) {
			data[i] += shift
		}
	}
}
// Writes reconstructed samples into the caller's DICOM-native frame buffer (pixel-interleaved).
@(private)
assemble_frame :: proc(
	tile: ^J2K_Tile, params: ^J2K_Params, info: J2K_Image, dst: []u8,
) -> J2K_Error {
	if len(dst) < info.frame_bytes do return .Output_Too_Small
	rows := info.rows
	cols := info.cols
	samples := info.samples
	bps := info.bytes_per_sample
	signed := info.signed
	bitmax: i32 = (1 << u32(info.bits)) - 1
	for c in 0 ..< params.csiz {
		tilec := &tile.comps[c]
		comp := &params.comps[c]
		x0 := tilec.x0 * i32(comp.dx)
		y0 := tilec.y0 * i32(comp.dy)
		x1 := tilec.x1 * i32(comp.dx)
		y1 := tilec.y1 * i32(comp.dy)
		for y in y0 ..< y1 {
			for x in x0 ..< x1 {
				if x < 0 || y < 0 || x >= i32(cols) || y >= i32(rows) do continue
				// Sample position within this tile-component; subsampling folds via dx/dy.
				sx := (x - x0) / i32(comp.dx)
				sy := (y - y0) / i32(comp.dy)
				if sx < 0 || sy < 0 || int(sx) >= tilec.w || int(sy) >= int(tilec.y1 - tilec.y0) do continue
				val := tilec.data[int(sy) * tilec.w + int(sx)]
				// pydicom _apply_sign_correction: when the codestream signedness
				// disagrees with DICOM PixelRepresentation, sign-extend the sample
				// from the codestream precision into BitsAllocated (left-then-right
				// shift on the final integer). Example: 13-bit unsigned decoded as
				// 16-bit signed 6192 -> (6192 << 3) as int16 = -16000 -> >>3 = -2000.
				if info.signed != comp.sgnd && info.bits > comp.prec && info.bits <= 16 {
					sh := info.bits - comp.prec
					wrapped := u16(u32(val) << u32(sh))
					val = i32(i16(wrapped) >> u16(sh))
				}
				u := u32(val)
				if !signed {
					u = u32(clamp_i32(val, 0, bitmax))
				} else {
					// Signed DICOM pixel: wrap into two's-complement of BitsAllocated.
					u = u32(val) & u32((1 << u32(info.bits)) - 1)
				}
				off := (int(y) * cols + int(x)) * samples + c
				if bps == 1 {
					dst[off] = u8(u & 0xFF)
				} else {
					dst[off * 2] = u8(u & 0xFF)
					dst[off * 2 + 1] = u8((u >> 8) & 0xFF)
				}
			}
		}
	}
	return .None
}
@(private)
clamp_i32 :: proc "contextless" (v, lo, hi: i32) -> i32 {
	return min(max(v, lo), hi)
}
// ---------------------------------------------------------------------------------------------
// DICOM encapsulation wrapper.
// ---------------------------------------------------------------------------------------------
@(private)
j2k_attribute :: proc(doc: ^Document, tag: Tag) -> (v: int, ok: bool) {
	e, found := document_find(doc, tag)
	if !found do return 0, false
	if e.vr == .IS {
		n, nok := value_is(doc, e)
		return n, nok
	}
	u, uok := value_u64(doc, e)
	return int(u), uok
}
// Derives decoding geometry from top-level image attributes and validates the PixelData
// element is an encapsulated J2K value.
j2k_image_info :: proc(doc: ^Document, pixel: Element) -> (info: J2K_Image, err: J2K_Error) {
	if doc.ts.uid != J2K_UID && doc.ts.uid != J2K_UID_J2K do return {}, .Not_J2K_Transfer_Syntax
	if .Encapsulated not_in pixel.flags do return {}, .Not_Encapsulated
	rows, ok_rows := j2k_attribute(doc, Tag{0x0028, 0x0010})
	cols, ok_cols := j2k_attribute(doc, Tag{0x0028, 0x0011})
	bits, ok_bits := j2k_attribute(doc, Tag{0x0028, 0x0100})
	if !ok_rows || !ok_cols || !ok_bits do return {}, .Missing_Image_Attributes
	samples, ok_samples := j2k_attribute(doc, Tag{0x0028, 0x0002})
	if !ok_samples do samples = 1
	frames, ok_frames := j2k_attribute(doc, Tag{0x0028, 0x0008})
	if !ok_frames do frames = 1
	signed := false
	if pr, ok := j2k_attribute(doc, Tag{0x0028, 0x0103}); ok {
		signed = pr != 0
	}
	if rows <= 0 || cols <= 0 || bits <= 0 || (bits % 8) != 0 || bits > 16 ||
	   samples <= 0 || samples > J2K_MAX_COMPONENTS || frames <= 0 {
		return {}, .Invalid_Image_Parameters
	}
	bps := bits / 8
	info = J2K_Image{
		rows              = rows,
		cols              = cols,
		samples           = samples,
		bits              = bits,
		signed            = signed,
		frames            = frames,
		bytes_per_sample  = bps,
		frame_bytes       = rows * cols * samples * bps,
	}
	return info, .None
}

// Decodes a raw J2K frame codestream into `dst` (must hold info.frame_bytes bytes).
// This is the entry point for callers that already extracted the codestream.
j2k_decode_codestream :: proc(cs: []u8, dst: []u8, info: J2K_Image) -> J2K_Error {
	if len(dst) < info.frame_bytes do return .Output_Too_Small
	code := j2k_unwrap_jp2(cs)
	params: J2K_Params
	tiles: [dynamic]J2K_Tile_Data
	defer {
		for i in 0 ..< len(tiles) do delete(tiles[i].data)
		delete(tiles)
	}
	err := parse_codestream(code, &params, &tiles)
	if err != .None do return err
	// Cross-check codestream geometry against the DICOM attributes. The DC level
	// shift follows the codestream SIZ sign bit; when it disagrees with DICOM
	// PixelRepresentation, assemble_frame sign-extends from the codestream precision
	// (pydicom's _apply_sign_correction, J2K_pixelrep_mismatch.dcm).
	if int(params.xsiz - params.xosiz) != info.cols ||
	   int(params.ysiz - params.yosiz) != info.rows || params.csiz != info.samples {
		return .Invalid_Image_Parameters
	}
	for tileno in 0 ..< params.tw * params.th {
		if tileno >= len(tiles) || len(tiles[tileno].data) == 0 do return .Bad_Codestream
		tile: J2K_Tile
		err = j2k_init_tile(&params, &tile, tileno)
		if err != .None {
			j2k_destroy_tile(&tile, params.csiz)
			return err
		}
		t2 := J2K_T2{
			tile   = &tile,
			params = &params,
			buf    = tiles[tileno].data[:],
			pos    = 0,
			end    = len(tiles[tileno].data),
		}
		err = decode_packets(&t2)
		if err == .None {
			for c in 0 ..< params.csiz {
				err = decode_cblks(&tile, &params, &t2, c)
				if err != .None do break
				dwt_decode(&tile.comps[c])
			}
		}
		if err == .None {
			mct_decode(&tile, &params)
			dc_level_shift(&tile, &params)
			err = assemble_frame(&tile, &params, info, dst)
		}
		j2k_destroy_tile(&tile, params.csiz)
		if err != .None do return err
	}
	return .None
}

// Decodes one J2K frame into `dst` (must hold info.frame_bytes bytes).
j2k_decode_frame :: proc(
	doc:         ^Document,
	pixel:       Element,
	frame_index: int,
	dst:         []u8,
	info:        J2K_Image,
) -> J2K_Error {
	if frame_index < 0 || frame_index >= info.frames do return .Invalid_Image_Parameters
	cs, owned, ok := encapsulated_frame_codestream(doc, pixel, frame_index, info.frames)
	if !ok do return .Bad_Codestream
	// defer is block-scoped in Odin: the conditional must live at proc scope, or the buffer
	// would be freed before the codestream is decoded.
	defer if owned do delete(cs)
	return j2k_decode_codestream(cs, dst, info)
}
// Decodes every frame of an encapsulated J2K PixelData into `dst`. Mirrors rle_decode.
j2k_decode :: proc(doc: ^Document, pixel: Element, dst: []u8) -> (written: int, err: J2K_Error) {
	info, ierr := j2k_image_info(doc, pixel)
	if ierr != .None do return 0, ierr
	if len(dst) < info.frame_bytes * info.frames do return 0, .Output_Too_Small
	for f in 0 ..< info.frames {
		frame := dst[f * info.frame_bytes:(f + 1) * info.frame_bytes]
		e := j2k_decode_frame(doc, pixel, f, frame, info)
		if e != .None do return f * info.frame_bytes, e
	}
	return info.frame_bytes * info.frames, .None
}