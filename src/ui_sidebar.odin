package nautilus

import "core:fmt"
import rl "../vendor/skald"

// Task 9: 左侧紧凑树（设计 g2-a）。Patient → Study → Series → [Frame]
// 展平成一个行列表，交给 `virtual_list` 渲染；帧行只持有索引，标签在
// 行构建器里现拼，所以展开 690 帧不会产生 690 次堆分配。

Sidebar_Row_Kind :: enum u8 {
	Patient,
	Study,
	Series,
	Frame,
}

Sidebar_Row :: struct {
	kind: Sidebar_Row_Kind,
	// label is preformatted for the header rows (patient / study / series),
	// whose count is bounded by the scan. Frame rows leave it "" and format
	// from entries[entry] in the row builder — visible rows only. Strings
	// are owned by the caller's allocator; sidebar_destroy_rows frees them.
	label: string,
	patient: u32,
	study:  u32,
	series: u32,
	entry:  u32,
	// expanded is only meaningful for series rows (drives the chevron).
	expanded: bool,
}

MAX_VIEWPORTS :: 4

View_Layout :: enum u8 {
	Single, // 1x1
	Two, // 1x2
	Quad, // 2x2
}

layout_count :: proc(l: View_Layout) -> int {
	switch l {
	case .Single: return 1
	case .Two: return 2
	case .Quad: return 4
	}
	return 1
}

// SIDEBAR_W is the tree column (design: 248 px). The empty state, the
// header and the list all read it so the pane cannot drift between them.
SIDEBAR_W :: 248

// ROW_W is the label budget inside one row: the column width minus the
// row padding and the scrollbar gutter.
ROW_W :: SIDEBAR_W - 24

// Row heights. `virtual_list` measures each row in variable-height mode,
// so a frame row costs 20 px instead of the old flat 44.
PATIENT_ROW_H :: 24
STUDY_ROW_H :: 26
SERIES_ROW_H :: 48
FRAME_ROW_H :: 20

// sidebar_build_rows flattens the tree into renderable rows. Every series
// is one card (modality badge, description, geometry, cursor, slice bar);
// its frames are listed only when the series is expanded.
sidebar_build_rows :: proc(tree: ^Study_Tree, expanded: ^map[Series_Key]bool, allocator := context.allocator) -> []Sidebar_Row {
	rows: [dynamic]Sidebar_Row
	for patient, pi in tree.patients {
		name := patient.name
		if name == "" do name = "未知患者"
		append(&rows, Sidebar_Row{
			kind = .Patient,
			label = fmt.aprintf("%s", name, allocator = allocator),
			patient = u32(pi),
		})
		for si in patient.studies {
			study := &tree.studies[si]
			append(&rows, Sidebar_Row{
				kind = .Study,
				label = study_row_label(study, allocator),
				patient = u32(pi),
				study = si,
			})
			for sci in 0 ..< len(study.series) {
				ser := &study.series[sci]
				key := Series_Key{study = si, series = u32(sci)}
				open := expanded != nil && expanded[key]
				label := ser.description
				if label == "" {
					label = fmt.aprintf("序列 %d", ser.number, allocator = allocator)
				} else {
					label = fmt.aprintf("%s", label, allocator = allocator)
				}
				append(&rows, Sidebar_Row{
					kind = .Series,
					label = label,
					patient = u32(pi),
					study = si,
					series = u32(sci),
					expanded = open,
				})
				if !open do continue
				for fi in ser.frames {
					append(&rows, Sidebar_Row{
						kind = .Frame,
						patient = u32(pi),
						study = si,
						series = u32(sci),
						entry = fi,
					})
				}
			}
		}
	}
	return rows[:]
}

sidebar_destroy_rows :: proc(rows: []Sidebar_Row) {
	for r in rows do if r.label != "" do delete(r.label)
	delete(rows)
}

