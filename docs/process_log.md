# Process Log — Conservation Field-Data App

Running development journal for the thesis (Design Science Research): what was built, *why* each decision was made, problems encountered, and how the system changed over time. Newest entries at the bottom.

---

## 2026-06-26, 21:31 CEST (19:31 UTC) — Session 1: First vertical slice (app ↔ Supabase round-trip)

**Goal (CLAUDE.md §10):** Build the smallest end-to-end slice to prove the data flow — connect the Flutter app to the local self-hosted Supabase, create a first table via a migration, and write a record from the phone into our own Postgres. Deliberately trivial; learning-focused (first real Flutter/Supabase work).

### What was built
- Added `supabase_flutter` to `pubspec.yaml`.
- Initialized the Supabase client **once** at startup: made `main()` async, called `WidgetsFlutterBinding.ensureInitialized()`, then `Supabase.initialize(url, publishableKey)`.
- Created the first migration `..._create_notes.sql` defining `public.notes`:
  - `id uuid primary key default gen_random_uuid()`
  - `text text not null`
  - `created_at timestamptz not null default now()`
- Built a minimal screen (replaced the counter): a `TextField` + Save button that inserts via `supabase.from('notes').insert({'text': ...})`, with `try/catch` and SnackBar feedback.
- **Result:** notes save from the physical phone into local Supabase with a server-generated UUID and timestamp, verified in Studio. ✅ Full app → DB write path proven.

### Key decisions & rationale
- **Networking via `adb reverse`, not `10.0.2.2`.** `10.0.2.2` is an *emulator-only* alias for the host loopback; we run on a physical Samsung S22. Chose `adb reverse tcp:54321 tcp:54321`, which tunnels the phone's `127.0.0.1:54321` to the laptop across the adb link — works over **USB and wireless**, needs no LAN IP and no firewall changes, and works with Supabase's default loopback binding. The app therefore targets `http://127.0.0.1:54321`. *(This corrects the original CLAUDE.md §7 note.)*
- **Cleartext HTTP enabled for debug builds only.** Android blocks plaintext HTTP by default (API 28+). Added `android:usesCleartextTraffic="true"` to `android/app/src/debug/AndroidManifest.xml` so it never touches release builds (production will be HTTPS).
- **UUID primary key** (not an auto-increment integer): lets a client mint globally-unique IDs *offline* without coordination — required for the planned offline queue + multi-tenant sync.
- **`timestamptz` (UTC-aware)** for `created_at`: correct for a field app spanning time zones, and the same type the future Darwin Core `event_date` will use.
- **Schema — including GRANTs — lives in migrations**, never in ad-hoc Studio clicks: reproducible, version-controlled, auditable (DSR requirement; CLAUDE.md §7).
- **Temporary `grant insert, select on public.notes to anon`** to close the no-auth loop. Explicitly a throwaway: it opens the table to anyone holding the publishable key — the *opposite* of the sovereignty model — and will be replaced by GoTrue auth + org-scoped RLS.
- Using the **new-style publishable key** (`sb_publishable_…`) through the `publishableKey:` parameter (the library deprecated the old `anonKey:` name).

### Problems hit & how they were resolved
- **`flutter run`: "Error connecting to the service protocol" over wireless.** This is the Dart VM service (developer tooling: hot reload / DevTools), **not** the app's Supabase connection — `Supabase init completed` logged fine and the installed app kept running on the phone. Cause: wireless-adb flakiness. Mitigations: re-run `flutter run`; or use USB for the dev session (the `adb reverse` tunnel works there too). Logged as a recurring "wireless tax."
- **`PostgrestException 42501: permission denied for table notes`.** This surfaced the **two-layer Postgres permission model**: a **GRANT** (table-level: may this role perform this operation at all?) is checked *before* **RLS** (row-level: which rows?). The error was the GRANT gate — `anon` had no INSERT privilege — *not* RLS. (Corrected an earlier oversimplification that "RLS off ⇒ anon can write.") Resolved with the temporary grant above. The fact that the request reached Postgres at all also confirmed the full network path was working.

### Concepts established (useful for the thesis write-up)
- Migration files are **cumulative deltas**; the current schema = all migrations applied in timestamp order, not "the latest file." `supabase db reset` = local, destructive, replays everything; `supabase db push` = production, forward-only, non-destructive unless the SQL itself is. Migrations are forward-only (no automatic rollback).
- `Supabase.initialize()` builds the client and restores any saved session **locally**; it does **not** open or verify a network connection — the connection is lazy, on the first query. (Explains why init succeeded before networking was set up.)
- `async`/`await` is non-blocking *waiting*, not offline persistence; offline-first is separate machinery, and the `catch` block is where it will hook in.
- `created_at default now()` records **server insert time**, not capture time — offline use will need a client-supplied `event_date`.
- In Postgres, `text` vs `varchar(n)` perform identically; prefer `text`.

### State change
- **Before:** default Flutter counter app on the phone; local Supabase running but not connected to the app; no schema.
- **After:** app connected to local Supabase via `adb reverse`; first migration + `public.notes` table; working insert round-trip verified in Studio.

### Next steps
1. **Read/list** `notes` back in the app to close the full app → DB → app loop (CLAUDE.md §10, step 4).
2. The real chapter: **GoTrue auth + `organizations` + `memberships` + org-scoped RLS**, replacing the temporary `anon` grant — this is the data-sovereignty mechanism and the thesis core.
3. Grow `notes` → `observations` (PostGIS geometry, photo, Darwin Core fields + JSONB `attributes`).

---

## 2026-06-26/27 — Session 2: Round-trip closed; auth; org/membership schema
*(Backfilled 2026-07-21 from working notes; dates per file mtimes.)*

### What was built
- **Read path**: notes list loads in `initState()` (never in `build()` — rebuild→fetch→setState loop), `select().order('created_at', descending)`, three render states (loading/empty/list), re-read after each save. §10 vertical slice **complete**: app → DB → app on the physical phone.
- **Auth (GoTrue)**: `LoginScreen` (email+password sign-in/sign-up, password-visibility toggle), `AuthGate` on `onAuthStateChange` as `MaterialApp.home`, sign-out action. Sessions persist on-device; the JWT rides every request as a Bearer header; in SQL the user appears as `auth.uid()` with role `authenticated`.
- **Migration 2** `create_orgs_and_memberships`: `organizations` (billing-ready placeholder fields, unused) and `memberships` as user↔org **bridge table** (FKs to `auth.users` and `organizations`, `on delete cascade`, `role` with CHECK constraint, `unique (user_id, org_id)`).
- Temporary grant widened to `anon, authenticated` so the loop kept working post-login (still a marked throwaway).

### Key reasoning
- Bridge table because user↔org is many-to-many and a membership carries its own attribute (`role`); a single `org_id` column on the user could encode neither.
- Auth before RLS because policies key on `auth.uid()` — without login there is nothing to scope rows to.

## 2026-07-21 — Session 3: Org-scoped RLS applied; first commits; docs backfill

### What happened
- **Migration 3** `add_org_scoping_and_rls` written and applied (`db reset`): `notes.org_id`, RLS enabled on all three tables, `anon` fully revoked, `authenticated` grants + membership-subquery policies. Details and alternatives: `docs/decisions/003`. Studio confirms RLS active (no "RLS disabled" warnings; Studio itself still sees all rows — `service_role` bypasses RLS by design).
- **Repo versioning prepared.** CLAUDE.md §9 flagged zero commits after ~4 weeks of work (real data-loss near-miss during a copy operation). Everything (app, 3 migrations, docs) is now **staged**; René commits himself (authorship policy: commits are made by him, not by the agent) once the RLS isolation test passes. Going forward: small, working-step commits — `git log` doubles as dated process evidence.
- **Decision records backfilled** after a month of sitting empty: `001` (adb reverse networking), `002` (UUID PKs + timestamptz), `003` (org-scoped RLS). The CLAUDE.md §11 contract is now mechanical — decision files get written *when the decision is made*, not retrospectively.
- **Thesis-side scope change noted (D-002, 2026-07):** offline on-device classifier (MobileNetV3/EfficientNet-Lite → TFLite) is now in scope; evaluation compares offline vs. online Pl@ntNet on the same test set (replaces the iNaturalist/QField/ArcGIS feature comparison). All three identifications (offline/online/expert) will be stored, never overwritten. No build work on this yet — affects the roadmap after the observations schema.

### Problem hit & resolution
- **`SocketException: Connection refused` on sign-up after the month-long gap.** Phone's `127.0.0.1:54321` had no listener: the `adb reverse` tunnel had evaporated (reboots/reconnects since June) — the predicted recurring cost of decision 001. Supabase itself was up (Studio reachable). Fix: re-run `adb reverse tcp:54321 tcp:54321`, verify with `adb reverse --list`. Also: `db reset` wiped `auth.users`, so test accounts must be re-created — a seed file for dev users/orgs is now on the shortlist to stop this recurring.
- Stale zero-byte `.git/index.lock` blocked the initial commit; removed after confirming no live git process.

