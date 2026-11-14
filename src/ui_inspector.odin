package nautilus

// Task 10 (M3): 右侧 Tag 检查器与结构化解码诊断。
//
// Tag 行提取只读文档的根元素（不展开序列），关键字来自生成的
// `tag_keywords.odin`；搜索覆盖 Tag 号、Keyword 与值文本三路。

import "core:fmt"
import "core:os"
import "core:strings"
import rl "../vendor/skald"
import d "../vendor/dicom"

Tag_Row :: struct {
	tag:     u32,
	keyword: string,
	vr:      string,
	length:  u32,
	value:   string, // trimmed, ellipsised for display; points into doc
}

// max_tag_value_chars keeps long binary values from being copied into
// the inspector list; the diagnostic panel shows the byte count instead.
MAX_TAG_VALUE_CHARS :: 64

// extract_tag_rows lists the document's root elements as displayable
// rows. Text VRs are shown verbatim (ellipsised); binary VRs as
// "<N bytes>". Strings point into `doc`; the rows themselves are
// allocated from `allocator`.
extract_tag_rows :: proc(doc: ^d.Document, allocator := context.allocator) -> []Tag_Row {
	elems := d.document_root(doc)
	rows := make([]Tag_Row, len(elems), allocator)
	n := 0
	defer if n != len(rows) {
		// Unreachable in practice; keeps the slice fully described.
	}

	for e in elems {
		kw := tag_keyword(e.tag)
		value := ""
		if .Sequence in e.flags {
			value = fmt.tprintf("<sequence>")
		} else if .Encapsulated in e.flags {
			value = fmt.tprintf("<%d bytes, encapsulated>", e.length)
		} else {
			raw := d.document_value(doc, e)
			text := d.value_text(doc, e)
			if text != "" {
				value = strings.trim_right(text, "\x00 ")
				if len(value) > MAX_TAG_VALUE_CHARS {
					value = fmt.tprintf("%s…", value[:MAX_TAG_VALUE_CHARS])
				}
			} else {
				value = fmt.tprintf("<%d bytes>", len(raw))
			}
		}
		// The document is destroyed when this proc returns, so every string
		// that points into its mmap must be cloned.
		rows[n] = Tag_Row{
			tag = d.tag_to_u32(e.tag),
			keyword = strings.clone(kw),
			vr = fmt.tprintf("%v", e.vr),
			length = e.length,
			value = strings.clone(value),
		}
		n += 1
	}
	return rows[:n]
}

// filter_tag_rows returns the indices whose tag hex, keyword, or value
// contains `query` (case-insensitive). An empty query matches all.
filter_tag_rows :: proc(rows: []Tag_Row, query: string, allocator := context.allocator) -> []int {
	out := make([]int, len(rows), allocator)
	n := 0
	q := strings.to_lower(query, context.temp_allocator)
	if q == "" {
		for i in 0 ..< len(rows) {
			out[n] = i
			n += 1
		}
		return out[:n]
	}
	for r, i in rows {
		tag_hex := fmt.tprintf("%04X,%04X", u16(r.tag >> 16), u16(r.tag & 0xFFFF))
		if strings.contains(strings.to_lower(tag_hex, context.temp_allocator), q) ||
		   strings.contains(strings.to_lower(r.keyword, context.temp_allocator), q) ||
		   strings.contains(strings.to_lower(r.value, context.temp_allocator), q) {
			out[n] = i
			n += 1
		}
	}
	return out[:n]
}

// ---------------------------------------------------------------------------
// structured decode diagnostics

Diagnostic :: struct {
	path:       string,
	open_err:   d.Parse_Error,
	pixel_err:  d.Pixel_Error,
	decode_ok:  bool,
	has_preamble: bool,
	filesize:   i64,
	open_ms:    f64,
	decode_ms:  f64,
	info:       d.Pixel_Info,
	fragments:  int,
	transfer_syntax: string,
	frame_bytes: int,
	note:       string,
}

