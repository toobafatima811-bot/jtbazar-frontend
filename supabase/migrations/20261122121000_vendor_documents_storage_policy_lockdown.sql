-- Only the audited vendor-document-access Edge Function may read or delete vendor documents as an administrator.
-- Vendor owners retain access to their own documents under the owner-only policies.
drop policy if exists vendor_documents_admin_read on storage.objects;
drop policy if exists vendor_documents_owner_or_admin_read on storage.objects;
drop policy if exists vendor_documents_admin_delete on storage.objects;
