-- Create the notes table in our `public` schema.
-- literally just a simple table with an id, text, and a timestamp
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  text text not null,
  created_at timestamptz not null default now()
);

-- DEV ONLY: let the anonymous role read/write notes so the no-auth
-- round-trip works. To be REPLACED by auth + org-scoped RLS — this is
-- the opposite of the sovereignty model, on purpose, just to close the loop.
grant insert, select on public.notes to anon, authenticated;