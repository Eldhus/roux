# Migrations

How a roux app's database follows its code from release to release: what you write, what runs
when the app starts, and what happens across deploys and on a team.


## Three files, one job each

A roux app's database is SQL in `db/`. `roux-db` checks it and compiles it into the app as it
builds, as it does for queries. No SQL is read at run time, and there is no migration command.

| file | says | |
|---|---|---|
| `schema.sql` | what the database is | its `CREATE` statements; edit it freely, the database follows |
| `ledger.sql` | what was done to the data by hand | a rename, a drop, rows moved: steps in order, added at the end, never changed once run |
| `Dishes.sql`, … | what the app asks of it | the queries, each a typed Roc function |

The two migration files split the work by what each can know. `schema.sql` describes an end
state, so roux can work out how to reach it. It cannot know intent: to SQLite, a renamed column
looks exactly like one column dropped and another added. The ledger records the intent, as SQL,
in the order it happened.


## Most changes: edit schema.sql

Adding a table, a column, an index, a view, a trigger or a constraint is an edit to `schema.sql`,
and nothing more. Under `roux dev` the change reaches the dev database on the next reload; in
production, when the new executable starts. Each step is printed before it runs:

```sql
-- schema.sql: a nullable column added
CREATE TABLE dish (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT) STRICT;
```

```text
roux: migrating dishes.db, 4 steps
  table `dish`: aside, to make it anew
    ALTER TABLE "dish" RENAME TO "roux_old_dish"
  table `dish`: as schema.sql makes it
    CREATE TABLE dish (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT) STRICT
  table `dish`: its rows, by id, name
    INSERT INTO "dish" ("id", "name") SELECT "id", "name" FROM "roux_old_dish"
  table `dish`: the old one
    DROP TABLE "roux_old_dish"
```

A table whose `CREATE` changed by a single byte is rebuilt the way
[SQLite's manual](https://www.sqlite.org/lang_altertable.html#otheralter) describes: the old table
set aside, the new one made exactly as `schema.sql` writes it, the rows copied by the columns both
have, the old table dropped. Whether the rows fit a new constraint is SQLite's to say as it copies
them. An `AUTOINCREMENT` carries on from where it was.

Most apps go a long time without a ledger at all.


## When data must move: the ledger

Rename a column in `schema.sql` alone and the app refuses to start: losing the old column's
values is never a guess roux makes. The refusal writes the step:

```text
column `dish.title` is in the database, not in schema.sql: its values would go. Renamed? Add the
step to ledger.sql: `ALTER TABLE dish RENAME COLUMN title TO name;` Gone on purpose?
`ALTER TABLE dish DROP COLUMN title;`
```

Paste it into `db/ledger.sql`, and the database renames the column on its next start. A ledger
after a year might read:

```sql
-- db/ledger.sql: add steps at the end. A step that ran is never changed.
ALTER TABLE dish RENAME COLUMN title TO name;

-- Dishes get a slug (schema.sql makes it NOT NULL UNIQUE).
ALTER TABLE dish ADD COLUMN slug TEXT;
UPDATE dish SET slug = lower(replace(name, ' ', '-'));

-- Tags move out of a comma-separated column.
CREATE TABLE tag (dish_id INTEGER NOT NULL REFERENCES dish (id), label TEXT NOT NULL,
  PRIMARY KEY (dish_id, label)) STRICT, WITHOUT ROWID;
INSERT INTO tag (dish_id, label)
  WITH RECURSIVE split (dish_id, label, rest) AS (
    SELECT id, '', tags || ',' FROM dish
    UNION ALL
    SELECT dish_id, substr(rest, 1, instr(rest, ',') - 1), substr(rest, instr(rest, ',') + 1)
    FROM split WHERE rest <> '')
  SELECT dish_id, label FROM split WHERE label <> '';
ALTER TABLE dish DROP COLUMN tags;

DROP TABLE menu;
```

- **A step is one SQL statement**, ended by `;`. roux-db splits the file where SQLite says each
  statement ends, so a `;` inside a string or a trigger's body does not split it.
- **Steps are plain SQL, run as written.** Any `UPDATE`, `INSERT … SELECT` or `ALTER TABLE`
  works: a split, a merge or a type change is a few lines of SQL.
- **Each step runs once on every database.** The database records each step as it runs it, in a
  table of its own, `roux_ledger`, so the next start runs only the steps after. roux-db keeps
  every name starting `roux_` for roux.
- **A step that ran is never changed.** A database refuses a ledger whose step differs from the
  one it ran, and quotes both. Comments between steps are not part of them: edit those freely.
- **A new database runs no step.** It is made from `schema.sql` as it is now, and records every
  step as run.


## What runs when the app starts

Before it serves, in one transaction:

1. **The ledger's new steps**, in order, each recorded in `roux_ledger` as it runs.
2. **What `schema.sql` changed**: new tables made, changed tables rebuilt with their rows,
   indexes, views and triggers made again.
3. **The check.** The database must be exactly what `schema.sql` makes, compared row by row in
   `sqlite_schema`, with no foreign key pointing nowhere. Then it commits.

A failure anywhere rolls it all back: the database is as it was, nothing is recorded, and the app
does not start, saying which step failed and why. When any step of the ledger runs, the database
is copied first into `<path>.before-ledger/` (the last four copies kept). Migrations only go
forward; that copy, or one `Sqlite.backup!` made, is the way back.

**The one rule to learn:** a step runs on the database as the last deploy left it, before
`schema.sql`'s changes. So a step that fills a column also adds it, as the slug above does with
`ADD COLUMN`. Then `schema.sql` makes the column `NOT NULL`, and the rebuild checks that every row
has a value.

Two more things follow from steps being plain SQL. Foreign keys are off while the steps run, as
in SQLite's own procedure for changing a table, so nothing cascades; they are checked once, at
the end. And SQLite drops no column a view still reads: drop the view in a step first, and
`schema.sql` makes it again.

Every view, trigger and `REFERENCES` in `schema.sql` is checked as the app builds: one that names
a table or column the schema no longer makes is refused there, not at the request that would run
it. The ledger's steps are the one SQL roux-db does not check: they name tables as they were when
written, which `schema.sql` no longer makes. A step is first checked when it runs, on a dev
database, then in a rehearsal.


## When it refuses

Every refusal leaves the database unchanged.

| you did | roux says |
|---|---|
| renamed a table in `schema.sql` alone | table `dish` is in the database, not in schema.sql: its rows would go. Renamed? Add the step to ledger.sql: `ALTER TABLE dish RENAME TO meal;` Gone on purpose? `DROP TABLE dish;` |
| wrote a step that uses a column only `schema.sql` adds | migrating dishes.db: ledger.sql's step 1: no such column: slug (a step runs on the database as the last deploy left it, before schema.sql's changes) |
| edited a step that ran | ledger.sql's step 2 is not what the database ran. It ran: … ledger.sql says: … A step that ran stays as it is: put it back, and add a step after it. |
| deleted parent rows their children still name | migrating dishes.db: rows that would break a foreign key: 2; course row 2 names no menu; course row 3 names no menu |
| wrote `PRAGMA`, `COMMIT` or `ATTACH` in a step | migrating dishes.db: ledger.sql's step 1: a migration may not hold a PRAGMA (the platform sets them) |
| left a step without its `;` | roux-db: a step with no `;` after it: each step of ledger.sql is one statement, ended by `;` |


