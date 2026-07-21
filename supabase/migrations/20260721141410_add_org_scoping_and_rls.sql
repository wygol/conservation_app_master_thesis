-- === Make notes org-aware, then lock everything down with RLS ===

-- 1. Every note belongs to an organization.
alter table public.notes
  add column org_id uuid references public.organizations (id) on delete cascade;

-- 2. Drop the temporary wide-open access for anonymous clients.
revoke insert, select on public.notes from anon;

-- 3. Turn on RLS. Once on, a table denies everything until a policy allows it
--    (the service_role key bypasses RLS — that's why Studio still shows all rows).
alter table public.organizations enable row level security;
alter table public.memberships  enable row level security;
alter table public.notes        enable row level security;

-- 4. Table privileges for logged-in users. Grants ENABLE an operation;
--    policies below decide WHICH ROWS. Both are required.
grant select, insert on public.notes         to authenticated;
grant select          on public.memberships  to authenticated;
grant select          on public.organizations to authenticated;

-- 5. memberships: you can read only your own membership rows.
create policy "read own memberships"
on public.memberships for select
to authenticated
using ( user_id = auth.uid() );

-- 6. organizations: you can read only orgs you belong to.
create policy "read my organizations"
on public.organizations for select
to authenticated
using ( id in (select org_id from public.memberships where user_id = auth.uid()) );

-- 7. notes: read only notes whose org you belong to.
create policy "read notes in my orgs"
on public.notes for select
to authenticated
using ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );

-- 8. notes: insert only into an org you belong to.
create policy "insert notes in my orgs"
on public.notes for insert
to authenticated
with check ( org_id in (select org_id from public.memberships where user_id = auth.uid()) );