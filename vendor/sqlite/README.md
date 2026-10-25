# vendor/sqlite

SQLite's amalgamation, as sqlite.org publishes it: `sqlite3.c` and `sqlite3.h`, nothing else (no
shell, no extension header: roux loads no extensions). Public domain. The host and the tools compile
this one copy, so a query is typed by the SQLite that runs it.

| | |
|---|---|
| version | 3.54.1 (`SQLITE_SOURCE_ID` 2026-10-16 14:45:20 555e07ef…), plus our patches |
| from | https://sqlite.org/2026/sqlite-amalgamation-3540100.zip |
| zip SHA3-256 | `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` (as sqlite.org/download.html lists it) |
| `sqlite3.c` SHA-256, pristine | `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52` |
| `sqlite3.h` SHA-256, pristine | `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c` |

The compile-time options are in `sqlite/options.zig`, each with why; a test asserts each one is in
the build (`sqlite3_compileoption_used`).

## Our patches

Each a commit of its own on top of the pristine files, marked `roux:` in the source, so the next
version re-applies the list.

1. **`sqlite3_column_nullable(stmt, N)`** (2026-10-06): whether a result column can be NULL.
    - It returns 1, 0, or -1 for an expression SQLite cannot prove never NULL.
    - Column metadata gives a column's origin table and column, but that is not enough.
    - A NOT NULL column can still be NULL from the inner side of an outer join.
    - Or from a scalar subquery, or from an arm of a compound select.
    - The resolver knows the first (`EP_CanBeNull`).
    - The patch follows `columnTypeImpl`'s path through subqueries and views to decide the rest.
    - Stored as a sixth column-name slot (`COLNAME_NULLABLE`, under `SQLITE_ENABLE_COLUMN_METADATA`).
    - roux-db types result columns by it.
    - `tools/roux-db/tests.zig` checks it on a matrix of shapes against the rows they return.

## Updating

When sqlite.org/changes.html shows a new release, download the amalgamation zip, check its
SHA3-256 against download.html (`openssl dgst -sha3-256`), copy the two files over these, update
this table, commit; then re-apply our patches as commits, and run `zig build test` and the floors
(`zig build sqlite-floor`).
