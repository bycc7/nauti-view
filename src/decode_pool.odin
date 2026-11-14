package nautilus

// Task 8: 常驻解码池。按 spec §4.2.1，池里有 K = min(4, 核数-1) 个长期
// 存活 worker，每个独占一个可复用 `dicom.Document`；任务按「当帧 > 预取」
// 优先级排队，同 Frame_Key 只执行一次。
//
// 结果不回投 SDL 事件（那需要 Skald 的窗口 id），而是进 `completed`
// 队列；主线程每帧 drain 一次，这与 §4.2.1 的 SDL_PushEvent 语义等价，
// 且让池在 headless 测试里可用。

import "core:runtime"
import "core:strings"
import "core:time"
import "core:sync"
import "core:thread"
import d "../vendor/dicom"

Decode_Priority :: enum u8 {
	Current, // the frame the user is looking at
	Prefetch, // neighbours
}

Decode_Request :: struct {
	key:      Frame_Key,
	priority: Decode_Priority,
	// generation lets a caller discard results from a superseded request
	// batch (e.g. the user jumped to another series).
	generation: u64,
}

@(private)
thread_sleep_ms :: proc(ms: i64) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}

@(private)
Decode_Job :: struct {
	req:      Decode_Request,
	// The worker decodes frame 0 of the file named by key.file only when
	// key.frame is 0; other frames reuse the parsed document.
	next:     ^Decode_Job,
}

Decode_Pool :: struct {
	lock:      sync.Mutex,
	queue:     ^Decode_Job, // singly linked, priority-ordered insert
	queued:    map[Frame_Key]bool, // dedupe by key
	completed: [dynamic]Load_Result,

	workers:   []^thread.Thread,
	// heap is a mutex-guarded process allocator: results cross threads, so
	// their memory must not live in any one worker's arena.
	heap_lock: sync.Mutex,
	heap:      runtime.Allocator,
	arenas:      [DECODE_POOL_MAX_WORKERS]runtime.Arena,
	temp_arenas: [DECODE_POOL_MAX_WORKERS]runtime.Arena,
	next_arena:      int,
	next_temp_arena: int,
	shutdown:  bool,
	in_flight: int,
	generation: u64,

	// Completed results awaiting a drain, protected by `done_lock`.
	// Fixed ring: the heap allocator is not thread-safe, so workers must
	// never allocate. Sized so a full queue can never overflow it.
	done_lock: sync.Mutex,
	done:      [DECODE_POOL_DONE_CAPACITY]Load_Result,
	done_head: int,
	done_len:  int,
}

DECODE_POOL_MAX_WORKERS :: 4
DECODE_POOL_DONE_CAPACITY :: 1024


decode_pool_init :: proc(p: ^Decode_Pool, max_workers := DECODE_POOL_MAX_WORKERS) {
	p.queued = make(map[Frame_Key]bool)
	p.heap = locking_allocator(&p.heap_lock, context.allocator)
	p.workers = make([]^thread.Thread, max_workers)
	worker_count := max(1, max_workers)
	started := 0
	for _ in 0 ..< worker_count {
		// Fresh context: inheriting the caller's would share its temp
		// arena, and workers allocating into it corrupt the main thread.
		// self_cleanup: the worker frees its own thread record on exit, so
		// the main thread only joins (never destroys) it.
		t := thread.create_and_start_with_data(p, decode_worker_run,
			init_context = runtime.default_context(), self_cleanup = true)
		if t == nil do continue
		p.workers[started] = t
		started += 1
	}
	if started < len(p.workers) do p.workers = p.workers[:started]
}

@(private)
decode_worker_run :: proc(data: rawptr) {
	p := cast(^Decode_Pool) data

	// Every allocation this worker makes - decode buffers, doc pools,
	// result strings - comes from a private arena. The global default
	// allocator and the shared temp arena are both single-threaded, and
	// sharing them across workers is exactly what crashes under load.
	// The arenas outlive the worker: results it hands back (frame bytes
	// and error strings) point into them, and the main thread reads those
	// after the worker has exited. Decode_Pool owns and frees them.
	idx := sync.atomic_add(&p.next_arena, 1)
	arena := &p.arenas[idx]
	context.allocator = runtime.arena_allocator(arena)
	context.temp_allocator = runtime.arena_allocator(&p.temp_arenas[idx])

	doc: d.Document
	d.document_init(&doc)
	defer d.document_destroy(&doc)

	for {
		sync.lock(&p.lock)
		for p.queue == nil && !p.shutdown {
			sync.unlock(&p.lock)
			thread_sleep_ms(1)
			sync.lock(&p.lock)
		}
		if p.shutdown && p.queue == nil {
			p.in_flight -= 1
			sync.unlock(&p.lock)
			break
		}
		job := p.queue
		p.queue = job.next
		job.next = nil
		delete_key(&p.queued, job.req.key)
		p.in_flight += 1
		sync.unlock(&p.lock)

		// `load_frame_cpu` allocates into whichever allocator is active,
		// and the result's ownership crosses to the caller, which frees it
		// with the process heap. Hand back a frame owned by that heap, and
		// keep the arena for the worker's scratch only.
		frame, err := load_frame_cpu(job.req.key.file)
		if frame != nil {
			owned := new(Cached_Frame, p.heap)
			owned^ = frame^
			owned.key.file = strings.clone(frame.key.file, p.heap)
			owned.raw = make([]u8, len(frame.raw), p.heap)
			copy(owned.raw, frame.raw)
			if frame.palette.valid {
				owned.palette.red = make([]u8, len(frame.palette.red), p.heap)
				copy(owned.palette.red, frame.palette.red)
				owned.palette.green = make([]u8, len(frame.palette.green), p.heap)
				copy(owned.palette.green, frame.palette.green)
				owned.palette.blue = make([]u8, len(frame.palette.blue), p.heap)
				copy(owned.palette.blue, frame.palette.blue)
			}
			frame = owned
		}
		res := Load_Result{gen = job.req.generation, frame = frame, err = err}
		sync.lock(&p.done_lock)
		slot := (p.done_head + p.done_len) % DECODE_POOL_DONE_CAPACITY
		p.done[slot] = res
		p.done_len += 1
		sync.unlock(&p.done_lock)

		sync.lock(&p.lock)
		p.in_flight -= 1
		sync.unlock(&p.lock)

		free(job)
	}
}

