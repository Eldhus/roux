# Queries

How a roux app reads and writes its database: SQL in files, typed by SQLite as the app builds,
called from Roc as ordinary functions.


## SQL in files, Roc out

An app's database is SQL in `db/`. `roux-db` checks it and compiles it into the app as it builds:
`roux build` and `roux dev` run it whenever the app has a `db/schema.sql`.

| file | written by | says |
|---|---|---|
| `schema.sql` | you | the tables, every one `STRICT` |
| `ledger.sql` | you | what was changed by hand ([migrations.md](migrations.md)) |
| `Dishes.sql`, … | you | queries, each named |
| `Dishes.roc`, … | roux-db | a typed function for each query, and a record type for its rows |
| `Database.roc` | roux-db | the schema and every statement, for `Sqlite.open!` |

Commit the generated `.roc` files beside the SQL: a diff of `Dishes.roc` shows what an edit to a
query did to its type.

```sql
-- db/Dishes.sql
-- name: by_id :one
-- @param id : I64
SELECT id, name, price_kr, note FROM dish WHERE id = :id;
```

```roc
## A row of `by_id`.
ById : { id : I64, name : Str, price_kr : I64, note : Sqlite.Nullable(Str) }

## `by_id`, Dishes.sql:1: one row, or `NotFound`.
by_id! : Sqlite.Read, { id : I64 } => Try(ById, [NotFound, DbErr(Sqlite.Err)])
```

No SQL is read at run time. Every statement is prepared once, when the app starts, and a call
names it by its number: there is no SQL string in Roc to build, and nothing to inject into.


## Where the types come from

From SQLite, never from reading the SQL. roux-db makes the schema in a database in memory and
prepares every query against it, and asks SQLite:

- **a result column's type**: its table's declaration. Tables are `STRICT`, so a column holds
  what it declares.
- **whether it can be NULL**: its table's `NOT NULL`, and the query around it. A column from the
  far side of a `LEFT JOIN` is nullable though its table says `NOT NULL`, and so is a scalar
  subquery's.
- **whether the query writes**: a query that writes takes `Sqlite.Write`, one that only reads
  takes `Sqlite.Read`.

| declared | Roc |
|---|---|
| `INTEGER`, `INT` | `I64` |
| `REAL` | `F64` |
| `TEXT` | `Str` |
| `BLOB` | `List(U8)` |
| `INTEGER`, annotated `Bool` | `Bool`: 0 or 1 |
| any of these, nullable | `Sqlite.Nullable(a)`: `Null` or `NotNull(a)` |

```sql
-- name: with_stars :many(200)
-- @column average : Nullable(F64)
SELECT d.name, avg(r.stars) AS average, r.stars AS some_stars
FROM dish d LEFT JOIN review r ON r.dish_id = d.id
GROUP BY d.id ORDER BY d.name;
```

```roc
WithStars : { name : Str, average : Sqlite.Nullable(F64), some_stars : Sqlite.Nullable(I64) }
```

`some_stars` is `Nullable` with no annotation: SQLite says the join can leave it empty.


## Annotations

What SQLite cannot say, a comment above the query says. One a line:

| annotation | what |
|---|---|
| `-- name: by_id :one` | the function's name, and how many rows: `:one`, `:many(N)` or `:exec` |
| `-- @param id : I64` | a parameter's type; every `:id` in the query needs one |
| `-- @column n : I64` | a result column's type, where it is an expression: `count(*)`, `coalesce(…)` |

Any other comment is prose, for people. A comment that starts with `@` and is not one of these
is refused, so a misspelt annotation never passes for prose.

| kind | returns |
|---|---|
| `:one` | the row, or `NotFound`: a 404 if the handler passes it on |
| `:many(N)` | a list of at most N rows (N up to 100,000) |
| `:exec` | nothing |

More rows than the kind allows is an error, `TooManyRows`, never a list silently cut short. A
`:one` query that finds two rows is a bug in the query, not the second row lost.

A `@column` may also say more than SQLite: `Bool` for an `INTEGER`, or never NULL where SQLite
says it may be. The app trusts it, and every value is checked as it is read, so a NULL in a column
annotated never NULL, or a 2 in a `Bool`, is the error `InvalidValue`, never a wrong value.


## Calling them

`Sqlite.open!` opens the database once, in `init!`, and the handle goes in the app's context. A
request then reads, or takes the writer:

```roc
init! = || {
    db = Sqlite.open!(Database.at("dishes.db"), { synchronous: Full })?
    Ok({ config: { port: 8080, static_dir: "" }, context: { db } })
}

dish! = |db, request, id| {
    { name, price_kr, .. } = Dishes.by_id!(Sqlite.read(db, request), { id })?
    Ok(Server.text("${name}: ${price_kr.to_str()} kr"))
}

rename! = |db, request, id, name| {
    tx = Sqlite.write!(db, request)?
    Dishes.rename!(tx, { id, name })?
    Sqlite.commit!(tx)?
    Ok(Server.text("renamed"))
}
```