### State
- **Schema:** `notes` (org-scoped), `organizations`, `memberships` — all RLS-locked, deny-by-default, anon locked out.
- **App:** auth-gated notes screen; does **not** yet send `org_id` (inserts will fail RLS until it does) and no memberships exist yet.
- **Next:** re-establish tunnel → re-create test users → bootstrap org+membership (Studio SQL, service role) → app sends `org_id` and reads membership via RLS → **two-user/two-org isolation test** (the sovereignty proof). Then: seed file, registration UX (own screen), org bootstrap flow decision (auto-create vs. invite).

### Session 3 (continued, same day) — automation of the dev loop
Division of labor shifted by agreement: René drives concepts/verification, agent implements. Added:
- **`lib/main.dart`**: screen now resolves the user's org at startup (`memberships.select('org_id')` — *no client-side user filter; RLS injects it server-side*) and sends `org_id` with every insert; human-readable guard when no membership exists.
- **`supabase/seed.sql`**: dev-only reproducible test world on every `db reset` — two confirmed users (`usera@test.at`/`userb@test.at`, local-only password), Org Alpha/Beta, memberships, sample notes. Ends the recurring "reset wiped my accounts" cost. Direct `auth.users` inserts are a local-seeding-only technique (prod users go through GoTrue exclusively).
- **`tools/dev_connect.ps1` + `.bat`**: one-click tunnel restore (finds adb, dedupes stale wireless devices, sets `adb reverse`, verifies laptop-side 54321). Root cause of today's `Connection refused`: assumption that USB needs no tunnel — it does; reverses are registered per device connection and die on transport switch.
- Earlier agent-made commits were **reverted** at René's request (he commits himself); tree left fully staged.

### Session 3 (continued 2) — onboarding model implemented (ADR 004)
Decision 004 ratified: sales-led org provisioning, admin-managed membership, no public self-signup. Implemented:
- **Login gated**: "Create account" removed; "Need access? Ask your admin" dialog instead. GoTrue `enable_signup = false` in `config.toml` (server-side enforcement — the UI change is cosmetic, the backend rule is the real gate). Requires `supabase stop` + `supabase start` to take effect (data persists).
- **`tools/provision_org.ps1`**: one command creates org + confirmed admin + membership in a single transaction (docker exec → psql). Local/dev technique (direct `auth.users` insert, like seed); production variant should create users via GoTrue Admin API. Template for the future Stripe-webhook handler.
- **Refactor**: `main.dart` split into `main.dart` (bootstrap + `AuthGate`) + `screens/login_screen.dart` + `screens/notes_screen.dart` (`MyHomePage` → `NotesScreen`). No logic changes.
- **Deliberately deferred** (thesis-clock reasoning): in-app admin-invite machinery (memberships write-path policies / server function). Not needed for the field evaluation — script-provisioned accounts suffice; the memberships-RLS-recursion design problem is documented in ADR 004 consequences and will be tackled only if time allows after `observations`.

**Verified on device (later that day):** stack restart with `enable_signup = false` works; gated login + "ask your admin" dialog work; `provision_org.ps1` provisions a fresh org+admin that logs in fully isolated (RLS-correct). `docs/architecture.md` written (first as-built snapshot); CLAUDE.md §9 refreshed to current state.

**Result: ISOLATION TEST PASSED (2026-07-21).** On-device verification: `usera@test.at` sees exactly the two Org Alpha notes and can write; `userb@test.at` sees exactly the one Org Beta note. Same table, same database, zero crossover — the CLAUDE.md §6 sovereignty claim is demonstrated, not asserted. Marked as **Milestone 1** (git tag `m1-sovereignty-slice`). Open follow-ups: org onboarding flow (auto-create vs. invite — product decision), registration UX, `notes` → `observations`.

---

## 2026-09-06 — Session 4: observations schema, active-park context, invitations, Darwin Core export

> ### ⚠️ Read this first if you are the app agent and did not write these files
>
> **This session was done by the THESIS agent, at René's explicit direction**, working from the
> MasterThesis folder into this repo. That is the opposite of the one-way flow §11 of `CLAUDE.md`
> lays down (repo → vault, never the reverse), so it is called out here rather than left to be
> discovered.
>
> **The default rule still stands.** This was a one-off because the observations schema is the
> point where the thesis and the app stop being separable: the same table that stores a field record
> is the instrument the thesis measures its central claim with, and getting it wrong in the app
> would have made the thesis unmeasurable. Nothing else was touched. If a future session finds this
> confusing, raise it with René rather than reconciling it silently.
>
> **Nothing here is committed.** René commits himself (authorship policy, session 3).

### Why the schema had to come before more app work

The previous plan (`CLAUDE.md` §6) described the runtime as: *"when connectivity returns, the online
Pl@ntNet result overrides the offline suggestion."* Implemented literally, that destroys the thesis'
central measurement — the offline-vs-online comparison — at the moment it is taken. There is no
recovering it afterwards from production data. So the determination model had to be settled before
either the capture flow or the model work proceeded, because both write into it.

### What was built

**Migration 4 — `20260905120000_create_observations_and_identifications.sql`**

Seven tables, PostGIS finally enabled (it had shipped in the image and was never turned on):

| Table | What it is |
|---|---|
| `taxa` | the label space. **Not** org-scoped — a taxon is a fact about the world. Mixed-rank by design (species *and* genus rows), carrying `gbif_taxon_key` and `accepted_gbif_key` |
| `checklist_entries` | which taxa a park expects. This is what the on-device model's output mask is built from |
| `model_versions` | which artefact produced a prediction |
| `survey_events` | the Humboldt Extension layer — eight of the fifty-five ratified terms, the ones a phone can fill honestly |
| `observations` | the `dwc:Occurrence`. Point **or** polygon |
| `identifications` | **append-only.** Every determination attempt, machine and human, forever |
| `observation_media` | photos, with the plant organ Pl@ntNet takes as a parameter |

