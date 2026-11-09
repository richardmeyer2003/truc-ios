-- TURC roster foundation. Hosted changes are applied through a recorded migration.
-- No student/authentication seed records are part of this schema.
create schema if not exists turc_private;
create extension if not exists btree_gist with schema extensions;
set search_path = public, extensions, pg_catalog;
revoke all on schema turc_private from public, anon, authenticated;
grant usage on schema turc_private to authenticated, service_role;

create table public.turc_accounts (
  user_id uuid primary key references auth.users(id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1
);
create table public.turc_districts (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 160),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1
);
create table public.turc_schools (
  id uuid primary key default gen_random_uuid(),
  district_id uuid not null references public.turc_districts(id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 160),
  timezone text not null default 'America/Los_Angeles',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1,
  unique (id, district_id)
);
create index turc_schools_district_idx on public.turc_schools(district_id);
create table public.turc_memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.turc_accounts(user_id) on delete restrict,
  district_id uuid not null references public.turc_districts(id) on delete restrict,
  school_id uuid,
  role text not null check (role in ('admin', 'staff', 'parent')),
  active boolean not null default true,
  can_assign_badges boolean not null default false,
  can_generate_qr boolean not null default false,
  can_print_badges boolean not null default false,
  can_issue_replacements boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1,
  foreign key (school_id, district_id) references public.turc_schools(id, district_id) on delete restrict,
  check (school_id is not null or role = 'admin'),
  check (role = 'staff' or not (can_assign_badges or can_generate_qr or can_print_badges or can_issue_replacements))
);
create unique index turc_memberships_district_unique on public.turc_memberships(user_id, district_id) where school_id is null;
create unique index turc_memberships_school_unique on public.turc_memberships(user_id, school_id, role) where school_id is not null;
create index turc_memberships_district_idx on public.turc_memberships(district_id);
create index turc_memberships_school_district_idx on public.turc_memberships(school_id, district_id);
create index turc_memberships_active_user_idx on public.turc_memberships(user_id, district_id, school_id, role) where active;

