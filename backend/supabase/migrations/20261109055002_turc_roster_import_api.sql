-- Authenticated import wrappers use private, narrowly checked transaction routines.
create table turc_private.roster_import_previews (
  job_id uuid primary key references public.turc_import_jobs(id) on delete cascade,
  rows jsonb not null,
  year_version bigint not null,
  expires_at timestamptz not null default now() + interval '30 minutes'
);
alter table turc_private.roster_import_previews enable row level security;
revoke all on turc_private.roster_import_previews from public, anon, authenticated;

create function turc_private.preview_roster_import(p_school uuid, p_year uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_year public.turc_school_years%rowtype; v_s public.turc_students%rowtype; v_e public.turc_enrollments%rowtype;
  v_row jsonb; v_normal jsonb; v_snapshot jsonb; v_rows jsonb := '[]'; v_errors jsonb := '[]';
  v_seen text[] := '{}'; v_external text; v_first text; v_last text; v_grade text; v_classroom text;
  v_line integer := 1; v_action text; v_added integer := 0; v_updated integer := 0; v_unchanged integer := 0; v_job uuid;
begin
  if not turc_private.school_admin(p_school) then raise exception 'Admin access to this school is required' using errcode = '42501'; end if;
  select * into v_year from public.turc_school_years where id = p_year and school_id = p_school and active;
  if not found then raise exception 'Choose the active school year for this school' using errcode = '22023'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Rows must be an array' using errcode = '22023'; end if;
  if jsonb_array_length(p_rows) not between 1 and 1000 or octet_length(p_rows::text) > 1048576 then
    raise exception 'Choose 1–1,000 rows, no larger than 1 MB' using errcode = '22023'; end if;

  -- Expired previews are removed during the next preview in the same school.
  update public.turc_import_jobs j set status = 'expired' where j.school_id = p_school and j.status = 'preview'
    and exists (select 1 from turc_private.roster_import_previews p where p.job_id = j.id and p.expires_at <= now());
  delete from turc_private.roster_import_previews p using public.turc_import_jobs j
    where p.job_id = j.id and j.school_id = p_school and p.expires_at <= now();

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_line := v_line + 1;
    if jsonb_typeof(v_row) <> 'object' then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row',v_line,'message','Invalid row structure')); continue; end if;
    if jsonb_typeof(v_row->'student_id') is distinct from 'string' or jsonb_typeof(v_row->'first_name') is distinct from 'string'
      or jsonb_typeof(v_row->'last_name') is distinct from 'string'
      or (v_row ? 'grade' and jsonb_typeof(v_row->'grade') not in ('string','null'))
      or (v_row ? 'classroom' and jsonb_typeof(v_row->'classroom') not in ('string','null')) then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row',v_line,'message','Map text values to Student ID, First Name, Last Name, Grade and Classroom')); continue; end if;
    v_external := btrim(v_row->>'student_id'); v_first := btrim(v_row->>'first_name'); v_last := btrim(v_row->>'last_name');
    v_grade := nullif(btrim(v_row->>'grade'),''); v_classroom := nullif(btrim(v_row->>'classroom'),'');
    if length(v_external) not between 1 and 80 or length(v_first) not between 1 and 100 or length(v_last) not between 1 and 100
      or coalesce(length(v_grade),0) > 40 or coalesce(length(v_classroom),0) > 120 then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row',v_line,'message','Student ID and names are required; check field lengths')); continue; end if;
    if v_external = any(v_seen) then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row',v_line,'message','Duplicate Student ID in this file')); continue; end if;
    v_seen := array_append(v_seen,v_external);
    select * into v_s from public.turc_students where school_id = p_school and external_student_id = v_external;
    select * into v_e from public.turc_enrollments where school_id = p_school and school_year_id = p_year and student_id = v_s.id;
    -- Single-record editing can assert the version shown when its form opened.
    if v_row ? '_expected_version' and (v_s.id is null or v_row->>'_expected_version' <> v_s.row_version::text) then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row',v_line,'message','This student changed. Refresh the roster and edit again.')); continue; end if;
    if v_row ? '_expected_enrollment_version' and v_row->>'_expected_enrollment_version' is distinct from coalesce(v_e.row_version::text,'0') then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('row',v_line,'message','This enrollment changed. Refresh the roster and edit again.')); continue; end if;
    v_normal := jsonb_build_object('student_id',v_external,'first_name',v_first,'last_name',v_last);
    if v_row ? 'grade' then v_normal := v_normal || jsonb_build_object('grade',v_grade); end if;
    if v_row ? 'classroom' then v_normal := v_normal || jsonb_build_object('classroom',v_classroom); end if;
    if v_s.id is null then v_action := 'new'; v_added := v_added + 1;
    elsif v_s.first_name is distinct from v_first or v_s.last_name is distinct from v_last or v_e.id is null
      or (v_row ? 'grade' and v_e.grade is distinct from v_grade) or (v_row ? 'classroom' and v_e.classroom is distinct from v_classroom) then
      v_action := 'update'; v_updated := v_updated + 1;
    else v_action := 'unchanged'; v_unchanged := v_unchanged + 1; end if;
    v_snapshot := jsonb_build_object('values',v_normal,'action',v_action,'existing_id',v_s.id,'student_version',v_s.row_version,
      'enrollment_id',v_e.id,'enrollment_version',v_e.row_version);
    v_rows := v_rows || jsonb_build_array(v_snapshot);
  end loop;
  if jsonb_array_length(v_errors) > 0 then return jsonb_build_object('valid',false,'errors',v_errors); end if;
  insert into public.turc_import_jobs(school_id,school_year_id,requested_by,request_id,status,row_count,summary)
    values(p_school,p_year,auth.uid(),gen_random_uuid(),'preview',jsonb_array_length(v_rows),
      jsonb_build_object('new',v_added,'updated',v_updated,'unchanged',v_unchanged)) returning id into v_job;
  insert into turc_private.roster_import_previews(job_id,rows,year_version) values(v_job,v_rows,v_year.row_version);
  return jsonb_build_object('valid',true,'job_id',v_job,'summary',jsonb_build_object('new',v_added,'updated',v_updated,'unchanged',v_unchanged),
    'rows',(select jsonb_agg(jsonb_build_object('values',r->'values','action',r->>'action')) from jsonb_array_elements(v_rows) r),
    'expires_at',now()+interval '30 minutes');