**The central design problem, and the resolution.** Darwin Core allows exactly one Identification per
Occurrence (`dwc:identificationID`: *"One dwc:Identification object is allowed per dwc:Occurrence
object"*). We need three or more, never overwritten. Darwin Core is an **exchange format**, not a
storage model — the standard itself says its value is *"explicitly independent of technical
implementation"* and that it *"is not a prescription for how to manage collection data"*. So: our
layer is relational and append-only; Darwin Core is what we **project to at export**, with the
superseded determinations serialised into `dwc:previousIdentifications`. Nothing lost, nothing
misrepresented. Details in `docs/decisions/007`.

**`observations` has no `scientific_name` column.** That is deliberate and is the whole point: the
determination is not an attribute of the occurrence. Read it through the `observations_current` view.
The earlier thesis-side spec wanted the column denormalised and kept in sync by a trigger, and warned
in the same breath "never leave the two out of sync" — a view cannot go out of sync.

**Two columns that exist purely so the thesis is measurable from ordinary records:**
`identifications.checklist_masked` (was the park checklist applied?) and `identifications.top_k`
(the full ranked candidate list). Without `top_k`, top-5 accuracy cannot be computed from production
data at all.

**Append-only is enforced by the absence of an UPDATE grant**, not by convention or careful
application code. A client attempting to overwrite a determination gets `permission denied for table
identifications` from Postgres. Superseding is an insert plus `accept_identification()`.

**Migration 5 — `20260906090000_org_context_invitations_and_dwc_export.sql`**

- `organizations` becomes a park instance that can publish: `boundary`, `country_code`, and the
  dataset-level Darwin Core/EML metadata a partner needs (`dataset_name`, `rights_holder`,
  `default_license`, contact, `publishing_status`, `export_unverified`).
- `user_settings.active_org_id` + `set_active_org()` — the active park (ADR 005).
- `invitations` + `accept_pending_invitations()` — admin-managed onboarding (ADR 006).
- `my_parks` — what the Settings switcher reads.
- `dwc_occurrence_export` and `dwc_export_readiness` — the export contract (ADR 007).

### App changes

- `lib/services/org_context.dart` — the active park, as a `ChangeNotifier`. Claims invitations on
  sign-in, then loads the park list. The app's only genuinely global state; passed down explicitly
  rather than through a service locator so it stays visible.
- `lib/services/identification_service.dart` — **the core/domain seam now exists as code**, not just
  as intent (`architecture.md` §7 flagged this). Nothing implements it against a real service yet;
  `UnconfiguredIdentificationService` throws. It exists now because the two identification paths have
  to be separable from the first line of capture code.
- `lib/models/models.dart` — hand-written, no code generation. Each model owns one `fromMap`, and
  that is the only place a column name appears as a string.
- `lib/screens/settings_screen.dart` — the park switcher, plus admin invite management.
- `lib/screens/set_password_screen.dart` — where an invited person chooses their password.
- `lib/screens/observations_screen.dart` — the active park's records, showing **which of the three
  paths** produced each name. A ranger must be able to tell a phone's guess from a colleague's
  determination at a glance.
- `lib/screens/home_shell.dart`, `lib/main.dart` — three-destination shell; `AuthGate` gains the
  invited/password-set routing step.
- `supabase/seed.sql` — extended. `ranger@test.at / password123` is a member of **both** seeded orgs,
  so the multi-park case is on screen after every `db reset` rather than something you must construct.
- `tools/invite_user.ps1` — the service-role half of the invitation flow.

### Problems hit and resolved

- **`permission denied for view observations_current`.** The view was created in migration 4 with no
  `GRANT`. RLS decides *which rows*; the grant decides whether the role may read the relation **at
  all**, and a view does not inherit its base tables' grants. Every user would have hit this on first
  launch. Found by running the migration against a real PostgreSQL 16 + PostGIS 3 instance rather
  than by reading it. Fixed, and **test 19 now asserts that every relation the app reads is readable
  by `authenticated`** — the class of bug, not the instance.
- **The export was emitting rows for a park with no licence metadata.** Technically valid SQL,
  practically the exact thing a publishing partner would query. `dwc_occurrence_export` now excludes
  parks whose dataset metadata is incomplete, which makes its contract airtight: everything in the
  view is publishable as it stands. Consequence: an unconfigured park exports **nothing**, which
  looks like a bug until you read `dwc_export_readiness`. That view is part of the feature.
- **Unverified machine determinations were being exported.** Now they are not, unless a park opts in
  with `export_unverified`. Default false.
- **The seed's human identifications were missing their `source` value** and failed the NOT NULL
  check. Caught by running the seed, not by reading it.

### Verified — and what "verified" means here

Both migrations were **applied to a real PostgreSQL 16 + PostGIS 3** instance with a faithful
stand-in for what Supabase provides (`auth.users`, `auth.uid()`, the `anon`/`authenticated` roles,
and migrations 1–3 replicated verbatim), and the full seed replayed on top.

- `supabase/tests/test_observations_rls.sql` — **9 assertions PASS, 11 negatives correctly rejected.**
  Includes the multi-park ranger seeing both orgs, a Beta user seeing zero Alpha identifications,
  cross-org insert refused by RLS, and the append-only block.
- `supabase/tests/test_org_context_and_export.sql` — **25 assertions PASS, 3 negatives correctly
  rejected.** Park switching, the invitation flow end to end, generalisation at the export boundary
  with the stored coordinate untouched, and the export contract.

**Not verified: the Dart.** There is no Flutter or Dart SDK reachable from the environment this
session ran in, so `flutter analyze` was **not** run and the app was **not** built or launched.
The Dart is written conservatively against the patterns already in this repo, but treat it as
unreviewed until `flutter analyze` is green on a real machine. That is the honest state.

### State after this session

- **Schema:** 10 tables, 4 views, 4 functions, all RLS-locked deny-by-default.
- **App:** compiles-in-principle only (see above). Capture flow, map, camera and sync still unbuilt.
- **Next:** run `flutter analyze`, then `supabase db reset`, then sign in as `ranger@test.at` and
  confirm the Settings switcher offers two parks and the records list changes with it. After that:
  map + GPS + point capture → photo + Storage → the Pl@ntNet adapter behind `IdentificationService`.
- **Known hole:** Supabase **Storage bucket policies are not written**. `observation_media` rows are
  protected by RLS; the photo objects they point at are not. Until that is closed the sovereignty
  claim has a gap, and it is a gap in the thesis' architecture chapter too.

---

## 2026-09-07 — Session 5: member management, the flat three-guess view, testPark_A, record editor

> Same provenance as the 2026-09-06 entry: **written by the thesis agent at René's direction.**
> Nothing committed to git.

### What prompted it

René had the app compiling but Studio showed only `organizations`, `notes` and `memberships` —
**the migrations from session 4 had never been applied.** Writing a migration is not running it, and
the session-4 entry did not say loudly enough that `supabase db reset` was still owed. Corrected
here: `tools/apply_and_verify.ps1` now does the whole thing in one command and proves it worked.

Three asks, plus one correction:

1. **The three determinations as *columns*.**
2. **Admins add and remove people; members add and edit records.**
3. **testPark_A**, a real park to test with.
4. Storage bucket: a placeholder, explicitly not a priority.

### The three-guesses-as-columns question

This is the one worth reading, because it looks like a design reversal and is not.

They stay **rows** in `identifications`. That is what stops them overwriting each other, which is the
thesis' central measurement — and Postgres enforces it by there being no UPDATE grant on that table.
But "give me one row per observation with offline / online / expert side by side" is an entirely
reasonable thing to want, so `observations_wide` provides exactly that as a **read view**:

```
offline_guess  offline_rank  offline_confidence  offline_checklist_masked  offline_at
online_guess   online_rank   online_confidence                             online_at
expert_guess   expert_rank   expert_by  expert_status                      expert_at
accepted_name  accepted_source  accepted_rank  accepted_status
```

Real columns would mean writing the same fact twice and keeping the copies in sync — the exact trap
the July design fell into and warned about in the same breath. A view cannot fall out of sync.
None of these reach GBIF: `dwc_occurrence_export` carries the accepted determination plus
`dwc:previousIdentifications`, and nothing else.

### Migration 6 — `20260907100000_members_wide_view_and_storage.sql`

| Object | Purpose |
|---|---|
| `observations_wide` | the three determinations side by side, most-recent-per-source |
| `park_members(org_id)` | who is in this park, with e-mail and how many records each has recorded. A **function**, not a view, because `memberships` holds a `user_id` and the address lives in `auth.users`, which clients cannot read |
| `remove_member(user_id, org_id)` | admin-only. **Deletes the membership, never the records.** Refuses to remove the last admin; clears the person's active park if it was this one; revokes any stale invitation |
| `set_member_role(user_id, org_id, role)` | promote/demote, with the same last-admin guard |
| `record_identification(...)` | one call = insert a determination and, optionally, accept it. Two round-trips that must not half-succeed |
| storage bucket `observation-photos` | **placeholder.** Org-scoped by *path convention* (`<org_id>/…`) which nothing enforces. Good enough to unblock photo upload, explicitly not good enough for the sovereignty claim |

**Why removal cannot lose data.** `observations.recorded_by` is a plain-text snapshot taken at
capture time — it is what carries `dwc:recordedBy` into the archive. `recorded_by_user_id` is a
convenience link with `on delete set null`. So a record keeps its attribution even if the account is
deleted outright, and removing a *membership* touches neither. Verified: after removing the ranger,
their observation still reads `recorded_by = 'Park Ranger'` and still exports to GBIF.

### App changes

- `lib/screens/record_editor_screen.dart` — **create and edit a record.** Taxon picker fed from the
  park's `checklist_entries` (so an identification is only reachable if the park expects that taxon),
  date/time, coordinates, uncertainty, count, habitat, remarks, sensitivity. On an existing record
  the three determinations are listed read-only; adding one appends, it does not overwrite.
- `lib/screens/members_screen.dart` — who is in the park, with each person's record count shown
  precisely so that removing an active recorder is a considered act. Admins get invite, role change
  and remove, behind a confirmation that says the records stay.
- `lib/models/models_extra.dart` — `ObservationDetail`, `ChecklistTaxon`, `ParkMember`.
- `observations_screen.dart` gains a **+ Record** FAB and tap-to-edit; `settings_screen.dart` gains
  a **People** entry (visible to everyone, actionable by admins).

**Coordinates are typed in, not read from GPS.** There is no `geolocator` in `pubspec.yaml`, and
adding a location plugin is a separate decision with its own permission story. Typing them means the
whole write path is testable today; the GPS button replaces two text fields later and nothing else
changes.

### testPark_A

In `supabase/seed.sql`, so it survives every `db reset` — which is the point, because a reset wipes
`auth.users` and anything made with `provision_org.ps1` disappears with it. That has now bitten this
project twice.

```
admin@park.at  / password123   admin of testPark_A
ranger@park.at / password123   member of testPark_A
ranger@test.at / password123   member of THREE parks — the switcher case
```

testPark_A is configured for publication end to end (dataset name, rights holder, CC-BY licence,
country, boundary), and carries one record with all three determinations, so
`dwc_occurrence_export` produces a signable row for it immediately.

### Verified — and what was NOT

All six migrations plus the full seed were applied to a **real PostgreSQL 16 + PostGIS 3** instance
in the agent's own environment, and exercised:

- `observations_wide` returns the three guesses as columns, correctly
- `park_members()` lists members with e-mail and record counts
- `remove_member()` removes the membership; the record survives with `recorded_by` intact and still
  exports to GBIF
- removing the last admin is refused
- `dwc_occurrence_export` yields a complete row for testPark_A

**Two bugs found by running it**: `park_members()` had an ambiguous `user_id` — PL/pgSQL resolves an
unqualified name to the OUT parameter before the table column, so every reference inside a function
whose OUT parameters share a column name has to be qualified. And the seed used `7e57pa4c-…` as a
UUID, which is not hex.

**NOT verified: nothing was run on René's machine.** The agent cannot reach it — terminals are
click-only under computer use (no typing), and the local Supabase is not reachable from the device
VM. So `supabase db reset` has **not** been run, `flutter analyze` has **not** been run on the
session-5 Dart, and the app has not been launched with it.

### What René has to run

```powershell
.\tools\apply_and_verify.ps1
```

One command: checks Docker and the stack, runs `db reset` (migrations 1–6 + seed), runs both SQL
test suites and counts PASS/FAIL, then prints the three determinations, the GBIF export row, and
anything a publishing partner would reject. Then `flutter analyze` and run the app.

### State

- **Schema:** 10 tables, 6 views, 7 functions, RLS deny-by-default throughout.
- **App:** records can be created and edited; people can be invited, promoted and removed. No map,
  no GPS, no camera, no offline queue, no identification implementation.
- **Next:** capture flow (map + GPS + camera + Storage upload), then the Pl@ntNet adapter behind
  `IdentificationService`.
- **Known holes:** the Storage bucket policies are a placeholder that trusts a path convention
  nothing enforces; no Darwin Core Archive writer; session-5 Dart unanalysed.

---

## 2026-09-08 — Session 6: the save bug, and what René's testing changed about the design

> Same provenance as sessions 4 and 5: **thesis agent, at René's direction.** Nothing committed.

### The bug, and why the error message pointed at the wrong thing

**Symptom.** Saving a record showed *"permission denied for table users"*, which reads as a missing
grant on `observations`. But the record was created anyway — visible after a refresh, and visible
immediately to the other user — just with no species on it. Both the admin and the member hit it.

**Cause.** Exactly one function in the schema was `SECURITY INVOKER` while reading `auth.users`:
`record_identification()`, which looks the caller's e-mail up for `dwc:identifiedBy`.
`SECURITY INVOKER` runs with the **caller's** privileges, and `authenticated` has no `SELECT` on
`auth.users` — correctly; the user table is not client-readable. Every sibling function that touches
`auth.users` (`accept_pending_invitations`, `park_members`, `remove_member`) was already
`SECURITY DEFINER`, which is why none of them ever showed it.

The app saves in two steps — insert the observation, then record the determination. Step 1 succeeded,
step 2 threw. Hence: record exists, species missing, error shown. Nothing was wrong with the RLS
policies or the grants on `observations`.

Reproduced before fixing, by running the two statements the app runs, as `authenticated`.

**Fix (migration 7).** `record_identification()` becomes `SECURITY DEFINER` like its siblings — and
because `SECURITY DEFINER` also bypasses RLS, the organisation check RLS was doing implicitly is now
**explicit** inside the function. Losing that check while gaining the privilege is exactly how a fix
like this becomes a data leak. It also now refuses a determination that names neither a taxon nor a
verbatim name, which would otherwise put a meaningless row in the log.

**The regression test is for the class, not the instance.** `supabase/tests/test_function_privileges.sql`
asserts that (1) no `SECURITY INVOKER` function in `public` reads `auth.users`, and (2) every
`SECURITY DEFINER` function references `auth.uid()` — i.e. re-states the rule RLS is no longer
enforcing for it. Both pass. This is the same move as the missing-`GRANT` test in session 5: the
next function someone writes gets caught by the rule rather than by a user.

### The stale session — signed in as nobody

**Symptom.** On first load, an `admin@park.at` session that was signed in but could see nothing.
Signing out and back in fixed it.

**Cause.** `supabase db reset` wipes `auth.users`, but the JWT on the phone is still signed with the
same secret from `config.toml`, so it keeps validating. The old `admin@park.at` was created by
`provision_org.ps1` with a random UUID; after the reset that UUID no longer exists. `auth.uid()`
returns a user id belonging to nobody, so there are no memberships, so there are no parks. The app
was **authenticated as nobody** and showed a dead end.

**Fix.** `OrgContext` now distinguishes "still loading" from "loaded, and there genuinely is no
park", and the records screen offers **Try again** and **Sign out** with an explanation instead of a
blank list. A failure inside `accept_pending_invitations()` also no longer prevents the park list
from loading — a person who already belongs to a park does not need an invitation claimed to see it.

This will keep happening after every `db reset`, so the app has to handle it rather than the
operator having to remember it.

### What René's testing changed about the design — the important part

> *"I do not really want to add a precise species anyways in the record but instead an image. So
> maybe this was just a dummy run … instead of a species dropdown I will put the image in that place
> and then I or an expert will select the real species based on the AI feedback and AI's certainty
> or uncertainty."*

That is the right workflow and the schema was already built for it — but **the app was enforcing the
opposite**, refusing to save a record without a species. Corrected:

- **A determination is now optional.** A record with no species is a normal state, not a
  half-finished one. It reads as *"Awaiting determination"* in the list, not *"Not determined"*.
- The species dropdown is explicitly marked as the **stand-in for the photograph**, with a disabled
  Photograph card above it showing where the camera goes. It stays afterwards as the manual fallback
  for a record made without a usable photo.
- `comment on table public.observations` now records the intent in the database itself, so the next
  person to read the schema learns it there rather than from a chat log.

The workflow this settles on: **photograph → on-device model proposes → online service proposes →
a person confirms.** Three determinations, appended, never overwritten. Which is what
`identifications` was built to hold.

### The expert role — René's open question, not yet built

> *"probably best by creating an expert role and only users/admins with the expert extension/role
> can fill in that determination field for the person, but then probably only via a dropdown to keep
> standardized names"*

Deliberately **not** implemented — René said he is still thinking about it, and a speculative role in
the schema is worse than none. What is worth recording while it is fresh:

- **The dropdown instinct is right and is already how it works.** A determination points at a
  `taxa` row, and the picker only offers taxa in that park's `checklist_entries`. Free text is
  possible (`verbatim_identification`) but is not what the app writes. Standardised names are not a
  future feature; they are the current design.
- **`memberships.role` is already `check (role in ('admin','member'))`.** Adding `'expert'` is a
  one-line constraint change plus a check inside `record_identification()`. Cheap either way, which
  is a reason not to guess now.
- **The real design question is not the role, it is the verb.** Darwin Core distinguishes *who made
  the identification* (`dwc:identifiedBy`) from *how far it has been checked*
  (`dwc:identificationVerificationStatus`). Right now every human determination is written as
  `verified`, which is wrong for a ranger's own guess. The honest model is probably: anyone may
  record a determination, and it is written `unverified`; an **expert** determination is what sets
  `verified`. That is a smaller and more defensible change than gating who may type at all, and it
  maps onto a Darwin Core term rather than onto a permission invented here.
- **A third option worth considering:** no new role at all — `admin` already means "trusted in this
  park", and a park with five staff may not need a fourth tier. Decide by asking a park, not by
  reasoning about it.

### Verified

All **seven** migrations plus the full seed applied to a real PostgreSQL 16 + PostGIS 3 instance,
then the two statements the app runs, as `authenticated`:

| Suite | Result |
|---|---|
| `test_observations_rls.sql` | 9 pass, 0 fail, 11 expected errors |
| `test_org_context_and_export.sql` | 25 pass, 0 fail, 3 expected errors |
| `test_function_privileges.sql` *(new)* | 5 pass, 0 fail, 2 expected errors |
| **total** | **39 assertions, 0 failures** |

End to end: a record saves, its determination attaches, `observations_current` shows
`Leontopodium nivale / human / verified`; and a record with no species saves and reads as awaiting
determination. Both negatives refused — a non-member cannot write a determination onto another
park's record, and an empty determination is rejected.

**Not verified:** `flutter analyze` on this session's Dart, and nothing was run on René's machine.

### What to run

```powershell
.\tools\apply_and_verify.ps1
```

Migration 7 is new, so this needs the full reset, not `-SkipReset`. It now runs three suites.

### State

- **Schema:** 10 tables, 6 views, 7 functions, 7 migrations.
- **App:** records save with or without a species; determinations append; people can be invited,
  promoted, removed; the park switcher works; a dead session can recover itself.
- **Next:** the capture flow — camera, Storage upload, then the `IdentificationService`
  implementations. That is what turns the species dropdown into the photograph.
- **Known holes:** Storage bucket policies are a placeholder; no Darwin Core Archive writer; the
  expert-role question above is open; session-6 Dart unanalysed.

## 2026-09-13 — Session 7: app work paused on purpose; the model goes first

*Written by the thesis agent. No code changed in this session — this entry exists so that whoever
opens this repository next knows why it stopped where it did.*

### The decision

**App development is paused. It is not blocked, and nothing here is broken.** René asked which was
the better next move — keep building the app, or go after the AI prediction — and the answer was
the model, for a reason worth writing down: *the app is a known quantity and the model is not.*

Everything still open in this repository is work whose outcome nobody doubts. The capture flow will
work. Storage policies will be written. A Darwin Core Archive writer will emit an archive that
validates. None of it can fail in a way that changes the thesis.

The model can. The thesis' central claim is that an offline on-device model, masked to a park's
species checklist, gets close enough to an online service to be worth shipping — and that the
checklist mask itself buys measurable accuracy (proposition P2, ≥ 3 pp). Nobody has measured that
yet. If it turns out to be false, the thesis needs to know now, while there is still time to make
the negative result the finding rather than the failure.

So: find out whether the model works, then come back and perfect the app around what it actually
does.

### Why this repository is at a good stopping point

The app already does the one thing the thesis genuinely needs from it: **it writes real,
org-scoped, append-only field records against a schema verified by execution.** That is the
measuring instrument. 7 migrations, 10 tables, 6 views, 7 functions, 4 test suites, 39 assertions,
0 failures. `identifications` cannot be edited by any client, so the offline guess, the online guess
and the human determination survive independently — which is precisely what makes P1 and P2
measurable from ordinary production records rather than from a laboratory harness.

`model_versions` and `identifications` are already the landing site for whatever the model work
produces. **Nothing in the ML pipeline is waiting on this repository.**

### Where the thesis side actually is

Task 0 — the GBIF coverage check across all 1,050 species-level classes — has been run. The
headline is good: 91 % of species clear 100 field photographs, median 7,235, and the Austrian
held-out test pool is viable. Coverage is not the constraint anyone feared.

The class list was the last blocker and it is **frozen as of 2026-09-13 at 1,025 classes** (thesis
decision D-033): 979 vascular species classes, 45 genus classes, and one aggregate class meaning
*"this is a moss, and it needs an expert"*. Seventy-eight park-list names that GBIF could not settle
mechanically were decided by a stated rule — 31 recovered, 24 merged, 20 excluded with reasons.

**One thing from that work is worth knowing here, because the same trap exists in this app.** The
first version of the name-resolution rule picked whichever candidate had the most Austrian
photographs. It produced *Festuca pratensis* -> *Bromus erectus* and *Ranunculus nemorosus* ->
*Anemone nemorosa*: confident, plausible, and wrong. A count measures how common a taxon is, not how
likely a mapping is. When this repository eventually maps model output onto `taxa` rows, do not
resolve names by popularity — `identifications.scientific_name` is a text snapshot precisely so a
wrong mapping cannot silently rewrite history, but a wrong mapping is still wrong.

None of it touches this repository's code.

### What to do when app work resumes

In this order, and the reasons are in `docs/AGENT_ROLES.md`:

1. **Storage bucket policies.** `observation_media` *rows* are RLS-protected; the photo *objects*
   they point at are not. Until that is closed the data-sovereignty claim has a real hole, and it is
   a hole in the thesis' Chapter 5, not only in the app. Highest-value work outstanding.
2. **The capture flow** — camera → Storage upload → the two `IdentificationService` implementations.
   This is what turns the species dropdown into a photograph, which is what René asked for after
   testing session 6. It is also where the model's output will arrive, so it is worth building once
   the model's output shape is known rather than guessing it now.
3. **`flutter analyze`** on sessions 4–6 Dart — never run in an agent session, no SDK reachable.
4. **The expert-determination question** (`architecture.md`, ADR 008 and the open question in
   session 6). Still open on purpose: a new `expert` role, or gate only which determinations may be
   written `verified` rather than `unverified`. The second maps onto a Darwin Core term
   (`dwc:identificationVerificationStatus`) instead of inventing a permission here — but decide it
   by asking a park, not by reasoning about it.
5. **The Darwin Core Archive writer** (O8). `dwc_occurrence_export` is the contract; the writer is
   the missing half. Validate an archive, do not publish one (D-030).

### Rules that do not change while this is paused

The six non-negotiables in `docs/AGENT_ROLES.md` hold regardless of who touches the repo next.
The two most easily broken by an innocent refactor:

- **`identifications` has no UPDATE grant, for anyone.** That absence *is* the append-only
  guarantee. Adding a grant to "fix" an edit button silently destroys the thesis' ability to measure
  its central claim, and nothing would fail loudly.
- **A `SECURITY DEFINER` function must re-state its org check.** It bypasses RLS, so the rule RLS was
  enforcing has to be written out by hand. This is the bug that broke saving in session 6.

### State

Unchanged from session 6. Working tree uncommitted — René commits himself.

---

## 2026-10-09, 19:49 CEST — Session 8: the thesis model comes to the app (measurement round)

*App agent. Resumes app work after the pause of session 7: the VPS handed over the trained Arm 2
model (`ml-pipeline/arm2_export/README_for_app_agent.md`) for a correctness check and the phone
measurements O3a–O3c. Not the final integration — temperature and per-species thresholds come later.*

### What was built
- **Assets:** the shipped file `large075_plain_int8_weight_only.tflite` (4,425,408 bytes) +
  `labels.csv` (1,004 rows) + the thesis fixtures `phone_reference.json`, `ref_01..05.jpg` —
  copied from the thesis folder (read-only) and verified byte-for-byte against the hashes in
  `phone_reference.json`.
- **`lib/ml/`** — the domain-agnostic engine: bit-exact Pillow resample port, reference
  preprocessing, labels parser, `TfliteClassifier` (tflite_flutter 0.12.1 / LiteRT 1.4.0, 1 thread,
  loaded once, kept alive), FFI probes (CPU pinning, `/proc` memory), memory sampler isolate, and
  the measurement protocol.
- **`OfflineModelIdentificationService`** — first real implementation of the seam (uncalibrated
  softmax, no threshold, first photograph only).
- **`LiteRtJavaBench.kt`** — LiteRT Java API with XNNPACK explicitly off, the guaranteed
  no-delegate reference (MethodChannel).
- **Identify tab** (`model_lab_screen.dart`) replacing Notes in the bar; also reachable from the
  login screen, since the model needs no backend. `MODEL_LAB_AUTORUN` dart-define makes it the
  home screen and runs the protocol by itself.
- **`tools/measure_model.ps1`** — the whole round in one command (see ADR 009, architecture §6).
- Unit tests `test/ml/` pinning the Dart port to Pillow-computed hashes.

### Dead end documented before it happened — the desk study
Before writing any Dart, the reference pipeline was reproduced on the desktop from the handover
files (exact: means Δ 0.00000, logits Δ ≤ 0.0001), which made it possible to *test the obvious
implementation first*. **Naive bilinear resizing — what a Flutter developer reaches for — fails the
handover:** it passes the channel-mean criterion with room to spare but misses the logit tolerance
by up to 64× and loses top-5 agreement, while top-1 stays right on these confident photographs. A
check built only on means and top-1 would have passed a silently skewed pipeline. Hence the
bit-exact port (ADR 009). A second finding: decoder-sized pixel noise (±1 level on 10 % of pixels)
already costs 0.127 logits — the ±0.1 tolerance implicitly demands a bit-identical JPEG decoder,
so the correctness check now hashes every stage against Pillow to say *where* a mismatch comes from.
Reproducible: `tools/model_check/desk_study.py`, output in `docs/measurements/2026-10-09_desk_study/`.

### The delegate question
`tflite_flutter` has no switch to remove a runtime-default delegate, and whether its LiteRT build
applies XNNPACK by default is undocumented (the desktop runtime does: 3× faster than plain kernels
on x86). Rather than assume, one run answers it three ways: the once-per-process XNNPACK log line
attributed to the first interpreter (C1), the Java-API no-XNNPACK reference (C3), and — if XNNPACK
turns out to be the default — Google's TFLite Benchmark Tool with `--use_xnnpack=false` under
`taskset` (René chose "both" for this fallback).

### Verification status — honest
- Python transliterations of the Dart resize logic were checked bit-exact against Pillow (RGB and
  RGBA strides, up/downscale, identity, 13.4× downscale of a 12 MP image).
- **The Dart, Kotlin and PowerShell have NOT been compiled or run by the agent** — the agent's
  sandbox has no Flutter SDK and cannot reach René's machine. `tools/measure_model.ps1` runs
  `flutter analyze` and `flutter test test/ml` before building and stops with the output if
  anything fails. Expect possibly one round trip for compile errors.
- Build risk named in ADR 009: the app uses AGP 9.0.1; tflite_flutter 0.12.1's Gradle file targets
  AGP 8.6. Fallback: `flutter_litert` (source-compatible).

### Noticed, not changed (for later)
- `supabase/seed.sql` seeds `model_versions` with `class_count 1089, temperature 1.42`. The shipped
  model has 1,004 classes and the thesis' fitted temperature is 1.91 (thesis Project_State,
  2026-10-09). Seed data, but it looks like real numbers; align when calibration is integrated.
