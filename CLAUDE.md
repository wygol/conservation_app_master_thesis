# CLAUDE.md — Conservation Field-Data App

> Context file for building this project. Most things below are settled *enough* to act on; where something is genuinely open, it's marked. Treat decisions in **§ Tech Stack** and **§ Architecture** as already-made — don't re-litigate them unless I ask. Note: details may still shift; this is the rough direction, not a contract.

---

## 1. What we're building (one paragraph)

A **mobile field-data app for conservation organisations**. A field worker stands at a location, captures a geotagged **point or polygon**, photographs a species, an AI (**Pl@ntNet**) suggests the identification, and the result becomes a structured, geotagged, timestamped record in **the organisation's own database**. Unlike consumer apps (iNaturalist, the Pl@ntNet app), the organisation **owns and controls its data**, sees **only its own records** (no crowd-sourced noise), can connect **its own GIS** to it, and **decides for itself** whether to publish anything to GBIF. The differentiator is **organisation-first data sovereignty + GIS interoperability**, not plant identification (which is not novel).

---

## 2. Context: this is a master's thesis *and* a potential business

- **Academic:** MSc Applied Geoinformatics, Z_GIS, University of Salzburg. Supervisor has approved building it **with commercial intent**. Methodology: **Design Science Research** (build-and-evaluate). Data model aligns to **Darwin Core**.
- **The thesis contribution is the architecture, not the app:** the configurable **data-sovereignty model** + **standards-based GIS interoperability**. Plant ID is one instance of a generic capability.
- **Evaluation (the academic deliverable):** SUS usability test with real users, accuracy assessment of the species suggestions against expert IDs, and — new since 2026-07 — a **comparison of the offline on-device model against the online Pl@ntNet model on the same test set**. That comparison **replaces** the previously planned feature comparison against iNaturalist, QField and ArcGIS Field Maps (scope trade, thesis decision D-002). Do not plan work for the old comparison.
- **Timeline reality:** target submission **end of October / November 2026**. This is deliberately ambitious and is treated as a *goal, not a hard deadline* — overrunning is acceptable, drifting is not. An internship (Kelag) eats part of the summer. So: **core build by late summer; protect Sept–Oct for evaluation + writing.** AI compresses *coding*, not field tests, real users, or writing.

---

## 3. Goals & guiding philosophy (the "why")

- **Personal/business:** this is **founder-training**. A previous startup failed primarily on **distribution**, so the operating lesson is *distribution matters more than product — the value was never the code.* Approach is **market-pull**: validate real pain/willingness-to-pay with actual orgs before scaling marketing. The thesis field-test orgs (the supervisor has **nature-park contacts** = warm intros) are potential **first pilot customers** — validation and evaluation are the same activity.
- **Target customers (the funded end):** public agencies, **national parks**, regulated companies with biodiversity-reporting duties — **not** broke NGOs.
- **Life fit:** I value a **calm, minimalist, low-stress** life. The intended model is **bootstrapped micro-SaaS** (Walling / MicroConf style) — calm, profitable, often-solo — not blitzscale. Keep that ethos in technical choices: **few moving parts, low maintenance.**
- **Honest open question:** whether *plant mapping specifically* is commercially meaningful is unvalidated — to be tested via park conversations. The modular design (below) preserves the option to **swap the use case** later (e.g. utility vegetation management, urban tree cadastre, infrastructure/defect inspection) without rebuilding the core.

---

## 4. Design approach: modular core + swappable domain layer (IMPORTANT)

Keep a clean seam between two parts:

- **Core (domain-agnostic, reusable):** map view, current location, point/polygon capture, photo capture, dynamic form, offline queue + sync, auth, multi-tenancy. **Knows nothing about plants.**
- **Domain layer (swappable):** the observation fields + form definition, the **AI adapter** (Pl@ntNet behind an `IdentificationService` interface — `identify(images) -> suggestions`), and labels.

