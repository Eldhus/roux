# roc's Zig glue spec

`ZigGlue.roc`, verbatim from roc-lang/roc at the commit of the pinned
nightly (`.roc-version`): `src/glue/src/ZigGlue.roc` at `c34079d`
(nightly-2026-10-06-c34079d), from the source archive at
`https://github.com/roc-lang/roc/archive/c34079d4cde82f475df7c1994c714ba25b29b951.tar.gz`
on 2026-10-08 (unchanged since `130536d`).

sha256 `ff18757f6f1f360903bf581720fd1f7348a68d89719ed2a6633df33e3e323733`

`roc glue --no-cache` with it generates the host's
`host/roc_platform_abi.zig` (TODO, the Roc glue chore; `--no-cache`:
roc-lang/roc#12139). The template contracts are laid out by roux's own
spec, `tools/rocstache/Layout.roc`. Never edited. With each nightly:
fetch it again at the new commit, update the commit and sha256 here.

License: roc's, the Universal Permissive License (roc-lang/roc).
