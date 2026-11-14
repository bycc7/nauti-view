package dicom

import "base:runtime"

// Contract C4: a Document owns every buffer an Element may point into -- the borrowed or mapped
// source bytes, the inflated dataset buffer (Deflated TS), and the element/item/fragment pools.
// Element values are (offset, length) pairs rather than slices, so nothing can outlive the owner.
//
// Contract C5: single post-order pass. Each level stages its direct children in a Document-owned
// scratch stack and flushes them into a pool when the level ends, so every Span is a contiguous
// slice and no level needs a second pass or a per-level allocation.

Element_Flag :: enum u8 {
	In_Body,      // value_offset refers to Document.body instead of Document.src
	Undefined,    // on-disk length was 0xFFFFFFFF
	Sequence,     // children index Document.items
	Encapsulated, // children index Document.fragments
}

Element_Flags :: bit_set[Element_Flag; u8]

Span :: struct {
	start: u32,
	count: u32,
}

Element :: struct {
	tag:          Tag,
	vr:           VR,
	flags:        Element_Flags,
	length:       u32, // on-disk length field, UNDEFINED_LENGTH when undefined
	value_offset: u64, // into Document.src, or Document.body when .In_Body
	children:     Span, // items for .Sequence, fragments for .Encapsulated
}

// 4 tag + 1 vr + 1 flags + 2 pad + 4 length + 4 pad + 8 offset + 8 span
#assert(size_of(Element) == 32)

Item :: struct {
	span:      Span, // elements of this item's dataset, contiguous in Document.elements
	length:    u32,
	undefined: bool,
	_pad:      [3]u8,
}

Fragment :: struct {
	offset: u64,
	length: u32,
	_pad:   [4]u8,
}

Phase :: enum u8 {
	Idle,
	Meta,
	Body,
}

// T4: context of the last parse failure. `tag`/`offset`/`depth` describe the element the
// parser was working on when it failed, not the byte the error was detected at.
Diagnostic :: struct {
	kind:   Parse_Error,
	tag:    Tag,
	offset: u32,
	depth:  u8,
}

Document :: struct {
	allocator: runtime.Allocator,

	src:      []u8, // borrowed from the caller, or owned through `mapped`
	mapped:   Mapped_File,
	body:     []u8, // inflated dataset for Deflated TS, otherwise nil
	inflated: [dynamic]u8,

	meta:   Meta_Info,
	ts:     Transfer_Syntax,
	phase:  Phase,
	limits: Limits,
	// Early-stop boundary for header scans: parsing halts (at depth 0)
	// before the element whose tag >= parse_stop, when non-zero. Used by
	// directory indexers via document_open_file_opts / document_parse_buffer_opts
	// so multi-fragment PixelData payloads are never walked. {0,0} disables it.
	parse_stop: Tag,
	error:  Diagnostic,

	meta_span: Span,
	root:      Span,

	elements:  [dynamic]Element,
	items:     [dynamic]Item,
	fragments: [dynamic]Fragment,

	scratch:       [dynamic]Element, // staged elements of the levels being built
	scratch_items: [dynamic]Item,    // staged items of the sequences being built
	warnings:      [dynamic]Warning,
}

document_init :: proc(doc: ^Document, allocator := context.allocator) {
	doc^ = Document{}
	doc.allocator = allocator
	doc.limits = DEFAULT_LIMITS
}

document_destroy :: proc(doc: ^Document) {
	unmap_file(&doc.mapped)
	delete(doc.inflated)
	delete(doc.elements)
	delete(doc.items)
	delete(doc.fragments)
	delete(doc.scratch)
	delete(doc.scratch_items)
	delete(doc.warnings)
	doc^ = Document{}
}

// Drops all parse state but keeps pool capacity, so a warm Document re-parses without allocating.
document_reset :: proc(doc: ^Document) {
	unmap_file(&doc.mapped)
	doc.src = nil
	doc.body = nil
	clear(&doc.inflated)
	clear(&doc.elements)
	clear(&doc.items)
	clear(&doc.fragments)
	clear(&doc.scratch)
	clear(&doc.scratch_items)
	clear(&doc.warnings)
	doc.meta = {}
	doc.ts = {}
	doc.phase = .Idle
	doc.error = {}
	// Limits are configuration, not parse state: a caller that tightened them before the first
	// parse keeps them across document_parse_buffer/document_open_file re-use.
	doc.meta_span = {}
	doc.root = {}
}