@(private)
study_row_label :: proc(study: ^Study_Node, allocator := context.allocator) -> string {
	date := study_date_label(study.date)
	mod := modality_label(study.modality)
	switch {
	case date != "" && mod != "??":
		return fmt.aprintf("%s · %s · %d 序列", date, mod, len(study.series), allocator = allocator)
	case date != "":
		return fmt.aprintf("%s · %d 序列", date, len(study.series), allocator = allocator)
	case mod != "??":
		return fmt.aprintf("%s · %d 序列", mod, len(study.series), allocator = allocator)
	}
	return fmt.aprintf("%d 序列", len(study.series), allocator = allocator)
}

modality_label :: proc(m: string) -> string {
	return m == "" ? "??" : m
}

// study_date_label turns the raw DICOM DA value ("20260519") into the
// header's "2026-05-19". Anything that is not eight digits passes through
// untouched rather than guessing.
study_date_label :: proc(raw: string) -> string {
	if len(raw) != 8 do return raw
	for c in raw do if c < '0' || c > '9' do return raw
	return fmt.tprintf("%s-%s-%s", raw[0:4], raw[4:6], raw[6:8])
}

// series_geom_label is the card's geometry line, width first as readers
// expect ("512×512 · 16 位"): DICOM Columns is the width, Rows the height.
series_geom_label :: proc(cols, rows, bits: int) -> string {
	if rows <= 0 || cols <= 0 do return ""
	if bits <= 0 do return fmt.tprintf("%d×%d", cols, rows)
	return fmt.tprintf("%d×%d · %d 位", cols, rows, bits)
}

// series_cursor_text is "36/172" for the frame on screen; empty when the
// series has no frames.
series_cursor_text :: proc(cursor, count: int) -> string {
	if count <= 0 do return ""
	return fmt.tprintf("%d/%d", clamp(cursor + 1, 1, count), count)
}

// clipped_label renders a single-line label in a fixed-width cell.
// `Text_Overflow.Ellipsis` is only consulted when max_width == 0; passing
// max_width switches the node to word-wrap, which is what let long file
// names grow past the row and overlap the next one. Keep the cap on the
// container, not on the text.
@(private)
clipped_label :: proc(label: string, color: rl.Color, size, width: f32) -> rl.View {
	return rl.col(
		rl.text(label, color, size, 0, 0, .Ellipsis),
		width = max(width, 24),
		height = 0,
		cross_align = .Stretch,
	)
}

// series_progress maps the 0-based cursor to [0, 1] for the slice bar:
// frame 0 is 0, the last frame is 1.
series_progress :: proc(cursor, count: int) -> f32 {
	if count <= 1 do return 0
	return clamp(f32(cursor) / f32(count - 1), 0, 1)
}

// sidebar_row_key identifies a row by what it points at, never by its
// index: expanding an earlier series shifts every later row, and widget
// state (hover/press) plus virtual_list's row scope must follow the item.
sidebar_row_key :: proc(r: Sidebar_Row) -> u64 {
	h := u64(r.kind) + 1
	h = (h ~ u64(r.patient + 1)) * 0x100000001B3
	h = (h ~ u64(r.study + 1)) * 0x100000001B3
	h = (h ~ u64(r.series + 1)) * 0x100000001B3
	h = (h ~ u64(r.entry + 1)) * 0x100000001B3
	return h
}

@(private)
sidebar_row_id :: proc(r: Sidebar_Row) -> rl.Widget_ID {
	return rl.Widget_ID(sidebar_row_key(r))
}

// Row identity for keeping the selection on the same item across a
// rebuild (expanding or collapsing a series reindexes the rows).
@(private)
Row_Ident :: struct {
	kind:    Sidebar_Row_Kind,
	patient: u32,
	study:   u32,
	series:  u32,
	entry:   u32,
}

@(private)
row_ident :: proc(r: Sidebar_Row) -> Row_Ident {
	return Row_Ident{r.kind, r.patient, r.study, r.series, r.entry}
}

@(private)
find_row :: proc(rows: []Sidebar_Row, ident: Row_Ident) -> int {
	for r, i in rows {
		if row_ident(r) == ident do return i
	}
	return -1
}

