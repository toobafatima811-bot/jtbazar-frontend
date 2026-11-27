BEGIN;

DROP POLICY IF EXISTS product_images_storage_vendor_insert ON storage.objects;
DROP POLICY IF EXISTS product_images_storage_vendor_delete ON storage.objects;

CREATE POLICY product_images_storage_vendor_insert
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'product-images'
  AND (storage.foldername(storage.objects.name))[1] = (SELECT auth.uid())::text
  AND EXISTS (
    SELECT 1
    FROM public.products AS p
    JOIN public.seller_profiles AS s ON s.id = p.seller_id
    WHERE p.id::text = (storage.foldername(storage.objects.name))[2]
      AND s.user_id = (SELECT auth.uid())
      AND s.status = 'approved'
  )
);

CREATE POLICY product_images_storage_vendor_delete
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'product-images'
  AND (storage.foldername(storage.objects.name))[1] = (SELECT auth.uid())::text
  AND EXISTS (
    SELECT 1
    FROM public.products AS p
    JOIN public.seller_profiles AS s ON s.id = p.seller_id
    WHERE p.id::text = (storage.foldername(storage.objects.name))[2]
      AND s.user_id = (SELECT auth.uid())
      AND s.status = 'approved'
  )
);

-- Administrator document reads/deletes are reserved for the audited Edge Function.
DROP POLICY IF EXISTS vendor_documents_owner_or_admin_delete ON storage.objects;
DROP POLICY IF EXISTS vendor_documents_admin_delete ON storage.objects;

COMMIT;