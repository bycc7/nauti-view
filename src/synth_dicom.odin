package nautilus

// Task 7: 合成最小 DICOM 文件（显式 VR 小端、无 file meta），供
// study_loader 测试使用。只有扫描需要的元素，够 odin-dcm 的嗅探器识别。

import "core:encoding/endian"
import "core:fmt"
import "core:strings"

@(private)
Synth_Writer :: struct {
	buf: [dynamic]u8,
}

@(private)
synth_bytes :: proc(w: ^Synth_Writer, group, element: u16, vr: string, value: []u8) {
	append(&w.buf, u8(group & 0xFF), u8(group >> 8), u8(element & 0xFF), u8(element >> 8))
	append(&w.buf, vr[0], vr[1])
	if vr == "OB" || vr == "UN" || vr == "SQ" || vr == "OW" || vr == "UT" {
		append(&w.buf, 0, 0)
		n := u32(len(value))
		append(&w.buf, u8(n & 0xFF), u8((n >> 8) & 0xFF), u8((n >> 16) & 0xFF), u8((n >> 24) & 0xFF))
	} else {
		n := u16(len(value))
		append(&w.buf, u8(n & 0xFF), u8(n >> 8))
	}
	append(&w.buf, ..value)
}

@(private)
synth_str :: proc(w: ^Synth_Writer, group, element: u16, vr: string, s: string) {
	n := len(s) + len(s) % 2 // DICOM values are even-length
	v := make([]u8, n, context.temp_allocator)
	copy(v, s)
	if n > len(s) do v[len(s)] = 0
	synth_bytes(w, group, element, vr, v[:])
}

@(private)
synth_us :: proc(w: ^Synth_Writer, group, element: u16, v: u16) {
	b := make([]u8, 2, context.temp_allocator)
	endian.put_u16(b, .Little, v)
	synth_bytes(w, group, element, "US", b)
}

// synth_dicom_series writes one frame whose identifying tags are set so
// the loader can group and sort it. The optional arguments drive the
// sidebar metadata path (patient grouping, series description, geometry);
// they default to the values the older tests rely on.
synth_dicom_series :: proc(
	instance: int,
	study := "1.2.3",
	series := "1.2.3.4",
	description := "",
	patient_id := "",
	patient_name := "",
	modality := "CT",
	rows := 2,
	cols := 2,
	bits := 16,
) -> []u8 {
	w: Synth_Writer
	w.buf = make([dynamic]u8, 0, 512, context.temp_allocator)

	synth_str(&w, 0x0008, 0x0020, "DA", "20240101") // StudyDate
	synth_str(&w, 0x0008, 0x0060, "CS", modality) // Modality
	synth_str(&w, 0x0008, 0x103E, "LO", description) // SeriesDescription
	synth_str(&w, 0x0010, 0x0010, "PN", patient_name) // PatientName
	synth_str(&w, 0x0010, 0x0020, "LO", patient_id) // PatientID
	synth_str(&w, 0x0020, 0x000D, "UI", study) // StudyInstanceUID
	synth_str(&w, 0x0020, 0x000E, "UI", series) // SeriesInstanceUID
	synth_str(&w, 0x0020, 0x0011, "IS", fmt.tprintf("%d", 1)) // SeriesNumber
	synth_str(&w, 0x0020, 0x0013, "IS", fmt.tprintf("%d", instance)) // InstanceNumber
	synth_us(&w, 0x0028, 0x0002, 1) // SamplesPerPixel
	synth_us(&w, 0x0028, 0x0010, u16(rows)) // Rows
	synth_us(&w, 0x0028, 0x0011, u16(cols)) // Columns
	synth_us(&w, 0x0028, 0x0100, u16(bits)) // BitsAllocated
	synth_us(&w, 0x0028, 0x0101, 16) // BitsStored
	synth_us(&w, 0x0028, 0x0103, 0) // PixelRepresentation
	synth_str(&w, 0x0028, 0x0004, "CS", "MONOCHROME2") // PhotometricInterpretation

	// PixelData: 2x2 16-bit samples. OB takes the 32-bit reserved form, so
	// synth_bytes emits a length the parser accepts.
	pix := make([]u8, 8, context.temp_allocator)
	for i in 0 ..< 4 {
		v := u16(i * 1000)
		pix[i * 2] = u8(v & 0xFF)
		pix[i * 2 + 1] = u8(v >> 8)
	}
	synth_bytes(&w, 0x7FE0, 0x0010, "OB", pix[:])
	return w.buf[:]
}