// inspect_file_diagnostic opens one file and records everything the
// diagnostic panel shows. It never decodes more than frame 0 and never
// fails: every error is reported in the struct.
inspect_file_diagnostic :: proc(path: string, allocator := context.allocator) -> (diag: Diagnostic) {
	diag.path = path
	if stat, serr := os.stat(path, allocator); serr == nil {
		diag.filesize = stat.size
	}

	doc: d.Document
	d.document_init(&doc, allocator)
	defer d.document_destroy(&doc)

	sw := init_stopwatch()
	diag.open_err = d.document_open_file_opts(&doc, path, d.TAG_PIXEL_DATA)
	diag.open_ms = elapsed_ms(&sw)
	if diag.open_err != .None {
		diag.note = fmt.aprintf("open: %v", diag.open_err, allocator = allocator)
		return
	}
	diag.transfer_syntax = doc.ts.uid
	diag.has_preamble = doc.meta.has_preamble

	// The early stop leaves PixelData itself unparsed; reparse fully for
	// the diagnostic picture (these runs are offline, not interactive).
	d.document_reset(&doc)
	if err := d.document_open_file(&doc, path); err != .None {
		diag.note = fmt.aprintf("full parse: %v", err, allocator = allocator)
		return
	}
	if e, ok := d.document_find(&doc, d.TAG_PIXEL_DATA); ok {
		diag.fragments = len(d.document_fragments(&doc, e))
	}

	info, perr := d.pixel_info(&doc)
	diag.info = info
	diag.pixel_err = perr
	if perr != .None {
		diag.note = fmt.aprintf("pixel_info: %v", perr, allocator = allocator)
		return
	}
	diag.frame_bytes = info.frame_bytes

	raw := make([]u8, info.frame_bytes, context.temp_allocator)
	sw2 := init_stopwatch()
	written, derr := d.pixel_decode_frame(&doc, 0, raw)
	diag.decode_ms = elapsed_ms(&sw2)
	if derr != .None || written == 0 {
		diag.pixel_err = derr
		diag.note = fmt.aprintf("decode: %v", derr, allocator = allocator)
		return
	}
	diag.decode_ok = true
	return
}

// ---------------------------------------------------------------------------
// panel state + view

Inspector_State :: struct {
	open:    bool,
	query:   string, // owned
	rows:    []Tag_Row, // owned by App_State.inspector_rows
	filtered: []int,
	scroll:   int,
	diag:     Diagnostic,
	has_diag: bool,
}

@(private)
inspector_free_rows :: proc(s: ^App_State) {
	for r in s.inspector.rows {
		if r.keyword != "" do delete(r.keyword)
		if r.value != "" do delete(r.value)
		if r.vr != "" do delete(r.vr)
	}
	if s.inspector.rows != nil do delete(s.inspector.rows)
	if s.inspector.filtered != nil do delete(s.inspector.filtered)
	s.inspector.rows = nil
	s.inspector.filtered = nil
}

// inspector_load_for rebuilds the tag list for `path`. Called when the
// viewport adopts a frame, never per UI frame: the refresh re-opens the
// file, which is far too expensive for the hot path.
inspector_load_for :: proc(s: ^App_State, path: string) {
	if path == "" do return
	doc: d.Document
	d.document_init(&doc)
	defer d.document_destroy(&doc)
	if err := d.document_open_file(&doc, path); err != .None do return

	inspector_free_rows(s)
	s.inspector.rows = extract_tag_rows(&doc)
	s.inspector.filtered = filter_tag_rows(s.inspector.rows, s.inspector.query)
	s.inspector.diag = inspect_file_diagnostic(path)
	s.inspector.has_diag = true
}

