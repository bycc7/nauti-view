package nautilus

// Task 7: 目录扫描建树。
//
// 流程：递归收集候选路径 → 单线程试扫出「第一个合法文件」做早期反馈 →
// K = min(核数, 8) 个 worker 并行分片，每个 worker 独占一个可复用
// `Document` → 汇总后按 Study/Series 分组、组内按 InstanceNumber 稳定排序。
//
// 扫描只读 PixelData 之前的元素（Task 2 的 early stop），所以 690 个
// 512×512 的 CT 不会把像素搬进内存。

import "core:fmt"
import "core:os"
import "core:runtime"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import "core:thread"
import d "../vendor/dicom"

TAG_STUDY_UID :: d.Tag{0x0020, 0x000D}
TAG_SERIES_UID :: d.Tag{0x0020, 0x000E}
TAG_SERIES_NUMBER :: d.Tag{0x0020, 0x0011}
TAG_INSTANCE_NUMBER :: d.Tag{0x0020, 0x0013}
TAG_MODALITY :: d.Tag{0x0008, 0x0060}
TAG_STUDY_DATE :: d.Tag{0x0008, 0x0020}
TAG_SERIES_DESCRIPTION :: d.Tag{0x0008, 0x103E}
TAG_PATIENT_NAME :: d.Tag{0x0010, 0x0010}
TAG_PATIENT_ID :: d.Tag{0x0010, 0x0020}
TAG_ROWS :: d.Tag{0x0028, 0x0010}
TAG_COLUMNS :: d.Tag{0x0028, 0x0011}
TAG_BITS_ALLOCATED :: d.Tag{0x0028, 0x0100}

Study_Entry :: struct {
	path:     string, // owned
	study:    u32, // index into Study_Tree.studies
	series:   u32, // index into studies[study].series
	instance: int,
	// pos is the frame's index inside its series (0-based). The sidebar
	// cursor and the progress bar read it; build_tree fills it last, after
	// the per-series InstanceNumber sort has settled the order.
	pos: int,
}

Series_Node :: struct {
	uid:      string, // owned
	description: string, // owned; SeriesDescription (0008,103E), may be ""
	modality: string, // owned; per-series, not inherited from the study
	number:   int,
	rows:     int,
	cols:     int,
	bits:     int,
	frames:   []u32, // indices into Study_Tree.entries, sorted by instance
	// cursor is the index into `frames` currently shown for this series.
	// Updated by mark_cursor when a viewport displays one of its frames.
	cursor:   int,
}

Patient_Node :: struct {
	id:   string, // owned; PatientID (0010,0020), may be ""
	name: string, // owned; PatientName (0010,0010), may be ""
	studies: []u32, // indices into Study_Tree.studies, date-desc order
}

Study_Node :: struct {
	uid:    string, // owned; "" for a study without StudyInstanceUID
	date:   string, // owned
	modality: string, // owned; the study's first modality (header only)
	patient: u32, // index into Study_Tree.patients
	count:  int,
	series: []Series_Node,
}

Study_Tree :: struct {
	entries: []Study_Entry,
	studies: []Study_Node,
	patients: []Patient_Node,
}

// Series_Key identifies one series card across row rebuilds. It is an
// index pair, not a UID: empty or cross-study-reused UIDs must not merge
// two cards, and the map that stores expansion is cleared on every scan.
Series_Key :: struct {
	study:  u32,
	series: u32,
}

@(private)
Patient_Key :: struct { id, name: string }

@(private)
Study_Key :: struct {
	patient: Patient_Key,
	uid:     string,
}

@(private)
Series_Scan_Key :: struct {
	study:  Study_Key,
	series: string,
}

study_tree_destroy :: proc(t: ^Study_Tree) {
	for e in t.entries {
		if e.path != "" do delete(e.path)
	}
	for s in t.studies {
		if s.uid != "" do delete(s.uid)
		if s.date != "" do delete(s.date)
		if s.modality != "" do delete(s.modality)
		for ser in s.series {
			if ser.uid != "" do delete(ser.uid)
			if ser.description != "" do delete(ser.description)
			if ser.modality != "" do delete(ser.modality)
			delete(ser.frames)
		}
		delete(s.series)
	}
	for p in t.patients {
		if p.id != "" do delete(p.id)
		if p.name != "" do delete(p.name)
		delete(p.studies)
	}
	delete(t.entries)
	delete(t.studies)
	delete(t.patients)
	t^ = {}
}

