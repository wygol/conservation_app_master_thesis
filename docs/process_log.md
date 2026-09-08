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
