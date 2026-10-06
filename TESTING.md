# Testing

How roux is tested, beyond the rule every Eldhus repository follows (the
tigerstyle skill: no test may fail by timing or chance). Here the clock
and randomness come into an app through its `Context` or a parameter, so
a test fixes them. The server under the
platform is tested in fourneau (its simulator and fuzzing; fourneau's
TESTING.md) and against Go and axum in fourneau-dragrace.

## The flywheel

| command | what | budget |
|---|---|---|
| `zig build test` | tidy over the host and `sqlite/`, with fourneau's rules; SQLite's build checked (its options, with SQLite's own assertions and C undefined-behaviour traps on) | a second (cached; the first build compiles SQLite, ~15 s) |
| `zig build platform` | the host as `libhost.a` (`-Dhost-heap=checked` for the checked heap) | seconds |
| `roc test` in an example | the app's `expect`s | seconds |
| `zig build spec` (M4, not yet) | every example over a real listener, requests against expected responses | a minute |

## Layers

1. **The platform's Roc modules** carry `expect`s for refused and missing
   inputs, not only the happy path.
2. **Each feature is an example** in `examples/` with a case in the spec:
   the requests and the responses expected, run over a real listener.
3. **Apps** carry their own `roc test` expects.

## Memory safety

| bug | defence | where it is checked |
|---|---|---|
| out of bounds | Zig's bounds checks: the host ships ReleaseSafe | examples, production |
| use after free, Roc heap | `-Dhost-heap=checked`: `std.heap.SafeAllocator` never reuses an address, so a stale pointer faults or panics; it checks double frees, foreign frees and writes after free, with stack traces | Roc apps under load, checked heap |
| leaks, Roc | the host counts Roc allocations per shard and asserts the count is back to its start whenever a shard is idle; on in every build (experiment 13) | every request, production included |
| data races | shared nothing: a shard is one thread; what crosses shards is the Roc context (atomic reference counts) and the heap (thread-safe). ThreadSanitizer runs on fourneau-hello, not yet the host: it links musl, which TSan's runtime does not support | fourneau's load runs |

A Roc app under the checked heap: `zig build platform -Dhost-heap=checked`,
`roc build`, then load it (135k requests/s against 586k: it records a
stack trace per allocation).
