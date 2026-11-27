-- Verified Android catalog indexes whose referenced columns exist in the current development schema.
-- The vendor_hidden-dependent product indexes are intentionally deferred until that column's source definition is found.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_products_name_trgm
  ON public.products USING gin (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_product_images_product_primary_sort
  ON public.product_images (product_id, is_primary DESC, sort_order ASC);

CREATE INDEX IF NOT EXISTS idx_product_variants_product_active_sort
  ON public.product_variants (product_id, sort_order ASC)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_categories_active_parent_sort
  ON public.categories (is_active, parent_id, sort_order ASC);

COMMIT;