- The desktop latency in `arm2_export_large075_plain.json` (9.03 ms) was taken with the default
  resolver, which applies XNNPACK — it is not a "no delegate" figure (hint written for the thesis
  agent in `MasterThesis/app_agent_hints/`).

### Pre-flight review — four failures caught before they reached the phone
Because nothing could be compiled here, an independent reviewer agent read every new file against the
verified APIs before handover. It found four defects that would each have cost a full round trip on
René's machine — documented because, in DSR terms, a caught failure is a result:
- **The report could never have arrived.** Flutter logs Dart `print` through `__android_log_print`,
  which formats into liblog's 1024-byte buffer: every logcat message is cut at 1023 bytes. The report
  was chunked at 3,000 characters, so its checksum would have failed on every run. Now 900.
- **The script would not even have parsed on Windows PowerShell 5.1.** It was UTF-8 without BOM and
  contained em dashes; 5.1 reads such files as cp1252, where the dash's last byte becomes U+201D — a
  typographic quote PowerShell treats as a real one, ending double-quoted strings early. Now ASCII.
- **Undefined behaviour in the XNNPACK configuration.** tflite_flutter's `XNNPackDelegateOptions`
  binding struct predates LiteRT 1.4.0's larger `TfLiteXNNPackDelegateOptions`; the runtime would read
  past the allocation (weight-cache path/descriptor fields). C2 now passes no options (LiteRT defaults,
  single-threaded) — which also makes it the same configuration a runtime-default XNNPACK would be.
