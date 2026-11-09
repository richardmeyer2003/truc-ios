-- Native QR/NDEF adapters share one authenticated, transactional scan processor.
create table turc_private.turc_courses (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null unique references public.turc_schools(id),
  name text not null check (length(btrim(name)) between 1 and 80),
  distance_mm bigint not null check (distance_mm between 1 and 1000000000),
  cooldown_seconds integer not null check (cooldown_seconds between 0 and 3600),
  version bigint not null default 1,
  updated_at timestamptz not null default now()
);
create table turc_private.turc_badges (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.turc_schools(id),
  student_id uuid not null,
  token text not null unique check (token ~ '^turc:v1:[a-f0-9]{64}$'),
  active boolean not null default true,
  nfc_verified boolean not null default false,
  issued_by uuid not null references public.turc_accounts(user_id),
  request_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (student_id,school_id) references public.turc_students(id,school_id),
  unique (issued_by,request_id)
);
create unique index turc_badge_one_active on turc_private.turc_badges(student_id) where active;
create index turc_badges_school on turc_private.turc_badges(school_id);
create table turc_private.turc_days (
  id uuid primary key default gen_random_uuid(), school_id uuid not null references public.turc_schools(id),
  school_year_id uuid not null, activity_date date not null,
  foreign key (school_year_id,school_id) references public.turc_school_years(id,school_id),
  unique (school_id,activity_date), unique (id,school_id)
);
create table turc_private.turc_scan_attempts (
  id uuid primary key default gen_random_uuid(), school_id uuid not null references public.turc_schools(id),
  operator_id uuid not null references public.turc_accounts(user_id), event_id uuid not null, device_id uuid not null,
  source text not null check (source in ('qr','nfc')), token_hash text not null,
  observed_at timestamptz not null, received_at timestamptz not null,
  result jsonb not null, unique (operator_id,event_id)
);
create index turc_scan_attempts_school on turc_private.turc_scan_attempts(school_id,received_at);
create table public.turc_laps (
  id uuid primary key default gen_random_uuid(), school_id uuid not null references public.turc_schools(id),
  student_id uuid not null, school_year_id uuid not null, day_id uuid not null,
  badge_id uuid not null references turc_private.turc_badges(id),
  operator_id uuid not null references public.turc_accounts(user_id), event_id uuid not null,
  activity_date date not null, accepted_at timestamptz not null,
  distance_mm bigint not null check(distance_mm > 0), course_version bigint not null,
  foreign key (student_id,school_id) references public.turc_students(id,school_id),
  foreign key (school_year_id,school_id) references public.turc_school_years(id,school_id),
  foreign key (day_id,school_id) references turc_private.turc_days(id,school_id),
  unique(operator_id,event_id)
);
create index turc_laps_student_time on public.turc_laps(student_id,accepted_at desc);
create index turc_laps_school_day on public.turc_laps(school_id,activity_date);
create index turc_laps_year on public.turc_laps(school_year_id,student_id);
create index turc_laps_day on public.turc_laps(day_id);
create index turc_laps_badge on public.turc_laps(badge_id);

alter table turc_private.turc_courses enable row level security;
alter table turc_private.turc_badges enable row level security;
alter table turc_private.turc_days enable row level security;
alter table turc_private.turc_scan_attempts enable row level security;
alter table public.turc_laps enable row level security;
revoke all on turc_private.turc_courses,turc_private.turc_badges,turc_private.turc_days,turc_private.turc_scan_attempts from public,anon,authenticated;
revoke all on public.turc_laps from public,anon,authenticated;
grant select on public.turc_laps to authenticated;
create policy turc_laps_read on public.turc_laps for select to authenticated using (turc_private.read_student(student_id,school_id));
create trigger turc_laps_audit after insert on public.turc_laps for each row execute function turc_private.audit_record();
create trigger turc_badges_audit after insert or update on turc_private.turc_badges for each row execute function turc_private.audit_record();
create trigger turc_courses_audit after insert or update on turc_private.turc_courses for each row execute function turc_private.audit_record();

create function turc_private.can_scan(p_school uuid) returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and turc_private.active_user()
    and (turc_private.school_admin(p_school) or turc_private.school_member(p_school,array['staff']))
    and exists(select 1 from public.turc_schools s join public.turc_districts d on d.id=s.district_id where s.id=p_school and s.active and d.active);
