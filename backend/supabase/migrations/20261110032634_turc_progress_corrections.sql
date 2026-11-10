-- Append-only adjustments keep original scans and the installed app compatible.
create table turc_private.turc_lap_corrections (
  id uuid primary key default gen_random_uuid(), lap_id uuid not null references public.turc_laps(id),
  school_id uuid not null references public.turc_schools(id), student_id uuid not null references public.turc_students(id),
  version bigint not null, distance_mm bigint not null check(distance_mm between 1 and 1000000000), voided boolean not null,
  reason text not null check(length(btrim(reason)) between 3 and 500),
  actor_id uuid not null references public.turc_accounts(user_id), request_id uuid not null,
  created_at timestamptz not null default clock_timestamp(), unique(lap_id,version),unique(actor_id,request_id)
);
create index turc_corrections_student on turc_private.turc_lap_corrections(student_id);
create index turc_corrections_school on turc_private.turc_lap_corrections(school_id);
create table turc_private.turc_mileage_resets (
  id uuid primary key default gen_random_uuid(), school_id uuid not null references public.turc_schools(id),
  student_id uuid not null references public.turc_students(id), school_year_id uuid references public.turc_school_years(id),
  cutoff timestamptz not null, reason text not null check(length(btrim(reason)) between 3 and 500),
  actor_id uuid not null references public.turc_accounts(user_id), request_id uuid not null,
  created_at timestamptz not null default clock_timestamp(), unique(actor_id,request_id)
);
create index turc_resets_student on turc_private.turc_mileage_resets(student_id,cutoff desc);
create index turc_resets_school on turc_private.turc_mileage_resets(school_id);
create index turc_resets_year on turc_private.turc_mileage_resets(school_year_id);
alter table turc_private.turc_lap_corrections enable row level security;
alter table turc_private.turc_mileage_resets enable row level security;
revoke all on turc_private.turc_lap_corrections,turc_private.turc_mileage_resets from public,anon,authenticated;
create trigger turc_corrections_audit after insert on turc_private.turc_lap_corrections for each row execute function turc_private.audit_record();
create trigger turc_resets_audit after insert on turc_private.turc_mileage_resets for each row execute function turc_private.audit_record();

-- Owner-only view: access is mediated by checked private functions below.
create view turc_private.turc_effective_laps as
select l.*, coalesce(c.distance_mm,l.distance_mm) effective_distance_mm,coalesce(c.voided,false) voided,
  coalesce(c.version,0) correction_version,c.reason correction_reason,
  exists(select 1 from turc_private.turc_mileage_resets r where r.student_id=l.student_id and l.accepted_at<=r.cutoff
    and (r.school_year_id is null or r.school_year_id=l.school_year_id)) reset_excluded
from public.turc_laps l left join lateral
  (select * from turc_private.turc_lap_corrections c where c.lap_id=l.id order by version desc limit 1)c on true;
revoke all on turc_private.turc_effective_laps from public,anon,authenticated;