- **A likely release-build failure:** R8 "Missing class org.tensorflow.lite.gpu.GpuDelegateFactory$Options"
  (litert-gpu packaging; upstream issues open). `android/app/proguard-rules.pro` added.
Also fixed: the Benchmark Tool's warm-up statistics line would have been parsed instead of the timed
one; XNNPACK log lines from other processes could have faked the attribution (now filtered by the app's
PID); a crash of any process aborted the run (now only the app's own); a failing phase now still emits a
partial report; the full device log (other apps' messages) no longer lands in the results folder
(`tools/.cache/`, git-ignored); the build is a universal APK, because `--split-per-abi` raises the
versionCode and the next `flutter run` would have uninstalled the app and its login.

### State
Code complete for the round, unmeasured. **Next: René runs `tools\measure_model.bat` with the S22 on
USB** (no Supabase needed); the agent then writes the measurement report from the raw files.
Working tree uncommitted — René commits himself.

---

## 2026-10-10, 10:52 CEST — Session 8, continued: first run on René's machine

**What ran** (`tools/measure_model.ps1`, logs in
`docs/measurements/2026-10-10_arm2_phone/raw/2026-10-10_103514/`, run started 10:35):
- `flutter pub get`: OK (tflite_flutter 0.12.1, quiver added; crypto and ffi became direct).
- `flutter analyze`: **0 errors, 0 warnings**, 11 infos — the first time the Dart written without an
  SDK (2026-10-09) met a real analyzer. Five infos were in the new code (three redundant
  `dart:typed_data` imports, a constructor style); the other six are pre-existing in screens from
  2026-09 (deprecated `Radio` API, underscores, a null-aware element).
- `flutter test test/ml`: **28/28 passed.** This is the first execution of the Dart Pillow-resample
  port on a real Dart VM: hash-exact against Pillow 12.3.0 on six image sizes, in RGB and RGBA
  stride, plus Python-style rounding and the labels contract.
- `flutter build apk --release`: **FAILED** after 2 min 33 s, in a third-party module:

      Execution failed for task ':tflite_flutter:compileReleaseKotlin'.
      Inconsistent JVM-target compatibility detected for tasks
      'compileReleaseJavaWithJavac' (11) and 'compileReleaseKotlin' (21).

**Cause.** `android/gradle.properties` sets `android.builtInKotlin=false` (Flutter template). Under AGP 9
that makes Flutter apply the Kotlin Gradle Plugin to every plugin module. tflite_flutter 0.12.1 pins its
Java target to 11 but never sets a Kotlin target, so Kotlin falls back to the build JDK (21), and
Kotlin's target-consistency check stops the build. The existing plugins never hit this (they set both
targets); tflite_flutter is the first that does not. Same failure class as flutter_stripe issue #2486
(AGP 9.1.1, JDK 21, identical message). This is the risk ADR 009 named in advance ("tflite_flutter's
Gradle file targets AGP 8.6 … under AGP 9.0.1") — it materialised as a JVM-target mismatch, not as a
Gradle API break.

**Fix** (`android/build.gradle.kts`): for the `tflite_flutter` module only, set the Kotlin compile
tasks' `jvmTarget` to 11 — the module's own Java target, as read from the error. Rejected: turning
the check off globally (`kotlin.jvm.target.validation.mode`) — it would hide the same defect in any
future plugin; switching to `flutter_litert` — a larger change with more bundled runtimes, not
warranted by a one-line build-configuration problem.

**Also fixed, all visible in this run's output:** the failure message did not say where the logs were
(René could not find them); `Tee-Object` wrote the logs as UTF-16 with
"System.Management.Automation.RemoteException" for every empty stderr line; and the build output only
appeared after the build had finished. The script now prints the log folder at start and on any
failure, streams the build output live, and writes UTF-8 logs. The five lint infos in the new code are
cleaned up.

**Not yet verified:** that the fix makes the release build pass, and everything after it (R8 rules,
install, the protocol on the phone). Next: René reruns `tools\measure_model.bat`.

---

## 2026-10-10, ~12:00 CEST — Session 8, continued: second run — the first inference fails; a runtime defect, not a model defect

*App agent, this time on René's machine (Flutter SDK, NDK and the build available — the code was compiled
and the APK inspected here; the phone run itself was not repeated).*

**What ran** (run `docs/measurements/2026-10-10_arm2_phone/raw/2026-10-10_105927/`): `flutter pub get`,
`analyze` (0 errors, 0 warnings, 5 pre-existing infos), `test/ml` 28/28, **the release build passed** — the
Kotlin JVM-target fix of the morning works — install, autorun. O3a was read from the APK (the model entry is
the thesis file, `e0e182a8…`, 4,425,408 bytes, stored uncompressed), the interpreter (C1) was created in
13.7 ms, the M0/M1 memory snapshots were taken. Then the **first `invoke()`** of the correctness check failed:
the app reported `Bad state: failed precondition`; logcat had `E tflite : Input tensor 87 lacks data`.
Nothing after it was measured (correctness, O3b, O3c, 12 MP image, XNNPACK question).

**How the cause was found — each step with its evidence:**
1. *What is tensor 87?* No TFLite runtime on the laptop, so the FlatBuffer was read directly
   (now `tools/model_check/inspect_buffers.py`): INT8 weights `[64,1,1,16]`, input of `DEQUANTIZE` (op 13), and
   its buffer has **no inline data but `offset 2,562,976 / size 1,024`** — stored after the FlatBuffer. 78 of
   149 buffers are stored this way; tensor 87 is the first in execution order; the 11 inline constants before
   it loaded fine. So: the runtime reads inline weights and drops offset-stored ones.
2. *Why does the file look like that?* Every INT8 file of the thesis pipeline (spike and Arm 2) has the
   layout, every FP32 file has none: it is written by **ai-edge-quantizer**, which switches to external
   buffers once the packed weights exceed 256 KB (`model_modifier.py`; no option). The file still declares
   `min_runtime_version 1.15.0`.
3. *Why does the phone drop them when the desk study did not?* TF v2.20.0 source: `InterpreterBuilder`
   resolves an offset only `if (offset > 1 && allocation_)`, silently; the **C API** (`c_api.cc`, what
   tflite_flutter binds) builds it from the bare `Model*` **without the allocation**; Java (JNI) and Python
   build it from the `FlatBufferModel`, which carries it. The desk study ran Python — it could not see this.
4. *Is it fixed anywhere?* LiteRT commit `d17fd00` (2025-11-05) passes the allocation — one week after
   tflite_flutter 0.12.1 shipped with LiteRT 1.4.0. Checked in the **machine code** of
   `TfLiteInterpreterCreate` (`llvm-objdump`, NDK 28.2), register `x5` = allocation: the APK's library and
   LiteRT 1.4.0 and 1.4.1 `mov x5, xzr` (nullptr); **1.4.2 `ldr x5, [x8, #0x10]`** (the fix).

**Dead ends and rejected routes** (details in ADR 010): `Interpreter.fromFile` (same C-API builder);
LiteRT 2.x (no released 2.x AAR contains the `libtensorflowlite_jni.so` tflite_flutter opens — all ten
checked; *[corrected 2026-10-11: this said they ship `libLiteRt.so`; 2.0.x ship other libraries]*);
`flutter_litert`, ADR 009's fallback (meanwhile 3.9.x on LiteRT Next, a different API); the Java API as main
binding (rejected in ADR 009).

**The decision path — documented because it reversed the agent's first recommendation.** The agent first
recommended re-serializing the model with inline weights (TF's `flatbuffer_utils`; lossless in principle,
loads on every runtime). René approved it *on condition* that it fits the thesis, and asked for the check.
The check against `MasterThesis/` turned it around: the thesis ties every Arm 2 result to this file's SHA-256
(all test-set figures are LiteRT logits of `e0e182a8…`; `verify_numbers.py` block ARM2S asserts that the
scored file is the exported one; the handover asks to "confirm it is what the app ships"), invariant 14
forbids any model change after the single test scoring, and the proof that an inline copy computes the same
model needs the pinned training-pool photographs and the checkpoint — 0 of 318 photographs and no checkpoint
are on the laptop, they exist only on the VPS. Meanwhile the runtime fix had been verified in the binary.
**René's decision:** fix the instrument (the runtime), not the measured object; and hand the inline step to
the thesis pipeline **for future exports** (iOS: tflite_flutter 0.12.1 uses TensorFlow Lite 2.12 there, which
cannot read offset-stored weights at all).

**Changed:**
- `android/app/build.gradle.kts`: `litert` **and** `litert-gpu` 1.4.2 (`litert-gpu` 1.4.0's POM pins
  `litert-api` to exactly 1.4.0, so both must move).
- `lib/ml/measurement_protocol.dart`: `kLiteRtArtifact` → 1.4.2 (the report would otherwise misstate the
  runtime); `pubspec.yaml` comment.
- `tools/measure_model.ps1` 1.1: prints the runtime's own `E tflite` lines (app's process only) live, again
  in the summary, and records them as `runtime_errors_logcat` in `measurement.json`. Replayed against the
  failed run's logcat: it catches exactly "Input tensor 87 lacks data" and nothing else.