## Deploying

Stop the old executable and start the new one: it migrates, then serves. One process owns a
database, so the new one refuses to start while the old one runs. If the migration is refused,
the database is unchanged and the old executable still opens it.

An older executable put back over a database a newer one migrated opens it only when nothing
needs to change: its ledger is the start of the database's, and its `schema.sql` is what the
database holds. If a newer release added a column, the older executable is refused rather than
drop it; put back a copy from before the deploy (one `Sqlite.backup!` made, or, when steps ran,
the one in `<path>.before-ledger/`).


### Rehearse first

`ROUX_REHEARSE=1 ./app` copies the database beside itself, migrates the copy and runs `init!`
over it, prints what the deploy will, deletes the copy and exits (0 when it all went through),
serving nothing. Dev and staging databases reached this schema by their own paths; a rehearsal of
production's runs the very steps production will, on its data. The database is only read, but the
running app holds it: rehearse a copy `Sqlite.backup!` made (`ROUX_DATABASE=prod-copy.db`), or
rehearse in the deploy itself, between stopping the old executable and starting the new.


### A skipped release

Steps chain: a database that skipped five releases runs their steps in order, each on what the
one before it left. A table renamed `menu` to `carte` to `meal`, or a column renamed and then
filled under its new name, needs nothing special.

One thing does not chain: a step that uses what `schema.sql` alone added, in a release this
database skipped. Say release 9 adds `price_ore` in `schema.sql` and release 10's step fills it.
A dev database that took 9 then 10 is fine; production going from 8 straight to 10 runs the step
before any schema change, and fails:

```text
migrating shop.db: ledger.sql's step 1: no such column: price_ore (a step runs on the database
as the last deploy left it, before schema.sql's changes)
```

Nothing changed, and a rehearsal shows it before the deploy does. Deploy release 9 first. To
avoid it altogether, keep the rule above: a column a step fills is added by a step.


## Teams and branches

Both files merge as code does. Two branches that each add a column merge into a `schema.sql`
with both. Two that each add steps meet at the end of `ledger.sql`; git reports a conflict there,
and whoever merges decides which goes first. The order of steps is a real decision, and git makes
a person take it.

Production ran neither branch's steps, so it runs both, in the merged order. A dev database on
branch B already ran B's step as step 2. After the merge step 2 is A's, so to that database step
2 was edited, and it refuses to open rather than skip A's step or run B's twice. Two ways out:

- Give each branch its own database:
  `ROUX_DATABASE=dev-$(git branch --show-current).db roux dev main.roc`.
- Put back the copy made before the step ran, from `dishes.db.before-ledger/`. This is also how
  to work on a step while writing it: run it, look, put back the copy, edit, run again.