create or replace function turc_private.runner_totals(p_student uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_school uuid; v_day date; v_year uuid;
begin
  select s.school_id,(clock_timestamp() at time zone c.timezone)::date into v_school,v_day from public.turc_students s join public.turc_schools c on c.id=s.school_id where s.id=p_student;
  if v_school is null or not turc_private.read_student(p_student,v_school) then raise exception 'Runner access required' using errcode='42501'; end if;
  select id into v_year from public.turc_school_years where school_id=v_school and active;
  return (select jsonb_build_object('today_laps',count(*) filter(where activity_date=v_day),'today_mm',coalesce(sum(effective_distance_mm) filter(where activity_date=v_day),0),
    'year_laps',count(*) filter(where school_year_id=v_year),'year_mm',coalesce(sum(effective_distance_mm) filter(where school_year_id=v_year),0),
    'lifetime_laps',count(*),'lifetime_mm',coalesce(sum(effective_distance_mm),0))
    from turc_private.turc_effective_laps where student_id=p_student and not voided and not reset_excluded);
end; $$;

create function turc_private.school_progress(p_school uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_day date; v_year uuid;
begin
  if not turc_private.read_school(p_school) then raise exception 'School access required' using errcode='42501'; end if;
  select (clock_timestamp() at time zone timezone)::date into v_day from public.turc_schools where id=p_school;
  select id into v_year from public.turc_school_years where school_id=p_school and active;
  return (select coalesce(jsonb_agg(to_jsonb(t)),'[]') from (
    select s.id student_id,count(l.id) filter(where l.activity_date=v_day) today_laps,
    coalesce(sum(l.effective_distance_mm) filter(where l.activity_date=v_day),0) today_mm,
    count(l.id) filter(where l.school_year_id=v_year) year_laps,coalesce(sum(l.effective_distance_mm) filter(where l.school_year_id=v_year),0) year_mm,
    count(l.id) lifetime_laps,coalesce(sum(l.effective_distance_mm),0) lifetime_mm
    from public.turc_students s left join turc_private.turc_effective_laps l on l.student_id=s.id and not l.voided and not l.reset_excluded
    where s.school_id=p_school and turc_private.read_student(s.id,p_school) group by s.id order by s.id
  )t);
end; $$;

create function turc_private.runner_history(p_student uuid,p_before timestamptz,p_before_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_school uuid; v_laps jsonb; v_last jsonb; v_more boolean;
begin
  select school_id into v_school from public.turc_students where id=p_student;
  if v_school is null or not turc_private.read_student(p_student,v_school) then raise exception 'Runner access required' using errcode='42501'; end if;
  if (p_before is null)<>(p_before_id is null) then raise exception 'Invalid history cursor' using errcode='22023'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by accepted_at desc,id desc),'[]') into v_laps from(
    select l.id,l.activity_date,l.accepted_at,l.school_year_id,l.distance_mm original_distance_mm,l.effective_distance_mm distance_mm,
      l.voided,l.reset_excluded,l.correction_version,l.correction_reason,
      (select coalesce(jsonb_agg(jsonb_build_object('version',c.version,'distance_mm',c.distance_mm,'voided',c.voided,'reason',c.reason,'at',c.created_at,'by',a.display_name) order by c.version desc),'[]')
       from turc_private.turc_lap_corrections c join public.turc_accounts a on a.user_id=c.actor_id where c.lap_id=l.id) changes
    from turc_private.turc_effective_laps l where student_id=p_student and (p_before is null or (l.accepted_at,l.id)<(p_before,p_before_id))
    order by l.accepted_at desc,l.id desc limit 51)t;
  v_more:=jsonb_array_length(v_laps)>50; if v_more then v_laps:=v_laps-50; end if; v_last:=v_laps->-1;
  return jsonb_build_object('laps',v_laps,'next',case when v_more then jsonb_build_object('at',v_last->>'accepted_at','id',v_last->>'id') else null end,
    'resets',(select coalesce(jsonb_agg(jsonb_build_object('at',r.cutoff,'school_year_id',r.school_year_id,'reason',r.reason,'by',a.display_name) order by r.cutoff desc),'[]')
      from turc_private.turc_mileage_resets r join public.turc_accounts a on a.user_id=r.actor_id where r.student_id=p_student));
end; $$;

create function turc_private.correct_lap(p_lap uuid,p_version bigint,p_distance bigint,p_voided boolean,p_reason text,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v public.turc_laps; c turc_private.turc_lap_corrections; v_version bigint;
begin
  select * into v from public.turc_laps where id=p_lap;
  if v.id is null or not turc_private.school_admin(v.school_id) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_distance is null or p_distance not between 1 and 1000000000 or p_voided is null or p_reason is null or length(btrim(p_reason)) not between 3 and 500 or p_request is null or p_version is null then
    raise exception 'Distance, status, reason and request identifier are required' using errcode='22023'; end if;
  perform 1 from public.turc_students where id=v.student_id for update;
  select * into c from turc_private.turc_lap_corrections where actor_id=auth.uid() and request_id=p_request;
  if c.id is not null then
    if (c.lap_id,c.distance_mm,c.voided,c.reason) is distinct from (p_lap,p_distance,p_voided,btrim(p_reason)) then raise exception 'Request identifier reused' using errcode='22023'; end if;
    return jsonb_build_object('version',c.version,'replayed',true);
  end if;
  select correction_version into v_version from turc_private.turc_effective_laps where id=p_lap;
  if v_version<>p_version then raise exception 'Lap changed. Reopen it before editing.' using errcode='40001'; end if;
  insert into turc_private.turc_lap_corrections(lap_id,school_id,student_id,version,distance_mm,voided,reason,actor_id,request_id)
    values(p_lap,v.school_id,v.student_id,v_version+1,p_distance,p_voided,btrim(p_reason),auth.uid(),p_request);
  return jsonb_build_object('version',v_version+1,'replayed',false);
end; $$;

create function turc_private.reset_mileage(p_student uuid,p_year uuid,p_reason text,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_school uuid; v turc_private.turc_mileage_resets;
begin
  select school_id into v_school from public.turc_students where id=p_student;
  if v_school is null or not turc_private.school_admin(v_school) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_reason is null or length(btrim(p_reason)) not between 3 and 500 or p_request is null then raise exception 'A reason and request identifier are required' using errcode='22023'; end if;
  if p_year is not null and not exists(select 1 from public.turc_school_years where id=p_year and school_id=v_school) then raise exception 'School year does not belong to runner' using errcode='22023'; end if;
  perform 1 from public.turc_students where id=p_student for update;
  select * into v from turc_private.turc_mileage_resets where actor_id=auth.uid() and request_id=p_request;
  if v.id is not null then
    if (v.student_id,v.school_year_id,v.reason) is distinct from (p_student,p_year,btrim(p_reason)) then raise exception 'Request identifier reused' using errcode='22023'; end if;
    return jsonb_build_object('id',v.id,'replayed',true);
  end if;
  insert into turc_private.turc_mileage_resets(school_id,student_id,school_year_id,cutoff,reason,actor_id,request_id)
    values(v_school,p_student,p_year,clock_timestamp(),btrim(p_reason),auth.uid(),p_request) returning * into v;
  return jsonb_build_object('id',v.id,'replayed',false);
end; $$;

create function public.turc_school_progress(p_school uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.school_progress(p_school);$$;
create function public.turc_runner_history(p_student uuid,p_before timestamptz default null,p_before_id uuid default null) returns jsonb language sql security invoker set search_path='' as $$select turc_private.runner_history(p_student,p_before,p_before_id);$$;
create function public.turc_correct_lap(p_lap uuid,p_version bigint,p_distance bigint,p_voided boolean,p_reason text,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.correct_lap(p_lap,p_version,p_distance,p_voided,p_reason,p_request);$$;
create function public.turc_reset_mileage(p_student uuid,p_year uuid,p_reason text,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.reset_mileage(p_student,p_year,p_reason,p_request);$$;
revoke all on function turc_private.school_progress(uuid),turc_private.runner_history(uuid,timestamptz,uuid),turc_private.correct_lap(uuid,bigint,bigint,boolean,text,uuid),turc_private.reset_mileage(uuid,uuid,text,uuid),public.turc_school_progress(uuid),public.turc_runner_history(uuid,timestamptz,uuid),public.turc_correct_lap(uuid,bigint,bigint,boolean,text,uuid),public.turc_reset_mileage(uuid,uuid,text,uuid) from public,anon,authenticated;
grant execute on function turc_private.school_progress(uuid),turc_private.runner_history(uuid,timestamptz,uuid),turc_private.correct_lap(uuid,bigint,bigint,boolean,text,uuid),turc_private.reset_mileage(uuid,uuid,text,uuid),public.turc_school_progress(uuid),public.turc_runner_history(uuid,timestamptz,uuid),public.turc_correct_lap(uuid,bigint,bigint,boolean,text,uuid),public.turc_reset_mileage(uuid,uuid,text,uuid) to authenticated;