- New `tools/model_check/inspect_buffers.py`; ADR 010; ADR 009 status amended; `architecture.md` §2, §6.
- Thesis hint (new file): `MasterThesis/app_agent_hints/2026-10-10_arm2_phone_run_runtime_defect.md`.

**Verified here, before the phone:** analyze 0 errors / 0 warnings; `test/ml` 28/28; release build passes
(R8, Kotlin bench against `litert-api` 1.4.2); Gradle resolves the plugin's `litert:1.4.0 -> 1.4.2` and
`litert-gpu:1.4.0 -> 1.4.2`; the new APK's runtime reports `2.22.0-dev0+selfbuilt` and passes the allocation
(`ldr x5, [x8, #0x10]`); the model entry is unchanged. The script is pure ASCII and parses in PowerShell 5.1.

**Not verified:** the phone run. The correctness check against `phone_reference.json` is the test of the
whole chain; until it passes, "fixed" means "the known defect is gone from the binary".

### State
Ready for the third run of `tools\measure_model.bat` (phone on USB). The run of 10:59 stays in
`docs/measurements/` as the record of the failure. Working tree uncommitted — René commits himself.

---

## 2026-10-10, ~12:40 CEST — Session 8, continued: run 3 — the model is correct on the phone; two defects in the measurement tooling

