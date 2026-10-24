# roc's Zig glue spec

`ZigGlue.roc`, verbatim from roc-lang/roc at the commit of the pinned nightly (`.roc-version`):
`src/glue/src/ZigGlue.roc` at `f6c6cfb` (nightly-2026-10-24-f6c6cfb), from
`https://raw.githubusercontent.com/roc-lang/roc/f6c6cfb3d22265fced1ddf473a18dfadf3f1c706/src/glue/src/ZigGlue.roc`
on 2026-10-24 (unchanged since `130536d`).

sha256 `ff18757f6f1f360903bf581720fd1f7348a68d89719ed2a6633df33e3e323733`

`roc glue --no-cache` with it generates the host's `host/roc_platform_abi.zig` (`--no-cache`:
roc-lang/roc#12139). The template contracts are laid out by roux's own spec,
`tools/rocstache/Layout.roc`. Never edited. With each nightly: fetch it again at the new commit,
update the commit and sha256 here.

License: roc's, the Universal Permissive License (roc-lang/roc).
