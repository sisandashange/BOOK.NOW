# BOOK.NOW staff login deployment checklist

This feature is staged on `feature/staff-login-dashboard`. It is not live.

## Before deployment

1. Review the migration `20261119090000_staff_login.sql` after confirming the current production schema is still at the staff-management baseline.
2. Add the following Supabase Auth redirect URL to the project's allowed redirect URLs:
   - `https://getbooknow.co.za/vendor.html*`
3. Confirm the Edge Function runtime exposes `SUPABASE_PUBLISHABLE_KEYS` and `SUPABASE_SECRET_KEYS` (JSON objects with a `default` key), or the legacy `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`. The secret/service-role key must remain server-side only.
4. Deploy `supabase/functions/invite-staff/index.ts` as the `invite-staff` Edge Function with JWT verification enabled.
5. Deploy `supabase/functions/manage-staff-access/index.ts` as the `manage-staff-access` Edge Function with JWT verification enabled.
6. Apply the migration only after explicit production approval.
7. Publish the GitHub branch only after code review and successful tests.

## Required tests

- Existing owner sign-in, registration, store switching, bookings queue, calendar, staff management, services, payments and subscription gate remain unchanged for owners.
- Owner can invite a staff email for a staff record in a store they own.
- A non-owner cannot invoke invitations for another store or staff record.
- Invitation email opens `vendor.html`, lets the worker set a password, changes `invite_status` from `invited` to `active` through the authenticated `activate_staff_login()` RPC, and then routes them to the restricted staff dashboard.
- Staff can read only their own staff row and bookings allowed by the staff booking RLS policy.
- A SPECIFIC booking is visible only to its selected staff member and the owner.
- An ANY booking is visible to every active staff member linked to that service and to the owner.
- ANY bookings reserve one eligible worker in the database while remaining visible to every active worker eligible for that service.
- Availability excludes both specific bookings and the worker provisionally reserved for an ANY booking, so concurrent shared bookings cannot overbook the staff pool.
- Two workers accepting the same ANY booking concurrently results in exactly one successful assignment.
- Owner status-only updates (for example, pending to confirmed) preserve the provisional staff reservation; reactivating a cancelled booking is revalidated.
- Once accepted, the booking is visible to the winning worker and owner, and disappears from other workers' views.
- Deactivating a linked staff member bans the Auth account from new sign-ins/refreshes and sets `is_active=false`; RLS denies booking access immediately. Reactivation unbans the account and restores access.
- Existing access-token JWTs may remain cryptographically valid until expiry, but staff RLS checks the active staff row on every protected query and reject deactivated accounts.
- Takeaway bookings and bookings using assignment mode NONE retain their existing behavior.
- No real customer data is used for test bookings; remove all test rows after tests.

## Important boundaries

- The migration and Edge Function are source files only until separately deployed.
- This feature does not send phone push notifications to staff in its first version; shared bookings appear in the staff dashboard.
- Deactivation sets `is_active=false` first, immediately denying protected staff booking queries through RLS, then bans the Auth identity from new sign-ins/refreshes. Existing access-token JWTs may remain valid until expiry, but RLS still blocks staff data access. Reactivation unbans the identity before restoring the active staff row.
