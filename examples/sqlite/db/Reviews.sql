-- name: add :exec
-- @param dish_id : I64
-- @param stars : I64
INSERT INTO review (dish_id, stars) VALUES (:dish_id, :stars);

-- name: count :one
-- @column reviews : I64
SELECT count(*) AS reviews FROM review;