**What ran** (`docs/measurements/2026-10-10_arm2_phone/raw/2026-10-10_120250/`, LiteRT 1.4.2): build,
install and the whole protocol (56 s — app start to DONE, `elapsed_ms` 55,807) without an app error.
*[Corrected 2026-10-11: this said "53 s", which only measured up to the last memory snapshot.]*
- **Correctness: 6/6 PASS.** Max |Δlogit| 0.00006 against the ±0.1 tolerance, top-5 overlap 5/5, channel
  means within 0.000004; decode, resize and crop **bit-identical to Pillow** for all five photographs and the
  synthetic 12 MP image. The runtime reports `2.22.0-dev0+selfbuilt` (LiteRT 1.4.2). ADR 010's fix is thereby
  verified on the device.
- **The XNNPACK question is answered:** C1 created no XNNPACK delegate (logcat verdict `not_default`; the first
  "Created TensorFlow Lite XNNPACK delegate" line came from the explicit C2, which delegated 208 of 209
  nodes). C1 is the "no delegate" configuration Howard et al.'s protocol asks for.

**Defect 1 — the script hung while writing `measurement.json`** (René saw no output for minutes; the process
grew past 7 GB of RAM — observed with `Get-Process` during the session, not stored). Windows PowerShell 5.1
attaches file metadata (`PSPath`, `PSDrive`, `PSProvider`, …) to every line read with `Get-Content`; the
XNNPACK attribution stored such a line, and `ConvertTo-Json -Depth 14` serialized the drive/provider object
graph, which grows with every nesting level: the 59-character probe line becomes 496, 1,776 and 32,527
characters of JSON at depth 1, 2 and 3 (`docs/measurements/2026-10-10_arm2_phone/ps51_json_probe_output.txt`,
`tools/model_check/ps51_json_probe.ps1`). Earlier runs never stored such a line: run 2 aborted before C2
existed. Fix: `[string]` cast (script 1.2), verified on this run's own log — 8 lines, 2,983 characters of
JSON (same probe output). Lost with the hang: `measurement.json` (device facts, the APK/O3a record, the
dumpsys samples taken during classification). Kept: `report_app.json`, `logcat_app.txt`,
`dumpsys_snapshots.txt`, build logs.
*[Corrected 2026-10-11: this said "one 61-character line", "about 18× larger per nesting level",
"1,843 → 32,594 characters" and "50 ms". The line has 59 characters; the growth was ×3.7 and then ×17.7, not
×18 per level; the sizes came from an unstored session probe and depend on the PowerShell session's state —
the stored probe above is the reference; the timing was not stored.]*

**Defect 2 — the X2 was never pinned.** Every pin to cpu 7 returned EINVAL. Qualcomm core control pauses
big cores while the phone idles (read on the device: X2 `active_cpus=0` at idle, `offline_delay_ms=100`),
and the protocol idles 2 s before each configuration. A second bug compounded it: the affinity was
"restored" from `sched_getaffinity`, which omits paused cores, so the main thread stayed locked to
`[0..5]` — C2's 100 "prime" runs all ran on an A710. An adb-shell experiment confirmed the remedy before any
code changed: a busy loop wakes the X2 within ~20 ms, after which pinning holds. René chose
**wake-then-pin**; details and rejected alternatives in ADR 009, amendment 2026-10-10.
*[Provenance, added 2026-10-11: the core-control readings and the wake timing in this paragraph come from adb
output in the 2026-10-10 session and were not stored; `tools/model_check/core_control_check.sh` repeats the
experiment. The stored record of run 4 (`pin_first_errno` 22, pin held after 110–120 ms, every run on cpu 7)
confirms the mechanism independently.]*

**Changed:** `lib/ml/native_probe.dart` (`CpuAffinity.pinWaking`, `CpuTopology.possibleCpus`, a warning on
`get`); `lib/ml/measurement_protocol.dart` (C1/C2/C3 pin by `pinWaking`, a configuration that cannot be
pinned is reported as not measured, affinity reset to every possible CPU, `pin_*` fields in the report);
`tools/measure_model.ps1` 1.2 (the JSON fix; the summary prints NOT MEASURED, turns red when any run left
its core, and shows how long each pin took to hold); ADR 009 amendment.

**Verified here:** `flutter analyze` 0 errors / 0 warnings; `test/ml` 28/28; the script is ASCII and parses
in PowerShell 5.1; the JSON fix on the real log. **Not verified:** the release build with these changes (the
script builds first and stops on any failure) and `pinWaking` inside the app on the phone — the adb
experiment shows the mechanism, the next run's `pin_*` fields and per-run CPU records will show the app.

### State
Next: run 4 of `tools\measure_model.bat` for a complete record; then the measurement report, with a copy
for the thesis in `MasterThesis/app_agent_hints/`. No new model (ADR 010).

---

## 2026-10-10, ~12:50 CEST — Session 8, continued: run 4 — the measurement round is complete

**Run `2026-10-10_122950`** (script 1.2, LiteRT 1.4.2): complete — `measurement.json`, `report_app.json`
(checksum verified), all logs; no app error, no runtime error, `flutter analyze` and `test/ml` green.
- **Correctness 6/6 PASS** in C1, and in C2 and C3 as well; preprocessing bit-identical to Pillow.
- **Pinning works:** in all three X2 configurations the first pin was refused (core parked) and held after
  110–120 ms of waking; in all three A710 configurations it held at once; **100/100 timed runs on the pinned
  core in every configuration.** The wake-then-pin amendment is thereby verified on the device.
- **O3a** 4.43 MB · **O3b** 257,693 kB peak (dumpsys TOTAL PSS) · **O3c** C1 12.17 ms (X2) / 20.95 ms
  (A710) — all met. XNNPACK (C2) 8.55 / 15.77 ms at identical correctness.
- **Finding:** a 12 MP photograph decoded at full resolution peaks at 473,089 kB — above the O3b budget. The
  capture flow needs a reduction step before `app_load` (a train/serve question for the thesis).
- **Repeatability** against run 3: A710 C1/C2 within 1 %; on the X2 run 3 began in a faster transient
  state and settled at the same ~12.2 ms (CPU frequency not recorded).