// inspector renders the right-hand pane per design g1-a: a tab strip,
// a decode-diagnostic summary grid, then the four-column tag table.
inspector :: proc(ctx: ^rl.Ctx(Msg), s: App_State) -> rl.View {
	th := ctx.theme
	if !s.inspector.open {
		// Collapsed: no placeholder text, but the column keeps its width.
		return rl.col(width = 300)
	}

	snap := new(Inspector_Snapshot, context.temp_allocator)
	// Deep-enough copy: virtual_list builds rows after `view` returns, and
	// update may free the old backing arrays in the same frame.
	rows_copy := make([]Tag_Row, len(s.inspector.rows), context.temp_allocator)
	copy(rows_copy, s.inspector.rows)
	filt_copy := make([]int, len(s.inspector.filtered), context.temp_allocator)
	copy(filt_copy, s.inspector.filtered)
	snap^ = Inspector_Snapshot{
		rows = rows_copy,
		filtered = filt_copy,
		diag = s.inspector.diag,
		has_diag = s.inspector.has_diag,
		query = s.inspector.query,
	}

	header := rl.row(
		rl.text("Tags", th.color.primary, th.font.size_xs),
		rl.text("  诊断", th.color.fg_muted, th.font.size_xs),
		rl.flex(1, rl.spacer(0)),
		rl.text(fmt.tprintf("%d", len(snap.filtered)), th.color.fg_muted, th.font.size_xs),
		width = 0,
		height = 28,
		padding = th.spacing.sm,
		cross_align = .Center,
	)

	list := rl.virtual_list(ctx, snap, len(snap.filtered), 22, {300, 0},
		inspector_row_view,
		proc(st: ^Inspector_Snapshot, i: int) -> u64 { return u64(i) },
		overscan = 8,
	)

	return rl.col(
		header,
		diagnostic_summary(ctx, snap),
		rl.flex(1, list),
		width = 300,
		height = 0,
		cross_align = .Stretch,
	)
}

Inspector_Snapshot :: struct {
	rows:     []Tag_Row,
	filtered: []int,
	diag:     Diagnostic,
	has_diag: bool,
	query:    string,
}

@(private)
inspector_row_view :: proc(ctx: ^rl.Ctx(Msg), st: ^Inspector_Snapshot, i: int) -> rl.View {
	th := ctx.theme
	if st == nil || i >= len(st.filtered) do return rl.spacer(22)
	idx := st.filtered[i]
	if idx >= len(st.rows) do return rl.spacer(22)
	r := st.rows[idx]

	return rl.row(
		rl.text(fmt.tprintf("%04X,%04X", u16(r.tag >> 16), u16(r.tag & 0xFFFF)),
			th.color.primary, th.font.size_xs),
		rl.text(r.vr, th.color.warning, th.font.size_xs),
		rl.text(r.keyword, th.color.fg_muted, th.font.size_xs),
		rl.flex(1, rl.text(r.value, th.color.fg, th.font.size_xs)),
		width = 0,
		height = 22,
		padding = th.spacing.xs,
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
}

@(private)
diagnostic_summary :: proc(ctx: ^rl.Ctx(Msg), st: ^Inspector_Snapshot) -> rl.View {
	th := ctx.theme
	if !st.has_diag {
		return rl.col(width = 0, height = 0)
	}
	d := st.diag
	cell :: proc(ctx: ^rl.Ctx(Msg), label, value: string, accent: bool) -> rl.View {
		th2 := ctx.theme
		return rl.col(
			rl.text(label, th2.color.fg_muted, th2.font.size_xs),
			rl.text(value, accent ? th2.color.success : th2.color.fg, th2.font.size_xs),
			width = 0,
			spacing = 1,
		)
	}
	status := d.decode_ok ? "已解码" : "失败"
	return rl.col(
		rl.row(
			cell(ctx, "状态", status, d.decode_ok),
			cell(ctx, "打开", fmt.tprintf("%.1f ms", d.open_ms), false),
			width = 0, spacing = th.spacing.md,
		),
		rl.row(
			cell(ctx, "解码", fmt.tprintf("%.1f ms", d.decode_ms), false),
			cell(ctx, "帧字节", fmt.tprintf("%d B", d.frame_bytes), false),
			width = 0, spacing = th.spacing.md,
		),
		rl.row(
			cell(ctx, "分片", fmt.tprintf("%d", d.fragments), false),
			cell(ctx, "头", d.has_preamble ? "有 Preamble" : "无 Preamble", false),
			width = 0, spacing = th.spacing.md,
		),
		width = 0,
		padding = th.spacing.sm,
		spacing = th.spacing.xs,
		bg = th.color.surface,
		radius = th.radius.sm,
	)
}
