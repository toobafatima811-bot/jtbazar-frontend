BEGIN;

-- JTBazar Manual Orders: Phase 1 database support (admin + fulfilment).
-- Isolated from public.orders, delivery_batches and driver_assignments.
-- Apply once to the JTBazar Supabase project.

ALTER TABLE public.manual_order_items
  ADD COLUMN IF NOT EXISTS vendor_approval_status text NOT NULL DEFAULT 'not_required'
    CHECK (vendor_approval_status IN ('not_required','pending','approved','rejected')),
  ADD COLUMN IF NOT EXISTS delivery_readiness_status text NOT NULL DEFAULT 'ready'
    CHECK (delivery_readiness_status IN ('not_ready','ready','assigned','picked_up','delivered','failed')),
  ADD COLUMN IF NOT EXISTS vendor_approved_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS vendor_approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS vendor_approval_note text;

UPDATE public.manual_order_items
SET vendor_approval_status=CASE WHEN seller_id IS NULL THEN 'not_required' ELSE 'pending' END,
    delivery_readiness_status=CASE WHEN seller_id IS NULL THEN 'ready' ELSE 'not_ready' END;

CREATE OR REPLACE FUNCTION public.initialize_manual_order_item_fulfillment()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $function$
BEGIN
  IF NEW.seller_id IS NULL THEN
    NEW.vendor_approval_status:='not_required'; NEW.delivery_readiness_status:='ready';
  ELSE
    NEW.vendor_approval_status:='pending'; NEW.delivery_readiness_status:='not_ready';
  END IF;
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS manual_order_item_fulfillment_init ON public.manual_order_items;
CREATE TRIGGER manual_order_item_fulfillment_init BEFORE INSERT ON public.manual_order_items
FOR EACH ROW EXECUTE FUNCTION public.initialize_manual_order_item_fulfillment();

CREATE TABLE IF NOT EXISTS public.manual_order_driver_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manual_order_id uuid NOT NULL REFERENCES public.manual_orders(id) ON DELETE CASCADE,
  driver_user_id uuid NOT NULL REFERENCES auth.users(id),
  assigned_by uuid NOT NULL REFERENCES auth.users(id),
  status text NOT NULL DEFAULT 'assigned' CHECK(status IN ('assigned','picked_up','delivered','failed','cancelled')),
  cod_due_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK(cod_due_amount>=0),
  cod_collected_amount numeric(14,2) CHECK(cod_collected_amount IS NULL OR cod_collected_amount>=0),
  cod_collected_at timestamptz, picked_up_at timestamptz, delivered_at timestamptz,
  failed_reason text, failed_note text, delivery_proof_path text,
  cash_reconciled_amount numeric(14,2), cash_reconciled_at timestamptz,
  cash_reconciled_by uuid REFERENCES auth.users(id),
  assigned_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.manual_order_driver_assignment_items (
  assignment_id uuid NOT NULL REFERENCES public.manual_order_driver_assignments(id) ON DELETE CASCADE,
  manual_order_item_id uuid NOT NULL REFERENCES public.manual_order_items(id) ON DELETE RESTRICT,
  cod_due_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK(cod_due_amount>=0),
  PRIMARY KEY(assignment_id,manual_order_item_id)
);
CREATE INDEX IF NOT EXISTS manual_order_driver_assignments_order_idx ON public.manual_order_driver_assignments(manual_order_id,assigned_at DESC);
CREATE INDEX IF NOT EXISTS manual_order_driver_assignments_driver_idx ON public.manual_order_driver_assignments(driver_user_id,status,assigned_at DESC);
CREATE INDEX IF NOT EXISTS manual_order_driver_assignment_items_item_idx ON public.manual_order_driver_assignment_items(manual_order_item_id);

ALTER TABLE public.manual_order_driver_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_order_driver_assignment_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS manual_order_driver_assignments_admin_read ON public.manual_order_driver_assignments;
CREATE POLICY manual_order_driver_assignments_admin_read ON public.manual_order_driver_assignments
FOR SELECT TO authenticated USING((SELECT private.has_role('admin'::public.app_role)));
DROP POLICY IF EXISTS manual_order_driver_assignment_items_admin_read ON public.manual_order_driver_assignment_items;
CREATE POLICY manual_order_driver_assignment_items_admin_read ON public.manual_order_driver_assignment_items
FOR SELECT TO authenticated USING((SELECT private.has_role('admin'::public.app_role)));

CREATE OR REPLACE FUNCTION public.guard_manual_order_item_delete_after_assignment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  IF EXISTS(SELECT 1 FROM public.manual_order_driver_assignment_items ai WHERE ai.manual_order_item_id=OLD.id) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='This manual order item has driver assignment history and cannot be edited or removed. Create a new manual order instead.';
  END IF;
  RETURN OLD;
END;
$function$;
DROP TRIGGER IF EXISTS manual_order_item_assignment_delete_guard ON public.manual_order_items;
CREATE TRIGGER manual_order_item_assignment_delete_guard BEFORE DELETE ON public.manual_order_items
FOR EACH ROW EXECUTE FUNCTION public.guard_manual_order_item_delete_after_assignment();

CREATE OR REPLACE FUNCTION public.guard_manual_order_delete_after_assignment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  IF EXISTS(SELECT 1 FROM public.manual_order_driver_assignments a WHERE a.manual_order_id=OLD.id) THEN
    RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='This manual order has driver assignment history and cannot be deleted.';
  END IF;
  RETURN OLD;
END;
$function$;
DROP TRIGGER IF EXISTS manual_order_assignment_delete_guard ON public.manual_orders;
CREATE TRIGGER manual_order_assignment_delete_guard BEFORE DELETE ON public.manual_orders
FOR EACH ROW EXECUTE FUNCTION public.guard_manual_order_delete_after_assignment();

COMMIT;