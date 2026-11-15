-- Walk-a-thon scores share roster identity with TURC and have their own lap ledger.
create table turc_private.walk_events (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.turc_schools(id),
  school_year_id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 100),
  min_lap_seconds integer not null check (min_lap_seconds between 1 and 3600),
  status text not null default 'draft' check (status in ('draft','open','closed')),
  created_at timestamptz not null default clock_timestamp(),
  foreign key (school_year_id,school_id) references public.turc_school_years(id,school_id),
  unique (id,school_id)
);
create index walk_events_school on turc_private.walk_events(school_id,created_at desc);
create index walk_events_year on turc_private.walk_events(school_year_id,school_id);

create table turc_private.walk_entries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  school_id uuid not null,
  student_id uuid not null,
  bib_code uuid not null unique default gen_random_uuid(),
  first_name text not null,
  last_name text not null,
  grade text not null check (grade in ('TK','K','1','2','3','4','5')),
  teacher text,
  laps integer not null default 0 check (laps>=0),
  last_lap_at timestamptz,
  foreign key (event_id,school_id) references turc_private.walk_events(id,school_id),
  foreign key (student_id,school_id) references public.turc_students(id,school_id),
  unique (event_id,student_id)
);
create index walk_entries_student on turc_private.walk_entries(student_id,school_id);

create table turc_private.walk_scan_receipts (
  event_id uuid not null references turc_private.walk_events(id),
  operator_id uuid not null references public.turc_accounts(user_id),
  request_id uuid not null,
  code_hash bytea not null,
  result jsonb not null,
  received_at timestamptz not null default clock_timestamp(),
  primary key (event_id,operator_id,request_id)
);
create index walk_receipts_operator on turc_private.walk_scan_receipts(operator_id);
alter table turc_private.walk_events enable row level security;
alter table turc_private.walk_entries enable row level security;
alter table turc_private.walk_scan_receipts enable row level security;
revoke all on turc_private.walk_events,turc_private.walk_entries,turc_private.walk_scan_receipts from public,anon,authenticated;

create function turc_private.walk_grade(p_grade text) returns text
language sql immutable set search_path='' as $$
  select case normalized
    when 'tk' then 'TK' when 'transitional kindergarten' then 'TK'
    when 'k' then 'K' when 'kg' then 'K' when 'kinder' then 'K' when 'kindergarten' then 'K' when '0' then 'K' when '00' then 'K'
    else substring(normalized from '^0?([1-5])(?:st|nd|rd|th)?$') end
  from (select lower(regexp_replace(btrim(p_grade),'^grade\s+','','i')) normalized) g;
$$;
revoke all on function turc_private.walk_grade(text) from public,anon,authenticated;

