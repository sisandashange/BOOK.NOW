# Booking-reference attempt limiter — review and test plan

This change is proposed on `security/booking-reference-attempt-limiter` only. It has not been applied to the production Supabase project and has not been merged or deployed.

## Intended behaviour

- Repeated failed reference/phone matches for an **existing** booking reference cause an escalating delay on later attempts. Including the fixed 0.4-second failed-match response delay, the total added delay is capped at 3 seconds. A correct phone/reference pair is still allowed through and clears the counter; there is no hard lockout.
- The limiter is shared across booking lookup, receipt retrieval, EFT-detail retrieval, cancellation, rescheduling, review submission, and customer push registration. This prevents switching RPCs to bypass the same reference's limit.
- Successful reference/phone verification clears that reference's failed-attempt counter.
- Business-rule failures after identity is verified (for example, a paid booking cannot be rescheduled) do not count as failed identity attempts.
- Unknown/random references are not persisted in the limiter table. This avoids creating unbounded rows from random guesses.
- The limiter stores only a keyed HMAC fingerprint of the booking reference. It does not store raw booking references or phone numbers.
- Requests for the same reference are serialized with a transaction-scoped advisory lock so concurrent failures cannot bypass the escalating delay.
- No frontend changes are required; RPC names, parameters, return shapes, and existing grants are preserved.

## Required isolated-environment tests

Run only against a disposable local database or isolated Supabase development branch with synthetic test bookings. Do not use real customer bookings.

1. **Successful lookup:** correct reference + correct phone returns the existing booking fields and clears prior failures.
2. **Escalating delay:** issue repeated wrong-phone attempts against one synthetic existing reference and verify the throttle delay plus the fixed 0.4-second failed-match delay increases but never exceeds 3 seconds in total.
3. **No lockout:** after many failed matches, a correct phone/reference pair must still succeed and clear the counter.
4. **Shared limiter:** verify the same reference's recent failure count affects lookup, receipt, EFT details, cancellation, rescheduling, review, and push registration consistently; correct identity must still pass.
5. **Window expiry:** after 15 minutes without further failures, the delay returns to its baseline.
6. **Unknown references:** repeated random/nonexistent references do not create rows in `private.booking_reference_attempts`.
7. **Valid identity, no bank details:** a valid reference/phone with no configured EFT details must not increment the failure counter.
8. **Valid identity, business-rule rejection:** paid, cancelled, too-close-to-appointment, already-reviewed, or non-completed bookings must not increment the identity failure counter after the correct phone is supplied.
9. **Concurrent attempts:** send simultaneous failed attempts against one synthetic reference; verify the escalating delay is consistent and concurrent calls cannot bypass serialization.
10. **Permissions:** `anon` and `authenticated` cannot use the private schema, read the secret, or execute private helper functions. Existing public RPC execute grants remain unchanged.
11. **Regression:** verify normal booking receipt, manage-my-booking lookup, EFT details, cancel/reschedule, review, and push setup all retain their current response shapes and behaviour.
12. **Temporary-object shadowing:** in a test session, create temporary tables with names matching referenced public tables (for example `bookings` and `reviews`), then call the affected `SECURITY DEFINER` RPCs. Verify they continue to use `public` tables; all functions with a non-empty search path must place `pg_temp` last.

## Review notes / limitations

- The limiter is reference-scoped, not IP-scoped. Unknown references are intentionally not recorded. BOOK.NOW references are generated from six cryptographically random bytes; this makes random reference discovery substantially harder, while the limiter slows phone-number guessing once a valid reference is targeted.
- A person who knows a valid reference can cause a temporary delay for that reference by submitting incorrect phone matches, but cannot lock the customer out. The delay is capped at 3 seconds, and the correct phone clears it.
- No live database, production booking, user account, website deployment, or Founder Dashboard has been changed by this proposal.
