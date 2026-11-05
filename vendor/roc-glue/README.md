# roc's Zig glue spec

`ZigGlue.roc`, verbatim from roc-lang/roc at the commit of the pinned nightly (`.roc-version`):
`src/glue/src/ZigGlue.roc` at `2622062` (nightly-2026-11-04-2622062), from
`https://raw.githubusercontent.com/roc-lang/roc/262206271cf05db948eef2b96fae88a1aca07b19/src/glue/src/ZigGlue.roc`
on 2026-11-05 (unchanged since `130536d`).

sha256 `ff18757f6f1f360903bf581720fd1f7348a68d89719ed2a6633df33e3e323733`

`roc glue --no-cache` with it generates the host's `host/roc_platform_abi.zig` (`--no-cache`:
roc-lang/roc#12139). The template contracts are laid out by roux's own spec,
`tools/rocstache/Layout.roc`. Never edited. With each nightly: fetch it again at the new commit,
update the commit and sha256 here.

License: roc's, the Universal Permissive License (roc-lang/roc).
