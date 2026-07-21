# 003 — Org-scoped RLS via `memberships` subquery (deny-by-default)
Date: 2026-07-21
Status: accepted
Thesis relevance: yes

## Context
Multi-tenancy is one shared database with `org_id` + RLS (settled, CLAUDE.md §5). RLS *is* the data-sovereignty mechanism: each organisation must be provably unable to see any other organisation's rows. Until now a **temporary** `grant … to anon` (decision at first round-trip, 2026-06-26) left `notes` wide open to close the no-auth loop; it was always marked as a throwaway.

Relevant mechanics: Postgres checks **two independent layers** — table-level GRANTs (may this role perform this operation at all?) first, then RLS policies (which rows?). Enabling RLS denies everything until a policy allows it. The `service_role` key bypasses RLS (Studio uses it); `anon`/`authenticated` requests from the app do not.

## Decision
Migration `20260721141410_add_org_scoping_and_rls.sql`:
- `notes.org_id uuid references organizations` added; **anon grants revoked entirely**.
- RLS **enabled** on `organizations`, `memberships`, `notes`.
- GRANTs only to `authenticated` (select on all three; insert on `notes`).
- Policies: `memberships` self-read (`user_id = auth.uid()`); `organizations` and `notes` readable when `org_id in (select org_id from memberships where user_id = auth.uid())`; `notes` insert `WITH CHECK` with the same subquery.

## Rationale
The membership subquery makes org access a plain, auditable SQL predicate evaluated **in the database on every request** — the client cannot opt out, and the same rule automatically governs every future access path (PostgREST, GeoServer→PostGIS views, exports). Self-read on `memberships` avoids policy recursion (it references only `auth.uid()`). Deny-by-default means forgetting a policy fails closed, not open.

## Alternatives rejected
- **`org_id` as a JWT custom claim** (no per-request subquery): claims go stale when membership changes mid-session and require a custom access-token hook; revisit only if the subquery is a *measured* bottleneck (no numbers invented — TBD).
- **Per-tenant databases/instances** — already rejected at architecture level (CLAUDE.md §5): operational load incompatible with solo maintenance.
- **App-side filtering (`.eq('org_id', …)`) as the isolation mechanism** — that is a UI convenience, not security; any client with the publishable key could omit it.
- **security-definer helper function** for the membership check — cleaner-looking policies, but more moving parts and a privilege-escalation surface; not needed at this size.

## Consequences
- Anonymous clients can no longer touch data at all; the sovereignty model is now real, not aspirational.
- The app must supply `org_id` on insert, and users need a membership before they can do anything — an **org bootstrap flow is now a required product decision** (auto-create own org on signup vs. invitation), currently done manually via Studio (service role).
- Studio remains an RLS-bypassing admin path by design; anyone holding the `service_role` key sees everything (key hygiene is security-critical).
- RLS policies are first-class security code; isolation must be verified with a two-user/two-org test and should later get automated tests.
