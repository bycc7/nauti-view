package nautilus

// Top instrument bar (design g1-a): brand, open actions, layout switch,
// window/level + transform + preset groups, and the inspector toggle.
// Buttons that map to a key mirror the shortcut in the label.

import "core:fmt"
import rl "../vendor/skald"

@(private)
tbtn :: proc(ctx: ^rl.Ctx(Msg), label: string, m: Msg, active: bool = false) -> rl.View {
	th := ctx.theme
	bg := active ? th.color.surface : rl.rgb(0x131822)
	fg := active ? th.color.primary : th.color.fg
	body := rl.row(
		rl.text(label, fg, th.font.size_xs),
		height = 26,
		padding = th.spacing.sm,
		cross_align = .Center,
	)
	return rl.clickable(ctx, body, m)
}

topbar :: proc(ctx: ^rl.Ctx(Msg), s: ^App_State) -> rl.View {
	th := ctx.theme
	layout_label := "1x1"
	switch s.layout {
	case .Single: layout_label = "1x1"
	case .Two:    layout_label = "1x2"
	case .Quad:   layout_label = "2x2"
	}

	return rl.row(
		rl.text("NAUTILUS", th.color.fg, th.font.size_sm),
		tbtn(ctx, "打开文件", Msg{kind = .Open_Dialog}),
		tbtn(ctx, "打开目录", Msg{kind = .Open_Directory}),
		tbtn(ctx, fmt.tprintf("布局 %s", layout_label), Msg{kind = .Layout_Cycle}),
		tbtn(ctx, "反相", Msg{kind = .Invert}, vp_active(s).window.invert),
		tbtn(ctx, "翻转 H", Msg{kind = .Flip_H}, vp_active(s).flip_h),
		tbtn(ctx, "翻转 V", Msg{kind = .Flip_V}, vp_active(s).flip_v),
		tbtn(ctx, "旋转", Msg{kind = .Rotate}),
		tbtn(ctx, "重置", Msg{kind = .Reset_Window}),
		rl.flex(1, rl.spacer(0)),
		tbtn(ctx, "标签面板", Msg{kind = .Toggle_Inspector}, s.inspector.open),
		width = 0,
		height = 40,
		padding = th.spacing.sm,
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
}
