-- Per-vendor commission control. Turning commission off restores each product's
-- stored vendor base price (and base variant / food prices) without rewriting
-- historical order-item commission snapshots.

ALTER TABLE public.seller_profiles
  ADD COLUMN IF NOT EXISTS commission_enabled boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.admin_set_vendor_commission(
  p_seller_id uuid,
  p_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_seller public.seller_profiles;
  v_product public.products;
  v_old_multiplier numeric;
  v_rate numeric(6,2);
  v_commission_amount numeric(12,2);
  v_customer_price numeric(12,2);
  v_base_food_unit numeric(12,4);
  v_food_unit_price numeric(12,2);
  v_divisor numeric;
  v_products_updated integer := 0;
BEGIN
  IF (auth.jwt()->>'role') IS DISTINCT FROM 'service_role'
     AND (auth.jwt()->>'aal') IS DISTINCT FROM 'aal2' THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='JTBazar authenticator verification is required.';
  END IF;
  IF NOT private.has_role('admin'::public.app_role) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Administrator access is required.';
  END IF;
  IF p_seller_id IS NULL OR p_enabled IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='A vendor and commission state are required.';
  END IF;

  SELECT * INTO v_seller
  FROM public.seller_profiles
  WHERE id=p_seller_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Vendor was not found.';
  END IF;

  IF v_seller.commission_enabled = p_enabled THEN
    RETURN jsonb_build_object(
      'seller_id', v_seller.id,
      'commission_enabled', v_seller.commission_enabled,
      'products_updated', 0,
      'changed', false
    );
  END IF;

  FOR v_product IN
    SELECT * FROM public.products
    WHERE seller_id=p_seller_id
    ORDER BY id
    FOR UPDATE
  LOOP
    v_old_multiplier := 1 + coalesce(v_product.commission_percent,0)/100;

    IF p_enabled THEN
      SELECT coalesce((s.category_rates->>v_product.category_id::text)::numeric,s.default_percent,0)
      INTO v_rate
      FROM public.commission_settings s
      WHERE s.singleton=true;
      v_rate := coalesce(v_rate,0);
    ELSE
      v_rate := 0;
    END IF;

    -- Variant overrides are stored as customer-facing prices with commission
    -- included. Convert back to base first, then apply the new vendor rate.
    UPDATE public.product_variants pv
    SET price_override=round((pv.price_override/v_old_multiplier)*(1+v_rate/100),2),
        updated_at=now()
    WHERE pv.product_id=v_product.id
      AND pv.price_override IS NOT NULL;

    IF v_product.food_selling_unit IS NOT NULL AND v_product.food_unit_price IS NOT NULL THEN
      -- Food unit prices are also stored with commission included.
      v_base_food_unit := v_product.food_unit_price/v_old_multiplier;
      v_food_unit_price := round(v_base_food_unit*(1+v_rate/100),2);
      v_divisor := CASE WHEN v_product.food_selling_unit IN ('kg','l') THEN 1000 ELSE 1 END;
      v_customer_price := round(
        v_food_unit_price*coalesce(v_product.food_quantity_increment,1)/v_divisor,2
      );
      v_commission_amount := round(v_base_food_unit*v_rate/100,2);

      UPDATE public.products
      SET price=v_customer_price,
          food_unit_price=v_food_unit_price,
          commission_percent=v_rate,
          commission_amount=v_commission_amount,
          updated_at=now()
      WHERE id=v_product.id;
    ELSE
      v_commission_amount := round(v_product.vendor_base_price*v_rate/100,2);
      v_customer_price := round(v_product.vendor_base_price+v_commission_amount,2);

      UPDATE public.products
      SET price=v_customer_price,
          commission_percent=v_rate,
          commission_amount=v_commission_amount,
          updated_at=now()
      WHERE id=v_product.id;
    END IF;

    v_products_updated := v_products_updated+1;
  END LOOP;

  UPDATE public.seller_profiles
  SET commission_enabled=p_enabled,
      updated_at=now()
  WHERE id=p_seller_id
  RETURNING * INTO v_seller;

  RETURN jsonb_build_object(
    'seller_id', v_seller.id,
    'commission_enabled', v_seller.commission_enabled,
    'products_updated', v_products_updated,
    'changed', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_set_vendor_commission(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_vendor_commission(uuid,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.vendor_get_commission_preview(p_category_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_rate numeric(6,2);
  v_seller public.seller_profiles;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sign in required.';
  END IF;

  SELECT * INTO v_seller
  FROM public.seller_profiles
  WHERE user_id=(SELECT auth.uid()) AND status='approved'
  FOR SHARE;

  IF NOT FOUND OR coalesce(v_seller.vendor_locked,false) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='An unlocked, approved seller account is required.';
  END IF;

  IF NOT coalesce(v_seller.commission_enabled,true) THEN
    RETURN 0;
  END IF;

  IF p_category_id IS NULL THEN
    SELECT default_percent INTO v_rate
    FROM public.commission_settings
    WHERE singleton=true;
  ELSE
    SELECT coalesce((s.category_rates->>p_category_id::text)::numeric,s.default_percent,0)
    INTO v_rate
    FROM public.commission_settings s
    WHERE s.singleton=true;
  END IF;

  RETURN coalesce(v_rate,0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.vendor_create_product(
  p_category_id uuid,
  p_name text,
  p_slug text,
  p_sku text,
  p_short_description text,
  p_description text,
  p_price numeric,
  p_supplier_cost numeric,
  p_fulfillment_expense numeric,
  p_minimum_profit numeric,
  p_track_inventory boolean DEFAULT true,
  p_discount_percent numeric DEFAULT 0,
  p_weight_grams integer DEFAULT NULL,
  p_specifications jsonb DEFAULT '[]'::jsonb,
  p_dimensions jsonb DEFAULT '{}'::jsonb,
  p_seo_title text DEFAULT NULL,
  p_seo_description text DEFAULT NULL,
  p_initial_stock integer DEFAULT 0
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  seller public.seller_profiles;
  product_id uuid;
  v_commission_percent numeric(6,2) := 0;
  v_commission_amount numeric(12,2) := 0;
  v_customer_price numeric(12,2);
BEGIN
  IF (auth.jwt()->>'role') IS DISTINCT FROM 'service_role'
     AND (auth.jwt()->>'aal') IS DISTINCT FROM 'aal2'
     AND (private.has_role('admin'::public.app_role) OR private.has_verified_totp_factor()) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='JTBazar authenticator verification is required.';
  END IF;

  SELECT * INTO seller
  FROM public.seller_profiles
  WHERE user_id=(SELECT auth.uid()) AND status='approved'
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='An approved seller account is required.';
  END IF;

  IF p_price IS NULL OR p_price < coalesce(p_supplier_cost,0)+coalesce(p_fulfillment_expense,0)+coalesce(p_minimum_profit,0) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Your base price does not meet the minimum profit rule.';
  END IF;
  IF coalesce(p_discount_percent,0)<0 OR coalesce(p_discount_percent,0)>100
     OR coalesce(p_initial_stock,0)<0
     OR (p_weight_grams IS NOT NULL AND p_weight_grams<0)
     OR jsonb_typeof(coalesce(p_specifications,'[]'::jsonb))<>'array'
     OR jsonb_typeof(coalesce(p_dimensions,'{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Product specifications, dimensions, discount, weight or stock are invalid.';
  END IF;

  IF coalesce(seller.commission_enabled,true) THEN
    SELECT coalesce((s.category_rates->>p_category_id::text)::numeric,s.default_percent,0)
    INTO v_commission_percent
    FROM public.commission_settings s
    WHERE s.singleton=true;
  ELSE
    v_commission_percent := 0;
  END IF;

  v_commission_percent := coalesce(v_commission_percent,0);
  v_commission_amount := round(p_price*v_commission_percent/100,2);
  v_customer_price := round(p_price+v_commission_amount,2);

  INSERT INTO public.products(
    seller_id,category_id,name,slug,sku,short_description,description,price,
    vendor_base_price,commission_percent,commission_amount,
    supplier_cost,fulfillment_expense,minimum_profit,cost_updated_at,track_inventory,
    publication_status,moderation_status,discount_percent,weight_grams,specifications,
    dimensions,seo_title,seo_description
  ) VALUES (
    seller.id,p_category_id,p_name,p_slug,nullif(p_sku,''),coalesce(p_short_description,''),
    coalesce(p_description,''),v_customer_price,p_price,v_commission_percent,v_commission_amount,
    p_supplier_cost,coalesce(p_fulfillment_expense,0),coalesce(p_minimum_profit,0),now(),
    coalesce(p_track_inventory,true),
    'draft','pending_review',
    coalesce(p_discount_percent,0),
    p_weight_grams,coalesce(p_specifications,'[]'::jsonb),coalesce(p_dimensions,'{}'::jsonb),
    nullif(btrim(p_seo_title),''),nullif(btrim(p_seo_description),'')
  ) RETURNING id INTO product_id;

  IF coalesce(p_track_inventory,true) THEN
    INSERT INTO public.product_inventory(product_id,variant_id,quantity,low_stock_threshold)
    VALUES(product_id,NULL,coalesce(p_initial_stock,0),5);
  END IF;

  RETURN product_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.vendor_update_product(
  p_product_id uuid,
  p_category_id uuid,
  p_name text,
  p_slug text,
  p_sku text,
  p_short_description text,
  p_description text,
  p_price numeric,
  p_supplier_cost numeric,
  p_fulfillment_expense numeric,
  p_minimum_profit numeric,
  p_discount_percent numeric DEFAULT 0,
  p_weight_grams integer DEFAULT NULL,
  p_specifications jsonb DEFAULT '[]'::jsonb,
  p_dimensions jsonb DEFAULT '{}'::jsonb,
  p_seo_title text DEFAULT NULL,
  p_seo_description text DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  result_row public.products;
  v_seller public.seller_profiles;
  v_commission_percent numeric(6,2) := 0;
  v_commission_amount numeric(12,2) := 0;
  v_customer_price numeric(12,2);
BEGIN
  IF (auth.jwt()->>'role') IS DISTINCT FROM 'service_role'
     AND (auth.jwt()->>'aal') IS DISTINCT FROM 'aal2'
     AND (private.has_role('admin'::public.app_role) OR private.has_verified_totp_factor()) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='JTBazar authenticator verification is required.';
  END IF;

  SELECT * INTO v_seller
  FROM public.seller_profiles
  WHERE user_id=(SELECT auth.uid()) AND status='approved'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='An approved seller account is required.';
  END IF;

  IF p_price IS NULL OR p_price < coalesce(p_supplier_cost,0)+coalesce(p_fulfillment_expense,0)+coalesce(p_minimum_profit,0)
     OR coalesce(p_discount_percent,0)<0 OR coalesce(p_discount_percent,0)>100
     OR (p_weight_grams IS NOT NULL AND p_weight_grams<0)
     OR jsonb_typeof(coalesce(p_specifications,'[]'::jsonb))<>'array'
     OR jsonb_typeof(coalesce(p_dimensions,'{}'::jsonb))<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Product fields, base price, discount, weight or profit values are invalid.';
  END IF;

  IF coalesce(v_seller.commission_enabled,true) THEN
    SELECT coalesce((s.category_rates->>p_category_id::text)::numeric,s.default_percent,0)
    INTO v_commission_percent
    FROM public.commission_settings s
    WHERE s.singleton=true;
  ELSE
    v_commission_percent := 0;
  END IF;

  v_commission_percent := coalesce(v_commission_percent,0);
  v_commission_amount := round(p_price*v_commission_percent/100,2);
  v_customer_price := round(p_price+v_commission_amount,2);

  UPDATE public.products p SET
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
    moderation_reason=CASE WHEN p.moderation_status IN ('hidden','rejected','archived') THEN p.moderation_reason ELSE NULL END,
    moderated_by=CASE WHEN p.moderation_status IN ('hidden','rejected','archived') THEN p.moderated_by ELSE NULL END,
    moderated_at=CASE WHEN p.moderation_status IN ('hidden','rejected','archived') THEN p.moderated_at ELSE NULL END,
    updated_at=now()
  WHERE p.id=p_product_id AND p.seller_id=v_seller.id
  RETURNING p.* INTO result_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Product access was denied.';
  END IF;

  RETURN result_row;
END;
$function$;
