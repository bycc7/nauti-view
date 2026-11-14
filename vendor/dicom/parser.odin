package dicom

MAX_DEPTH :: 64
MAX_PRIVATE_CREATORS :: 64

Event_Kind :: enum u8 {
	Element,
	Sequence_Begin,
	Sequence_End,
	Item_Begin,
	Item_End,
	Fragment,
}

Event :: struct {
	kind:         Event_Kind,
	depth:        int,
	tag:          Tag,
	vr:           VR,
	undefined:    bool,
	offset:       int,
	length:       u32,
	value_offset: int,
}

Handler :: struct {
	on_event: proc(ev: Event, user: rawptr),
	user:     rawptr,
}

Parse_Options :: struct {
	stop_before_tag: Tag, // {0, 0} disables early stop
	max_elements:  int,   // 0 disables the count budget (Document always sets one)
}

// Stack-scoped Private Creator slot (Step 6). `creator` is a zero-copy slice into `p.c.buf`.
Private_Creator_Slot :: struct {
	depth:   u8,
	block:   u8,
	group:   u16,
	creator: string,
}

Parser :: struct {
	c:          Cursor,
	h:          Handler,
	opts:       Parse_Options,
	stopped:    bool,
	priv_slots: [MAX_PRIVATE_CREATORS]Private_Creator_Slot,
	priv_len:   int,
	n_elements: int, // every element, item and fragment, against Parse_Options.max_elements
	diag:       Diagnostic, // last element/item/fragment the parser touched (T4 error context)
}

// T3 resource budget: counts every parsed node so a crafted small file cannot stage a
// multi-gigabyte element pool.
@private
bump_elements :: proc(p: ^Parser) -> (err: Parse_Error) {
	p.n_elements += 1
	if p.opts.max_elements > 0 && p.n_elements > p.opts.max_elements do return .Limit_Exceeded
	return .None
}

emit :: #force_inline proc(p: ^Parser, ev: Event) {
	if p.h.on_event != nil {
		p.h.on_event(ev, p.h.user)
	}
}

register_private_creator :: proc "contextless" (p: ^Parser, depth: int, tag: Tag, raw_val: []u8) {
	creator := trim_private_creator(string(raw_val))
	if len(creator) == 0 do return
	d := u8(depth)
	blk := u8(tag.element & 0xFF)
	for i := p.priv_len - 1; i >= 0; i -= 1 {
		slot := &p.priv_slots[i]
		if slot.depth < d do break
		if slot.depth == d && slot.group == tag.group && slot.block == blk {
			slot.creator = creator
			return
		}
	}
	if p.priv_len < MAX_PRIVATE_CREATORS {
		p.priv_slots[p.priv_len] = Private_Creator_Slot{
			depth   = d,
			block   = blk,
			group   = tag.group,
			creator = creator,
		}
		p.priv_len += 1
	}
}

resolve_parser_private_vr :: proc "contextless" (p: ^Parser, depth: int, tag: Tag) -> (vr: VR, ok: bool) {
	if (tag.group & 1) == 0 || tag.element < 0x1000 do return .UN, false
	d := u8(depth)
	blk := u8(tag.element >> 8)
	// Search only the current dataset's depth so Item-level creators stay strictly local to their Item.
	for i := p.priv_len - 1; i >= 0; i -= 1 {
		slot := p.priv_slots[i]
		if slot.depth < d do break
		if slot.depth == d && slot.group == tag.group && slot.block == blk {
			return lookup_private_vr(slot.creator, tag)
		}
	}
	return .UN, false
}

parse_body :: proc(
	buf:   []u8,
	start: int,
	ts:    Transfer_Syntax,
	h:     Handler,
	opts:  Parse_Options = {},
) -> (end_pos: int, stopped: bool, err: Parse_Error) {
	p := Parser{
		c    = Cursor{buf = buf, pos = start},
		h    = h,
		opts = opts,
	}
	err = parse_dataset(&p, ts, len(buf), 0, false)
	return p.c.pos, p.stopped, err
}

