-- The golden test's database (tests.zig): `roux-db gen` on this
-- directory writes the expected Roc beside it.
CREATE TABLE dish (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  price_kr INTEGER NOT NULL,
  note TEXT,
  vegetarian INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX dish_by_name ON dish (name);

CREATE TABLE tag (
  dish_id INTEGER NOT NULL REFERENCES dish (id),
  label TEXT NOT NULL,
  PRIMARY KEY (dish_id, label)
) STRICT, WITHOUT ROWID;

-- The release, and the oldest a database may be at:
-- @release 9
-- @oldest 6
-- Gone on purpose, with their rows, when a database is migrated:
-- @drop 7 table menu
-- @drop 8 column dish photo
-- and what is new filled from what was there:
-- @from 8 column dish note = "photo caption" || '!'
-- @from 9 table tag = "dish tags"
