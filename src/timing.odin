package nautilus

import "core:time"

Stopwatch :: struct { start: time.Tick }

init_stopwatch :: proc() -> Stopwatch { return {start = time.tick_now()} }

elapsed_ms :: proc(sw: ^Stopwatch) -> f64 {
	return f64(time.duration_milliseconds(time.tick_since(sw.start)))
}
