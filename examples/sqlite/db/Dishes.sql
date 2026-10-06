-- name: all :many(200)
SELECT id, name, price_kr, note FROM dish ORDER BY name;

-- name: by_id :one
-- @param id : I64
SELECT id, name, price_kr, note FROM dish WHERE id = :id;

-- name: add :one
-- @param name : Str
-- @param price_kr : I64
-- @param note : Nullable(Str)
INSERT INTO dish (name, price_kr, note) VALUES (:name, :price_kr, :note)
RETURNING id;

-- name: rename :exec
-- @param id : I64
-- @param name : Str
UPDATE dish SET name = :name WHERE id = :id;

-- Every dish, with its average stars: NULL for a dish no one reviewed
-- (the LEFT JOIN), which SQLite says and roux-db types.
-- name: with_stars :many(200)
-- @column average : Nullable(F64)
-- @column best_stars : Nullable(I64)
SELECT d.name, avg(r.stars) AS average, max(r.stars) AS best_stars
FROM dish d LEFT JOIN review r ON r.dish_id = d.id
GROUP BY d.id ORDER BY d.name;