// mark_cursor records that `entry` is now the frame on screen, so the
// series card can show "36/172" and its progress bar. Unknown indices are
// ignored (a stale row from a previous scan, for instance).
mark_cursor :: proc(t: ^Study_Tree, entry: u32) {
	if entry >= u32(len(t.entries)) do return
	e := t.entries[entry]
	if e.study >= u32(len(t.studies)) do return
	st := &t.studies[e.study]
	if e.series >= u32(len(st.series)) do return
	st.series[e.series].cursor = e.pos
}

// ---------------------------------------------------------------------------
// scanning

// Scan_Result is what a worker produces for one file. All strings are
// cloned to the persistent heap because the worker's temp arena dies.
@(private)
Scan_Result :: struct {
	path:     string,
	ok:       bool,
	study:    string,
	series:   string,
	study_date: string,
	modality: string,
	description: string,
	patient_id:   string,
	patient_name: string,
	series_number:   int,
	instance_number: int,
	rows: int,
	cols: int,
	bits: int,
}

// trim_value strips DICOM's space/NUL padding so grouping keys and labels
// compare and display cleanly ("CT\0" vs "CT").
@(private)
trim_value :: proc(s: string) -> string {
	return strings.trim(s, " \x00\t\r\n")
}

// text_utf8 returns a text element as UTF-8. `value_text` hands back the
// raw bytes, so a GB18030 patient name or series description would reach
// the UI as invalid UTF-8 (mojibake). The declared charset is honoured;
// undeclared high bytes get the common Chinese PACS treatment (GBK), and
// truly undecodable bytes are scrubbed rather than drawn as garbage.
text_utf8 :: proc(doc: ^d.Document, e: d.Element) -> string {
	raw := d.document_value(doc, e)
	if utf8.valid_string(string(raw)) do return trim_value(string(raw))

	buf := make([]u8, len(raw) * 2 + 8, context.temp_allocator)
	if n := d.text_to_utf8(doc, e, buf); n >= 0 do return trim_value(string(buf[:n]))
	// Undeclared high bytes are GBK in practice for Chinese PACS. Only
	// guess that when nothing else was declared; an unsupported declared
	// charset (ISO 2022 extended sets) must not be misread as GBK.
	charset := d.document_charset(doc)
	if charset == .Ascii || charset == .Gb18030 {
		if n, dok := d.gb18030_to_utf8(buf, raw); dok do return trim_value(string(buf[:n]))
	}

	out := make([]u8, len(raw), context.temp_allocator)
	n := 0
	for i := 0; i < len(raw); {
		size := 1
		b := raw[i]
		if b >= 0xF0 {
			size = 4
		} else if b >= 0xE0 {
			size = 3
		} else if b >= 0xC0 {
			size = 2
		}
		if i + size <= len(raw) && utf8.valid_string(string(raw[i:i + size])) {
			copy(out[n:], raw[i:i + size])
			n += size
			i += size
		} else {
			out[n] = '?'
			n += 1
			i += 1
		}
	}
	return trim_value(string(out[:n]))
}

@(private)
read_text :: proc(doc: ^d.Document, tag: d.Tag) -> string {
	if e, ok := d.document_find(doc, tag); ok do return text_utf8(doc, e)
	return ""
}

