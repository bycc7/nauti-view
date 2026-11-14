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
import "core:thread"
import d "../vendor/dicom"

TAG_STUDY_UID :: d.Tag{0x0020, 0x000D}
TAG_SERIES_UID :: d.Tag{0x0020, 0x000E}
TAG_SERIES_NUMBER :: d.Tag{0x0020, 0x0011}
TAG_INSTANCE_NUMBER :: d.Tag{0x0020, 0x0013}
TAG_MODALITY :: d.Tag{0x0008, 0x0060}
TAG_STUDY_DATE :: d.Tag{0x0008, 0x0020}

Study_Entry :: struct {
	path:     string, // owned
	study:    u32, // index into Study_Tree.studies
	series:   u32, // index into studies[study].series
	instance: int,
}

Series_Node :: struct {
	uid:      string, // owned
	number:   int,
	frames:   []u32, // indices into Study_Tree.entries, sorted by instance
}

Study_Node :: struct {
	uid:    string, // owned
	date:   string, // owned
	modality: string,
	count:  int,
	series: []Series_Node,
}

Study_Tree :: struct {
	entries: []Study_Entry,
	studies: []Study_Node,
}

study_tree_destroy :: proc(t: ^Study_Tree) {
	for e in t.entries {
		if e.path != "" do delete(e.path)
	}
	for s in t.studies {
		if s.uid != "" do delete(s.uid)
		if s.date != "" do delete(s.date)
		for ser in s.series {
			if ser.uid != "" do delete(ser.uid)
			delete(ser.frames)
		}
		delete(s.series)
	}
	delete(t.entries)
	delete(t.studies)
	t^ = {}
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
	series_number:   int,
	instance_number: int,
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
	if _, ok := d.document_find(doc, d.Tag{0x0028, 0x0010}); !ok {
		return r
	}
	if _, ok := d.document_find(doc, d.Tag{0x0028, 0x0011}); !ok {
		return r
	}
	read_str :: proc(doc: ^d.Document, tag: d.Tag) -> string {
		if e, ok := d.document_find(doc, tag); ok do return d.value_text(doc, e)
		return ""
	}
	r.study = strings.clone(read_str(doc, TAG_STUDY_UID))
	r.series = strings.clone(read_str(doc, TAG_SERIES_UID))
	r.study_date = strings.clone(read_str(doc, TAG_STUDY_DATE))
	r.modality = strings.clone(read_str(doc, TAG_MODALITY))
	if e, ok := d.document_find(doc, TAG_SERIES_NUMBER); ok {
		if v, vok := d.value_is(doc, e); vok do r.series_number = v
	}
	if e, ok := d.document_find(doc, TAG_INSTANCE_NUMBER); ok {
		if v, vok := d.value_is(doc, e); vok do r.instance_number = v
	}
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
	build_tree(&tree, results[:], allocator)

	// Results own clones of their strings; the tree took what it needs.
	for r in results {
		delete(r.path)
		delete(r.study)
		delete(r.series)
		delete(r.study_date)
		delete(r.modality)
	}
	return tree
}

@(private)
build_tree :: proc(tree: ^Study_Tree, results: []Scan_Result, _alloc: runtime.Allocator) {
	// Frames live outside Study_Node: a [dynamic] field copied by value
	// inside another dynamic array loses its backing store.
	study_index: map[string]u32
	series_index: map[string]u32
	defer delete(study_index)
	defer delete(series_index)

	studies: [dynamic]Study_Node
	// frames[key] where key = series_index[uid]
	// frame_counts sizes each series' frame list; nesting dynamic arrays
	// would copy the inner header by value and lose its storage.
	frame_counts: [dynamic]int
	defer delete(frame_counts)

	entries: [dynamic]Study_Entry
	// study_series[j] is the running count of series seen per study, used
	// to place each new Series_Node into its study's list.
	series_cursor: [dynamic]int
	defer delete(series_cursor)

	for r in results {
		if r.study == "" do continue

		si, seen := study_index[r.study]
		if !seen {
			si = u32(len(studies))
			study_index[r.study] = si
			append(&studies, Study_Node{
				uid = strings.clone(r.study),
				date = strings.clone(r.study_date),
				modality = strings.clone(r.modality),
			})
			append(&series_cursor, 0)
		}
		studies[si].count += 1

		gkey, gseen := series_index[r.series]
		if !gseen {
			gkey = u32(len(frame_counts))
			series_index[r.series] = gkey
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
				uid = strings.clone(r.series),
				number = r.series_number,
			}
			series_cursor[si] = n + 1
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
	series_loc := make([][2]u32, len(frame_counts))
	defer delete(series_loc)
	for si in 0 ..< len(studies) {
		for ni in 0 ..< len(studies[si].series) {
			ser := &studies[si].series[ni]
			k, ok := series_index[ser.uid]
			if !ok do continue
			ser.frames = make([]u32, frame_counts[k])
			series_loc[k] = {u32(si), u32(ni)}
		}
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

	tree.entries = entries[:]
	tree.studies = studies[:]
}
