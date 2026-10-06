# vendor/sqlite

SQLite's amalgamation, as sqlite.org publishes it: `sqlite3.c` and
`sqlite3.h`, nothing else (no shell, no extension header: roux loads no
extensions). Public domain. The host and the tools compile this one copy,
so a query is typed by the SQLite that runs it.

| | |
|---|---|
| version | 3.53.4 (`SQLITE_SOURCE_ID` 2026-07-24 19:02:57 bf7c7f30…) |
| from | https://sqlite.org/2026/sqlite-amalgamation-3530400.zip |
| zip SHA3-256 | `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e` (as sqlite.org/download.html lists it) |
| `sqlite3.c` SHA-256 | `b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189` |
| `sqlite3.h` SHA-256 | `919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d` |

The compile-time options are in `sqlite/options.zig`, each with why; a
test asserts each one is in the build (`sqlite3_compileoption_used`).

## Our patches

None yet. A patch is a commit of its own on top of the pristine files,
listed here with why, so the next version re-applies the list.

## Updating

The Vendored sources chore (TODO.md): when sqlite.org/changes.html shows
a new release, download the amalgamation zip, check its SHA3-256 against
download.html (`openssl dgst -sha3-256`), copy the two files over these,
update this table, commit; then re-apply our patches as commits, run
`zig build test` and the floors (`zig build sqlite-floor`), and note the
numbers in DIARY.md.
