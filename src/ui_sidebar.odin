package nautilus

import "core:fmt"
import rl "../vendor/skald"

// Task 9: 左侧紧凑树。Study → Series → Frame 展平成一个行列表，
// 交给 `virtual_list` 渲染，只构建可见行。

Sidebar_Row_Kind :: enum u8 {
	Study,
	Series,
	Frame,
}

Sidebar_Row :: struct {
	kind:  Sidebar_Row_Kind,
	// label is preformatted at scan time so the row builder allocates
	// nothing per frame.
	label: string,
	depth: int,
	// entry is the Study_Tree.entries index for frame rows.
	entry: u32,
	// study/series are indices into the tree, for header rows.
	study:  u32,
	series: u32,

	// Series-card fields (design g2-a): modality badge, frame cursor,
	// geometry label, and the progress fraction for the slice bar.
	modality:  string,
	count:     int,
	cursor:    int,
	geom:      string,
	show_meta: bool,
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

// sidebar_build_rows flattens the tree into renderable rows. Per design
// g2-a every series is one card (modality badge, count, geometry, slice
// bar); its frames are only listed when the series is expanded, so a
// 690-frame study does not bury the navigation. Strings are owned by the
// caller's allocator and freed by sidebar_destroy_rows.
sidebar_build_rows :: proc(tree: ^Study_Tree, expanded: ^map[string]bool, allocator := context.allocator) -> []Sidebar_Row {
	rows: [dynamic]Sidebar_Row
	for si in 0 ..< len(tree.studies) {
		study := &tree.studies[si]
		append(&rows, Sidebar_Row{
			kind = .Study,
			label = fmt.aprintf("%s · %s  (%d 序列)", study.date,
				modality_label(study.modality), len(study.series), allocator = allocator),
			count = study.count,
			modality = study.modality,
			depth = 0,
			study = u32(si),
		})
		for sci in 0 ..< len(study.series) {
			ser := &study.series[sci]
			geom := ""
			if len(ser.frames) > 0 {
				e := tree.entries[ser.frames[0]]
				_ = e
			}
			append(&rows, Sidebar_Row{
				kind = .Series,
				label = fmt.aprintf("Series %d", ser.number, allocator = allocator),
				modality = study.modality,
				count = len(ser.frames),
				geom = geom,
				depth = 1,
				study = u32(si),
				series = u32(sci),
			})
			if expanded != nil && expanded[ser.uid] {
				for fi in ser.frames {
					entry := tree.entries[fi]
					append(&rows, Sidebar_Row{
						kind = .Frame,
						label = fmt.aprintf("%d  %s", entry.instance,
							short_name(entry.path), allocator = allocator),
						depth = 2,
						entry = fi,
						study = u32(si),
						series = u32(sci),
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

modality_label :: proc(m: string) -> string {
	return m == "" ? "??" : m
}

// sidebar renders the flat row list. Without a scan it shows the
// drop hint instead of an empty column.
sidebar :: proc(ctx: ^rl.Ctx(Msg), s: App_State) -> rl.View {
	th := ctx.theme
	if !s.has_tree {
		// The viewport owns the one open-a-file hint; keep the column's
		// width so the three-pane layout does not jump when a scan lands.
		return rl.col(width = 260)
	}

	snap := new(Sidebar_Snapshot, context.temp_allocator)
	snap^ = Sidebar_Snapshot{rows = s.rows, selected = s.selected_row}
	// The list must own a flexing slot: a zero height here collapses the
	// virtual_list viewport and nothing paints.
	return rl.col(
		rl.row(
			rl.text("检查与序列", th.color.fg_muted, th.font.size_xs),
			rl.flex(1, rl.spacer(0)),
			rl.text(fmt.tprintf("%d Studies", len(s.tree.studies)), th.color.primary, th.font.size_xs),
			width = 0,
			height = 28,
			padding = th.spacing.sm,
			cross_align = .Center,
		),
		rl.flex(1, rl.virtual_list(ctx, snap, len(s.rows), SERIES_ROW_H, {260, 0},
			sidebar_row_view,
			proc(st: ^Sidebar_Snapshot, i: int) -> u64 { return u64(i) },
			overscan = 6,
		)),
		width = 260,
		height = 0,
		cross_align = .Stretch,
	)
}

// SERIES_ROW_H is the tallest row the tree renders (a series card with
// its badge, count and slice bar). virtual_list uses one height for all
// rows, so every row gets this.
SERIES_ROW_H :: 44

Sidebar_Snapshot :: struct {
	rows:     []Sidebar_Row,
	selected: int,
}

@(private)
sidebar_row_view :: proc(ctx: ^rl.Ctx(Msg), st: ^Sidebar_Snapshot, i: int) -> rl.View {
	th := ctx.theme
	if st == nil || i < 0 || i >= len(st.rows) do return rl.spacer(22)
	row := st.rows[i]
	selected := i == st.selected

	switch row.kind {
	case .Study:
		body := rl.row(
			rl.text(row.label, th.color.fg, th.font.size_xs),
			rl.flex(1, rl.spacer(0)),
			rl.text(fmt.tprintf("%d im", row.count), th.color.fg_muted, th.font.size_xs),
			width = 0,
			height = SERIES_ROW_H,
			padding = th.spacing.xs,
			cross_align = .Center,
		)
		return rl.clickable(ctx, body, Msg{kind = .Select_Row, row = i}, id = rl.Widget_ID(i + 1))

	case .Series:
		// Design g2-a card: badge, title, count, then a slice bar.
		badge := rl.text(row.modality, th.color.primary, th.font.size_xs)
		title := rl.text(row.label, selected ? th.color.on_primary : th.color.fg, th.font.size_xs)
		top := rl.row(
			badge,
			title,
			rl.flex(1, rl.spacer(0)),
			rl.text(fmt.tprintf("%d", row.count), th.color.fg_muted, th.font.size_xs),
			width = 0,
			height = 20,
			spacing = th.spacing.xs,
			cross_align = .Center,
		)
		card := rl.col(
			top,
			rl.text(fmt.tprintf("%d 帧", row.count), th.color.fg_muted, th.font.size_xs),
			width = 0,
			height = SERIES_ROW_H,
			padding = th.spacing.xs,
			spacing = 2,
			main_align = .Center,
			bg = selected ? th.color.surface : {},
			radius = th.radius.sm,
		)
		return rl.clickable(ctx, card, Msg{kind = .Select_Row, row = i}, id = rl.Widget_ID(i + 1))

	case .Frame:
		color := selected ? th.color.on_primary : th.color.fg_muted
		body := rl.row(
			rl.spacer(12),
			rl.text(row.label, color, th.font.size_xs),
			height = SERIES_ROW_H,
			cross_align = .Center,
		)
		return rl.clickable(ctx, body, Msg{kind = .Select_Row, row = i}, id = rl.Widget_ID(i + 1))
	}
	return rl.spacer(22)
}
