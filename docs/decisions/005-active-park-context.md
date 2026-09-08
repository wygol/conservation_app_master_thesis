# 005 — One active park at a time, chosen by the person, switched in Settings
Date: 2026-09-06
Status: accepted
Thesis relevance: yes

## Context

`memberships` has been many-to-many since decision 003, so a person can belong
to several parks at once — a ranger who works for two neighbouring national
parks, a consultant who records for three. That was always true of the schema;
it had never been true of the *app*, which resolved "my org" by taking the first
membership row it found:

```dart
final rows = await supabase.from('memberships').select('org_id').limit(1);
```

With one membership that is correct. With two it is a coin toss, silently
resolved differently depending on row order, and it decides which
organisation's database a field record lands in. `observations.org_id` is a
single value and there is no correcting it afterwards without an admin.

## Decision

The app holds an **active park**. Every write carries it. The person chooses it,
and changes it in **Settings**, not on the capture screen.

- Stored server-side in `user_settings.active_org_id`, not only in device
  preferences, so the choice follows the person to a second phone and an admin
  can see which park a colleague is recording under.
- Changed through `set_active_org(uuid)`, which refuses an organisation the
  caller is not a member of. A wrong or compromised client cannot use it to
  reach a third park's data.
- Surfaced permanently: the park's name sits under the app-bar title on the
  records screen. A person recording for two parks must never have to guess.
- Read through the `my_parks` view, which is RLS-filtered to the caller.

## Rationale

Settings rather than a prominent switcher is deliberate. Switching park is a
consequential act — it changes which organisation owns everything recorded
afterwards — and it happens rarely, typically once when a shift starts. Putting
it one deliberate step away is the right trade against putting it under a thumb
that is also holding a plant.

Server-side storage rather than `SharedPreferences` costs one table and buys
two things: the choice survives a reinstall, and "which park was this person
recording under" is answerable, which matters when a record turns out to be in
the wrong place.

## Alternatives rejected

- **Infer the park from the coordinates** against a boundary polygon. Elegant
  until a ranger records from a car park outside the boundary, or two parks'
  buffers overlap, or the boundary has not been loaded. It would also mean the
  owning organisation changes if someone corrects a coordinate. Rejected as the
  *decision* mechanism — but kept as a *warning*:
  `observation_is_within_org_boundary()` exists and is deliberately not a
  constraint, so the app can say "this is outside Hohe Tauern — is that right?"
  without blocking real work or pushing people to fake coordinates.
- **Ask per observation.** Correct, and unbearable at the fiftieth record.
- **One account per park.** Two logins for one person, two sets of credentials,
  and a fresh problem every time someone forgets which they are in.

## Consequences

- `user_settings` is a new table with its own RLS. It is the first table whose
  rows are per *user* rather than per organisation.
- A person with no membership at all is now a first-class state, not a crash:
  they see "You do not belong to a park yet. Ask an administrator to invite
  you." This is what a newly invited colleague sees for the few seconds before
  their invitation is claimed.
- `OrgContext` is the app's only piece of genuinely global state. It is passed
  down explicitly rather than through a service locator, so it stays visible.
- The seed now includes `ranger@test.at`, a member of **both** seeded orgs, so
  the multi-park case is on screen after every `supabase db reset` rather than
  being something you have to construct to test.
