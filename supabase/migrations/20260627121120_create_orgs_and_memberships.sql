-- Customer organizations (one row per org / tenant).
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now(),
  -- Billing-ready placeholders per CLAUDE.md §5 (no Stripe yet; unused for now).
  stripe_customer_id text,
  subscription_status text,
  seats integer
);

-- Bridge table: which user belongs to which org, and in what role.
create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  org_id  uuid not null references public.organizations (id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now(),
  unique (user_id, org_id)   -- a user can be in a given org only once
);