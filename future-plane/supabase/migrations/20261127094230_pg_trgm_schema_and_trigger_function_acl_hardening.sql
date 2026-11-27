BEGIN;

ALTER EXTENSION pg_trgm SET SCHEMA extensions;

REVOKE ALL ON FUNCTION public.guard_manual_order_delete_after_assignment()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_manual_order_item_delete_after_assignment()
  FROM PUBLIC, anon, authenticated;

COMMIT;