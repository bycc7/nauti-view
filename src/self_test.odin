package nautilus

// Task 6 (M1) self-test: exercises the real open → decode → LUT → RGBA
// path headlessly, then checks the produced buffer is plausible for the
// file it came from. This is the red/green gate for M1; the GPU upload
// itself is verified on screen (final verify page).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import d "../vendor/dicom"

self_test :: proc(files: []string) -> int {
	total_fail := 0
	for file in files {
		sw := init_stopwatch()
		frame, err := load_frame_cpu(file)
		open_ms := elapsed_ms(&sw)
		if frame == nil {
			fmt.eprintfln("FAIL  %s: %s", file, err)
			total_fail += 1
			continue
		}

		w := frame.info.cols
		h := frame.info.rows
		rgba := make([]u8, w * h * 4)
		sw2 := init_stopwatch()
		ok := frame_to_rgba(frame, frame.window, rgba)
		lut_ms := elapsed_ms(&sw2)
		if !ok {
			fmt.eprintfln("FAIL  %s: frame_to_rgba refused (%v, %d samples)",
				file, frame.info.photometric, frame.info.samples)
			free_frame(frame)
			total_fail += 1
			continue
		}

		// Alpha must be opaque everywhere: a zero here means the LUT
		// packing is wrong and the GPU would blend the image translucent.
		bad_alpha := 0
		min_l, max_l := u8(255), u8(0)
		for i in 0 ..< w * h {
			a := rgba[i * 4 + 3]
			if a != 255 do bad_alpha += 1
			l := rgba[i * 4]
			if l < min_l do min_l = l
			if l > max_l do max_l = l
		}

		dynamic_range := int(max_l) - int(min_l)
		problems: [dynamic]string
		defer delete(problems)
		if bad_alpha != 0 {
			append(&problems, fmt.aprintf("%d non-opaque pixels", bad_alpha))
		}
		if dynamic_range < 8 {
			append(&problems, fmt.aprintf("flat image: L range %d..%d", min_l, max_l))
		}

		if len(problems) == 0 {
			fmt.printfln("OK    %s  %dx%d frame=%d bps=%d  open+decode %.1f ms  lut %.1f ms  L %d..%d",
				short_name(file), w, h, frame.info.frames, frame.info.bytes_per_sample,
				open_ms, lut_ms, min_l, max_l)
		} else {
			fmt.eprintfln("FAIL  %s: %s", file, join_strings(problems[:]))
			total_fail += 1
		}
		free_frame(frame)
		delete(rgba)
	}

	if total_fail != 0 {
		fmt.eprintfln("\nSELF-TEST FAILED (%d of %d files)", total_fail, len(files))
		return 1
	}
	fmt.printfln("\nSELF-TEST OK (%d files)", len(files))
	return 0
}

@(private)
free_frame :: proc(f: ^Cached_Frame) {
	if f.key.file != "" do delete(f.key.file)
	delete(f.raw)
	free(f)
}

@(private)
short_name :: proc(path: string) -> string {
	base := path
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			base = path[i + 1:]
			break
		}
	}
	if len(base) > 46 do return base[len(base) - 46:]
	return base
}

@(private)
join_strings :: proc(parts: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for p, i in parts {
		if i > 0 do strings.write_string(&sb, "; ")
		strings.write_string(&sb, p)
	}
	return strings.to_string(sb)
}

// unused import guard: os is used by the caller of self_test (main.odin).

@(private)
_os_guard :: proc() -> bool { return os.exists(".") }

// dump_rgba renders one file's frame 0 and writes the raw RGBA8 buffer to
// `out`, for byte-comparison against pydicom in the acceptance harness.
dump_rgba :: proc(file, out: string) -> int {
	frame, err := load_frame_cpu(file)
	if frame == nil {
		fmt.eprintfln("FAIL  %s: %s", file, err)
		return 1
	}
	defer free_frame(frame)

	rgba := make([]u8, frame.info.cols * frame.info.rows * 4)
	defer delete(rgba)
	if !frame_to_rgba(frame, frame.window, rgba) {
		fmt.eprintfln("FAIL  %s: frame_to_rgba refused", file)
		return 1
	}
	if werr := os.write_entire_file(out, rgba); werr != nil {
		fmt.eprintfln("FAIL  write %s: %v", out, werr)
		return 1
	}
	fmt.printfln("DUMP  %s  %dx%d  W %.0f / L %.0f", file, frame.info.rows, frame.info.cols,
		frame.window.width, frame.window.center)
	return 0
}

// self_test_dir exercises the directory path end to end: scan, build
// rows, then decode the first frame of every series through the same CPU
// pipeline the viewer uses.
self_test_dir :: proc(root: string) -> int {
	sw := init_stopwatch()
	tree := scan_directory(root, allocator = context.allocator)
	defer study_tree_destroy(&tree)
	scan_ms := elapsed_ms(&sw)

	if len(tree.entries) == 0 {
		fmt.eprintfln("FAIL  %s: no DICOM images found", root)
		return 1
	}

	series_total, frames_total := 0, 0
	for st in tree.studies {
		series_total += len(st.series)
		for ser in st.series do frames_total += len(ser.frames)
	}

	// First-frame latency for each series: the number the red line cares
	// about is the worst one.
	worst_ms := 0.0
	worst_name := ""
	decoded := 0
	for st in tree.studies {
		for ser in st.series {
			if len(ser.frames) == 0 do continue
			path := tree.entries[ser.frames[0]].path
			sw2 := init_stopwatch()
			frame, err := load_frame_cpu(path)
			ms := elapsed_ms(&sw2)
			if frame == nil {
				continue
			}
			free_frame(frame)
			decoded += 1
			if ms > worst_ms {
				worst_ms = ms
				worst_name = short_name(path)
			}
			_ = err
		}
	}

	fmt.printfln("DIR   %s", root)
	fmt.printfln("  scan %.1f ms | %d files | %d studies | %d series | %d frames",
		scan_ms, len(tree.entries), len(tree.studies), series_total, frames_total)
	fmt.printfln("  first frame of %d series decoded | worst %.1f ms (%s)", decoded, worst_ms, worst_name)

	// Every regular file in the directory gets a diagnostic, including
	// the ones the tree skips (no Rows/Columns: SR, RT, waveform).
	// Every regular file under `root`, at any depth.
	Inspected :: struct {
		total, openable, decodable, preamble_less: int,
	}
	ins: Inspected
	walk_diag :: proc(dir: string, ins: ^Inspected) {
		files, ferr := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if ferr != nil do return
		for fi in files {
			full, jerr := filepath.join({dir, fi.name}, allocator = context.temp_allocator)
			if jerr != nil do continue
			#partial switch fi.type {
			case .Directory:
				walk_diag(full, ins)
			case .Regular:
				d := inspect_file_diagnostic(full, context.temp_allocator)
				ins.total += 1
				if d.open_err == .None do ins.openable += 1
				if d.decode_ok do ins.decodable += 1
				if !d.has_preamble && d.open_err == .None do ins.preamble_less += 1
			}
		}
	}
	walk_diag(root, &ins)
	fmt.printfln("  inspected %d files | %d parsed | %d decoded | %d without preamble",
		ins.total, ins.openable, ins.decodable, ins.preamble_less)

	if scan_ms > 400 {
		fmt.eprintfln("FAIL  scan took %.1f ms (budget 400 ms)", scan_ms)
		return 1
	}
	fmt.printfln("\nSELF-TEST DIR OK")
	return 0
}