create table public.turc_school_years (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.turc_schools(id) on delete restrict,
  label text not null check (length(btrim(label)) between 1 and 40),
  starts_on date not null,
  ends_on date not null,
  active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1,
  check (ends_on >= starts_on),
  unique (school_id, label),
  unique (id, school_id),
  exclude using gist (school_id with =, daterange(starts_on, ends_on, '[]') with &&)
);
create unique index turc_one_active_year_per_school on public.turc_school_years(school_id) where active;
create table public.turc_students (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.turc_schools(id) on delete restrict,
  external_student_id text not null check (length(btrim(external_student_id)) between 1 and 80 and external_student_id = btrim(external_student_id)),
  first_name text not null check (length(btrim(first_name)) between 1 and 100),
  last_name text not null check (length(btrim(last_name)) between 1 and 100),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1,
  unique (school_id, external_student_id),
  unique (id, school_id)
);
create index turc_students_roster_idx on public.turc_students(school_id, last_name, first_name, id);
create table public.turc_enrollments (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.turc_schools(id) on delete restrict,
  student_id uuid not null,
  school_year_id uuid not null,
  grade text check (length(grade) <= 40),
  classroom text check (length(classroom) <= 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1,
  foreign key (student_id, school_id) references public.turc_students(id, school_id) on delete restrict,
  foreign key (school_year_id, school_id) references public.turc_school_years(id, school_id) on delete restrict,
  unique (student_id, school_year_id)
);
create index turc_enrollments_year_school_idx on public.turc_enrollments(school_year_id, school_id);
create index turc_enrollments_school_idx on public.turc_enrollments(school_id);
create index turc_enrollments_student_school_idx on public.turc_enrollments(student_id, school_id);
create table public.turc_guardian_links (
  id uuid primary key default gen_random_uuid(),
  guardian_user_id uuid not null references public.turc_accounts(user_id) on delete restrict,
  school_id uuid not null references public.turc_schools(id) on delete restrict,
  student_id uuid not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1,
  foreign key (student_id, school_id) references public.turc_students(id, school_id) on delete restrict,
  unique (guardian_user_id, student_id)
);
create index turc_guardian_links_student_school_idx on public.turc_guardian_links(student_id, school_id);
create index turc_guardian_links_school_idx on public.turc_guardian_links(school_id);
create index turc_guardian_links_active_user_idx on public.turc_guardian_links(guardian_user_id, school_id, student_id) where active;

-- Import execution remains a trusted-server operation in the next milestone.
create table public.turc_import_jobs (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.turc_schools(id) on delete restrict,
  school_year_id uuid not null,
  requested_by uuid not null references public.turc_accounts(user_id) on delete restrict,
  request_id uuid not null,
  status text not null check (status in ('preview', 'invalid', 'committed', 'expired')),
  row_count integer not null check (row_count between 0 and 1000),
  summary jsonb not null default '{}'::jsonb check (jsonb_typeof(summary) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  row_version bigint not null default 1,
  foreign key (school_year_id, school_id) references public.turc_school_years(id, school_id) on delete restrict,
  unique (school_id, request_id)
);
create index turc_import_jobs_year_school_idx on public.turc_import_jobs(school_year_id, school_id);
create index turc_import_jobs_requester_idx on public.turc_import_jobs(requested_by);
create table public.turc_audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid,
  district_id uuid references public.turc_districts(id) on delete restrict,
  school_id uuid references public.turc_schools(id) on delete restrict,
  relation_name text not null,
  record_id uuid not null,
  operation text not null check (operation in ('INSERT', 'UPDATE', 'DELETE')),
  changed_fields text[] not null default '{}',
  occurred_at timestamptz not null default now()
);
create index turc_audit_school_time_idx on public.turc_audit_events(school_id, occurred_at desc);
create index turc_audit_district_time_idx on public.turc_audit_events(district_id, occurred_at desc);

-- All lookups use the authenticated caller, not a user-supplied user ID or JWT role.
-- Definer helpers are private because membership RLS must not recursively query itself.
create function turc_private.active_user() returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.turc_accounts a join auth.users u on u.id = a.user_id
    where a.user_id = (select auth.uid()) and a.active and u.deleted_at is null
      and not coalesce(u.is_anonymous, false)
      and (u.banned_until is null or u.banned_until <= now())
  );