// sidebar renders the flat row list. Without a scan it shows the drop hint
// instead of an empty column.
sidebar :: proc(ctx: ^rl.Ctx(Msg), s: App_State) -> rl.View {
	th := ctx.theme
	if !s.has_tree {
		// The viewport owns the one open-a-file hint; keep the column's
		// width so the three-pane layout does not jump when a scan lands.
		return rl.col(width = SIDEBAR_W)
	}

	snap := new(Sidebar_Snapshot, context.temp_allocator)
	snap^ = Sidebar_Snapshot{
		rows = s.rows,
		studies = s.tree.studies,
		patients = s.tree.patients,
		entries = s.tree.entries,
		selected = s.selected_row,
	}
	// Highlight the series the active panel is showing, so the tree says
	// where the viewport is while the wheel pages. `s` is a value copy, so
	// flip_current reads a local copy of the flip state.
	flip := s.flips[clamp(s.active_vp, 0, MAX_VIEWPORTS - 1)]
	if e, ok := flip_current(&flip); ok && e < u32(len(s.tree.entries)) {
		snap.active_study = s.tree.entries[e].study
		snap.active_series = s.tree.entries[e].series
		snap.active_valid = true
	}
	series_total := 0
	for st in s.tree.studies do series_total += len(st.series)

	// The list must own a flexing slot: a zero height here collapses the
	// virtual_list viewport and nothing paints.
	return rl.col(
		rl.row(
			rl.text("检查与序列", th.color.fg_muted, th.font.size_xs),
			rl.flex(1, rl.spacer(0)),
			rl.text(fmt.tprintf("%d 检查 · %d 序列", len(s.tree.patients), series_total),
				th.color.primary, th.font.size_xs),
			width = 0,
			height = 28,
			padding = th.spacing.sm,
			cross_align = .Center,
		),
		rl.flex(1, rl.virtual_list(ctx, snap, len(s.rows), 0, {SIDEBAR_W, 0},
			sidebar_row_view,
			proc(st: ^Sidebar_Snapshot, i: int) -> u64 { return sidebar_row_key(st.rows[i]) },
			overscan = 6,
			estimated_height = 32,
			variable_height = true,
			focusable = true,
			reveal_row = s.selected_row,
		)),
		width = SIDEBAR_W,
		height = 0,
		cross_align = .Stretch,
	)
}

// Sidebar_Snapshot is what the deferred row builder reads. The slices are
// headers into the tree's heap storage, which outlives the frame; the
// fill-mode `virtual_list` deep-copies this struct, not the arrays.
Sidebar_Snapshot :: struct {
	rows:     []Sidebar_Row,
	studies:  []Study_Node,
	patients: []Patient_Node,
	entries:  []Study_Entry,
	selected: int,
	// Series shown by the active panel; active_valid gates the highlight.
	active_study:  u32,
	active_series: u32,
	active_valid:  bool,
}

// sidebar_row_bg resolves the row background in priority order: selection,
// then the series on screen in the active panel, then hover.
@(private)
sidebar_row_bg :: proc(th: ^rl.Theme, selected, active, hovered: bool) -> rl.Color {
	if selected || active do return th.color.selection
	if hovered do return th.color.elevated
	return {}
}

