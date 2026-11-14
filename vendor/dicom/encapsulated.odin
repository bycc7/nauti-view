package dicom

import "core:encoding/endian"

// Frame byte extraction shared by all encapsulated (compressed) pixel syntaxes:
// RLE, JPEG and JPEG 2000. The first fragment is the Basic Offset Table; BOT[f] is
// the byte offset of frame f relative to the first frame fragment.
//
// Virtual position of fragment payload `index` (0-based, first non-BOT fragment): the
// concatenation of item headers and payloads, which is the coordinate space BOT offsets use.
@(private)
virtual_base :: proc "contextless" (frags: []Fragment, index: int) -> int {
	base := 0
	for j in 1 ..= index do base += 8 + int(frags[j].length)
	return base
}

// Maps a virtual position to (fragment index, payload byte offset). ok is false past the end.
@(private)
locate_virtual :: proc "contextless" (frags: []Fragment, pos: int) -> (index: int, off: int, ok: bool) {
	virtual := 0
	for i in 1 ..< len(frags) {
		payload_len := int(frags[i].length)
		if pos >= virtual && pos < virtual + 8 + payload_len {
			return i - 1, max(pos - virtual - 8, 0), true
		}
		virtual += 8 + payload_len
	}
	return 0, 0, false
}

// Copies the virtual byte range [start, end) across fragments into one buffer.
@(private)
copy_virtual :: proc (buf: []u8, frags: []Fragment, start, end: int) -> (out: []u8, ok: bool) {
	if start < 0 || end <= start do return nil, false
	// The range may include item headers; only payload bytes are copied, so the size is
	// counted first (one pass, no realloc) and the copy is the second pass.
	n := 0
	for i in 1 ..< len(frags) {
		payload_start := virtual_base(frags, i - 1) + 8
		payload_end := payload_start + int(frags[i].length)
		if payload_end <= start do continue
		if payload_start >= end do break
		n += min(end, payload_end) - max(start, payload_start)
	}
	if n <= 0 do return nil, false
	out = make([]u8, n)
	at := 0
	for i in 1 ..< len(frags) {
		payload_start := virtual_base(frags, i - 1) + 8
		payload_end := payload_start + int(frags[i].length)
		if payload_end <= start do continue
		if payload_start >= end do break
		from := max(start, payload_start) - payload_start
		to := min(end, payload_end) - payload_start
		f := frags[i]
		if f.offset + u64(to) > u64(len(buf)) do return nil, false
		copy(out[at:at + to - from], buf[f.offset + u64(from):f.offset + u64(to)])
		at += to - from
	}
	if at != n do return nil, false
	return out, true
}

// Returns the codestream bytes of one frame. When the whole frame lives inside a single
// fragment payload the slice aliases the document buffer (owned == false, do not delete);
// only frames actually split across fragments are copied (owned == true, delete it).
//
// The first fragment is the Basic Offset Table. BOT[f] is the byte offset of frame f in the
// virtual space (item headers included, PS3.5 A.4). Without a BOT, a single-frame pixel data
// is one codestream split over items, otherwise one fragment per frame.
encapsulated_frame_codestream :: proc(doc: ^Document, pixel: Element, frame_index: int, frames: int) -> (cs: []u8, owned: bool, ok: bool) {
	buf := doc.body if .In_Body in pixel.flags else doc.src
	frags := document_fragments(doc, pixel)
	if len(frags) < 2 do return nil, false, false

	bot := frags[0]
	bot_end := bot.offset + u64(bot.length)
	if bot_end > u64(len(buf)) do return nil, false, false
	bot_bytes := buf[bot.offset:bot_end]

	total_virtual := 0
	for i in 1 ..< len(frags) do total_virtual += 8 + int(frags[i].length)

	if len(bot_bytes) >= frames * 4 {
		if frame_index < 0 || frame_index >= frames do return nil, false, false
		start, _ := endian.get_u32(bot_bytes[frame_index * 4:][:4], .Little)
		end := u32(total_virtual)
		if frame_index + 1 < frames {
			next, _ := endian.get_u32(bot_bytes[(frame_index + 1) * 4:][:4], .Little)
			if next > start do end = next
		}
		if int(start) >= total_virtual || int(end) > total_virtual || end <= start {
			return nil, false, false
		}
		fi, off_start, ok0 := locate_virtual(frags, int(start))
		if !ok0 do return nil, false, false
		ei, off_end, ok1 := locate_virtual(frags, int(end) - 1)
		if !ok1 do return nil, false, false
		if fi == ei {
			f := frags[fi + 1]
			if f.offset + u64(off_end + 1) > u64(len(buf)) do return nil, false, false
			return buf[f.offset + u64(off_start):f.offset + u64(off_end + 1)], false, true
		}
		out, cok := copy_virtual(buf, frags, int(start), int(end))
		return out, true, cok
	}

	// No BOT (or too short): one fragment per frame, unless the value is single-frame.
	if frames == 1 {
		// The whole pixel value is one codestream, possibly split over several items.
		total := 0
		for i in 1 ..< len(frags) do total += int(frags[i].length)
		out := make([]u8, total)
		at := 0
		for i in 1 ..< len(frags) {
			f := frags[i]
			fend := f.offset + u64(f.length)
			if fend > u64(len(buf)) do return nil, false, false
			copy(out[at:at + int(f.length)], buf[f.offset:fend])
			at += int(f.length)
		}
		return out, true, true
	}
	if frame_index < 0 || frame_index >= len(frags) - 1 do return nil, false, false
	f := frags[frame_index + 1]
	fend := f.offset + u64(f.length)
	if fend > u64(len(buf)) do return nil, false, false
	return buf[f.offset:fend], false, true
}
// Accepts either a raw J2K codestream (SOC FF4F) or a JP2 file/box stream and returns
// the raw codestream slice. Some GDCM-era encoders wrote a JP2 wrapper inside DICOM
// PixelData; the standard requires a raw codestream but real files exist.
j2k_unwrap_jp2 :: proc(b: []u8) -> []u8 {
	if len(b) >= 4 && b[0] == 0xFF && b[1] == 0x4F do return b
	if len(b) < 12 || b[0] != 0 || b[1] != 0 || b[2] != 0 || b[3] != 0x0C {
		return b
	}
	// Walk the box list looking for the "jp2c" codestream box.
	p := 0
	for p + 8 <= len(b) {
		length := int(u32(b[p]) << 24 | u32(b[p + 1]) << 16 | u32(b[p + 2]) << 8 | u32(b[p + 3]))
		kind := [4]u8{b[p + 4], b[p + 5], b[p + 6], b[p + 7]}
		if kind == {'j', 'p', '2', 'c'} {
			start := p + 8
			end := len(b)
			if length > 8 && p + length <= len(b) do end = p + length
			if start >= end do return b
			return b[start:end]
		}
		if length < 8 do return b
		p += length
	}
	return b
}