**Report:** `docs/measurements/2026-10-10_arm2_phone/report.md`, copy for the thesis in
`MasterThesis/app_agent_hints/2026-10-10_arm2_phone_measurement_report.md` (new file; the earlier hint files
are unchanged).

### State
The measurement round of ADR 009 is complete. Open for the capture flow: the CPU configuration (C1 or
XNNPACK), the reduction of camera photographs and EXIF orientation (thesis call), calibration (temperature
and thresholds from the thesis), and dropping the measurement fixtures from release builds. Working tree
uncommitted — René commits.

---

## 2026-10-11 — Session 8, continued: every documented number checked against stored data

*René asked whether all written-down measurements are correct and backed by metadata. Answered by
re-deriving them, not by assurance.*

**How it was checked.**
- `tools/model_check/verify_report_numbers.py` re-derives every figure in the measurement report from the raw
  files (run 122950; run 120250 for repeatability), checks the numbers in this log, ADR 010, `CLAUDE.md` and
  the thesis hint notes against stored evidence, and proves that the thesis copy of the report plus its
  corrigendum equals the corrected report: **127/127** (`docs/measurements/2026-10-10_arm2_phone/
  verify_report_numbers_output.txt`). A mutation test — two numbers in the report changed by one digit —
  made it fail on exactly those claims.
- Evidence that so far existed only as session output is now stored, with the scripts that produce it:
  `docs/measurements/2026-10-10_litert_c_api_check/` — the LiteRT binaries (incl. all ten released 2.x AARs),
  25/25 upstream source facts checked against the raw files (the first reading had gone through a summarising
  web tool), the Gradle resolution, the buffer layout of every thesis `.tflite` — and
  `docs/measurements/2026-10-10_arm2_phone/ps51_json_probe_output.txt`.

**What was wrong — no measured value, but six statements:**
1. Report: "the Java heap is 2–9 MB" — the data say 2,068–9,476 kB (2.1–9.7 MB).
2. Report: "run 122950 holds about 12.2 ms throughout" — its blocks of 10 runs average 12.11–12.38 ms.
3. Report: "logits within 0.00006" — the app stores |Δ logit| rounded to 5 decimals; now "largest logit
   difference 0.00006 (rounded to 5 decimals)".
4. This log: run 3 took "53 s" — it took 56 s (`elapsed_ms` 55,807).
5. This log: "one 61-character line", "about 18× per nesting level" — **the 61 was never counted; the line has
   59 characters**; the growth was ×3.7, then ×17.7; the sizes came from an unstored session probe.
6. ADR 010 and this log: "LiteRT 2.x ships `libLiteRt.so`" — generalised from 2.1.0 alone; 2.0.x ship other
   libraries. The substance — no released 2.x AAR contains `libtensorflowlite_jni.so` — now holds for all ten.

All corrected in place with dated markers. The thesis copy of the report sits in a new-files-only folder, so
it got `MasterThesis/app_agent_hints/2026-10-11_corrigendum_arm2_phone_measurement_report.md`. One check
failure was the check's own defect (run 1's build log is UTF-16) and was fixed in the script.

**Still not stored — said so where it is used:** the core-control readings of the 2026-10-10 adb session (ADR
009 amendment; `tools/model_check/core_control_check.sh` repeats them, and run 4's stored pin record confirms
the mechanism) and the hung script's memory growth (observed with `Get-Process`).

**For the method:** a number typed while explaining is a claim like any other. Figures enter a document only
from a stored file or a re-runnable script; for the measurement figures, the verification script enforces it.

## 2026-10-11 — Session 9: the capture flow MVP (ADR 011)

*René: one area for data input, one for visualisation, settings; Notes removed; a record with a photo the
model grades and a central frame while photographing; the schema's fields with good UI/UX; the most likely
species under the photo, the top 5 with their confidence one tap away; a simple web map with the records'
geometries and a symbology (families, perhaps native vs neophyte) — "reflect critically whether all of this
is a good idea", and build it without Supabase running.*

**The reflection, before any code.** The direction is right: the capture flow is the app's reason to exist
(the "missing centre" of §10), and the frame is not cosmetics — the model sees only the centre square
(ADR 009), so showing that square is accuracy for free. Four parts were deliberately *not* built as asked:
1. **Native vs neophyte** — no table holds it, and a hand-made list would put an unsourced botanical claim
   on the map. It needs a data decision first (e.g. `dwc:establishmentMeans` per checklist entry).
2. **Calibrated confidence** — the app shows raw scores, labelled "not calibrated". The temperature and
   thresholds have to arrive as a verifiable file (thesis question 2), not as a number copied from notes.
3. **A photo reduction step** — the model runs on the photo as taken: the 12 MP path measured on
   2026-10-10. Which reduction matches training is thesis question 1.
4. **Martin + MapLibre** — raster tiles straight from basemap.at and OpenStreetMap need nothing to run.
   Swapping later touches one file.

"80 % without Supabase" held for the code, but nothing that talks to the database has run yet.

**What was built** (details: ADR 011, `docs/architecture.md` §2):
- Tabs **Records · Map · Settings**. The model lab moved into Settings; the Notes screen was deleted (its
  table stays).
- **Camera** (`camera` 0.12.1 / CameraX, maximum resolution) showing the model's square — the outside
  dimmed — plus tap to focus, flash and gallery.
- **The photo loses its GPS position on the device** before anything else happens to it
  (`JpegInfo.stripGps`). The model, Storage and `sha256` all see the same bytes.
- **Suggestion card** under the photo: the top-1, and the top-5 with scores on tap.
- **Determination** from the park checklist, **best-fix GPS** with the device accuracy, a **map picker** as
  the fallback.
- Time, count and details (life stage, habitat, remarks), and sensitivity.
- **Save in four named steps** with partial-failure messages.
- **Map** with family / status colouring, a legend with counts and highlight, and the basemap switch.
- **Records list** shared with the map (`RecordsStore`), with filter chips Awaiting / Suggested /
  Confirmed.

**Corrections on the way — recorded because they are results.**
1. **`exif_stripped` was first going to be an honest flag** (`!hasGps`), because the app could not strip.
   It became actual stripping instead. An honest flag on a photo that still carries the coordinate would
   have sent that coordinate to Pl@ntNet the day the online path is written. Blanking the GPS directory in
   place, rather than re-encoding, keeps the pixels — and with them ADR 009's bit-exact preprocessing.
   Checked with Pillow 12.3.0, which shares no code with the app; the app's output is pinned in fixtures
   (`tools/model_check/check_gps_stripping.py` → `docs/measurements/2026-10-11_gps_stripping/`).
2. **The first "Other families" grey, `#8A8A85`, was chosen by eye — and failed the palette validator**
   against the green slot: colour-blind ΔE 4.5 (target ≥ 8), normal vision 14.2 (floor 15). It was
   replaced by `#5C5B57`, worst pairs 9.2 / 19.8 (`docs/measurements/2026-10-11_map_palette/`). The
   method says to compute colour, not eyeball it; the one colour not computed was the one that failed.
3. **A new record started GPS and the camera at the same moment.** Android answers a second permission
   request, made while the first is on screen, as cancelled — so on the very first record one of the two
   would have failed. They now start one after the other.
4. **"Where am I" kept GPS on behind other tabs**, because the shell keeps the map alive. It now stops when
   the tab is hidden.
5. A test assumed Pillow writes the EXIF segment first; Pillow writes APP0 (JFIF) first.

**Findings for René — not changed, because the seed and schema are the thesis agent's:**
- **The seed's taxa do not share GBIF keys with `labels.csv`.** Gentiana clusii is 5343979 in the seed and
  7270031 in the labels; the model's edelweiss class is subspecies *alpinum*. Only the genus class
  *Hieracium* joins, so almost every suggestion is stored verbatim and cannot be taken over as a
  determination until `taxa` and the checklist are loaded from the label space.
- **`dwc_occurrence_export` drops a record whose accepted determination has no `taxa` row**, and
  `dwc_export_readiness` does not list that as a blocker.

**Verification.**
- `flutter analyze`: 0 errors, 0 warnings. The 3 infos are in older files.
- `flutter test`: **86/86**. 28 from before; 58 new — frame 5, JPEG metadata 12, payloads 12, plant
  domain 13, prepared photo 3, record digests 8, suggestion card 5.
- Release APK: built, 94.1 MB (`docs/measurements/2026-10-11_mvp_build/flutter_build.txt`; run 122950's was 83.6 MB, `docs/measurements/2026-10-10_arm2_phone/raw/2026-10-10_122950/flutter_build.txt` — what was added since is the camera, location, image-picker and map packages with their Android libraries, and the new app code; the 10.5 MB were not broken down further). The new plugins needed no Gradle change under AGP 9.
- **Not run on a phone, not run against Supabase.**

**State.** Next: run the flow on the phone (CLAUDE.md §10, item 4, with its list of device checks). Then
load `taxa` from the label space, then the Pl@ntNet adapter.