@(private)
scan_one_file :: proc(doc: ^d.Document, path: string) -> Scan_Result {
	r := Scan_Result{path = strings.clone(path)}
	if err := d.document_open_file_opts(doc, path, d.TAG_PIXEL_DATA); err != .None {
		return r
	}
	// The parse stops *before* PixelData, so look for the image geometry
	// that precedes it: SR / RT objects carry no Rows/Columns and have
	// nothing to show.
	if _, ok := d.document_find(doc, TAG_ROWS); !ok {
		return r
	}
	if _, ok := d.document_find(doc, TAG_COLUMNS); !ok {
		return r
	}
	read_str :: proc(doc: ^d.Document, tag: d.Tag) -> string {
		return read_text(doc, tag)
	}
	// Rows/Columns/BitsAllocated are binary US, which `value_is` (a text
	// parser for IS/DS) cannot read; pixel_attribute picks the right path.
	read_int :: proc(doc: ^d.Document, tag: d.Tag) -> int {
		if v, ok := d.pixel_attribute(doc, tag); ok do return v
		return 0
	}
	r.study = strings.clone(read_str(doc, TAG_STUDY_UID))
	r.series = strings.clone(read_str(doc, TAG_SERIES_UID))
	r.study_date = strings.clone(read_str(doc, TAG_STUDY_DATE))
	r.modality = strings.clone(read_str(doc, TAG_MODALITY))
	r.description = strings.clone(read_str(doc, TAG_SERIES_DESCRIPTION))
	r.patient_id = strings.clone(read_str(doc, TAG_PATIENT_ID))
	r.patient_name = strings.clone(read_str(doc, TAG_PATIENT_NAME))
	r.series_number = read_int(doc, TAG_SERIES_NUMBER)
	r.instance_number = read_int(doc, TAG_INSTANCE_NUMBER)
	r.rows = read_int(doc, TAG_ROWS)
	r.cols = read_int(doc, TAG_COLUMNS)
	r.bits = read_int(doc, TAG_BITS_ALLOCATED)
	r.ok = true
	return r
}

@(private)
Scan_Shard :: struct {
	paths:  []string,
	doc:    d.Document,
	out:    [dynamic]Scan_Result,
	allocator: runtime.Allocator,
}

@(private)
scan_shard_run :: proc(data: rawptr) {
	s := cast(^Scan_Shard) data
	// The shard's strings outlive the thread and are freed by the joiner:
	// allocate them with the caller's allocator, not the thread default.
	context.allocator = s.allocator
	d.document_init(&s.doc, s.allocator)
	defer d.document_destroy(&s.doc)
	for p in s.paths {
		res := scan_one_file(&s.doc, p)
		if res.ok {
			append(&s.out, res)
		} else if res.path != "" {
			delete(res.path)
		}
	}
	// Worker threads own their temp arena; release it before exiting.
	runtime.default_temp_allocator_destroy(
		cast(^runtime.Default_Temp_Allocator) context.temp_allocator.data)
}

// collect_candidates walks `root` recursively and returns every regular
// file path, sorted so parallel results do not depend on readdir order.
@(private)
collect_candidates :: proc(root: string, allocator: runtime.Allocator) -> []string {
	out: [dynamic]string
	walk :: proc(dir: string, out: ^[dynamic]string, allocator: runtime.Allocator) {
		files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil do return
		for fi in files {
			full, jerr := filepath.join({dir, fi.name}, allocator = context.temp_allocator)
			if jerr != nil do continue
			#partial switch fi.type {
			case .Directory:
				walk(full, out, allocator)
			case .Regular:
				// Every regular file is a candidate: datasets without a
				// meta header (or any suffix) are real, and `scan_one_file`
				// rejects anything that is not a DICOM image.
				append(out, strings.clone(full, allocator))
			}
		}
	}
	walk(root, &out, allocator)
	slice.sort(out[:])
	return out[:]
}

// accepts_extension filters obvious non-DICOM files. Extension-less files
// are included because many archives store instances by UID with no suffix.
@(private)
accepts_extension :: proc(name: string) -> bool {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	switch ext {
	case "", ".dcm", ".ima", ".dic", ".dicom":
		return true
	}
	return false
}

