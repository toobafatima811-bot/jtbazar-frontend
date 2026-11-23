-- Prevent vendors from changing their own commission exemption flag.
CREATE OR REPLACE FUNCTION private.enforce_vendor_commission_admin_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role'
     AND NOT private.has_role('admin'::public.app_role) THEN
    IF TG_OP='INSERT' AND NEW.commission_enabled IS DISTINCT FROM true THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Only administrators can change vendor commission settings.';
    END IF;
    IF TG_OP='UPDATE' AND NEW.commission_enabled IS DISTINCT FROM OLD.commission_enabled THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Only administrators can change vendor commission settings.';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS enforce_vendor_commission_admin_only ON public.seller_profiles;
CREATE TRIGGER enforce_vendor_commission_admin_only
BEFORE INSERT OR UPDATE ON public.seller_profiles
FOR EACH ROW
EXECUTE FUNCTION private.enforce_vendor_commission_admin_only();

REVOKE ALL ON FUNCTION private.enforce_vendor_commission_admin_only() FROM PUBLIC, anon, authenticated;