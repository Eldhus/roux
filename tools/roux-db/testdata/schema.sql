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