// scan_directory is the public entry point: synchronous, so it can be
// called from `cmd_thread` or any worker.
scan_directory :: proc(root: string, allocator := context.allocator) -> Study_Tree {
	tree: Study_Tree
	if !os.exists(root) do return tree

	// Everything below — worker clones, shard output, tree nodes, and the
	// frees on this side — must use the caller's allocator.
	own := context.allocator
	context.allocator = allocator
	defer context.allocator = own

	paths := collect_candidates(root, allocator)
	defer {
		for p in paths do delete(p)
		delete(paths)
	}
	if len(paths) == 0 do return tree

	// More workers than this stop paying for themselves: the scan is
	// mmap + a few hundred bytes of tag reads per file.
	worker_count := min(len(paths), 8)
	shards := make([]Scan_Shard, worker_count, context.temp_allocator)
	chunk := (len(paths) + worker_count - 1) / worker_count
	threads := make([dynamic]^thread.Thread, 0, worker_count, context.temp_allocator)

	for i in 0 ..< worker_count {
		lo := i * chunk
		if lo >= len(paths) do break
		hi := min(lo + chunk, len(paths))
		shards[i] = Scan_Shard{paths = paths[lo:hi], allocator = allocator}
		t := thread.create_and_start_with_data(&shards[i], scan_shard_run)
		if t == nil {
			// Fall back to running the shard inline rather than losing files.
			scan_shard_run(&shards[i])
		} else {
			append(&threads, t)
		}
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	// Merge, then group.
	results := make([dynamic]Scan_Result, 0, len(paths), context.temp_allocator)
	for i in 0 ..< worker_count {
		append(&results, ..shards[i].out[:])
		delete(shards[i].out)
	}
	build_tree(&tree, results[:])

	// Results own clones of their strings; the tree took what it needs.
	for r in results {
		delete(r.path)
		delete(r.study)
		delete(r.series)
		delete(r.study_date)
		delete(r.modality)
		delete(r.description)
		delete(r.patient_id)
		delete(r.patient_name)
	}
	return tree
}

@(private)
build_tree :: proc(tree: ^Study_Tree, results: []Scan_Result) {
	// Frames live outside Study_Node: a [dynamic] field copied by value
	// inside another dynamic array loses its backing store. Same rule for
	// patients: study indices live in Patient_Node.studies.
	patient_index: map[Patient_Key]u32
	study_index: map[Study_Key]u32
	series_index: map[Series_Scan_Key]u32
	defer delete(patient_index)
	defer delete(study_index)
	defer delete(series_index)

	patients: [dynamic]Patient_Node
	studies: [dynamic]Study_Node
	// frame_counts sizes each series' frame list; nesting dynamic arrays
	// would copy the inner header by value and lose its storage.
	frame_counts: [dynamic]int
	defer delete(frame_counts)

	entries: [dynamic]Study_Entry
	// series_cursor[si] is the running count of series seen per study, used
	// to place each new Series_Node into its study's list.
	series_cursor: [dynamic]int
	defer delete(series_cursor)
	// series_loc[gkey] is the series' (study, index-in-study) at creation
	// time: the placement the frame fill needs before the sort moves cards.
	series_loc: [dynamic][2]u32
	defer delete(series_loc)
	// study_patient keeps the patient key per study so the patient index can
	// be remapped after the patient list is sorted.
	study_patient: [dynamic]Patient_Key
	defer delete(study_patient)

	for r in results {
		pkey := Patient_Key{trim_value(r.patient_id), trim_value(r.patient_name)}
		pi, pseen := patient_index[pkey]
		if !pseen {
			pi = u32(len(patients))
			patient_index[pkey] = pi
			append(&patients, Patient_Node{
				id = strings.clone(pkey.id),
				name = strings.clone(pkey.name),
			})
		}

		// A present StudyInstanceUID always identifies one study, whatever
		// the patient spelling says. A missing one groups per patient
		// instead of dropping the file.
		skey := Study_Key{uid = trim_value(r.study)}
		if skey.uid == "" do skey.patient = pkey

		si, sseen := study_index[skey]
		if !sseen {
			si = u32(len(studies))
			study_index[skey] = si
			append(&studies, Study_Node{
				uid = strings.clone(skey.uid),
				date = strings.clone(r.study_date),
				modality = strings.clone(r.modality),
				patient = pi,
			})
			append(&series_cursor, 0)
			append(&study_patient, pkey)
		}
		studies[si].count += 1

		// Series identity is (study, SeriesInstanceUID): an empty UID, or
		// one reused by another study, must not merge two cards.
		kkey := Series_Scan_Key{study = skey, series = trim_value(r.series)}
		gkey, gseen := series_index[kkey]
		if !gseen {
			gkey = u32(len(frame_counts))
			series_index[kkey] = gkey
			append(&frame_counts, 0)

			// Grow this study's series slice and place the new node.
			n := series_cursor[si]
			grown := make([]Series_Node, n + 1)
			if studies[si].series != nil {
				copy(grown, studies[si].series)
				delete(studies[si].series)
			}
			studies[si].series = grown
			studies[si].series[n] = Series_Node{
				uid = strings.clone(kkey.series),
				description = strings.clone(trim_value(r.description)),
				modality = strings.clone(r.modality),
				number = r.series_number,
				rows = r.rows,
				cols = r.cols,
				bits = r.bits,
			}
			series_cursor[si] = n + 1
			append(&series_loc, {si, u32(n)})
		}

		ei := u32(len(entries))
		append(&entries, Study_Entry{
			path = strings.clone(r.path),
			study = si,
			series = gkey,
			instance = r.instance_number,
		})
		frame_counts[gkey] += 1
	}

	// Attach frames and sort. The global key is remapped to the series'
	// position inside its study once sorting moves things around, so do
	// the frame assignment first.
	// Allocate each series' frame list at its final size, then walk the
	// entries once and place each index into its owner's list.
	fill_at := make([]int, len(frame_counts))
	defer delete(fill_at)
	for gkey in 0 ..< len(series_loc) {
		loc := series_loc[gkey]
		studies[loc[0]].series[loc[1]].frames = make([]u32, frame_counts[gkey])
	}
	for ei in 0 ..< len(entries) {
		k := entries[ei].series
		if k >= u32(len(series_loc)) do continue
		loc := series_loc[k]
		ser := &studies[loc[0]].series[loc[1]]
		i := fill_at[k]
		if i < len(ser.frames) do ser.frames[i] = u32(ei)
		fill_at[k] += 1
	}

	// Frames within a series: InstanceNumber, ties broken by entry index.
	// Odin proc literals capture nothing, so this is an explicit insertion
	// sort over the small per-series lists rather than a comparator that
	// would have to read `entries`.
	for si in 0 ..< len(studies) {
		for &ser in studies[si].series {
			f := ser.frames
			for i in 1 ..< len(f) {
				key := f[i]
				ki := entries[key].instance
				j := i - 1
				for j >= 0 {
					ej := entries[f[j]].instance
					if ej < ki || (ej == ki && f[j] < key) do break
					f[j + 1] = f[j]
					j -= 1
				}
				f[j + 1] = key
			}
		}
	}
	for si in 0 ..< len(studies) {
		slice.sort_by(studies[si].series, proc(a, b: Series_Node) -> bool {
			if a.number != b.number do return a.number < b.number
			return a.uid < b.uid
		})
	}
	slice.sort_by(studies[:], proc(a, b: Study_Node) -> bool {
		if a.date != b.date do return a.date > b.date
		return a.uid < b.uid
	})

	// Patient layer: sort the cards (name, unknown last), remap each
	// study's patient index, then attach the studies in their final order.
	slice.sort_by(patients[:], proc(a, b: Patient_Node) -> bool {
		if a.name != b.name {
			if a.name == "" do return false
			if b.name == "" do return true
			return a.name < b.name
		}
		return a.id < b.id
	})
	new_patient_index: map[Patient_Key]u32
	defer delete(new_patient_index)
	for p, i in patients do new_patient_index[Patient_Key{p.id, p.name}] = u32(i)
	for si in 0 ..< len(studies) {
		if pi, ok := new_patient_index[study_patient[si]]; ok do studies[si].patient = pi
	}
	counts := make([]int, len(patients))
	defer delete(counts)
	cursor := make([]int, len(patients))
	defer delete(cursor)
	for st in studies do counts[st.patient] += 1
	for i in 0 ..< len(patients) {
		patients[i].studies = make([]u32, counts[i])
	}
	for si in 0 ..< len(studies) {
		pi := studies[si].patient
		patients[pi].studies[cursor[pi]] = u32(si)
		cursor[pi] += 1
	}

	// Final entry indices: after the series and study sorts, remap each
	// entry to its (study, series, pos) so the sidebar cursor and paging
	// never touch a stale global key.
	for si in 0 ..< len(studies) {
		for ni in 0 ..< len(studies[si].series) {
			for ei, pos in studies[si].series[ni].frames {
				entries[ei].study = u32(si)
				entries[ei].series = u32(ni)
				entries[ei].pos = pos
			}
		}
	}

	tree.entries = entries[:]
	tree.studies = studies[:]
	tree.patients = patients[:]
}
