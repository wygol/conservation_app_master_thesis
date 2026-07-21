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

**Result: ISOLATION TEST PASSED (2026-07-21).** On-device verification: `usera@test.at` sees exactly the two Org Alpha notes and can write; `userb@test.at` sees exactly the one Org Beta note. Same table, same database, zero crossover — the CLAUDE.md §6 sovereignty claim is demonstrated, not asserted. Marked as **Milestone 1** (git tag `m1-sovereignty-slice`). Open follow-ups: org onboarding flow (auto-create vs. invite — product decision), registration UX, `notes` → `observations`.
