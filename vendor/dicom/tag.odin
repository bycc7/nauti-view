package dicom

Tag :: struct {
	group:   u16,
	element: u16,
}

#assert(size_of(Tag) == 4)

TAG_FILE_META_INFO_GROUP_LEN :: Tag{0x0002, 0x0000}
TAG_TRANSFER_SYNTAX_UID      :: Tag{0x0002, 0x0010}
TAG_ITEM                     :: Tag{0xFFFE, 0xE000}
TAG_ITEM_DELIMITATION        :: Tag{0xFFFE, 0xE00D}
TAG_SEQ_DELIMITATION         :: Tag{0xFFFE, 0xE0DD}
TAG_PIXEL_DATA               :: Tag{0x7FE0, 0x0010}

UNDEFINED_LENGTH :: u32(0xFFFF_FFFF)

tag_to_u32 :: #force_inline proc "contextless" (t: Tag) -> u32 {
	return (u32(t.group) << 16) | u32(t.element)
}

tag_from_u32 :: #force_inline proc "contextless" (v: u32) -> Tag {
	return Tag{u16(v >> 16), u16(v & 0xFFFF)}
}
