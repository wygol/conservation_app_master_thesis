# 006 — Admin-managed onboarding by e-mail invitation
Date: 2026-09-06
Status: accepted
Supersedes part of: 004 (sales-led, admin-managed onboarding) — 004's *policy*
stands; this decision fills in the mechanism it deliberately left unbuilt.
Thesis relevance: partly (it is product plumbing, but the membership write-path
is the same RLS surface the sovereignty claim rests on)

## Context

Decision 004 disabled public sign-up and said orgs and their first admin are
provisioned by the operator. It also recorded that the in-app admin-invite
machinery was **deliberately not built yet**, because a `memberships` write-path
needs care: an insert policy on `memberships` would have to query `memberships`
to decide whether the caller is an admin, and a policy that queries its own
table recurses.

That gap now blocks ordinary use. An admin cannot add a colleague without the
operator running a script for every single person.

## Decision

Three moving parts, and **no client ever inserts into `memberships`**.

1. **`invitations` table.** An admin inserts a row: e-mail, role, their own park.
   RLS allows the insert only when the caller is an `admin` of *that* park, and
   only with `invited_by = auth.uid()`. A partial unique index allows one live
   invitation per person per park.
2. **A service-role step sends the mail.** `tools/invite_user.ps1` reads pending
   rows and calls GoTrue's `/auth/v1/invite`, passing user metadata
   `{invited: true}`. Mailing needs the secret key, which never lives in the app.
   Post-thesis this becomes an Edge Function on insert.
3. **`accept_pending_invitations()`** — `SECURITY DEFINER`, called by the app
   right after sign-in. It reads the caller's address from `auth.users` (not
   from the JWT, which can be stale after an e-mail change), turns every live
   invitation for that address into a membership, expires the stale ones, and
   sets the person's active park if they have none.

The app routes a person to `SetPasswordScreen` when their metadata says
`invited == true` and `password_set != true`. Both flags are checked, not just
the second, so accounts that existed before this flow — the seeded dev users —
are never trapped on that screen.

## Rationale

Routing membership creation through one `SECURITY DEFINER` function is what
avoids the recursion decision 003 flagged, and it leaves exactly **one** write
path to audit rather than a policy whose correctness depends on reading it very
carefully. The function is small enough to read in full in one screen.

`accept_pending_invitations()` is idempotent and returns a count, so calling it
on every sign-in is free and the app needs no "have I already claimed this"
state.

Reading the e-mail from `auth.users` rather than the JWT matters more than it
looks: a JWT is issued at sign-in and a person who changes their address mid-
session would otherwise claim invitations addressed to their old one.

## Alternatives rejected

- **An insert policy on `memberships` with an admin subquery.** The recursion
  decision 003 named. Postgres does support this with care, but the failure mode
  is a policy that silently evaluates to false, and the thing it guards is the
  sovereignty boundary.
- **GoTrue invite alone, with no `invitations` table.** GoTrue can invite, but
  it knows nothing about parks or roles. The membership still has to come from
  somewhere, and without a row there is no record of who invited whom.
- **A magic-link-only flow with no password.** Fewer moving parts, but a ranger
  in a valley with no signal cannot receive a magic link, and offline-first is
  the whole premise.
- **Letting admins set a colleague's initial password.** Simplest of all, and
  wrong: nobody should ever know another person's password, and it would make
  every account's provenance ambiguous.

## Consequences

- An admin's invitation list is visible only to admins **of that park**. Test 3d
  asserts a member sees zero.
- An invited person who *already has an account* gets no mail (GoTrue returns
  422) and is simply added on their next sign-in. The script handles this rather
  than treating it as an error.
- The set-password screen is also reachable from Settings as an ordinary
  password change, so it is not a single-use screen.
- **Not built:** admin removal of a member, and role changes after the fact.
  Both need the same `SECURITY DEFINER` treatment and neither blocks the thesis.
