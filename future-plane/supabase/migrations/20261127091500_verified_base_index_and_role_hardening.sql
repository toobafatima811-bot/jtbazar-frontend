BEGIN;

CREATE INDEX IF NOT EXISTS admin_order_notes_created_by_idx ON public.admin_order_notes (created_by);
CREATE INDEX IF NOT EXISTS categories_parent_id_idx ON public.categories (parent_id);
CREATE INDEX IF NOT EXISTS inventory_movements_actor_id_idx ON public.inventory_movements (actor_id);
CREATE INDEX IF NOT EXISTS inventory_movements_variant_id_idx ON public.inventory_movements (variant_id);
CREATE INDEX IF NOT EXISTS notifications_related_order_id_idx ON public.notifications (related_order_id);
CREATE INDEX IF NOT EXISTS order_items_variant_id_idx ON public.order_items (variant_id);
CREATE INDEX IF NOT EXISTS product_inventory_variant_product_fk_idx ON public.product_inventory (variant_id, product_id);
CREATE INDEX IF NOT EXISTS products_category_id_idx ON public.products (category_id);
CREATE INDEX IF NOT EXISTS user_roles_assigned_by_idx ON public.user_roles (assigned_by);
CREATE INDEX IF NOT EXISTS wishlist_items_product_id_idx ON public.wishlist_items (product_id);
CREATE INDEX IF NOT EXISTS wishlist_items_variant_product_fk_idx ON public.wishlist_items (variant_id, product_id);

CREATE POLICY user_roles_deny_client_access
  ON public.user_roles FOR ALL TO anon, authenticated
  USING (false)
  WITH CHECK (false);

COMMIT;