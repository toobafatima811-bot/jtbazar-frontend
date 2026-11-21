# JTBazar Vendor Identity & CNIC Privacy Policy

**Status:** Proposed operational policy for review. This policy is not a legal opinion and should be checked by a Pakistan-based privacy/tax adviser before public launch.

## Why JTBazar collects vendor identity information

JTBazar collects the vendor owner's full name, account/contact details, shop address and location, CNIC number, and CNIC front/back images to:
- verify the person responsible for a seller account;
- protect the marketplace and customers against impersonation and fraud;
- secure vendor accounts and investigate reported misuse; and
- respond to a lawful request or resolve a genuine dispute.

CNIC information must not be used for advertising, sold, or shared with other vendors.

## Access and security

- The `vendor-documents` bucket must remain private.
- Only authorised marketplace administrators may review vendor verification documents.
- The admin dashboard must request a short-lived signed link through the `vendor-document-access` Edge Function.
- Each successful dashboard document-view request is recorded in `admin_audit_logs` with the administrator, seller profile, document type and timestamp. The log must not contain the CNIC number or signed URL.
- Vendor documents must not be copied into public storage, chat messages, product records or analytics.

## Retention schedule

- **Rejected applications:** retain CNIC data for up to 90 days after the final rejection decision, allowing a reasonable correction or appeal period. Then securely delete the CNIC number and front/back image files.
- **Approved vendors:** retain CNIC data only while the vendor relationship remains active. After the vendor account is formally closed, securely delete the CNIC number and front/back image files within 90 days.
- **Legal hold:** retain only the specific information required for a documented legal obligation, active dispute or fraud investigation. Record the reason and review the hold periodically.
- **Business profile PDFs:** these are separate from CNIC records and must follow their own operational/legal retention need; do not automatically delete them under the CNIC schedule.

## Deletion procedure

When a record reaches its deletion date and no legal hold applies:
1. Remove the CNIC front and back objects from the private `vendor-documents` bucket.
2. Clear `cnic_number`, `cnic_front_path` and `cnic_back_path` on the seller profile.
3. Keep only the minimum audit evidence needed to show that access/deletion was handled; never keep a copy of the CNIC in the audit log.
4. Record the deletion date and responsible administrator in an approved operational record.

**Important implementation note:** The policy and dashboard access logging are being added in code. A scheduled automatic purge is not configured by this change; JTBazar must run a documented retention review and deletion process until an automated cleanup job is separately tested and enabled. Do not tell vendors that deletion is automatically scheduled until that automation is live.

## Vendor notice

Show the purpose, access restrictions, 90-day retention schedule and support route beside the CNIC fields before a vendor submits an application.