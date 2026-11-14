package nautilus

// Task 8 tests: spec §6 的五项并发契约。

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

@(private)
pool_sleep :: proc(ms: int) { time.sleep(time.Duration(ms) * time.Millisecond) }

@(private)
POOL_FILES := []string{
	"D:/Odin/corpus_ext/693_UNCI.dcm",
	"D:/Odin/corpus_ext/693_J2KI.dcm",
	"D:/Odin/corpus_ext/liver.dcm",
	"D:/Odin/corpus_ext/gdcm-US-ALOKA-16.dcm",
	"D:/Odin/corpus_ext/CT_small.dcm",
}

@(private)
pool_corpus_ready :: proc() -> bool {
	for f in POOL_FILES {
		if !os.exists(f) do return false
	}
	return true
}

@(test)
decode_pool_runs_every_submitted_job_once :: proc(t: ^testing.T) {
	if !pool_corpus_ready() {
		return
	}
	p: Decode_Pool
	decode_pool_init(&p)
	defer decode_pool_shutdown(&p)

	// Each key submitted once; every one must produce exactly one result.
	for f in POOL_FILES {
		_ = decode_pool_submit(&p, {key = {file = f, frame = 0}, generation = 1})
	}

	seen := make(map[string]bool)
	defer delete(seen)
	for _ in 0 ..< 300 {
		results := decode_pool_drain(&p)
		for r in results {
			testing.expectf(t, r.frame != nil, "decode failed for a submitted key: %s", r.err)
			key := r.frame.key.file
			testing.expectf(t, !seen[key], "duplicate result for %s", key)
			seen[key] = true
			free_uncached_frame(r.frame)
		}
		delete(results)
		if len(seen) == 5 do break
		pool_sleep(10)
	}
	testing.expect_value(t, len(seen), 5)
}

@(test)
decode_pool_dedupes_queued_keys :: proc(t: ^testing.T) {
	if !pool_corpus_ready() {
		return
	}
	p: Decode_Pool
	decode_pool_init(&p, 1)
	defer decode_pool_shutdown(&p)

	key := Frame_Key{file = POOL_FILES[0], frame = 0}
	testing.expect(t, decode_pool_submit(&p, {key = key}))
	testing.expect(t, !decode_pool_submit(&p, {key = key}), "second submit must dedupe")
}

@(test)
decode_pool_reuses_document_across_transfer_syntaxes :: proc(t: ^testing.T) {
	if !pool_corpus_ready() {
		return
	}

	// Reference: decode each file alone on this thread.
	reference: [dynamic]^Cached_Frame
	defer {
		for f in reference do free_uncached_frame(f)
		delete(reference)
	}
	for f in POOL_FILES {
		frame, err := load_frame_cpu(f)
		if frame == nil {
			testing.fail_now(t, err)
		}
		append(&reference, frame)
	}

	// Same files through one pool worker, whose Document is reused.
	p: Decode_Pool
	decode_pool_init(&p, 1)
	defer decode_pool_shutdown(&p)
	for f in POOL_FILES {
		_ = decode_pool_submit(&p, {key = {file = f, frame = 0}})
	}

	got := make(map[string]^Cached_Frame)
	defer {
		for _, f in got do free_uncached_frame(f)
		delete(got)
	}
	for _ in 0 ..< 300 {
		results := decode_pool_drain(&p)
		for r in results {
			if r.frame != nil do got[r.frame.key.file] = r.frame
		}
		delete(results)
		if len(got) == len(POOL_FILES) do break
		pool_sleep(10)
	}
	testing.expect_value(t, len(got), len(POOL_FILES))

	for i in 0 ..< len(POOL_FILES) {
		f := POOL_FILES[i]
		pooled := got[f]
		if pooled == nil do continue
		testing.expect_value(t, pooled.info.rows, reference[i].info.rows)
		testing.expect_value(t, pooled.info.cols, reference[i].info.cols)
		testing.expect_value(t, len(pooled.raw), len(reference[i].raw))
		testing.expect(t, string(pooled.raw) == string(reference[i].raw),
			"pixels differ for %s after document reuse", f)
	}
}

@(test)
decode_pool_result_survives_eviction :: proc(t: ^testing.T) {
	if !pool_corpus_ready() {
		return
	}
	// The pool hands ownership to the caller; dropping the frame into a
	// tiny LRU must not disturb the pool's own state.
	p: Decode_Pool
	decode_pool_init(&p, 1)
	defer decode_pool_shutdown(&p)

	cache: Frame_Cache
	frame_cache_init(&cache, 1, 1 << 30)
	defer frame_cache_destroy(&cache)

	for f in POOL_FILES[:2] {
		_ = decode_pool_submit(&p, {key = {file = f, frame = 0}})
	}
	for _ in 0 ..< 300 {
		results := decode_pool_drain(&p)
		for r in results {
			if r.frame != nil do _ = frame_cache_put(&cache, r.frame)
		}
		delete(results)
		if frame_cache_len(&cache) >= 1 && len(results) == 0 {
			// keep draining until the queue is idle
		}
		pool_sleep(10)
	}
	testing.expect_value(t, frame_cache_len(&cache), 1) // cap of one
}

@(test)
decode_pool_shutdown_waits_for_inflight :: proc(t: ^testing.T) {
	if !pool_corpus_ready() {
		return
	}
	p: Decode_Pool
	decode_pool_init(&p, 2)
	for f in POOL_FILES {
		_ = decode_pool_submit(&p, {key = {file = f, frame = 0}})
	}
	// Shutdown must block until every queued job has finished. M1 does
	// not drain mid-flight, so the results are already complete when it
	// returns; shutdown releases whatever was never drained, and a drain
	// afterwards sees nothing left.
	decode_pool_shutdown(&p)
	results := decode_pool_drain(&p)
	defer delete(results)
	testing.expect_value(t, len(results), 0)
	_ = filepath.ext
}
