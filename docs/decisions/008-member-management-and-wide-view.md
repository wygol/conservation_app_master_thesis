# 008 — Members are removed without losing their records; the three determinations get a flat view
Date: 2026-09-07
Status: accepted
Thesis relevance: yes (the wide view; the membership half is product plumbing)

## Context

Two requests arrived together and pull in opposite directions.

**"Admins should be able to remove users (without their data getting deleted!)."** Obvious, and the
schema had a trap in it: `observations.recorded_by_user_id` is a foreign key to `auth.users`.

**"We can keep offlineModelGuess, onlineModelGuess and expertGuess as columns."** Also reasonable —
and the schema deliberately stores them as *rows* in an append-only `identifications` table, because
that is what stops them overwriting each other, which is the thesis' central measurement (D-029,
ADR 007).

## Decision

**Removal deletes the membership and nothing else.** `remove_member(user_id, org_id)` is
`SECURITY DEFINER`, admin-only, and:
- refuses to remove the last admin of a park;
- clears the person's `active_org_id` if it pointed at that park, so they are not left looking at
  something they can no longer read;
- revokes any still-pending invitation for that address in that park.

It does not touch `observations`, `identifications` or `observation_media`.

**The three determinations get a view, not columns.** `observations_wide` returns one row per
observation with `offline_guess` / `online_guess` / `expert_guess` and their rank, confidence and
timestamp side by side, plus whichever is accepted. Most-recent-per-source; the full history stays
in `identifications`.

Alongside: `park_members(org_id)` (a function, because the e-mail lives in `auth.users` which
clients cannot read), `set_member_role(...)` with the same last-admin guard, and
`record_identification(...)` so the app can insert-and-accept a determination in one call.

## Rationale

**Why removal is safe.** What carries attribution into a published archive is
`observations.recorded_by` — a plain **text snapshot** taken at capture time, which becomes
`dwc:recordedBy`. `recorded_by_user_id` is only a convenience link, and it is `on delete set null`.
So a record keeps its attribution even if the account is deleted outright; removing a membership is
strictly less than that. This was designed in at the start, and this decision is where the reason
becomes visible.

The record count is shown next to each person in the UI for the same reason: removing someone who
recorded two hundred observations should feel different from removing someone who recorded none.

**Why the guesses are a view.** Real columns would mean writing the same fact in two places and
keeping the copies in sync. The July data-model spec proposed exactly that — a denormalised
`scientific_name` on `observations`, maintained by a trigger — and warned in the same sentence
"never leave the two out of sync". A view cannot go out of sync. The request was for a *shape*, and
a view is the shape without the duplication.

None of these columns reach GBIF. `dwc_occurrence_export` carries the accepted determination in the
Identification terms plus the superseded ones in `dwc:previousIdentifications`, which is what the
standard provides for. The three-way split is ours to keep.

## Alternatives rejected

- **Deleting the `auth.users` row on removal.** Removes a person from *every* park at once, which is
  not what an admin of one park is asking for, and is unrecoverable.
- **Soft-deleting the membership** (`removed_at`) instead of deleting it. More history, but the RLS
  predicate everywhere becomes `... and removed_at is null`, and one place that forgets it is a
  silent cross-org leak. The invitation record already shows that someone was once added.
- **Materialising the three guesses as real columns with a trigger.** See Rationale.
- **A membership DELETE policy instead of a function.** Would have to query `memberships` to decide
  whether the caller is an admin — the self-referencing recursion ADR 003 flagged and ADR 006
  routed around. One `SECURITY DEFINER` write path, one thing to audit.

## Consequences

- `park_members()` exposes colleagues' e-mail addresses to every member of the park, not just
  admins. That is deliberate — a field team should know who else records there — but it *is* a
  disclosure, and if a park objects the check is one line.
- An admin cannot remove themselves; the UI hides the action for the current user.
- A removed person's records still show their name. That is correct for the archive and might
  surprise an admin who expected removal to be erasure. The confirmation dialog says so explicitly.
- **The storage bucket added in the same migration is a placeholder** and is scoped by a path
  convention that nothing enforces. It is not part of the sovereignty claim and is marked as such in
  `docs/architecture.md` §8.
