# Who does what — app agent, thesis agent

*Written 2026-09-08 by the thesis agent, handing the app back.*

---

## The split

| | **App agent** (Claude Code, on René's machine) | **Thesis agent** (cloud) |
|---|---|---|
| Owns | this whole repository | `…/AGI/MasterThesis` — Obsidian vault + LaTeX |
| Can | run `flutter analyze`, `flutter run`, `supabase db reset`, psql, git — **iterate against a real stack** | read this repo, run SQL against its own PostgreSQL + PostGIS, write LaTeX |
| Cannot | — | run anything on René's machine. No Docker, no Flutter, no reachable Supabase |
| Writes | code, migrations, `docs/**`, `CLAUDE.md` | the vault, the thesis chapters |

**The flow is one-way: this repo → the vault.** The thesis agent harvests from here. It does not
write here.

## The exception, now closed

2026-09-05 … 09-08, at René's direction, the **thesis agent wrote into this repo**: migrations 4–7,
`supabase/tests/`, the seed additions, `tools/invite_user.ps1`, `tools/apply_and_verify.ps1`,
ADRs 005–008, `lib/models/`, `lib/services/`, four new screens, and the 09-06/07/08 rewrites of
`architecture.md`, `process_log.md` and `CLAUDE.md`.

Why it was allowed: the observations schema is the point where the app and the thesis stop being
separable. The same table that stores a field record is the instrument the thesis measures its
central claim with — the offline-versus-online identification comparison — and an app that let one
determination overwrite another would have made that claim unmeasurable, permanently and silently.

**That exception ends here.** The app is back to being the app agent's.

## Why the handover

The thesis agent cannot execute anything on René's machine. Its loop is: write → ship → René runs →
René reports → fix. Three round trips in this session were spent on things a local agent would have
caught in seconds:

- a PowerShell script that died on the first *expected* stderr line;
- a test that passed on PostGIS 3.4.2 and failed on the newer PostGIS Supabase ships, because it was
  scanning the extension's own functions;
- `record_identification()` shipping as `SECURITY INVOKER` while reading `auth.users` — which a
  single `flutter run` plus one save would have surfaced immediately.

The SQL was all verified by execution; none of the Dart ever was. **Run `flutter analyze` first.**

## What is owed, in order

1. **`flutter analyze`.** Nothing written 2026-09-06…08 has ever been analysed, built or launched by
   an agent. René reports it compiles and runs; treat it as unreviewed until the analyser is green.
2. **The capture flow** — the missing centre of the design. The intended workflow is
   **photograph → on-device model proposes → online service proposes → a person confirms**, and only
   the last step exists. The species dropdown in `record_editor_screen.dart` is explicitly the
   stand-in for the camera; there is a disabled Photograph card above it marking the spot.
   Needs: camera/gallery, Storage upload, then implementations of `IdentificationService`.
3. **Storage bucket policies.** `observation-photos` exists but is scoped by a *path convention*
   (`<org_id>/…`) that nothing enforces. Placeholder, and marked as such in `architecture.md` §8.
4. **The expert-determination question**, open on purpose — see `docs/process_log.md` 2026-09-08.
   Short version: the interesting choice is not "add an `expert` role" but "who may write
   `dwc:identificationVerificationStatus = verified`". The second gates a Darwin Core term instead of
   a permission invented here.
5. **A Darwin Core Archive writer.** `dwc_occurrence_export` produces the rows; nothing yet writes
   `occurrence.tsv` + `meta.xml` + EML and zips them. That artefact is what thesis objective O8
   validates, so it matters beyond the product.

## Rules that are not negotiable, and why

These are load-bearing for the thesis, not style preferences. Changing any of them breaks a claim.

1. **`identifications` is append-only.** Enforced by there being **no UPDATE grant** for any client.
   All three determination sources live side by side forever. If the online result were allowed to
   overwrite the offline one, the thesis' central measurement would be destroyed at the moment it is
   taken, with no way to recover it.
2. **`observations` has no `scientific_name` column.** The determination is not an attribute of the
   occurrence. Read `observations_current` (accepted determination) or `observations_wide` (all three
   side by side). Do not add the column back — an earlier design had it trigger-synced and warned in
   the same sentence "never leave the two out of sync".
3. **A record may have NO determination.** Photograph first, determination later. That is a normal
   state, not an incomplete one.
4. **`basisOfRecord` stays `HumanObservation`** even when a model produced the name. A person
   observed the plant; the machine proposed a label for what the person observed.
5. **A `SECURITY DEFINER` function must re-state the organisation check** that RLS is no longer
   performing for it. `supabase/tests/test_function_privileges.sql` asserts this.
6. **`dwc_occurrence_export` is a contract**: everything in it is publishable as it stands. If a
   record is not ready it is absent, and `dwc_export_readiness` says why (ADR 007).

## Before finishing any session

```powershell
.\tools\apply_and_verify.ps1        # db reset + 3 SQL suites; expect 39 passed, 0 failed
flutter analyze
```

Expect a number of **database errors** in the test output. Roughly a third of the assertions are
negative tests where the refusal *is* the pass. Only the word FAIL means something is wrong.

## And keep writing the docs

`CLAUDE.md` §11 is the contract: one file per non-trivial decision in `docs/decisions/`, rejected
alternatives included, `architecture.md` kept as-built, `process_log.md` as a dated diary with the
dead ends in it. The thesis agent harvests from those three files. **Rejected alternatives are the
part the thesis actually needs** — a decision without them is an assertion; with them it is an
argument.