$$;
create function turc_private.scan_course(p_school uuid,p_name text,p_distance bigint,p_cooldown integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v turc_private.turc_courses;
begin
  if not turc_private.can_scan(p_school) then raise exception 'School scanning access required' using errcode='42501'; end if;
  if p_name is not null then
    if not turc_private.school_admin(p_school) then raise exception 'Admin access required' using errcode='42501'; end if;
    insert into turc_private.turc_courses(school_id,name,distance_mm,cooldown_seconds) values(p_school,btrim(p_name),p_distance,p_cooldown)
    on conflict(school_id) do update set name=excluded.name,distance_mm=excluded.distance_mm,cooldown_seconds=excluded.cooldown_seconds,version=turc_courses.version+1,updated_at=clock_timestamp();
  end if;
  select * into v from turc_private.turc_courses where school_id=p_school;
  return case when v.id is null then jsonb_build_object('configured',false) else to_jsonb(v)||jsonb_build_object('configured',true) end;
end; $$;

create function turc_private.runner_badge(p_student uuid,p_replace boolean,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_student public.turc_students; v_badge turc_private.turc_badges;
begin
  select * into v_student from public.turc_students where id=p_student for update;
  if v_student.id is null or not turc_private.can_scan(v_student.school_id) or not turc_private.school_admin(v_student.school_id) then
    raise exception 'Admin access required' using errcode='42501'; end if;
  if not v_student.active or not exists(select 1 from public.turc_enrollments e join public.turc_school_years y on y.id=e.school_year_id where e.student_id=p_student and y.active) then
    raise exception 'Active runner enrollment required' using errcode='22023'; end if;
  if p_request is null then raise exception 'Request identifier required' using errcode='22023'; end if;
  select * into v_badge from turc_private.turc_badges where issued_by=auth.uid() and request_id=p_request;
  if v_badge.id is not null then
    if v_badge.student_id<>p_student or not v_badge.active then raise exception 'Badge request is stale' using errcode='22023'; end if;
    return to_jsonb(v_badge)-'issued_by'-'request_id';
  end if;
  select * into v_badge from turc_private.turc_badges where student_id=p_student and active;
  if v_badge.id is null or coalesce(p_replace,false) then
    update turc_private.turc_badges set active=false where student_id=p_student and active;
    insert into turc_private.turc_badges(school_id,student_id,token,issued_by,request_id)
      values(v_student.school_id,p_student,'turc:v1:'||replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),auth.uid(),p_request) returning * into v_badge;
  end if;
  return to_jsonb(v_badge)-'issued_by'-'request_id';
end; $$;

create function turc_private.confirm_nfc(p_badge uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare v turc_private.turc_badges;
begin
  select * into v from turc_private.turc_badges where id=p_badge;
  if v.id is null or not turc_private.can_scan(v.school_id) or not turc_private.school_admin(v.school_id) then raise exception 'Admin access required' using errcode='42501'; end if;
  perform 1 from public.turc_students where id=v.student_id for update;
  update turc_private.turc_badges set nfc_verified=true where id=p_badge and active;
  if not found then raise exception 'Badge was replaced; reload the runner badge' using errcode='40001'; end if;
  return true;
end; $$;

create function turc_private.runner_totals(p_student uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_school uuid; v_day date; v_year uuid;
begin
  select s.school_id,(clock_timestamp() at time zone c.timezone)::date into v_school,v_day from public.turc_students s join public.turc_schools c on c.id=s.school_id where s.id=p_student;
  if v_school is null or not turc_private.read_student(p_student,v_school) then raise exception 'Runner access required' using errcode='42501'; end if;
  select id into v_year from public.turc_school_years where school_id=v_school and active;
  return (select jsonb_build_object('today_laps',count(*) filter(where activity_date=v_day),'today_mm',coalesce(sum(distance_mm) filter(where activity_date=v_day),0),
    'year_mm',coalesce(sum(distance_mm) filter(where school_year_id=v_year),0),'lifetime_mm',coalesce(sum(distance_mm),0)) from public.turc_laps where student_id=p_student);
end; $$;

create function turc_private.submit_scan(p_school uuid,p_token text,p_event uuid,p_device uuid,p_source text,p_observed timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_now timestamptz:=clock_timestamp(); v_day date; v_year uuid; v_session uuid; v_last timestamptz;
  v_hash text; v_result jsonb; v_reason text; v_student public.turc_students; v_badge turc_private.turc_badges;
  v_course turc_private.turc_courses; v_existing turc_private.turc_scan_attempts;
begin
  if not turc_private.can_scan(p_school) then raise exception 'School scanning access required' using errcode='42501'; end if;
  if p_event is null or p_device is null or p_source is null or p_source not in('qr','nfc') or p_observed is null or p_token is null or length(p_token)>200 then
    raise exception 'Invalid scan payload' using errcode='22023'; end if;
  v_hash:=encode(sha256(convert_to(p_token,'UTF8')),'hex');
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_event::text,0));
  select * into v_existing from turc_private.turc_scan_attempts where operator_id=auth.uid() and event_id=p_event;
  if v_existing.id is not null then
    if (v_existing.school_id,v_existing.token_hash,v_existing.device_id,v_existing.source,v_existing.observed_at) is distinct from (p_school,v_hash,p_device,p_source,p_observed) then
      raise exception 'Event identifier reused with a different payload' using errcode='22023'; end if;
    return v_existing.result||jsonb_build_object('replayed',true);
  end if;
  select * into v_course from turc_private.turc_courses where school_id=p_school;
  select (v_now at time zone timezone)::date into v_day from public.turc_schools where id=p_school;
  select id into v_year from public.turc_school_years where school_id=p_school and active and v_day between starts_on and ends_on;
  if abs(extract(epoch from v_now-p_observed))>120 then v_reason:='clock_or_connection';
  elsif v_course.id is null then v_reason:='course_not_configured';
  elsif v_year is null then v_reason:='no_active_year';
  else
    select * into v_badge from turc_private.turc_badges where school_id=p_school and token=p_token and active;
    if v_badge.id is null then v_reason:='unknown_or_replaced_badge';
    else
      select * into v_student from public.turc_students where id=v_badge.student_id for update;
      -- This lock is also used by badge replacement and serializes cooldown checks across devices.
      if not exists(select 1 from turc_private.turc_badges where id=v_badge.id and active) then v_reason:='unknown_or_replaced_badge';
      elsif not v_student.active or not exists(select 1 from public.turc_enrollments where student_id=v_student.id and school_year_id=v_year) then v_reason:='inactive_runner';
      else
        select max(accepted_at) into v_last from public.turc_laps where student_id=v_student.id;
        if v_last is not null and v_now < v_last+make_interval(secs=>v_course.cooldown_seconds) then v_reason:='cooldown';
        else
          insert into turc_private.turc_days(school_id,school_year_id,activity_date) values(p_school,v_year,v_day) on conflict(school_id,activity_date) do nothing;
          select id into v_session from turc_private.turc_days where school_id=p_school and activity_date=v_day;
          insert into public.turc_laps(school_id,student_id,school_year_id,day_id,badge_id,operator_id,event_id,activity_date,accepted_at,distance_mm,course_version)
            values(p_school,v_student.id,v_year,v_session,v_badge.id,auth.uid(),p_event,v_day,v_now,v_course.distance_mm,v_course.version);
        end if;
      end if;
    end if;
  end if;
  v_result:=jsonb_build_object('accepted',v_reason is null,'reason',coalesce(v_reason,'accepted'),'event_id',p_event);
  if v_student.id is not null and v_reason is null then v_result:=v_result||jsonb_build_object('student_id',v_student.id,'name',v_student.first_name||' '||v_student.last_name,'totals',turc_private.runner_totals(v_student.id)); end if;
  insert into turc_private.turc_scan_attempts(school_id,operator_id,event_id,device_id,source,token_hash,observed_at,received_at,result)
    values(p_school,auth.uid(),p_event,p_device,p_source,v_hash,p_observed,v_now,v_result);
  return v_result;
end; $$;

-- Invoker wrappers expose only the checked, private implementations.
create function public.turc_scan_course(p_school uuid,p_name text default null,p_distance bigint default null,p_cooldown integer default null) returns jsonb language sql security invoker set search_path='' as $$select turc_private.scan_course(p_school,p_name,p_distance,p_cooldown);$$;
create function public.turc_runner_badge(p_student uuid,p_replace boolean,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.runner_badge(p_student,p_replace,p_request);$$;
create function public.turc_confirm_nfc(p_badge uuid) returns boolean language sql security invoker set search_path='' as $$select turc_private.confirm_nfc(p_badge);$$;
create function public.turc_runner_totals(p_student uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.runner_totals(p_student);$$;
create function public.turc_submit_scan(p_school uuid,p_token text,p_event uuid,p_device uuid,p_source text,p_observed timestamptz) returns jsonb language sql security invoker set search_path='' as $$select turc_private.submit_scan(p_school,p_token,p_event,p_device,p_source,p_observed);$$;
revoke all on function turc_private.can_scan(uuid),turc_private.scan_course(uuid,text,bigint,integer),turc_private.runner_badge(uuid,boolean,uuid),turc_private.confirm_nfc(uuid),turc_private.runner_totals(uuid),turc_private.submit_scan(uuid,text,uuid,uuid,text,timestamptz),public.turc_scan_course(uuid,text,bigint,integer),public.turc_runner_badge(uuid,boolean,uuid),public.turc_confirm_nfc(uuid),public.turc_runner_totals(uuid),public.turc_submit_scan(uuid,text,uuid,uuid,text,timestamptz) from public,anon,authenticated;
grant execute on function turc_private.scan_course(uuid,text,bigint,integer),turc_private.runner_badge(uuid,boolean,uuid),turc_private.confirm_nfc(uuid),turc_private.runner_totals(uuid),turc_private.submit_scan(uuid,text,uuid,uuid,text,timestamptz),public.turc_scan_course(uuid,text,bigint,integer),public.turc_runner_badge(uuid,boolean,uuid),public.turc_confirm_nfc(uuid),public.turc_runner_totals(uuid),public.turc_submit_scan(uuid,text,uuid,uuid,text,timestamptz) to authenticated;