// decode_pool_submit queues a request unless the same key is already
// queued. Returns false when the key was already pending.
decode_pool_submit :: proc(p: ^Decode_Pool, req: Decode_Request) -> bool {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	if p.queued[req.key] do return false
	p.queued[req.key] = true

	job := new(Decode_Job)
	job.req = req

	// Priority insert: Current requests go ahead of Prefetch ones, but
	// never ahead of another Current.
	if req.priority == .Prefetch {
		// append at tail
		if p.queue == nil {
			p.queue = job
		} else {
			tail := p.queue
			for tail.next != nil do tail = tail.next
			tail.next = job
		}
	} else {
		// insert before the first Prefetch, or at the tail if none
		prev: ^Decode_Job
		cur := p.queue
		for cur != nil && cur.req.priority == .Current {
			prev = cur
			cur = cur.next
		}
		job.next = cur
		if prev == nil {
			p.queue = job
		} else {
			prev.next = job
		}
	}
	return true
}

// decode_pool_drain moves finished results to the caller. The caller
// becomes the owner of each Load_Result's frame.
decode_pool_drain :: proc(p: ^Decode_Pool, allocator := context.allocator) -> []Load_Result {
	sync.lock(&p.done_lock)
	n := p.done_len
	out := make([]Load_Result, n, allocator)
	for i in 0 ..< n {
		out[i] = p.done[(p.done_head + i) % DECODE_POOL_DONE_CAPACITY]
	}
	p.done_head = (p.done_head + n) % DECODE_POOL_DONE_CAPACITY
	p.done_len = 0
	sync.unlock(&p.done_lock)
	return out
}

// decode_pool_shutdown waits for queued and in-flight work, then joins.
decode_pool_shutdown :: proc(p: ^Decode_Pool) {
	sync.lock(&p.lock)
	p.shutdown = true
	sync.unlock(&p.lock)

	for t in p.workers {
		if t != nil do thread.join(t)
	}
	for i in 0 ..< len(p.workers) {
		runtime.arena_destroy(&p.temp_arenas[i])
		runtime.arena_destroy(&p.arenas[i])
	}
	delete(p.workers)
	p.workers = nil

	// Anything still queued never ran; free it.
	for cur := p.queue; cur != nil; {
		next := cur.next
		free(cur)
		cur = next
	}
	p.queue = nil
	delete(p.queued)
	for i in 0 ..< p.done_len {
		r := p.done[(p.done_head + i) % DECODE_POOL_DONE_CAPACITY]
		if r.frame != nil do free_uncached_frame(r.frame)
	}
	p.done_len = 0
}

// locking_allocator wraps `base` so concurrent calls from any number of
// threads serialize. Odin's default heap allocator is not thread-safe;
// this is the smallest correct shared allocator for cross-thread results.
@(private)
Locking_Allocator :: struct {
	lock: sync.Mutex,
	base: runtime.Allocator,
}

@(private)
locking_alloc_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	l := cast(^Locking_Allocator) data
	sync.lock(&l.lock)
	defer sync.unlock(&l.lock)
	return l.base.procedure(l.base.data, mode, size, alignment, old_memory, old_size, loc)
}

locking_allocator :: proc(lock: ^sync.Mutex, base: runtime.Allocator) -> runtime.Allocator {
	la := new(Locking_Allocator)
	la.lock = lock^
	la.base = base
	return runtime.Allocator{
		procedure = locking_alloc_proc,
		data      = la,
	}
}

// decode_pool_pending reports how many finished results are waiting.
// The main loop polls this each frame to decide whether to wake
// `update`: a worker completing does not itself produce a Msg.
decode_pool_pending :: proc(p: ^Decode_Pool) -> int {
	sync.lock(&p.done_lock)
	n := p.done_len
	sync.unlock(&p.done_lock)
	return n
}
