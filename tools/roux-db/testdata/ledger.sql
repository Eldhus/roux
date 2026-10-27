-- The golden test's ledger: what changed by hand, a step each, in order.
-- Steps name tables as they were then: `menu` is no table of schema.sql.
DROP TABLE menu;

-- A photo's caption became the dish's note.
UPDATE dish SET note = "photo caption" || '!' WHERE note IS NULL;
ALTER TABLE dish DROP COLUMN "photo caption";
ALTER TABLE "dish tags" RENAME TO tag;
