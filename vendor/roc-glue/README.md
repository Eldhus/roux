# roc's Zig glue spec

`ZigGlue.roc`, verbatim from roc-lang/roc at the commit of the pinned
nightly (`.roc-version`): `src/glue/src/ZigGlue.roc` at `130536d`
(nightly-2026-10-04-130536d), fetched from
`https://raw.githubusercontent.com/roc-lang/roc/130536d/src/glue/src/ZigGlue.roc`
on 2026-10-07.

sha256 `ff18757f6f1f360903bf581720fd1f7348a68d89719ed2a6633df33e3e323733`

Used twice: `roc glue` with it generates the host's
`host/roc_platform_abi.zig` (TODO, the Roc glue chore), and the `roux`
tool embeds it to lay out each app's template contracts (DESIGN.md,
Templates). Never edited. With each nightly: fetch it again at the new
commit, update the commit and sha256 here.

License: roc's, the Universal Permissive License (roc-lang/roc).
