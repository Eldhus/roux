-- name: of_dish :many(50)
-- @param dish_id : I64
SELECT dish_id, label FROM tag WHERE dish_id = :dish_id ORDER BY label;
