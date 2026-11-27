BEGIN;

REVOKE ALL ON FUNCTION public.vendor_create_product(
  uuid,text,text,text,text,text,numeric,numeric,numeric,numeric,boolean,numeric,integer,jsonb,jsonb,text,text,integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vendor_create_product(
  uuid,text,text,text,text,text,numeric,numeric,numeric,numeric,boolean,numeric,integer,jsonb,jsonb,text,text,integer
) TO authenticated;

REVOKE ALL ON FUNCTION public.vendor_update_product(
  uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,integer,jsonb,jsonb,text,text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vendor_update_product(
  uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,integer,jsonb,jsonb,text,text
) TO authenticated;

COMMIT;