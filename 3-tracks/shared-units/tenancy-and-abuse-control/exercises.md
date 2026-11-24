# Tenancy and abuse control · Exercises

## Build a workspace reservation API

Build a service that lets company clients reserve meeting rooms. Issue short-lived access tokens for pre-provisioned clients. Readers can view reservations and schedulers can create them. Use a composite key so two companies can use the same room or reservation ID.

### Acceptance

- Publish the active and staged public keys. Show both sets of unexpired tokens working during overlap. Retire the previous key after its last token expires.
- Check missing credentials, a reader attempting to create, valid scheduling, and distinct reservations with the same ID in two tenants. A nonexistent reservation and one outside the caller's tenant have the same response.
- Apply row-level security through a dedicated login. With a one-connection test pool, verify that a scoped transaction is followed by an unscoped transaction that sees zero reservations and cannot insert.
- Spend one tenant's budget across two instances. A second tenant can still reserve, and limited responses include a retry delay. Run the same test with local buckets to expose the budget difference.
- Choose a behavior on quota store failure. Inject a pause and measure the resulting status and time. Explain how your choice affects availability and admitted work.

## Extend the quota policy

Give reads and writes distinct budgets. Document the Redis key layout and which verified claims determine each key. Show that exhausting read capacity leaves the intended write budget available without mixing tenants.

## Additional practice

[flagpole, multi-tenant feature flags](exercise-flagpole.md)