// ---------------------------------------------------------------------------------------------
// Builder: turns parser events into the flattened pools above.
// ---------------------------------------------------------------------------------------------

Build_Frame :: struct {
	elem_mark: u32, // scratch length when an item's dataset started
	item_mark: u32, // scratch_items length when a sequence started
	frag_mark: u32, // fragments length when an encapsulated value started
	tag:       Tag,
	vr:        VR,
	offset:    u64,
	length:    u32,
	undefined: bool,
}

Builder :: struct {
	doc:    ^Document,
	frames: [MAX_DEPTH + 2]Build_Frame,
	depth:  int,
}

// Moves scratch[mark:] into the persistent pool and rewinds the scratch. The copied region is
// contiguous by construction, which is what makes Span a plain (start, count) pair.
flush_scratch_elements :: proc(doc: ^Document, mark: int) -> Span {
	n := len(doc.scratch) - mark
	if n <= 0 do return Span{u32(len(doc.elements)), 0}
	base := len(doc.elements)
	append(&doc.elements, ..doc.scratch[mark:])
	shrink(&doc.scratch, mark)
	return Span{u32(base), u32(n)}
}

flush_scratch_items :: proc(doc: ^Document, mark: int) -> Span {
	n := len(doc.scratch_items) - mark
	if n <= 0 do return Span{u32(len(doc.items)), 0}
	base := len(doc.items)
	append(&doc.items, ..doc.scratch_items[mark:])
	shrink(&doc.scratch_items, mark)
	return Span{u32(base), u32(n)}
}

builder_event :: proc(ev: Event, user: rawptr) {
	b := (^Builder)(user)
	doc := b.doc
	in_body := doc.phase == .Body && len(doc.body) > 0

	switch ev.kind {
	case .Element:
		flags: Element_Flags
		if in_body do flags += {.In_Body}
		if ev.length == UNDEFINED_LENGTH do flags += {.Undefined}
		append(&doc.scratch, Element{
			tag = ev.tag,
			vr = ev.vr,
			flags = flags,
			length = ev.length,
			value_offset = u64(ev.value_offset),
		})

	case .Item_Begin:
		b.frames[b.depth] = Build_Frame{
			elem_mark = u32(len(doc.scratch)),
			tag = ev.tag,
			vr = ev.vr,
			offset = u64(ev.offset),
			length = ev.length,
			undefined = ev.undefined,
		}
		b.depth += 1

	case .Item_End:
		b.depth -= 1
		f := b.frames[b.depth]
		span := flush_scratch_elements(doc, int(f.elem_mark))
		append(&doc.scratch_items, Item{
			span = span,
			length = f.length,
			undefined = f.undefined,
		})

	case .Sequence_Begin:
		b.frames[b.depth] = Build_Frame{
			item_mark = u32(len(doc.scratch_items)),
			frag_mark = u32(len(doc.fragments)),
			tag = ev.tag,
			vr = ev.vr,
			offset = u64(ev.offset),
			length = ev.length,
			undefined = ev.undefined,
		}
		b.depth += 1

	case .Fragment:
		append(&doc.fragments, Fragment{offset = u64(ev.value_offset), length = ev.length})

	case .Sequence_End:
		b.depth -= 1
		f := b.frames[b.depth]

		flags: Element_Flags
		if in_body do flags += {.In_Body}
		if f.undefined do flags += {.Undefined}

		children: Span
		if f.vr == .SQ {
			flags += {.Sequence}
			children = flush_scratch_items(doc, int(f.item_mark))
		} else {
			// Encapsulated value: its fragments were appended contiguously while it was parsed,
			// so the span is already correct and no copy is needed.
			flags += {.Encapsulated}
			children = Span{f.frag_mark, u32(len(doc.fragments)) - f.frag_mark}
		}

		append(&doc.scratch, Element{
			tag = f.tag,
			vr = f.vr,
			flags = flags,
			length = f.length,
			value_offset = f.offset,
			children = children,
		})
	}
}

// ---------------------------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------------------------

document_parse_buffer :: proc(doc: ^Document, src: []u8) -> Parse_Error {
	document_reset(doc)
	doc.src = src
	return document_parse_current(doc)
}

document_open_file :: proc(doc: ^Document, path: string) -> Parse_Error {
	return document_open_file_opts(doc, path, Tag{})
}

document_open_file_opts :: proc(doc: ^Document, path: string, stop_before_tag: Tag) -> Parse_Error {
	document_reset(doc)
	doc.parse_stop = stop_before_tag
	mapped, merr := map_file(path)
	if merr != .None {
		doc.parse_stop = Tag{}
		return merr
	}
	doc.mapped = mapped
	doc.src = mapped.data
	err := document_parse_current(doc)
	doc.parse_stop = Tag{}
	return err
}