**Rules:**
- Build the **plant version concretely**, but **behind clean interfaces** — design for *replaceability*, not *configurability*.
- **Do NOT build a generic/configurable "everything engine"** or plugin framework now. That's premature abstraction from imagination. Wait until there are 2–3 real use cases before abstracting.
- Swapping use cases later = change the observation fields/form + write a new AI adapter. The capture flow should not need to change.

---

## 5. Tech stack (settled)

- **Client:** Flutter. **Android is the primary and validated platform** — all development, testing and the field evaluation happen on Android. iOS is *not* a parallel target: at the very end, budget a couple of days to verify the build on a borrowed Mac or a macOS CI runner (e.g. GitHub Actions). Until an iOS build actually exists, state it honestly everywhere as **"cross-platform by design, validated on Android"** — never claim a demonstrated iOS build. Avoid Android-only packages and platform-specific hacks so that end-of-project verification stays cheap.
- **Backend:** **Supabase — the open-source software, self-hosted** (NOT the hosted US service). Gives Postgres + **PostGIS**, GoTrue **Auth**, **Storage**, Realtime, auto REST API (**PostgREST**).
- **Hosting:**
  - **Dev (now):** Supabase **locally** via the CLI (Docker) on my Windows laptop.
  - **Thesis demo / production (later):** self-hosted Supabase on **EU infrastructure** — likely **Elestio-managed on Hetzner** (fire-and-forget ops + EU sovereignty), or own VPS. EU jurisdiction is the point (US CLOUD Act → use EU-jurisdiction infra).
- **AI identification:** **Pl@ntNet API** — send **image only, no coordinates** (coordinates stay in our DB; this is core to the sovereignty story).
- **GIS interoperability:** **GeoServer** exposing the PostGIS layer via **OGC WMS/WFS** → consumed by **QGIS** and a **GeoLibre** web dashboard.
- **Optional dissemination:** **GBIF** via Darwin Core Archive export — the org's choice.
- **Billing (DEFERRED to post-thesis):** **Stripe** — purchase on a **web page** (not in-app, due to Apple rules), a **webhook** (Supabase Edge Function) syncs seat count to the DB, the app only **reads** entitlement. Build the schema **billing-ready** now; don't build Stripe yet.
- **Version control:** GitHub. **Migrations-first** via the Supabase CLI.

### Decisions already made (don't re-open unless asked)
- **Shared multi-tenancy:** ONE database, `org_id` + **Row-Level Security** — **NOT** one instance/database per tenant.
- **Auth = GoTrue** (built into Supabase) — **NOT** Keycloak (no extra service to run).
- **Self-hosted Supabase, not hosted** (sovereignty + thesis framing + supervisor steer).
- **Solo-maintainable is a hard constraint** — prefer fewer moving parts every time.

---

## 6. Architecture & data model

**One PostgreSQL database.** Schemas inside it:
- `auth` — **Supabase-managed**; holds real user accounts (`auth.users`). We don't build this.
- `public` — **ours**; all our tables live here.

> **The data model is no longer a sketch.** It was designed, written, executed against a real
> PostgreSQL + PostGIS instance and tested on 2026-09-05/06. The authoritative description is
> **`docs/architecture.md` §3**; the reasoning is in **`docs/decisions/005–007`**; the migrations are
> `supabase/migrations/20260905120000_*` and `20260906090000_*`. What follows is the summary — where
> it disagrees with `architecture.md`, that file wins.

**Tenancy and people:** `organizations` (one row per **park instance**, now also carrying the park
boundary and the dataset-level metadata a GBIF publishing partner needs) · `memberships` (user ↔ org,
many-to-many, with `role`) · `user_settings` (`active_org_id` — which park a person is currently
recording under) · `invitations` (admin-created, claimed on first sign-in).