- **Reads run on the request's shard**, on one of its readers, each a statement at a time.
- **Writes run on the one writer**, one request at a time. `Sqlite.write!` takes it and begins a
  transaction; `Sqlite.commit!` commits and gives it back. `Sqlite.reading(tx)` reads inside the
  transaction, its writes included.
- **A transaction is the request's.** One still open when the handler returns is rolled back. An
  error answer stays as it was; a success becomes a 500, since what it did was undone.
- **A safe method does not write.** `Sqlite.write!` for a GET, HEAD, OPTIONS or TRACE is
  `WriteRefused`.
- **Nothing that waits on the client happens while holding the writer.** Read the request's
  body first: read while holding the writer, it is `BodyDuringWrite`, since every other writer
  would wait on this one's client.

`ROUX_DATABASE` overrides the database's path, for a copy or a branch's own database.


## Errors

A query's error is `NotFound` (a `:one` that found no row) or `DbErr(e)`, and a handler that
returns it unchanged answers by its kind:

| error | when | answered |
|---|---|---|
| `NotFound` | a `:one` found no row | 404 |
| `Constraint(msg)` | a `UNIQUE`, `NOT NULL`, `CHECK` or `FOREIGN KEY` refused the write | 500, unless the handler says otherwise |
| `WriterBusy(msg)` | the writer stayed busy past the wait, or too many waited | 503 |
| `ReadersBusy(msg)` | every reader of the shard stayed busy past the wait | 503 |
| `TimedOut(msg)` | a statement ran past 2 s | 500 |
| `TooManyRows(msg)` | more rows than the kind allows | 500 |
| `InvalidValue(msg)` | a value its type does not hold | 500 |
| `WriteRefused(msg)` | a write for a safe method, a second `write!`, a write without one | 500 |

A constraint is usually the client's mistake, a name taken or a price of 0, and the handler
turns it into a 400 (`BadRequest` is answered 400):

```roc
Err : [NotFound, BadRequest(Str), DbErr(Sqlite.Err)]

{ id } = Dishes.add!(tx, { name, price_kr, note }) ? constraint_as_bad_request

constraint_as_bad_request : [DbErr(Sqlite.Err), NotFound] -> Err
constraint_as_bad_request = |err|
    match err {
        DbErr(Constraint(message)) => BadRequest(message)
        DbErr(other) => DbErr(other)
        NotFound => NotFound
    }
```

```text
WARN respond! POST /dishes?name=Roux&price_kr=90: BadRequest("Dishes.add: UNIQUE constraint failed: dish.name")
```


## When it refuses

roux-db prints every problem in every file, each at its line, and writes nothing until there are
none.

| you wrote | roux-db says |
|---|---|
| a parameter with no type | by_name has no `-- @param name : Type`: SQLite cannot say a parameter's type |
| an expression column with no type | column dishes is an expression, which SQLite cannot type: annotate `-- @column dishes : Type` |
| an annotation the table contradicts | @column name: the column is text in its table, not I64 |
| `:exec` for a query that returns rows | names returns rows: `:one` or `:many(N)`, not `:exec` |
| `:many` without its bound | `:many`: the kind is `:one`, `:many(N)` with N from 1 to 100000, or `:exec` |
| a `?` parameter | parameter ?: name it `:name` (roux binds by name, one style) |
| `-- @parm` | unknown annotation @parm: roux-db knows `-- name:`, `-- @param` and `-- @column` |
| a query with no name | every statement of a query file is named: `-- name: query_name :one` before it |
| a column the table lacks | no such column: title |
| a `DROP` in a query | a query may not hold a DROP (a step of ledger.sql drops on purpose) |
| a table not `STRICT` | table t is not STRICT: roux types a column by its declared type, which only a STRICT table enforces |

A query reads and writes rows, nothing more: a `CREATE` or a `DROP` in one is refused. A
`PRAGMA`, `ATTACH`, `BEGIN` or `COMMIT` is refused in a query and in `schema.sql` alike: the
platform sets the pragmas, and a transaction is the request's. Names become Roc, so a query, a parameter or a
column is `snake_case` and no Roc keyword, and a query file's name is `PascalCase`.


## Settings

The second argument of `Sqlite.open!`:

- **`synchronous`**: `Full`, a commit is on the disk when `commit!` returns; or `Normal`, at the
  next checkpoint. With `Normal` a power loss or a kernel panic may lose the last commits (a crash
  of the app loses none), for about 30 times the commits a second.
- **`read_wait_ms`**, **`write_wait_ms`**, **`writers_waiting`**: how long a request waits for a
  reader (100 ms) or the writer (1 s), and how many may wait for the writer (64), before a 503.
  The defaults shed load early; an app that would rather queue raises them, up to 60 s and 4,096.


## Backups

The running app holds the database: no other process can open it, to copy it or otherwise.
`Sqlite.backup!(db, request, { directory: "backups", keep: 7 })` copies it from inside, as it is
now, while writes go on: a whole file named for the time (`backup-20261006T235959Z.db`), the
oldest past `keep` deleted. It writes files, so a safe method may not call it, as for
`Sqlite.write!`.