document_parse_buffer_opts :: proc(doc: ^Document, src: []u8, stop_before_tag: Tag) -> Parse_Error {
	document_reset(doc)
	doc.parse_stop = stop_before_tag
	doc.src = src
	err := document_parse_current(doc)
	doc.parse_stop = Tag{}
	return err
}

document_parse_current :: proc(doc: ^Document) -> Parse_Error {
	// Pin the allocator so pool growth and inflation never depend on ambient context.
	outer := context.allocator
	context.allocator = doc.allocator
	defer context.allocator = outer

	b := Builder{doc = doc}
	h := Handler{on_event = builder_event, user = &b}

	doc.phase = .Meta
	c := Cursor{buf = doc.src}
	meta, merr := parse_meta(&c, h)
	if merr != .None {
		doc.error = Diagnostic{kind = merr, offset = u32(c.pos)}
		return merr
	}
	doc.meta = meta

	// File Meta Information elements are staged; close them off as their own block.
	doc.meta_span = flush_scratch_elements(doc, 0)

	body, start, berr := prepare_dataset_body(doc.src, doc.meta, &doc.inflated, doc.limits.max_inflated_bytes, doc.allocator)
	if berr != .None {
		doc.error = Diagnostic{kind = berr, offset = u32(doc.meta.data_offset)}
		return berr
	}
	if doc.meta.ts.deflated do doc.body = body

	if rerr := resolve_dataset_encoding(body, start, &doc.meta); rerr != .None do return rerr
	doc.ts = doc.meta.ts

	for i in 0 ..< doc.meta.warning_len {
		append(&doc.warnings, doc.meta.warnings[i])
	}

	doc.phase = .Body
	p := Parser{
		c    = Cursor{buf = body, pos = start},
		h    = h,
		opts = Parse_Options{max_elements = doc.limits.max_elements, stop_before_tag = doc.parse_stop},
	}
	perr := parse_dataset(&p, doc.ts, len(body), 0, false)
	if perr != .None {
		doc.error = Diagnostic{kind = perr, tag = p.diag.tag, offset = p.diag.offset, depth = p.diag.depth}
		return perr
	}
	end_pos, stopped := p.c.pos, p.stopped
	if !stopped && end_pos != len(body) {
		doc.error = Diagnostic{kind = .Invalid_Length, offset = u32(end_pos)}
		return .Invalid_Length
	}

	doc.root = flush_scratch_elements(doc, 0)
	return .None
}

// ---------------------------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------------------------

document_root :: proc(doc: ^Document) -> []Element {
	return document_elements(doc, doc.root)
}

document_elements :: proc(doc: ^Document, span: Span) -> []Element {
	end := u64(span.start) + u64(span.count)
	if end > u64(len(doc.elements)) do return nil
	return doc.elements[span.start:end]
}

document_items :: proc(doc: ^Document, e: Element) -> []Item {
	if .Sequence not_in e.flags do return nil
	end := u64(e.children.start) + u64(e.children.count)
	if end > u64(len(doc.items)) do return nil
	return doc.items[e.children.start:end]
}

document_fragments :: proc(doc: ^Document, e: Element) -> []Fragment {
	if .Encapsulated not_in e.flags do return nil
	end := u64(e.children.start) + u64(e.children.count)
	if end > u64(len(doc.fragments)) do return nil
	return doc.fragments[e.children.start:end]
}

// Element values never dangle: the returned slice is a view into a buffer the Document owns.
document_value :: proc(doc: ^Document, e: Element) -> []u8 {
	if .Sequence in e.flags || .Encapsulated in e.flags do return nil
	buf := doc.body if .In_Body in e.flags else doc.src
	end := e.value_offset + u64(e.length)
	if end > u64(len(buf)) do return nil
	return buf[e.value_offset:end]
}

document_find :: proc(doc: ^Document, tag: Tag) -> (Element, bool) {
	for e in document_root(doc) {
		if e.tag == tag do return e, true
	}
	return {}, false
}

document_error :: proc (doc: ^Document) -> Diagnostic {
	return doc.error
}

document_find_string :: proc(doc: ^Document, tag: Tag) -> (string, bool) {
	e, ok := document_find(doc, tag)
	if !ok do return "", false
	v := document_value(doc, e)
	return string(v), len(v) > 0
}
