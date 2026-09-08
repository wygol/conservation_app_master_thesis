# 007 — The Darwin Core export is a contract: everything in it is publishable
Date: 2026-09-06
Status: accepted
Thesis relevance: yes — this is objective O8 and part of the sovereignty claim

## Context

The organisation decides for itself whether anything is published to GBIF. The
thesis does **not** publish: it *validates*. Publishing needs an endorsed
publishing organisation with lead time we may not have, and it would reintroduce
a third-party dependency the thesis deliberately removed. What the thesis claims
is that the archive it generates would pass — and the useful product outcome is
that a park can hand a publishing partner something the partner only has to sign
off, rather than audit.

That target is what makes the design non-obvious. A view that emits every row
with the terms filled in where available is easy, and useless: the partner
discovers the null licences.

## Decision

`dwc_occurrence_export` has a stated contract: **every row in it is publishable
as it stands.** A record that is not ready is absent, and
`dwc_export_readiness` names, per record, what is missing.

Four rules are enforced in the view rather than in application code:

1. **`sensitivity = 'withheld'` never leaves.** No flag, no option.
2. **`sensitivity = 'generalised'` is rounded at the boundary** — two decimal
   degrees, `coordinateUncertaintyInMeters` raised to at least 1000, and
   `dwc:dataGeneralizations` plus `dwc:informationWithheld` state that it was
   done. **The stored coordinate is never degraded**; the park keeps its own
   precision.
3. **Only determinations a person has confirmed are published**, unless the park
   opts in with `organizations.export_unverified`. An unverified model guess is
   precisely the row a publishing partner would query.
4. **Only parks whose dataset-level metadata is complete export at all** —
   `datasetName`, `rightsHolder`, `license`. Those live on `organizations`
   because no occurrence row carries them and a Darwin Core Archive's EML needs
   them.

Column names in the view are the Darwin Core term names verbatim, so writing the
archive is `copy (select … ) to 'occurrence.tsv'` plus a `meta.xml` and an EML
file. Nothing is assembled by hand.

## Rationale

Darwin Core permits exactly one Identification per Occurrence
(`dwc:identificationID`: *"One dwc:Identification object is allowed per
dwc:Occurrence object"*). We keep three or more. The view resolves this the way
the standard intends: the accepted determination becomes the Identification
terms, and the superseded ones are concatenated into
`dwc:previousIdentifications`, which is defined as *"A list of previous
identifications applied to the dwc:Organism, with their date or order, if
known"*. Nothing is lost and nothing is misrepresented.

`basisOfRecord` stays `HumanObservation` even when a model produced the name.
A person stood in front of the plant and observed it; the machine proposed a
label for what the person observed. GBIF's vocabulary defines HumanObservation
as *"A resource describing an observation made by one or more people"*. The
machine's role belongs in the Identification terms, not in the nature of the
record.

## Alternatives rejected

- **Export everything and let the partner filter.** That is the thing the whole
  design is trying to avoid.
- **Generalise sensitive coordinates in storage.** Irreversible, and it destroys
  the park's own data to solve a publication problem.
- **A materialised view.** Premature: nobody has measured a performance problem,
  and a stale export is worse than a slow one.
- **Publishing to GBIF within the thesis.** Rejected — see Context.

## Consequences

- A park with records but no `datasetName` exports **nothing**, which looks like
  a bug until you read `dwc_export_readiness`. That view is therefore part of
  the feature, not a debugging aid, and the admin UI must surface it.
- `export_unverified` defaults to **false**. A park that wants the wider,
  lower-confidence dataset opts in per park.
- Storage objects are not covered. `observation_media` rows are protected by
  RLS; the photo objects they point at are governed by Supabase Storage
  policies, which are separate and **not yet written**. Until they are, the
  sovereignty claim has a hole — see `docs/architecture.md` §8.
