-- name: by_id :one
-- @param id : I64
SELECT id, name, price_kr, note FROM dish WHERE id = :id;

-- Prose is fine anywhere among the comments.
-- name: cheap :many(100)
-- @param below : I64
-- @column n : I64
SELECT name, count(*) OVER () AS n FROM dish WHERE price_kr < :below ORDER BY name;

-- name: rename :exec
-- @param id : I64
-- @param name : Str
UPDATE dish SET name = :name WHERE id = :id;

-- name: add :one
-- @param name : Str
-- @param price_kr : I64
-- @param note : Nullable(Str)
-- @param vegetarian : Bool
INSERT INTO dish (name, price_kr, note, vegetarian)
VALUES (:name, :price_kr, :note, :vegetarian)
RETURNING id;

-- name: flags :many(1000)
-- An annotation may narrow (NOT NULL, checked when read) or say Bool.
-- @column vegetarian : Bool
-- @column note : Str
SELECT vegetarian, note FROM dish;