parse_dataset :: proc(
	p:          ^Parser,
	ts:         Transfer_Syntax,
	limit:      int,
	depth:      int,
	undef_item: bool,
) -> Parse_Error {
	if depth > MAX_DEPTH do return .Max_Depth_Exceeded
	saved_priv_len := p.priv_len
	defer p.priv_len = saved_priv_len

	stop_u32 := tag_to_u32(p.opts.stop_before_tag)

	for p.c.pos < limit {
		offset := p.c.pos
		if depth == 0 && stop_u32 != 0 {
			next_t := peek_tag(&p.c, ts.order) or_return
			if tag_to_u32(next_t) >= stop_u32 {
				p.stopped = true
				return .None
			}
		}

		tag, vr, length := read_element_header(&p.c, ts.implicit_vr, ts.order) or_return
		p.diag = Diagnostic{tag = tag, offset = u32(offset), depth = u8(depth)}
		bump_elements(p) or_return

		if tag == TAG_ITEM_DELIMITATION {
			if undef_item && length == 0 do return .None
			return .Bad_Delimiter
		}
		if tag.group == 0xFFFE {
			return .Bad_Delimiter
		}

		// PS3.5 6.2.2: the Value of an Explicit VR element with VR UN is encoded as Implicit VR LE.
		// Step 6: when VR is UN (either Implicit VR on a private tag, or Explicit VR written as UN),
		// consult the active Private Creator for this dataset level if standard lookup gave .UN.
		un_implicit := !ts.implicit_vr && vr == .UN
		vr_inferred_sq := false
		sub_ts := ts
		if un_implicit {
			sub_ts.implicit_vr = true
			sub_ts.order = .Little
			if dict_vr := lookup_vr(tag); dict_vr != .UN {
				vr = dict_vr
				vr_inferred_sq = (vr == .SQ)
			}
		}
		if vr == .UN && (tag.group & 1) == 1 && tag.element >= 0x1000 {
			if priv_vr, ok := resolve_parser_private_vr(p, depth, tag); ok && priv_vr != .UN {
				vr = priv_vr
				vr_inferred_sq = (vr == .SQ)
			}
		}
		// Guard inferred defined-length SQ: only expand as a Sequence if empty or starts with TAG_ITEM.
		if vr_inferred_sq && length != UNDEFINED_LENGTH && length > 0 {
			if next_t, perr := peek_tag(&p.c, sub_ts.order); perr != .None || next_t != TAG_ITEM {
				vr = .UN
			}
		}
		ev_vr := vr

		if length == UNDEFINED_LENGTH {
			if tag == TAG_PIXEL_DATA || vr == .OB || vr == .OW || vr == .OB_OW {
				emit(p, Event{kind = .Sequence_Begin, depth = depth, tag = tag, vr = vr, undefined = true, offset = offset, length = length, value_offset = p.c.pos})
				parse_fragments(p, ts.order, limit, depth + 1) or_return
				emit(p, Event{kind = .Sequence_End, depth = depth, tag = tag, vr = vr, undefined = true, offset = offset, length = length, value_offset = p.c.pos})
			} else if ev_vr == .SQ || un_implicit || ts.implicit_vr {
				emit(p, Event{kind = .Sequence_Begin, depth = depth, tag = tag, vr = .SQ, undefined = true, offset = offset, length = length, value_offset = p.c.pos})
				parse_sequence(p, sub_ts, limit, depth + 1, true) or_return
				emit(p, Event{kind = .Sequence_End, depth = depth, tag = tag, vr = .SQ, undefined = true, offset = offset, length = length, value_offset = p.c.pos})
			} else {
				return .Invalid_Length
			}
		} else if ev_vr == .SQ {
			end := sub_limit(&p.c, length, limit) or_return
			emit(p, Event{kind = .Sequence_Begin, depth = depth, tag = tag, vr = .SQ, undefined = false, offset = offset, length = length, value_offset = p.c.pos})
			parse_sequence(p, sub_ts, end, depth + 1, false) or_return
			emit(p, Event{kind = .Sequence_End, depth = depth, tag = tag, vr = .SQ, undefined = false, offset = offset, length = length, value_offset = p.c.pos})
		} else {
			val_pos := p.c.pos
			val_bytes := read_bytes(&p.c, u64(length)) or_return
			if (tag.group & 1) == 1 && tag.element >= 0x0010 && tag.element <= 0x00FF {
				register_private_creator(p, depth, tag, val_bytes)
			}
			emit(p, Event{kind = .Element, depth = depth, tag = tag, vr = vr, offset = offset, length = length, value_offset = val_pos})
		}
	}

	if undef_item do return .Unexpected_EOF
	if p.c.pos != limit do return .Invalid_Length
	return .None
}

parse_sequence :: proc(
	p:         ^Parser,
	ts:        Transfer_Syntax,
	limit:     int,
	depth:     int,
	undefined: bool,
) -> Parse_Error {
	if depth > MAX_DEPTH do return .Max_Depth_Exceeded

	for p.c.pos < limit {
		item_off := p.c.pos
		tag := read_tag(&p.c, ts.order) or_return
		length := read_u32(&p.c, ts.order) or_return
		p.diag = Diagnostic{tag = tag, offset = u32(item_off), depth = u8(depth)}

		if tag == TAG_SEQ_DELIMITATION {
			if undefined && length == 0 do return .None
			return .Bad_Delimiter
		}
		if tag != TAG_ITEM do return .Bad_Delimiter

		bump_elements(p) or_return
		val_pos := p.c.pos
		emit(p, Event{kind = .Item_Begin, depth = depth, tag = tag, vr = .ITEM, undefined = (length == UNDEFINED_LENGTH), offset = item_off, length = length, value_offset = val_pos})
		if length == UNDEFINED_LENGTH {
			parse_dataset(p, ts, limit, depth, true) or_return
		} else {
			end := sub_limit(&p.c, length, limit) or_return
			parse_dataset(p, ts, end, depth, false) or_return
		}
		emit(p, Event{kind = .Item_End, depth = depth, tag = tag, vr = .ITEM, undefined = (length == UNDEFINED_LENGTH), offset = item_off, length = length, value_offset = val_pos})
	}

	if undefined do return .Unexpected_EOF
	if p.c.pos != limit do return .Invalid_Length
	return .None
}

parse_fragments :: proc(
	p:     ^Parser,
	order: Byte_Order,
	limit: int,
	depth: int,
) -> Parse_Error {
	if depth > MAX_DEPTH do return .Max_Depth_Exceeded

	for p.c.pos < limit {
		frag_off := p.c.pos
		tag := read_tag(&p.c, order) or_return
		length := read_u32(&p.c, order) or_return
		p.diag = Diagnostic{tag = tag, offset = u32(frag_off), depth = u8(depth)}

		if tag == TAG_SEQ_DELIMITATION {
			if length == 0 do return .None
			return .Bad_Delimiter
		}
		if tag != TAG_ITEM || length == UNDEFINED_LENGTH do return .Bad_Delimiter

		bump_elements(p) or_return
		val_pos := p.c.pos
		_ = read_bytes(&p.c, u64(length)) or_return
		emit(p, Event{kind = .Fragment, depth = depth, tag = tag, vr = .ITEM, offset = frag_off, length = length, value_offset = val_pos})
	}
	return .Unexpected_EOF
}