end;
$$;

create function turc_private.commit_roster_import(p_job uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_job public.turc_import_jobs%rowtype; v_preview turc_private.roster_import_previews%rowtype;
  v_s public.turc_students%rowtype; v_e public.turc_enrollments%rowtype;
  v_row jsonb; v_value jsonb; v_id uuid; v_version bigint; v_result jsonb;
begin
  -- Scope and owner checks happen before returning any job details.
  select * into v_job from public.turc_import_jobs where id = p_job;
  if v_job.id is null or v_job.requested_by is distinct from auth.uid() or not turc_private.school_admin(v_job.school_id) then
    raise exception 'This import is unavailable to your account' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_job.school_id::text, 0));
  select * into v_job from public.turc_import_jobs where id = p_job for update;
  if v_job.status = 'committed' then return v_job.summary || jsonb_build_object('committed',true,'already_committed',true); end if;
  select * into v_preview from turc_private.roster_import_previews where job_id = p_job for update;
  if v_job.status <> 'preview' or v_preview.job_id is null or v_preview.expires_at <= now() then
    raise exception 'This preview expired. Upload the file again.' using errcode = '22023'; end if;
  select row_version into v_version from public.turc_school_years where id = v_job.school_year_id and school_id = v_job.school_id and active for share;
  if v_version is distinct from v_preview.year_version then raise exception 'The school year changed. Create a new preview.' using errcode = '40001'; end if;
  -- Recheck every row before writing anything. Row locks also serialize direct edits.
  for v_row in select value from jsonb_array_elements(v_preview.rows) order by value->'values'->>'student_id' loop
    v_value := v_row->'values';
    select * into v_s from public.turc_students where school_id = v_job.school_id and external_student_id = v_value->>'student_id' for update;
    if v_s.id is distinct from (v_row->>'existing_id')::uuid or v_s.row_version is distinct from (v_row->>'student_version')::bigint then
      raise exception 'The roster changed since this preview. Create a new preview.' using errcode = '40001'; end if;
    select * into v_e from public.turc_enrollments where student_id = v_s.id and school_year_id = v_job.school_year_id and school_id = v_job.school_id for update;
    if v_e.id is distinct from (v_row->>'enrollment_id')::uuid or v_e.row_version is distinct from (v_row->>'enrollment_version')::bigint then
      raise exception 'An enrollment changed since this preview. Create a new preview.' using errcode = '40001'; end if;
  end loop;
  for v_row in select value from jsonb_array_elements(v_preview.rows) order by value->'values'->>'student_id' loop
    v_value := v_row->'values'; v_id := (v_row->>'existing_id')::uuid;
    if v_id is null then
      insert into public.turc_students(school_id,external_student_id,first_name,last_name)
        values(v_job.school_id,v_value->>'student_id',v_value->>'first_name',v_value->>'last_name') returning id into v_id;
    else
      update public.turc_students set first_name = v_value->>'first_name', last_name = v_value->>'last_name'
        where id = v_id and (first_name is distinct from v_value->>'first_name' or last_name is distinct from v_value->>'last_name');
    end if;
    if (v_row->>'enrollment_id') is null then
      insert into public.turc_enrollments(school_id,student_id,school_year_id,grade,classroom)
        values(v_job.school_id,v_id,v_job.school_year_id,v_value->>'grade',v_value->>'classroom');
    else
      update public.turc_enrollments set grade = case when v_value ? 'grade' then v_value->>'grade' else grade end,
        classroom = case when v_value ? 'classroom' then v_value->>'classroom' else classroom end
        where id = (v_row->>'enrollment_id')::uuid and ((v_value ? 'grade' and grade is distinct from v_value->>'grade')
          or (v_value ? 'classroom' and classroom is distinct from v_value->>'classroom'));
    end if;
  end loop;
  v_result := v_job.summary || jsonb_build_object('committed',true,'already_committed',false,'row_count',v_job.row_count);
  update public.turc_import_jobs set status = 'committed', summary = v_result where id = p_job;
  delete from turc_private.roster_import_previews where job_id = p_job;
  return v_result;