@(private)
sidebar_row_view :: proc(ctx: ^rl.Ctx(Msg), st: ^Sidebar_Snapshot, i: int) -> rl.View {
	th := ctx.theme
	if st == nil || i < 0 || i >= len(st.rows) do return rl.spacer(FRAME_ROW_H)
	row := st.rows[i]
	selected := i == st.selected
	id := sidebar_row_id(row)
	hov := rl.widget_hovered(ctx, id)

	switch row.kind {
	case .Patient:
		bg := sidebar_row_bg(th, selected, false, hov)
		body := rl.row(
			clipped_label(row.label, th.color.fg, th.font.size_xs, ROW_W - 56),
			rl.flex(1, rl.spacer(0)),
			rl.text(fmt.tprintf("%d 检查", len(st.patients[row.patient].studies)),
				th.color.fg_muted, th.font.size_xs),
			width = 0,
			height = PATIENT_ROW_H,
			padding = th.spacing.xs,
			bg = bg,
			radius = th.radius.sm,
			cross_align = .Center,
		)
		return rl.clickable(ctx, body, Msg{kind = .Select_Row, row = i}, id = id, focusable = false)

	case .Study:
		bg := sidebar_row_bg(th, selected, false, hov)
		study := &st.studies[row.study]
		body := rl.row(
			rl.spacer(th.spacing.xs),
			clipped_label(row.label, th.color.fg_muted, th.font.size_xs, ROW_W - 64),
			rl.flex(1, rl.spacer(0)),
			rl.text(fmt.tprintf("%d 幅", study.count), th.color.fg_muted, th.font.size_xs),
			width = 0,
			height = STUDY_ROW_H,
			padding = th.spacing.xs,
			bg = bg,
			radius = th.radius.sm,
			cross_align = .Center,
		)
		return rl.clickable(ctx, body, Msg{kind = .Select_Row, row = i}, id = id, focusable = false)

	case .Series:
		ser := &st.studies[row.study].series[row.series]
		active := st.active_valid && st.active_study == row.study && st.active_series == row.series
		bg := sidebar_row_bg(th, selected, active, hov)
		badge_color := th.color.fg_muted
		switch ser.modality {
		case "CT": badge_color = th.color.success
		case "MG": badge_color = th.color.warning
		case "DX", "DR", "CR", "MR": badge_color = th.color.primary
		}
		title_color := (selected || active) ? th.color.primary : th.color.fg

		// Two sibling hit regions: the chevron toggles the frame list, the
		// body selects and shows the series. Nested clickables would both
		// fire on one click.
		chevron := row.expanded ? "▼" : "▶"
		toggle := rl.clickable(ctx,
			rl.text(chevron, th.color.fg_muted, th.font.size_xs),
			Msg{kind = .Toggle_Series, row = i},
			id = rl.Widget_ID(sidebar_row_key(row) ~ 0xA5A5), focusable = false)

		body := rl.col(
			rl.row(
				rl.text(ser.modality, badge_color, th.font.size_xs),
				clipped_label(row.label, title_color, th.font.size_xs, ROW_W - 104),
				rl.flex(1, rl.spacer(0)),
				rl.text(series_cursor_text(ser.cursor, len(ser.frames)), th.color.fg_muted, th.font.size_xs),
				width = 0,
				height = 18,
				spacing = th.spacing.xs,
				cross_align = .Center,
			),
			rl.row(
				rl.text(series_geom_label(ser.cols, ser.rows, ser.bits), th.color.fg_muted, th.font.size_xs),
				rl.flex(1, rl.spacer(0)),
				rl.text(fmt.tprintf("Ser #%d", ser.number), th.color.fg_muted, th.font.size_xs),
				width = 0,
				height = 14,
				cross_align = .Center,
			),
			rl.progress(ctx, series_progress(ser.cursor, len(ser.frames)),
				height = 3, color_bg = th.color.border, color_fill = th.color.primary),
			width = 0,
			height = SERIES_ROW_H - 2 * th.spacing.xs,
			spacing = 2,
			cross_align = .Stretch,
		)
		card := rl.row(
			toggle,
			rl.flex(1, rl.clickable(ctx, body, Msg{kind = .Select_Row, row = i}, id = id, focusable = false)),
			width = 0,
			height = SERIES_ROW_H,
			padding = th.spacing.xs,
			spacing = th.spacing.xs,
			bg = bg,
			radius = th.radius.sm,
			cross_align = .Stretch,
		)
		return card

	case .Frame:
		entry := st.entries[row.entry]
		color := selected ? th.color.on_primary : th.color.fg_muted
		bg := sidebar_row_bg(th, selected, false, hov)
		// Start of the name, not the path-tail `short_name` keeps for the
		// status bar: the row elides the end it cannot fit.
		label := fmt.tprintf("%d  %s", entry.instance, base_name(entry.path))
		body := rl.row(
			rl.spacer(th.spacing.md),
			clipped_label(label, color, th.font.size_xs, ROW_W - 22),
			width = 0,
			height = FRAME_ROW_H,
			padding = th.spacing.xs,
			bg = bg,
			radius = th.radius.sm,
			cross_align = .Center,
		)
		return rl.clickable(ctx, body, Msg{kind = .Select_Row, row = i}, id = id, focusable = false)
	}
	return rl.spacer(FRAME_ROW_H)
}
