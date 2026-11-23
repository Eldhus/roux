# roc's Zig glue spec

`ZigGlue.roc`, verbatim from roc-lang/roc at the commit of the pinned Roc (`.roc-version`):
`src/glue/src/ZigGlue.roc` at `15177e9` (0.1.0_RC1), from
`https://raw.githubusercontent.com/roc-lang/roc/15177e91f62cafddf5336c455e00e9f05427ac16/src/glue/src/ZigGlue.roc`
on 2026-11-23.

sha256 `1863ef8ed10f4222f8ca4147fe8548c69cdb6618e380f7029df235704c1ca33b`

`roc glue` with it generates the host's `host/roc_platform_abi.zig` (`--no-cache` was needed
until roc-lang/roc#12139 was fixed). The template contracts are laid out by roux's own spec,
`tools/rocstache/Layout.roc`. Never edited. With each Roc bump: fetch it again at the new commit,
update the commit and sha256 here.

License: roc's, the Universal Permissive License (roc-lang/roc).