create function turc_private.walk_events_for_school(p_school uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if not turc_private.can_scan(p_school) then raise exception 'School staff access required' using errcode='42501'; end if;
  return jsonb_build_object('admin',turc_private.school_admin(p_school),'events',coalesce((
    select jsonb_agg(to_jsonb(e) order by e.created_at desc) from turc_private.walk_events e where school_id=p_school
  ),'[]'::jsonb));
end; $$;

create function turc_private.walk_save_event(p_school uuid,p_event uuid,p_name text,p_min_seconds int,p_status text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e turc_private.walk_events; y uuid;
begin
  if not turc_private.can_scan(p_school) or not turc_private.school_admin(p_school) then raise exception 'School Admin access required' using errcode='42501'; end if;
  if p_event is null then
    select id into y from public.turc_school_years where school_id=p_school and active;
    if y is null then raise exception 'Set up an active school year first' using errcode='22023'; end if;
    if p_status is distinct from 'draft' then raise exception 'Create a draft first' using errcode='22023'; end if;
    insert into turc_private.walk_events(school_id,school_year_id,name,min_lap_seconds)
    values(p_school,y,btrim(p_name),p_min_seconds) returning * into e;
  else
    select * into e from turc_private.walk_events where id=p_event and school_id=p_school for update;
    if e.id is null then raise exception 'Event not available' using errcode='42501'; end if;
    if p_status is null or p_status not in ('draft','open','closed') or
       (e.status='open' and p_status='draft') or (e.status='closed' and p_status<>'closed') or
       (e.status='draft' and p_status='closed') then
      raise exception 'This event cannot change to that status' using errcode='22023';
    end if;
    if e.status='draft' and p_status='open' and not exists(select 1 from turc_private.walk_entries where event_id=e.id) then
      raise exception 'Register at least one student before opening the event' using errcode='22023';
    end if;
    if e.status<>'closed' then
      update turc_private.walk_events set name=coalesce(btrim(p_name),name),min_lap_seconds=coalesce(p_min_seconds,min_lap_seconds),status=p_status
        where id=e.id returning * into e;
    end if;
  end if;
  return to_jsonb(e);
end; $$;

create function turc_private.walk_registration(p_event uuid,p_students uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e turc_private.walk_events;
begin
  select * into e from turc_private.walk_events where id=p_event;
  if e.id is null or not turc_private.can_scan(e.school_id) or not turc_private.school_admin(e.school_id) then raise exception 'School Admin access required' using errcode='42501'; end if;
  if p_students is not null then
    select * into e from turc_private.walk_events where id=p_event for update;
    if e.status<>'draft' then raise exception 'Registration is locked once scanning starts' using errcode='22023'; end if;
    if cardinality(p_students)>5000 then raise exception 'Too many entrants in one event' using errcode='22023'; end if;
    if exists(select 1 from unnest(p_students) as chosen(id) where not exists(
      select 1 from turc_private.walk_entries w where w.event_id=e.id and w.student_id=chosen.id
      union all
      select 1 from public.turc_students s join public.turc_enrollments n on n.student_id=s.id and n.school_year_id=e.school_year_id
      where s.id=chosen.id and s.school_id=e.school_id and s.active and turc_private.walk_grade(n.grade) is not null
    )) then raise exception 'Choose enrolled students in grades TK–5 from this school' using errcode='22023'; end if;
    delete from turc_private.walk_entries where event_id=e.id and not (student_id=any(p_students));
    insert into turc_private.walk_entries(event_id,school_id,student_id,first_name,last_name,grade,teacher)
      select e.id,e.school_id,s.id,s.first_name,s.last_name,turc_private.walk_grade(n.grade),n.classroom
      from public.turc_students s join public.turc_enrollments n on n.student_id=s.id and n.school_year_id=e.school_year_id
      where s.id=any(p_students) and s.school_id=e.school_id and s.active and turc_private.walk_grade(n.grade) is not null
      on conflict (event_id,student_id) do nothing;
  end if;
  return jsonb_build_object('event',to_jsonb(e),'roster',coalesce((
    select jsonb_agg(to_jsonb(r) order by last_name,first_name,student_id) from (
      select s.id student_id,s.first_name,s.last_name,turc_private.walk_grade(n.grade) grade,n.classroom teacher
      from public.turc_students s join public.turc_enrollments n on n.student_id=s.id and n.school_year_id=e.school_year_id
      where s.school_id=e.school_id and s.active and e.status='draft'
    ) r
  ),'[]'::jsonb),'entries',coalesce((
    select jsonb_agg(jsonb_build_object('student_id',student_id,'first_name',first_name,'last_name',last_name,'grade',grade,'teacher',teacher,'code','wt1:'||bib_code::text) order by last_name,first_name,student_id)
    from turc_private.walk_entries where event_id=e.id
  ),'[]'::jsonb));
end; $$;

create function turc_private.walk_display(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare e turc_private.walk_events;
begin
  select * into e from turc_private.walk_events where id=p_event;
  if e.id is null or not turc_private.can_scan(e.school_id) then raise exception 'School staff access required' using errcode='42501'; end if;
  return jsonb_build_object('event',jsonb_build_object('name',e.name,'status',e.status),'rows',coalesce((
    select jsonb_agg(jsonb_build_object('id',id,'name',first_name||' '||left(last_name,1)||'.','grade',grade,'laps',laps)
      order by laps desc,last_lap_at asc nulls last,last_name,first_name,id)
    from turc_private.walk_entries where event_id=e.id
  ),'[]'::jsonb));
end; $$;

create function turc_private.walk_scan(p_event uuid,p_code text,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e turc_private.walk_events; w turc_private.walk_entries; receipt turc_private.walk_scan_receipts;
  actor uuid:=auth.uid(); code_digest bytea; received timestamptz; decision_time timestamptz; remaining int; result jsonb;
begin
  select * into e from turc_private.walk_events where id=p_event for share;
  if e.id is null or not turc_private.can_scan(e.school_id) then raise exception 'School staff access required' using errcode='42501'; end if;
  if p_request is null or p_code is null or p_code !~ '^wt1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'Scan a Walk-a-thon bib QR code' using errcode='22023';
  end if;
  received:=clock_timestamp();
  code_digest:=sha256(convert_to(p_code,'UTF8'));
  perform pg_advisory_xact_lock(hashtextextended(e.id::text||actor::text||p_request::text,0));
  select * into receipt from turc_private.walk_scan_receipts where event_id=e.id and operator_id=actor and request_id=p_request;
  if receipt.request_id is not null then
    if receipt.code_hash<>code_digest then raise exception 'Request already used for a different bib' using errcode='22023'; end if;
    return receipt.result||jsonb_build_object('replayed',true);
  end if;
  if e.status<>'open' then
    result:=jsonb_build_object('accepted',false,'reason','event_not_open');
  else
    select * into w from turc_private.walk_entries where event_id=e.id and bib_code=substring(p_code from 5)::uuid for update;
    if w.id is null then
      result:=jsonb_build_object('accepted',false,'reason','unknown_bib');
    else
      decision_time:=clock_timestamp();
      remaining:=ceil(extract(epoch from w.last_lap_at+make_interval(secs=>e.min_lap_seconds)-received));
      if remaining>0 then
        -- Check arrival time after acquiring the row lock. Waiting on another scanner cannot turn a duplicate into a lap.
        remaining:=greatest(1,ceil(extract(epoch from w.last_lap_at+make_interval(secs=>e.min_lap_seconds)-decision_time))::int);
        result:=jsonb_build_object('accepted',false,'reason','too_soon','remaining_seconds',remaining,'laps',w.laps);
      else
        update turc_private.walk_entries set laps=laps+1,last_lap_at=decision_time where id=w.id returning * into w;
        result:=jsonb_build_object('accepted',true,'name',w.first_name||' '||left(w.last_name,1)||'.','laps',w.laps);
      end if;
    end if;
  end if;
  insert into turc_private.walk_scan_receipts(event_id,operator_id,request_id,code_hash,result,received_at)
    values(e.id,actor,p_request,code_digest,result,received);
  return result;
end; $$;

create function public.turc_walk_events(p_school uuid) returns jsonb language sql stable security invoker set search_path='' as $$select turc_private.walk_events_for_school(p_school);$$;
create function public.turc_walk_save_event(p_school uuid,p_event uuid,p_name text,p_min_seconds int,p_status text) returns jsonb language sql security invoker set search_path='' as $$select turc_private.walk_save_event(p_school,p_event,p_name,p_min_seconds,p_status);$$;
create function public.turc_walk_registration(p_event uuid,p_students uuid[] default null) returns jsonb language sql security invoker set search_path='' as $$select turc_private.walk_registration(p_event,p_students);$$;
create function public.turc_walk_display(p_event uuid) returns jsonb language sql stable security invoker set search_path='' as $$select turc_private.walk_display(p_event);$$;
create function public.turc_walk_scan(p_event uuid,p_code text,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.walk_scan(p_event,p_code,p_request);$$;

revoke all on function turc_private.walk_events_for_school(uuid),turc_private.walk_save_event(uuid,uuid,text,int,text),turc_private.walk_registration(uuid,uuid[]),turc_private.walk_display(uuid),turc_private.walk_scan(uuid,text,uuid),
  public.turc_walk_events(uuid),public.turc_walk_save_event(uuid,uuid,text,int,text),public.turc_walk_registration(uuid,uuid[]),public.turc_walk_display(uuid),public.turc_walk_scan(uuid,text,uuid) from public,anon,authenticated;
grant execute on function turc_private.walk_events_for_school(uuid),turc_private.walk_save_event(uuid,uuid,text,int,text),turc_private.walk_registration(uuid,uuid[]),turc_private.walk_display(uuid),turc_private.walk_scan(uuid,text,uuid),
  public.turc_walk_events(uuid),public.turc_walk_save_event(uuid,uuid,text,int,text),public.turc_walk_registration(uuid,uuid[]),public.turc_walk_display(uuid),public.turc_walk_scan(uuid,text,uuid) to authenticated;
