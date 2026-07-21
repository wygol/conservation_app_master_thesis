# 002 — UUID primary keys and `timestamptz` timestamps
Date: 2026-06-26
Status: accepted
Thesis relevance: yes

## Context
The target architecture is offline-first field capture with multi-tenant sync (CLAUDE.md §4–6): devices must be able to create records without connectivity, and rows from many organisations share one database. The first table (`notes`) sets the pattern later inherited by `observations`.

## Decision
Primary keys are `uuid default gen_random_uuid()`; timestamps are `timestamptz` with a server-side `default now()` for `created_at`. Free-text columns use `text` (with `CHECK` constraints where values are constrained), not `varchar(n)`.

## Rationale
- **UUIDs** can be minted on-device while offline with no central coordination and no collision risk across devices/tenants — a sequential integer requires asking the database for the next value, which is exactly what an offline client cannot do.
- **`timestamptz`** stores UTC-aware instants, correct across time zones and DST; matches what Darwin Core `eventDate` handling will need.
- In Postgres, `text` and `varchar` have identical storage/performance; length caps are better expressed as explicit `CHECK` constraints where they are a real rule.

## Alternatives rejected
- **`bigserial` / identity columns** — central sequence breaks offline creation; also leaks row-count/ordering information across API surfaces.
- **Client-supplied timestamps only** — device clocks skew; server `created_at` is kept as an audit anchor. (Consequence below.)
- **`varchar(n)` habit** — no benefit in Postgres; arbitrary caps cause avoidable failures.

## Consequences
`created_at` records **server arrival time, not field-capture time**. Offline capture therefore requires a separate client-supplied `event_date` (Darwin Core) on `observations` — two timestamps with distinct meanings, both kept.
