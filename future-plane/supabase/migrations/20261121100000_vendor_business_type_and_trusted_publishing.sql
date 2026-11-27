-- Add operational business type and an admin-controlled trusted vendor publishing permission.
-- Existing vendors default to individual_seller; all new applications must select a business type.
ALTER TABLE public.seller_profiles
  ADD COLUMN IF NOT EXISTS business_type text NOT NULL DEFAULT 'individual_seller',
  ADD COLUMN IF NOT EXISTS allow_product_publishing_without_review boolean NOT NULL DEFAULT false;

ALTER TABLE public.seller_profiles
  DROP CONSTRAINT IF EXISTS seller_profiles_business_type_check;
ALTER TABLE public.seller_profiles
  ADD CONSTRAINT seller_profiles_business_type_check
  CHECK (business_type IN ('individual_seller','retail_store','restaurant','grocery_store','bakery','cafe'));

CREATE OR REPLACE FUNCTION public.admin_set_vendor_product_publishing_permission(
  p_seller_id uuid,
  p_enabled boolean
)
RETURNS public.seller_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  result_row public.seller_profiles;
BEGIN
  IF (auth.jwt() ->> 'role') IS DISTINCT FROM 'service_role'
     AND (auth.jwt() ->> 'aal') IS DISTINCT FROM 'aal2'
     AND (private.has_role('admin'::public.app_role) OR private.has_verified_totp_factor()) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='JTBazar authenticator verification is required.';
  END IF;
  IF NOT private.has_role('admin'::public.app_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Administrator access is required.';
  END IF;
  UPDATE public.seller_profiles
  SET allow_product_publishing_without_review = coalesce(p_enabled,false),
      updated_at = now()
  WHERE id = p_seller_id
  RETURNING * INTO result_row;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Seller profile was not found.';
  END IF;
  INSERT INTO public.admin_audit_logs(actor_id,action,entity,entity_id,details)
  VALUES ((SELECT auth.uid()),'UPDATE','seller_profiles',result_row.id,
    jsonb_build_object('allow_product_publishing_without_review',result_row.allow_product_publishing_without_review));
  RETURN result_row;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_set_vendor_product_publishing_permission(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_vendor_product_publishing_permission(uuid,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.vendor_create_product(p_category_id uuid, p_name text, p_slug text, p_sku text, p_short_description text, p_description text, p_price numeric, p_supplier_cost numeric, p_fulfillment_expense numeric, p_minimum_profit numeric, p_track_inventory boolean DEFAULT true, p_discount_percent numeric DEFAULT 0, p_weight_grams integer DEFAULT NULL::integer, p_specifications jsonb DEFAULT '[]'::jsonb, p_dimensions jsonb DEFAULT '{}'::jsonb, p_seo_title text DEFAULT NULL::text, p_seo_description text DEFAULT NULL::text, p_initial_stock integer DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  seller public.seller_profiles;
  product_id uuid;
  v_commission_percent numeric(6,2) := 0;
  v_commission_amount numeric(12,2) := 0;
  v_customer_price numeric(12,2);
begin
  if (auth.jwt()->>'role') is distinct from 'service_role' and (auth.jwt()->>'aal') is distinct from 'aal2'
     and (private.has_role('admin'::public.app_role) or private.has_verified_totp_factor()) then
    raise exception using errcode='42501', message='JTBazar authenticator verification is required.';
  end if;
  select * into seller from public.seller_profiles
  where user_id=(select auth.uid()) and status='approved' for share;
  if not found then raise exception using errcode='42501', message='An approved seller account is required.'; end if;
  if p_price is null or p_price < coalesce(p_supplier_cost,0)+coalesce(p_fulfillment_expense,0)+coalesce(p_minimum_profit,0) then
    raise exception using errcode='22023', message='Your base price does not meet the minimum profit rule.';
  end if;
  if coalesce(p_discount_percent,0)<0 or coalesce(p_discount_percent,0)>100 or coalesce(p_initial_stock,0)<0
    or (p_weight_grams is not null and p_weight_grams<0)
    or jsonb_typeof(coalesce(p_specifications,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_dimensions,'{}'::jsonb))<>'object' then
    raise exception using errcode='22023', message='Product specifications, dimensions, discount, weight or stock are invalid.';
  end if;
  select coalesce((s.category_rates->>p_category_id::text)::numeric,s.default_percent,0)
    into v_commission_percent from public.commission_settings s where s.singleton=true;
  v_commission_percent:=coalesce(v_commission_percent,0);
  v_commission_amount:=round(p_price*v_commission_percent/100,2);
  v_customer_price:=round(p_price+v_commission_amount,2);
  insert into public.products(
    seller_id,category_id,name,slug,sku,short_description,description,price,
    vendor_base_price,commission_percent,commission_amount,
    supplier_cost,fulfillment_expense,minimum_profit,cost_updated_at,track_inventory,
    publication_status,moderation_status,discount_percent,weight_grams,specifications,
    dimensions,seo_title,seo_description
  ) values(
    seller.id,p_category_id,p_name,p_slug,nullif(p_sku,''),coalesce(p_short_description,''),
    coalesce(p_description,''),v_customer_price,p_price,v_commission_percent,v_commission_amount,
    p_supplier_cost,coalesce(p_fulfillment_expense,0),coalesce(p_minimum_profit,0),now(),
    coalesce(p_track_inventory,true),
    'draft','pending_review',
    coalesce(p_discount_percent,0),
    p_weight_grams,coalesce(p_specifications,'[]'::jsonb),coalesce(p_dimensions,'{}'::jsonb),
    nullif(btrim(p_seo_title),''),nullif(btrim(p_seo_description),'')
  ) returning id into product_id;
  if coalesce(p_track_inventory,true) then
    insert into public.product_inventory(product_id,variant_id,quantity,low_stock_threshold)
    values(product_id,null,coalesce(p_initial_stock,0),5);
  end if;
  return product_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.vendor_update_product(p_product_id uuid, p_category_id uuid, p_name text, p_slug text, p_sku text, p_short_description text, p_description text, p_price numeric, p_supplier_cost numeric, p_fulfillment_expense numeric, p_minimum_profit numeric, p_discount_percent numeric DEFAULT 0, p_weight_grams integer DEFAULT NULL::integer, p_specifications jsonb DEFAULT '[]'::jsonb, p_dimensions jsonb DEFAULT '{}'::jsonb, p_seo_title text DEFAULT NULL::text, p_seo_description text DEFAULT NULL::text)
 RETURNS products
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  result_row public.products;
  v_commission_percent numeric(6,2) := 0;
  v_commission_amount numeric(12,2) := 0;
  v_customer_price numeric(12,2);
begin
  if (auth.jwt()->>'role') is distinct from 'service_role' and (auth.jwt()->>'aal') is distinct from 'aal2'
     and (private.has_role('admin'::public.app_role) or private.has_verified_totp_factor()) then
    raise exception using errcode='42501', message='JTBazar authenticator verification is required.';
  end if;
  if p_price is null or p_price < coalesce(p_supplier_cost,0)+coalesce(p_fulfillment_expense,0)+coalesce(p_minimum_profit,0)
    or coalesce(p_discount_percent,0)<0 or coalesce(p_discount_percent,0)>100
    or (p_weight_grams is not null and p_weight_grams<0)
    or jsonb_typeof(coalesce(p_specifications,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_dimensions,'{}'::jsonb))<>'object' then
    raise exception using errcode='22023', message='Product fields, base price, discount, weight or profit values are invalid.';
  end if;
  select coalesce((s.category_rates->>p_category_id::text)::numeric,s.default_percent,0)
    into v_commission_percent from public.commission_settings s where s.singleton=true;
  v_commission_percent:=coalesce(v_commission_percent,0);
  v_commission_amount:=round(p_price*v_commission_percent/100,2);
  v_customer_price:=round(p_price+v_commission_amount,2);
  update public.products p set
    category_id=p_category_id,name=p_name,slug=p_slug,sku=nullif(p_sku,''),
    short_description=coalesce(p_short_description,''),description=coalesce(p_description,''),
    price=v_customer_price,vendor_base_price=p_price,commission_percent=v_commission_percent,
    commission_amount=v_commission_amount,supplier_cost=p_supplier_cost,
    fulfillment_expense=coalesce(p_fulfillment_expense,0),minimum_profit=coalesce(p_minimum_profit,0),
    cost_updated_at=now(),discount_percent=coalesce(p_discount_percent,0),weight_grams=p_weight_grams,
    specifications=coalesce(p_specifications,'[]'::jsonb),dimensions=coalesce(p_dimensions,'{}'::jsonb),
    seo_title=nullif(btrim(p_seo_title),''),seo_description=nullif(btrim(p_seo_description),''),
    moderation_status=CASE WHEN p.moderation_status IN ('hidden','rejected','archived') THEN p.moderation_status ELSE 'pending_review' END,
    publication_status='draft'::public.publication_status,
    moderation_reason=CASE WHEN p.moderation_status IN ('hidden','rejected','archived') THEN p.moderation_reason ELSE null END,
    moderated_by=CASE WHEN p.moderation_status IN ('hidden','rejected','archived') THEN p.moderated_by ELSE null END,
    moderated_at=CASE WHEN p.moderation_status IN ('hidden','rejected','archived') THEN p.moderated_at ELSE null END,updated_at=now()
  where p.id=p_product_id and p.seller_id in (
    select s.id from public.seller_profiles s where s.user_id=(select auth.uid()) and s.status='approved'
  ) returning p.* into result_row;
  if not found then raise exception using errcode='42501', message='Product access was denied.'; end if;
  return result_row;
end;
$function$;


-- Publish trusted-vendor listings only after the complete editor workflow (variants, food details and images) succeeds.
-- Hidden, rejected and archived products remain blocked and always require an administrator decision.
CREATE OR REPLACE FUNCTION public.vendor_finalize_product_submission(p_product_id uuid)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  result_row public.products;
  trusted_vendor boolean := false;
BEGIN
  IF (auth.jwt() ->> 'role') IS DISTINCT FROM 'service_role'
     AND (auth.jwt() ->> 'aal') IS DISTINCT FROM 'aal2'
     AND (private.has_role('admin'::public.app_role) OR private.has_verified_totp_factor()) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='JTBazar authenticator verification is required.';
  END IF;

  SELECT coalesce(sp.allow_product_publishing_without_review,false)
    INTO trusted_vendor
  FROM public.seller_profiles sp
  JOIN public.products p ON p.seller_id=sp.id
  WHERE p.id=p_product_id
    AND sp.user_id=(SELECT auth.uid())
    AND sp.status='approved'
    AND coalesce(sp.vendor_locked,false)=false;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Approved vendor product access was denied.';
  END IF;

  IF trusted_vendor THEN
    UPDATE public.products
    SET moderation_status='approved',
        publication_status='published'::public.publication_status,
        moderation_reason=NULL,
        moderated_by=NULL,
        moderated_at=NULL,
        updated_at=now()
    WHERE id=p_product_id
      AND moderation_status='pending_review'
    RETURNING * INTO result_row;
  ELSE
    SELECT * INTO result_row
    FROM public.products
    WHERE id=p_product_id
      AND seller_id IN (SELECT id FROM public.seller_profiles WHERE user_id=(SELECT auth.uid()) AND status='approved');
  END IF;

  IF result_row.id IS NULL THEN
    SELECT * INTO result_row FROM public.products WHERE id=p_product_id;
  END IF;
  IF result_row.id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Product was not found.';
  END IF;
  RETURN result_row;
END;
$function$;

REVOKE ALL ON FUNCTION public.vendor_finalize_product_submission(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vendor_finalize_product_submission(uuid) TO authenticated;