exception when unique_violation then
  raise exception 'The roster changed since this preview. Create a new preview.' using errcode = '40001';
end;
$$;
-- Public RPCs deliberately run as the invoker; privileged work remains private
-- and checks caller identity, live Admin membership, school and job ownership.
create function public.turc_preview_roster_import(p_school uuid,p_year uuid,p_rows jsonb) returns jsonb
language sql security invoker set search_path = '' as $$ select turc_private.preview_roster_import(p_school,p_year,p_rows); $$;
create function public.turc_commit_roster_import(p_job uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select turc_private.commit_roster_import(p_job); $$;
revoke all on function turc_private.preview_roster_import(uuid,uuid,jsonb),turc_private.commit_roster_import(uuid),
  public.turc_preview_roster_import(uuid,uuid,jsonb),public.turc_commit_roster_import(uuid) from public,anon,authenticated;
grant execute on function turc_private.preview_roster_import(uuid,uuid,jsonb),turc_private.commit_roster_import(uuid),
  public.turc_preview_roster_import(uuid,uuid,jsonb),public.turc_commit_roster_import(uuid) to authenticated;
comment on function public.turc_preview_roster_import(uuid,uuid,jsonb) is 'Admin-only validated import preview, maximum 1000 rows, no student changes.';
comment on function public.turc_commit_roster_import(uuid) is 'Admin-owned atomic import with version checks and idempotent retries.';
