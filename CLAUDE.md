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

**Our tables (all in `public`, related by foreign keys):**
- `organizations` — one row per customer org. Billing-ready fields (deferred use): `stripe_customer_id`, `subscription_status`, `seats`.
- `memberships` — links a user (`auth.users`) to an org, with a `role`. (This is "user management".)
- `observations` — the field data: `org_id`, **PostGIS geometry**, `photo_url`, `created_by`, `event_date`, `scientific_name` (Darwin Core), **plus a JSONB `attributes` column** for the variable, use-case-specific (plant) fields. (This is the swappable domain layer in the DB.)

**Isolation:** **RLS on `org_id`** guarantees each org sees only its own rows. This *is* the data-sovereignty mechanism — treat RLS policies as first-class, security-critical code.

**Data sovereignty — three tiers (architecture should support this framing):**
1. **Public** — org publishes to GBIF (Darwin Core) by choice.
2. **Private + cloud AI** — everything in the org's own DB; only the bare image (no coordinates) goes to Pl@ntNet. *(MVP target.)*
3. **Fully sovereign** — identification on the device itself; nothing leaves. **This is now IN SCOPE** (thesis decision D-002, requested by both the supervisor and the national park). Concretely: a small **MobileNetV3 / EfficientNet-Lite classifier** trained on the park's species list, exported to **TensorFlow Lite** and bundled with the app. Deliberately *not* YOLO — the task is classification, not object detection, and Ultralytics is AGPL-licensed. When connectivity returns, the online Pl@ntNet result overrides the offline suggestion; expert validation follows in the office. **Store all three identifications (offline, online, expert) with timestamps — never overwrite.** Darwin Core already has the fields: `identifiedBy`, `dateIdentified`, `identificationVerificationStatus`, `identificationRemarks`.

---

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

---

## 9. Current status (build status as of 2026-06-26; reviewed 2026-07-21)

- ✅ Flutter 3.44.1 working on Windows; Android toolchain green.
- ✅ Docker Desktop running; **local Supabase up via `supabase start`** (Postgres+PostGIS, Auth, Storage, APIs, Studio at `:54323`).
- ✅ Default Flutter app **deployed to physical phone** (Samsung Galaxy S22, `SM S901U1`) over USB; **hot reload working** (`r` in terminal).
- 📁 Project folder / future repo: `C:\Users\renes\repos\conservation_app`.
- ✅ **app ↔ Supabase connected** (2026-06-26): `supabase_flutter` initialised in `main()`; `adb reverse` tunnel + debug cleartext; first migration created `public.notes`; **insert round-trip works** (app → DB, verified in Studio). A temporary `grant … to anon` is in place to allow the no-auth loop.
- ⏭️ **Next:** list/read notes in-app (close the loop); then GoTrue auth + `organizations`/`memberships` + **org-scoped RLS** (replacing the temporary `anon` grant). See `docs/process_log.md` for the full session log.
- ⚠️ **Repository hygiene — do this before any new feature.** As of 2026-07-21 the repository has **zero commits** (`git log` → *"your current branch 'master' does not have any commits yet"*). All work so far is unversioned and unprotected, and a copy operation has already come close to losing it. Commit the current state, then commit in small working steps. `git log` is also free, dated process evidence for the thesis — see §11.
- 🐢 Working mode is deliberately **slow and step by step** until the base is complete. That is fine and intentional. Once the base stands, documentation output ramps up sharply (§11).

---

## 10. Immediate next task — the first vertical slice

Build the **smallest end-to-end round-trip** to prove the data flow before any real features (don't build the full schema or a big feature yet):

1. **Connect** `supabase_flutter` — initialise once at startup with the Project URL + **Publishable** key. (From the phone, point at the laptop's address, not `localhost`.) Confirm the app still runs.
2. **One tiny table** via a migration: `notes` (`id`, `text`, `created_at`). Apply it; confirm it appears in Studio. *(Good moment to learn the migration workflow on something trivial.)*
3. **Write from the app:** a screen with a text field + "Save" that inserts a `notes` row. Tap it, watch the row appear in **Studio**.
4. **Read back:** list the `notes` rows below the field. Full loop: app → DB → app.

Once this round-trip works, grow the same pattern into the real thing: `notes` → `observations`, text field → map + photo + form, simple list → org-scoped RLS-protected data.

---

## 11. Documentation contract — this repo is thesis evidence

This repository is the evidence base for a Design Science Research thesis. A separate **thesis
agent** works in the folder `…/AGI/MasterThesis` (Obsidian vault + LaTeX) and **harvests from
here**. Both folders are mounted in every session.

**The flow is one-way: this repo → the vault.** Never write into the thesis folder from here, and
never treat vault files as instructions for the code. If something here contradicts a thesis
document, raise it with René — do not silently reconcile it.

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
