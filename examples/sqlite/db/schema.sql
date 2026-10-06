-- The example's database: dishes and their reviews. STRICT, as roux-db
-- requires: a column's declared type is what it holds.
CREATE TABLE dish (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  price_kr INTEGER NOT NULL CHECK (price_kr > 0),
  note TEXT
) STRICT;

CREATE TABLE review (
  id INTEGER PRIMARY KEY,
  dish_id INTEGER NOT NULL REFERENCES dish (id),
  stars INTEGER NOT NULL CHECK (stars BETWEEN 1 AND 5)
) STRICT;

CREATE INDEX review_by_dish ON review (dish_id);
