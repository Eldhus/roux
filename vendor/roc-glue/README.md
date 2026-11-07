# roc's Zig glue spec

`ZigGlue.roc`, verbatim from roc-lang/roc at the commit of the pinned nightly (`.roc-version`):
`src/glue/src/ZigGlue.roc` at `ad3a5d2` (nightly-2026-11-07-ad3a5d2), from
`https://raw.githubusercontent.com/roc-lang/roc/ad3a5d2830b94fdac878ce1aaa73c64e7c57720f/src/glue/src/ZigGlue.roc`
on 2026-11-07 (unchanged since `130536d`).

sha256 `ff18757f6f1f360903bf581720fd1f7348a68d89719ed2a6633df33e3e323733`

`roc glue` with it generates the host's `host/roc_platform_abi.zig` (`--no-cache` was needed
until roc-lang/roc#12139 was fixed). The template contracts are laid out by roux's own spec,
`tools/rocstache/Layout.roc`. Never edited. With each nightly: fetch it again at the new commit,
update the commit and sha256 here.

License: roc's, the Universal Permissive License (roc-lang/roc).