$$;
create function turc_private.district_admin(p_district uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.active_user() and exists (
    select 1 from public.turc_memberships m where m.user_id = (select auth.uid())
      and m.district_id = p_district and m.school_id is null and m.role = 'admin' and m.active
  );
$$;
create function turc_private.school_admin(p_school uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.active_user() and exists (
    select 1 from public.turc_schools s where s.id = p_school and (
      turc_private.district_admin(s.district_id) or exists (
        select 1 from public.turc_memberships m where m.user_id = (select auth.uid())
          and m.school_id = s.id and m.role = 'admin' and m.active
      )
    )
  );
$$;
create function turc_private.school_member(p_school uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.active_user() and exists (
    select 1 from public.turc_memberships m
    join public.turc_schools s on s.id = m.school_id
    join public.turc_districts d on d.id = s.district_id
    where m.user_id = (select auth.uid()) and m.school_id = p_school
      and m.role = any(p_roles) and m.active and s.active and d.active
  );
$$;
create function turc_private.read_school(p_school uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.school_admin(p_school)
    or turc_private.school_member(p_school, array['staff', 'parent']);
$$;
create function turc_private.read_district(p_district uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.district_admin(p_district) or (turc_private.active_user() and exists (
    select 1 from public.turc_schools s where s.district_id = p_district and turc_private.read_school(s.id)
  ));
$$;
create function turc_private.linked_guardian(p_student uuid, p_school uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.school_member(p_school, array['parent']) and exists (
    select 1 from public.turc_guardian_links g where g.guardian_user_id = (select auth.uid())
      and g.student_id = p_student and g.school_id = p_school and g.active
  );
$$;
create function turc_private.read_student(p_student uuid, p_school uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.school_admin(p_school)
    or (turc_private.school_member(p_school, array['staff']) and exists (
      select 1 from public.turc_students s where s.id = p_student and s.school_id = p_school and s.active
    )) or turc_private.linked_guardian(p_student, p_school);
$$;
create function turc_private.manage_membership(p_district uuid, p_school uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select turc_private.district_admin(p_district)
    or (p_school is not null and turc_private.school_admin(p_school));
$$;

-- Client writes cannot move records between tenants or forge timestamps/versions.
create function turc_private.prepare_record() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare v_column text;
begin
  if TG_OP = 'UPDATE' then
    foreach v_column in array TG_ARGV loop
      if to_jsonb(new)->v_column is distinct from to_jsonb(old)->v_column then
        raise exception 'Record identity and scope are immutable' using errcode = '23514';
      end if;
    end loop;
    new.created_at := old.created_at;
    new.row_version := old.row_version + 1;
  else
    new.created_at := statement_timestamp();
    new.row_version := 1;
  end if;
  new.updated_at := statement_timestamp();
  return new;
end;
$$;
create function turc_private.validate_school() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'Unknown IANA timezone' using errcode = '23514';
  end if;
  return new;
end;
$$;
create function turc_private.validate_guardian() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.active and not exists (select 1 from public.turc_memberships m
    join public.turc_accounts a on a.user_id = m.user_id
    where m.user_id = new.guardian_user_id and m.school_id = new.school_id
      and m.role = 'parent' and m.active and a.active) then
    raise exception 'An active Parent membership is required for a guardian link' using errcode = '23514';
  end if;
  return new;
end;
$$;
create function turc_private.audit_record() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_new jsonb; v_old jsonb; v_row jsonb; v_school uuid; v_district uuid; v_fields text[];
begin
  if TG_OP <> 'DELETE' then v_new := to_jsonb(new); end if;
  if TG_OP <> 'INSERT' then v_old := to_jsonb(old); end if;
  v_row := coalesce(v_new, v_old);
  v_school := (v_row->>'school_id')::uuid;
  v_district := (v_row->>'district_id')::uuid;
  if TG_TABLE_NAME = 'turc_districts' then v_district := (v_row->>'id')::uuid; end if;
  if TG_TABLE_NAME = 'turc_schools' then v_school := (v_row->>'id')::uuid; end if;
  if v_school is not null and v_district is null then
    select district_id into v_district from public.turc_schools where id = v_school;
  end if;
  select coalesce(array_agg(k order by k), '{}') into v_fields from jsonb_object_keys(v_row) k
    where k not in ('created_at', 'updated_at', 'row_version')
      and (TG_OP <> 'UPDATE' or v_new->k is distinct from v_old->k);
  insert into public.turc_audit_events(actor_user_id, district_id, school_id, relation_name, record_id, operation, changed_fields)
    values (auth.uid(), v_district, v_school, TG_TABLE_NAME,
      coalesce((v_row->>'id')::uuid, (v_row->>'user_id')::uuid), TG_OP, v_fields);
  if TG_OP = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger turc_accounts_prepare before insert or update on public.turc_accounts for each row execute function turc_private.prepare_record('user_id');
create trigger turc_districts_prepare before insert or update on public.turc_districts for each row execute function turc_private.prepare_record('id');
create trigger turc_schools_prepare before insert or update on public.turc_schools for each row execute function turc_private.prepare_record('id', 'district_id');
create trigger turc_schools_validate before insert or update on public.turc_schools for each row execute function turc_private.validate_school();
create trigger turc_memberships_prepare before insert or update on public.turc_memberships for each row execute function turc_private.prepare_record('id', 'user_id', 'district_id', 'school_id');
create trigger turc_years_prepare before insert or update on public.turc_school_years for each row execute function turc_private.prepare_record('id', 'school_id');
create trigger turc_students_prepare before insert or update on public.turc_students for each row execute function turc_private.prepare_record('id', 'school_id');
create trigger turc_enrollments_prepare before insert or update on public.turc_enrollments for each row execute function turc_private.prepare_record('id', 'school_id', 'student_id', 'school_year_id');
create trigger turc_guardians_prepare before insert or update on public.turc_guardian_links for each row execute function turc_private.prepare_record('id', 'school_id', 'student_id', 'guardian_user_id');
create trigger turc_guardians_validate before insert or update on public.turc_guardian_links for each row execute function turc_private.validate_guardian();
create trigger turc_imports_prepare before insert or update on public.turc_import_jobs for each row execute function turc_private.prepare_record('id', 'school_id', 'school_year_id', 'requested_by', 'request_id');

do $$ declare t text; begin
  foreach t in array array['turc_accounts','turc_districts','turc_schools','turc_memberships','turc_school_years','turc_students','turc_enrollments','turc_guardian_links','turc_import_jobs'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function turc_private.audit_record()', t || '_audit', t);
  end loop;
  foreach t in array array['turc_accounts','turc_districts','turc_schools','turc_memberships','turc_school_years','turc_students','turc_enrollments','turc_guardian_links','turc_import_jobs','turc_audit_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on table public.%I to service_role', t);
  end loop;
end $$;
revoke all on all functions in schema turc_private from public, anon, authenticated;
grant execute on function turc_private.active_user(), turc_private.district_admin(uuid), turc_private.school_admin(uuid),
  turc_private.school_member(uuid, text[]), turc_private.read_school(uuid), turc_private.read_district(uuid),
  turc_private.linked_guardian(uuid, uuid), turc_private.read_student(uuid, uuid), turc_private.manage_membership(uuid, uuid)
  to authenticated;
-- Trigger execution does not require callers to have direct EXECUTE privileges.
grant select on public.turc_accounts, public.turc_districts, public.turc_schools,
  public.turc_memberships, public.turc_school_years, public.turc_students, public.turc_enrollments,
  public.turc_guardian_links, public.turc_import_jobs, public.turc_audit_events to authenticated;
grant update(display_name) on public.turc_accounts to authenticated;
-- No browser DELETE privilege: archive records through their active flag.
grant update(name, active) on public.turc_districts to authenticated;
grant insert(id, district_id, name, timezone, active), update(name, timezone, active) on public.turc_schools to authenticated;
grant insert(id, user_id, district_id, school_id, role, active, can_assign_badges, can_generate_qr, can_print_badges, can_issue_replacements),
  update(role, active, can_assign_badges, can_generate_qr, can_print_badges, can_issue_replacements) on public.turc_memberships to authenticated;
grant insert(id, school_id, label, starts_on, ends_on, active), update(label, starts_on, ends_on, active) on public.turc_school_years to authenticated;
grant insert(id, school_id, external_student_id, first_name, last_name, active), update(external_student_id, first_name, last_name, active) on public.turc_students to authenticated;
grant insert(id, school_id, student_id, school_year_id, grade, classroom), update(grade, classroom) on public.turc_enrollments to authenticated;
grant insert(id, school_id, student_id, guardian_user_id, active), update(active) on public.turc_guardian_links to authenticated;

create policy turc_accounts_read on public.turc_accounts for select to authenticated
  using (user_id = (select auth.uid()) and (select turc_private.active_user()));
create policy turc_accounts_edit on public.turc_accounts for update to authenticated
  using (user_id = (select auth.uid()) and (select turc_private.active_user()))
  with check (user_id = (select auth.uid()) and (select turc_private.active_user()));
create policy turc_districts_read on public.turc_districts for select to authenticated using (turc_private.read_district(id));
create policy turc_districts_edit on public.turc_districts for update to authenticated
  using (turc_private.district_admin(id)) with check (turc_private.district_admin(id));
create policy turc_schools_read on public.turc_schools for select to authenticated using (turc_private.read_school(id));
create policy turc_schools_add on public.turc_schools for insert to authenticated with check (turc_private.district_admin(district_id));
create policy turc_schools_edit on public.turc_schools for update to authenticated
  using (turc_private.school_admin(id)) with check (turc_private.school_admin(id));
create policy turc_memberships_read on public.turc_memberships for select to authenticated using (
  ((select turc_private.active_user()) and user_id = (select auth.uid())) or turc_private.manage_membership(district_id, school_id));
create policy turc_memberships_add on public.turc_memberships for insert to authenticated with check (
  user_id <> (select auth.uid()) and turc_private.manage_membership(district_id, school_id));
create policy turc_memberships_edit on public.turc_memberships for update to authenticated
  using (user_id <> (select auth.uid()) and turc_private.manage_membership(district_id, school_id))
  with check (user_id <> (select auth.uid()) and turc_private.manage_membership(district_id, school_id));
create policy turc_years_read on public.turc_school_years for select to authenticated using (turc_private.read_school(school_id));
create policy turc_years_add on public.turc_school_years for insert to authenticated with check (turc_private.school_admin(school_id));
create policy turc_years_edit on public.turc_school_years for update to authenticated
  using (turc_private.school_admin(school_id)) with check (turc_private.school_admin(school_id));
create policy turc_students_read on public.turc_students for select to authenticated using (turc_private.read_student(id, school_id));
create policy turc_students_add on public.turc_students for insert to authenticated with check (turc_private.school_admin(school_id));
create policy turc_students_edit on public.turc_students for update to authenticated
  using (turc_private.school_admin(school_id)) with check (turc_private.school_admin(school_id));
create policy turc_enrollments_read on public.turc_enrollments for select to authenticated using (turc_private.read_student(student_id, school_id));
create policy turc_enrollments_add on public.turc_enrollments for insert to authenticated with check (turc_private.school_admin(school_id));
create policy turc_enrollments_edit on public.turc_enrollments for update to authenticated
  using (turc_private.school_admin(school_id)) with check (turc_private.school_admin(school_id));
create policy turc_guardians_read on public.turc_guardian_links for select to authenticated using (
  turc_private.school_admin(school_id) or (guardian_user_id = (select auth.uid()) and turc_private.school_member(school_id, array['parent'])));
create policy turc_guardians_add on public.turc_guardian_links for insert to authenticated with check (turc_private.school_admin(school_id));
create policy turc_guardians_edit on public.turc_guardian_links for update to authenticated
  using (turc_private.school_admin(school_id)) with check (turc_private.school_admin(school_id));
create policy turc_imports_read on public.turc_import_jobs for select to authenticated using (turc_private.school_admin(school_id));
create policy turc_audit_read on public.turc_audit_events for select to authenticated using (
  (school_id is not null and turc_private.school_admin(school_id))
  or (school_id is null and district_id is not null and turc_private.district_admin(district_id)));

comment on schema turc_private is 'Non-exposed TURC RLS lookups and trigger routines; never add this schema to the Data API.';
comment on table public.turc_accounts is 'Provisioned only by a trusted administrator; signing up grants no TURC access.';
comment on table public.turc_memberships is 'Live database authorization. District Admin: school_id NULL. School roles: explicit school_id. Users cannot grant themselves membership.';
comment on table public.turc_import_jobs is 'Server-owned import bookkeeping; browser writes are not permitted. Import API is a later milestone.';
comment on table public.turc_audit_events is 'Trigger-owned audit history with changed column names, not copied student values. No browser writes.';
