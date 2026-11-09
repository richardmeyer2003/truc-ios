-- Read-only factory UID assignment. No tag contents are read as credentials or written.
alter table turc_private.turc_badges add column tag_uid text check(tag_uid ~ '^[A-F0-9]{14}$');
create unique index turc_badges_active_uid on turc_private.turc_badges(tag_uid) where active and tag_uid is not null;
comment on column turc_private.turc_badges.tag_uid is 'Read-only NTAG215 factory UID, canonical uppercase 7-byte hex. A lookup key, never user authentication.';

create function turc_private.badge_assignment(p_student uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_student public.turc_students; v_badge turc_private.turc_badges; v_school public.turc_schools; v_enrollment public.turc_enrollments;
begin
  select * into v_student from public.turc_students where id=p_student;
  if v_student.id is null or not turc_private.can_scan(v_student.school_id) or not turc_private.school_admin(v_student.school_id) then raise exception 'Admin access required' using errcode='42501'; end if;
  select * into v_badge from turc_private.turc_badges where student_id=p_student and active and tag_uid is not null;
  if v_badge.id is null then return null; end if;
  select * into v_school from public.turc_schools where id=v_student.school_id;
  select e.* into v_enrollment from public.turc_enrollments e join public.turc_school_years y on y.id=e.school_year_id where e.student_id=p_student and y.active;
  return jsonb_build_object('id',v_badge.id,'student_id',p_student,'tag_uid',v_badge.tag_uid,'token',v_badge.token,
    'student_name',v_student.first_name||' '||v_student.last_name,'student_number',v_student.external_student_id,
    'school_name',v_school.name,'grade',v_enrollment.grade,'classroom',v_enrollment.classroom);
end; $$;

create function turc_private.assign_tag(p_student uuid,p_uid text,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_student public.turc_students; v_badge turc_private.turc_badges; v_claim turc_private.turc_badges; v_uid text:=upper(btrim(p_uid));
begin
  if auth.uid() is null then raise exception 'Admin access required' using errcode='42501'; end if;
  if v_uid is null or v_uid !~ '^[A-F0-9]{14}$' or p_request is null then raise exception 'A valid NTAG215 UID and request identifier are required' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('turc-tag:'||v_uid,0));
  select * into v_student from public.turc_students where id=p_student for update;
  if v_student.id is null or not turc_private.can_scan(v_student.school_id) or not turc_private.school_admin(v_student.school_id) then raise exception 'Admin access required' using errcode='42501'; end if;
  if not v_student.active or not exists(select 1 from public.turc_enrollments e join public.turc_school_years y on y.id=e.school_year_id where e.student_id=p_student and y.active) then raise exception 'Active runner enrollment required' using errcode='22023'; end if;
  select * into v_badge from turc_private.turc_badges where issued_by=auth.uid() and request_id=p_request;
  if v_badge.id is not null then
    if not v_badge.active or v_badge.student_id<>p_student or v_badge.tag_uid is distinct from v_uid then raise exception 'Assignment request is stale or changed' using errcode='22023'; end if;
    return turc_private.badge_assignment(p_student);
  end if;
  select * into v_claim from turc_private.turc_badges where tag_uid=v_uid and active;
  if v_claim.id is not null then
    if v_claim.student_id=p_student then return turc_private.badge_assignment(p_student); end if;
    raise exception 'This sticker is already assigned. Choose an unassigned sticker.' using errcode='23505';
  end if;
  update turc_private.turc_badges set active=false where student_id=p_student and active;
  insert into turc_private.turc_badges(school_id,student_id,token,tag_uid,issued_by,request_id)
    values(v_student.school_id,p_student,'turc:v1:'||replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),v_uid,auth.uid(),p_request);
  return turc_private.badge_assignment(p_student);
end; $$;

create function public.turc_badge_assignment(p_student uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.badge_assignment(p_student);$$;
create function public.turc_assign_tag(p_student uuid,p_uid text,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select turc_private.assign_tag(p_student,p_uid,p_request);$$;
revoke all on function turc_private.badge_assignment(uuid),turc_private.assign_tag(uuid,text,uuid),public.turc_badge_assignment(uuid),public.turc_assign_tag(uuid,text,uuid) from public,anon,authenticated;
grant execute on function turc_private.badge_assignment(uuid),turc_private.assign_tag(uuid,text,uuid),public.turc_badge_assignment(uuid),public.turc_assign_tag(uuid,text,uuid) to authenticated;
-- Retire the previous QR-first/tag-writing pairing endpoints.
revoke execute on function public.turc_runner_badge(uuid,boolean,uuid),public.turc_confirm_nfc(uuid),turc_private.runner_badge(uuid,boolean,uuid),turc_private.confirm_nfc(uuid) from authenticated;

create or replace function turc_private.submit_scan(p_school uuid,p_token text,p_event uuid,p_device uuid,p_source text,p_observed timestamptz) returns jsonb
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
    select * into v_badge from turc_private.turc_badges where school_id=p_school and active and tag_uid is not null and ((p_source='qr' and token=p_token) or (p_source='nfc' and tag_uid=upper(btrim(p_token))));
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

