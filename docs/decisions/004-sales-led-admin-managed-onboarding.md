# 004 — Onboarding model: sales-led org provisioning, admin-managed membership
Date: 2026-07-21
Status: accepted (ratified by René 2026-07-21 after clarification of the RLS-recursion concern; trade-off acknowledged: operator is the bottleneck for new orgs during pilots)
Thesis relevance: yes

## Context
With org-scoped RLS live (003), memberships are the only gate to data — and currently only `service_role` can create them. A real flow is needed for (a) a new customer org coming into existence and (b) users entering that org. Target customers are national parks, agencies and regulated companies (CLAUDE.md §3): procurement-driven buyers reached via direct conversations, not self-serve signup. Solo-maintainable, calm-ops constraint applies.

## Decision
- **Org creation is concierge/sales-led:** operator (René) provisions each customer org + its first admin account via a parameterized script (same technique as `seed.sql`). No public self-serve org creation.
- **Membership is admin-managed:** the org's admin brings users in (invite); field workers never self-assign to an org. Public self-signup in the app is disabled or repurposed to "ask your organization's admin."
- **Staging:** for the thesis field test, script-provisioned accounts suffice; the in-app admin-invite machinery (RLS insert policy for org-admins or a server-side function) is built after the schema decision, potentially after evaluation.

## Rationale
Matches how public-sector B2B is actually bought (pilot conversations, provisioned accounts); offloads user management to the org — consistent with the sovereignty story (the org controls its own membership); zero abuse surface from open signup; near-zero code to maintain during validation; the provisioning script later becomes the Stripe-webhook handler body (CLAUDE.md §5 billing plan), so the model scales without rework.

## Alternatives rejected
- **Self-serve signup with auto-created personal org** (consumer-SaaS pattern): builds funnel product before demand is validated — contradicts the distribution-first lesson; creates spam-org surface; personal orgs are meaningless to agency buyers.
- **Open signup into a default/shared org:** breaks the tenancy model outright.
- **Both models at once:** premature configurability; revisit only if a self-serve segment materializes.

## Consequences
- A `tools/provision_org` script becomes required tooling (org + admin + membership in one transaction).
- GoTrue public signup must be disabled/gated in production config; login screen UX changes accordingly.
- The future admin-invite write-path on `memberships` is security-critical RLS work (self-referencing policy recursion risk — design deliberately).
- Onboarding latency is a human step by design during pilots; acceptable at 1–5 orgs, revisit at scale.