**The domain:** `taxa` (the label space, mixed-rank, GBIF backbone keys, *not* org-scoped) ·
`checklist_entries` (org → taxon; what the model's output mask is built from) · `model_versions` ·
`survey_events` (the Humboldt layer, nullable) · `observations` (the `dwc:Occurrence`, point or
polygon, PostGIS) · `identifications` (**append-only**) · `observation_media`.

**Views:** `observations_current` (what the app reads) · `my_parks` · `dwc_occurrence_export` ·
`dwc_export_readiness`.

**Three things to know before touching any of it:**

1. **`observations` has no `scientific_name` column, on purpose.** The determination is not an
   attribute of the occurrence. Read `observations_current`. Do not add the column back — the
   earlier design did have it, kept in sync by a trigger, and warned in the same breath "never leave
   the two out of sync". A view cannot go out of sync.
2. **A record may legitimately have NO determination.** The workflow is photograph first,
   determination later; `observations_current` shows such a record with a null `scientific_name`,
   which means *awaiting determination*, not *broken*. The app must never refuse to save without a
   species — it did, and that was wrong.
3. **`identifications` is append-only, and that is enforced by there being no UPDATE grant.** Not by
   convention, not by careful application code. All three determination sources — `offline_model`,
   `online_service`, `human` — live side by side forever, and superseding is an insert plus
   `accept_identification()`. **This is the thesis' central measurement.** If the online result were
   allowed to overwrite the offline one, the comparison would be destroyed at the moment it is taken.
4. **A person records under exactly ONE active park at a time** (`user_settings.active_org_id`,
   switched in Settings — ADR 005). `memberships` is many-to-many, so "my org" is not a question with
   one answer. The old `memberships.select('org_id').limit(1)` pattern was a coin toss and is gone.

**⚠️ The function-privilege rule, stated because breaking it cost a session.** A `SECURITY INVOKER`
function runs with the **caller's** privileges, and `authenticated` cannot read `auth.users`. Any
function needing the caller's e-mail must be `SECURITY DEFINER` — **and must then re-state the
organisation check that RLS is no longer performing for it**, or it becomes a cross-tenant write
path. `supabase/tests/test_function_privileges.sql` asserts both halves.

**Isolation:** **RLS on `org_id`** guarantees each org sees only its own rows. This *is* the
data-sovereignty mechanism — treat RLS policies as first-class, security-critical code. Note that a
**view needs its own GRANT**: RLS decides which rows, the grant decides whether the relation is
readable at all.

**Data sovereignty — three tiers (architecture should support this framing):**
1. **Public** — org publishes to GBIF (Darwin Core) by choice. The schema is built so a publishing
   partner only has to *sign off*, not audit: see ADR 007 and `dwc_export_readiness`. The thesis
   **validates** an archive; it does not publish one.
2. **Private + cloud AI** — everything in the org's own DB; only the bare image (no coordinates) goes
   to Pl@ntNet. *(MVP target.)*
3. **Fully sovereign** — identification on the device itself; nothing leaves. **IN SCOPE** (D-002).
   Small **MobileNetV3 / EfficientNet-Lite** classifier on the park's species list, exported to
   **TensorFlow Lite** and bundled. Deliberately *not* YOLO — classification, not detection, and
   Ultralytics is AGPL. When connectivity returns the online result is *recorded alongside* the
   offline one — **never over it** — and expert validation follows in the office.

## 7. Conventions & hard rules (for the agent)

- **Schema changes via migrations only.** `supabase migration new …`, write SQL, apply with `supabase db reset` (local). **Append new migrations; never edit applied ones.** Migrations rebuild *structure*, not *data*.
- **Never commit secrets.** `.env` stays in `.gitignore`. The **Publishable** key goes in the Flutter app (safe — RLS protects data). The **Secret** key is server-side only and bypasses RLS — never in app code.
- **Local networking:** the **Android emulator** reaches the laptop's local Supabase at **`http://10.0.2.2:54321`**. A **physical phone** (USB *or* wireless) does **not** — run `adb reverse tcp:54321 tcp:54321` to tunnel the phone's loopback to the laptop, and point the app at **`http://127.0.0.1:54321`**. Re-run `adb reverse` after any replug/reboot/`adb kill-server`. Plain HTTP to local Supabase also needs `android:usesCleartextTraffic="true"` in the **debug** manifest only (`android/app/src/debug/AndroidManifest.xml`).
- **Keep the core domain-agnostic.** Plant-specific logic lives in the domain layer behind interfaces (`IdentificationService` for the AI). No plant assumptions baked into core capture/sync/map widgets.
- **Don't over-engineer.** Clean seams, not configurable frameworks. Concrete first.
- **Respect the thesis-vs-commercial split.** Defer Stripe billing and polished self-service admin UI unless I ask. Thesis critical path = working capture app + sovereign/interoperable architecture + evaluation.
- **Styling:** default **Material 3** with one `ColorScheme.fromSeed` seed colour. Clean and functional beats flashy for a B2B field tool; polish UI only after functionality + pain are validated.

---

## 8. Working preferences

- I'm a capable learner but **new to Flutter/Dart** — explain the *reasoning* and trade-offs, not just code. I want to understand the system, not copy-paste blindly.
- Be **honest and critical**: flag risks, push back on bad ideas, surface trade-offs. Don't just agree.
- I do the architecture and lean on AI for implementation — so prioritise clear structure and clean seams I can reason about.
- Prefer small, verifiable steps over big drops.
- **I make all git commits myself.** Agents never commit (nor push, tag or rewrite history) — leave the
  working tree uncommitted and suggest a commit message instead.
- **The thesis folder (`…/AGI/MasterThesis`) is read-only for the app agent.** Read and use it freely,
  never change anything in it. The single exception: notes for the thesis agent go into the subfolder
  `MasterThesis/app_agent_hints/` (new files only).

---

## 9. Current status (build status as of 2026-09-06)

- ✅ Flutter 3.44.1 on Windows; Android toolchain green; local Supabase up via `supabase start`.
- ✅ App on the physical phone (Samsung Galaxy S22); dev networking via `adb reverse`
  (`tools/dev_connect.ps1`).
- ✅ **Milestone 1 — auth + org-scoped RLS, verified on device (2026-07-21).** Two-user/two-org
  isolation test passed. GoTrue email login, public self-signup disabled (ADR 004).
- ✅ **Observations schema (2026-09-05/06).** PostGIS enabled; `taxa`, `checklist_entries`,
  `model_versions`, `survey_events`, `observations`, `identifications`, `observation_media`, plus
  `observations_current`. **Darwin Core aligned; the determination log is append-only.**
- ✅ **Active-park context, invitations, Darwin Core export (2026-09-06).** `user_settings`,
  `invitations`, `my_parks`, `dwc_occurrence_export`, `dwc_export_readiness`, and the functions
  `set_active_org`, `accept_pending_invitations`, `accept_identification`,
  `observation_is_within_org_boundary`. ADRs 005–007.
- ✅ **Automated isolation and integrity tests** — `supabase/tests/`. **34 assertions pass, 14
  negative tests correctly rejected**, against a real PostgreSQL 16 + PostGIS 3. This is what ADR 003
  said "should later get automated tests"; it now exists, and it covers the **multi-park** person,
  not just two isolated single-park users.
- ✅ **Seed extended**: `ranger@test.at / password123` belongs to *both* seeded parks, so the
  multi-park case is on screen after every `db reset`.
- ✅ **Flutter layer for the above**: `OrgContext`, `IdentificationService` (interface only),
  models, `SettingsScreen` with the park switcher, `SetPasswordScreen`, `ObservationsScreen`,
  `HomeShell`, `AuthGate` routing.
- ⚠️ **The 2026-09-06 Dart has NOT been analysed, built or launched.** It was written in an
  environment with no Flutter/Dart SDK. `flutter analyze` first.
- ⚠️ **Supabase Storage bucket policies are not written.** Photo *rows* are RLS-protected; photo
  *objects* are not. The one real hole in the sovereignty claim.
- ✅ **On-device model integrated for the measurement round (2026-10-09, ADR 009)** — thesis
  Arm 2 file in `assets/model/`, bit-exact Pillow preprocessing (`lib/ml/`), offline
  `IdentificationService` (uncalibrated, no threshold), Identify tab, Kotlin Java-API reference,
  `tools/measure_model.ps1`. Run 1 (2026-10-10, 10:35): `flutter analyze` 0 errors, **unit tests
  28/28** (Pillow port verified on a real Dart VM); release build failed on a tflite_flutter Kotlin
  JVM-target mismatch under AGP 9 — fixed in `android/build.gradle.kts` (confirmed by run 2).
  Run 2 (10:59): build, install and O3a fine, then the **first inference failed** ("Input tensor 87
  lacks data"): LiteRT 1.4.0's C API loads the model's offset-stored weights as empty tensors.
  **Fixed by raising the runtime to LiteRT 1.4.2 (ADR 010); the model file is unchanged.**
  Run 3 (12:02): **correctness 6/6 PASS on the phone** (logits within 0.00006 of the desktop
  reference, preprocessing bit-identical to Pillow) — the fix holds. Two tooling defects found and
  fixed: the script hung writing `measurement.json` (PowerShell 5.1), and the X2 could not be
  pinned because core control pauses it while idle (wake-then-pin, ADR 009 amendment).
  ✅ **Run 4 (12:29) complete — the measurement round is done:** correctness 6/6, O3a 4.43 MB,
  O3b 257,693 kB peak, O3c 12.17 ms (X2) / 20.95 ms (A710) — all met on the S22. Finding: a 12 MP
  photo decoded at full resolution peaks at 473,089 kB (over budget) → the capture flow needs a
  reduction step. Report: `docs/measurements/2026-10-10_arm2_phone/report.md` (copy in
  `MasterThesis/app_agent_hints/`). Details: process log, session 8.
- 📄 Docs live: `docs/architecture.md` (as-built, updated 2026-10-10), `docs/decisions/001–010`,
  `docs/process_log.md` (sessions 1–8).
- ⏭️ **Next:** see §10.
- **Not built:** capture flow (map/GPS/camera/photo/offline queue/sync), online (Pl@ntNet)
  `IdentificationService`, calibration/thresholds in the app, Darwin Core Archive writer,
  GeoServer/OGC, Stripe, iOS build.
- Numbering trap: the repo's "Milestone 1" (sovereignty slice) is **not** M1 in the thesis vault
  (requirements).

## 10. Immediate next task

*(The original §10 described the first `notes` round-trip. That was completed on 2026-06-26 and is
kept only as the reference pattern in `screens/notes_screen.dart`.)*

**Right now, in order:**

0. ✅ **Done 2026-10-10 (run 4; report in `docs/measurements/2026-10-10_arm2_phone/report.md`).**
   The phone measurement round of the thesis model — kept here as the procedure for re-runs. Phone
   on USB, then
   `.\tools\measure_model.bat` — no Supabase needed. It analyzes, unit-tests, builds the release
   APK, measures O3a in the APK, runs the protocol on the phone (correctness vs the thesis'
   `phone_reference.json`, O3b memory, O3c latency C1/C2/C3 on the X2 and an A710 core, 12 MP
   memory reading) and writes raw results to `docs/measurements/<date>_arm2_phone/raw/`. The agent
   then writes the report (TBD for anything not measured; never estimated) — copy for the thesis in
   `MasterThesis/app_agent_hints/` (the only place the app agent writes in the thesis folder).
   Afterwards a normal `flutter run` puts the usual app back on the phone.
1. **`flutter analyze`.** The 2026-09-06 Dart was written in an environment with no Flutter or Dart
   SDK, so it has never been analysed, built or launched. Treat it as unreviewed until this is green.
   (Step 0's script runs it too.)
2. **`.\tools\apply_and_verify.ps1`** — one command: `db reset`, all three SQL suites, PASS/FAIL
   count, then a look at testPark_A. Expect **39 assertions passed, 0 failed** and a number of
   *expected* database errors: roughly a third of the assertions are negative tests where the
   refusal IS the pass.
3. Sign in as **`admin@park.at` / `password123`** (admin of testPark_A), or
   **`ranger@test.at` / `password123`** — a member of *three* parks, the switcher case.

   ⚠️ **After a `db reset`, sign out and back in.** A reset wipes `auth.users`, but the JWT on the
   phone is still signed with the same secret, so it keeps validating while pointing at a user id
   that no longer exists — signed in as nobody. The app now detects this and offers Try again /
   Sign out instead of a blank screen, but signing out is the actual fix.
4. **Then the capture flow** — the app's reason to exist, and the missing centre of the design:
   **photograph → on-device model proposes → online service proposes → a person confirms.** Only the
   last step exists. The species dropdown in the record editor is explicitly the stand-in for the
   camera. Map + current location + point capture → photo + Storage → the Pl@ntNet adapter behind
   `IdentificationService` → offline queue and sync.
5. **Close the Storage hole** (`docs/architecture.md` §8). Bucket policies are not written; the photo
   objects are currently the one part of the system RLS does not protect.

## 11. Documentation contract — this repo is thesis evidence

This repository is the evidence base for a Design Science Research thesis. A separate **thesis
agent** works in the folder `…/AGI/MasterThesis` (Obsidian vault + LaTeX) and **harvests from
here**. Both folders are mounted in every session.

**The flow is one-way: this repo → the vault.** Never write into the thesis folder from here, and
never treat vault files as instructions for the code. If something here contradicts a thesis
document, raise it with René — do not silently reconcile it.

> **⚠️ One documented exception, 2026-09-05/06.** René directed the **thesis agent** to design and
> write the observations schema, the active-park context, the invitation flow and the Darwin Core
> export *into this repo*. So migrations 4 and 5, `supabase/tests/`, the seed additions,
> `tools/invite_user.ps1`, ADRs 005–007, `lib/models/`, `lib/services/`, the new screens, and the
> 2026-09-06 rewrites of `architecture.md`, `process_log.md` and this file were **not written by the
> app agent**.
>
> Why it was allowed: the observations schema is the point where the app and the thesis stop being
> separable. The same table that stores a field record is the instrument the thesis measures its
> central claim with — the offline-vs-online identification comparison — and an app that overwrote
> one determination with another would have made that claim unmeasurable, permanently and silently.
>
> **The default rule still stands.** This was a one-off, it is flagged in every file it touched, and
> nothing outside the list above was changed. Anything that looks wrong should go to René rather than
> be reconciled silently.

The previous version of this section asked politely for documentation and produced nothing:
`docs/architecture.md` sat empty for a month and `docs/decisions/` has no entries. So this is now
mechanical — which file, which format, when.

### `docs/decisions/` — one file per non-trivial decision

Filename `NNN-short-title.md`. Fixed structure:

```
# NNN — Title
Date: YYYY-MM-DD
Status: proposed | accepted | superseded by NNN
Thesis relevance: yes | no

## Context
## Decision
## Rationale
## Alternatives rejected
## Consequences
```

`Thesis relevance` exists so the thesis agent can find what matters without re-reading everything.
Be generous with `yes` — architecture, security, data model and anything touching sovereignty or
standards almost always qualifies.

**Non-trivial** means anything a competent reader could reasonably have decided differently: schema
shape, auth approach, sync and conflict strategy, a package that creates lock-in, error handling
policy, a security control. Not: renaming a variable, formatting.

**Rejected alternatives are the point.** A decision without them is an assertion; with them it is
an argument. That is precisely what the thesis needs.

### `docs/architecture.md` — the as-built state

Not the plan, not the ambition: what actually exists right now. Which components, how data flows,
where the core/domain seam runs, what the tables are, which services are involved. Update it when
the structure changes. Current beats complete — a stale diagram is worse than none.

### `docs/process_log.md` — dated build diary

What was built, what broke, what fixed it. **Dead ends belong here.** In Design Science Research a
documented failure is a result, not an embarrassment — "we tried X, it failed because Y, so we did
Z" is exactly the reasoning the thesis has to show.

### Commits are documentation

Write meaningful commit messages. `git log` then becomes free, dated process evidence for the
thesis at zero extra effort. Commit in small working steps.

### Never invent numbers

Latency, model accuracy, file sizes, sync durations — every measured value travels with *how* it
was measured. If it has not been measured, write `TBD`. Nothing invented ever reaches the thesis.
