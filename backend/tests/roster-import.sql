-- Run with a trusted database connection. All fixtures, including auth users,
-- exist only inside this transaction. No real login credentials are created.
begin;
select set_config('turc.test_results', '[]', true);
do $test$
declare
  district_a uuid := gen_random_uuid(); district_b uuid := gen_random_uuid();
  school_a uuid := gen_random_uuid(); school_a2 uuid := gen_random_uuid(); school_b uuid := gen_random_uuid();
  year_a uuid := gen_random_uuid(); year_a2 uuid := gen_random_uuid(); year_b uuid := gen_random_uuid();
  district_admin uuid := gen_random_uuid(); school_admin uuid := gen_random_uuid();
  staff_a uuid := gen_random_uuid(); staff_b uuid := gen_random_uuid(); parent_a uuid := gen_random_uuid(); outsider uuid := gen_random_uuid();
  child_a uuid := gen_random_uuid(); child_a_other uuid := gen_random_uuid(); child_a_archived uuid := gen_random_uuid();
  child_a2 uuid := gen_random_uuid(); child_b uuid := gen_random_uuid();
  user_ids uuid[]; student_ids uuid[]; fixture_user uuid;
  v_count integer; v_version bigint; v_label text; v_role text; v_expected integer;
  v_results jsonb := '[]'::jsonb; v_test integer := 0;
  preview jsonb; committed jsonb; job uuid; first_version bigint; before_count integer;
begin
  user_ids := array[district_admin, school_admin, staff_a, staff_b, parent_a, outsider];
  student_ids := array[child_a, child_a_other, child_a_archived, child_a2, child_b];
  foreach fixture_user in array user_ids loop
    insert into auth.users(id, email, aud, role, is_anonymous)
      values (fixture_user, 'turc-test-' || fixture_user::text || '@example.invalid', 'authenticated', 'authenticated', false);
    insert into public.turc_accounts(user_id, display_name) values (fixture_user, 'Fictional permission tester');
  end loop;
  insert into public.turc_districts(id, name) values (district_a, 'Fictional District A'), (district_b, 'Fictional District B');
  insert into public.turc_schools(id, district_id, name) values
    (school_a, district_a, 'Fictional School A'), (school_a2, district_a, 'Fictional School A2'), (school_b, district_b, 'Fictional School B');
  insert into public.turc_school_years(id, school_id, label, starts_on, ends_on, active) values
    (year_a, school_a, '2026–27', '2026-08-01', '2027-07-31', true),
    (year_a2, school_a2, '2026–27', '2026-08-01', '2027-07-31', true),
    (year_b, school_b, '2026–27', '2026-08-01', '2027-07-31', true);
  insert into public.turc_students(id, school_id, external_student_id, first_name, last_name, active) values
    (child_a, school_a, '000123', 'Maya', 'Fictional', true),
    (child_a_other, school_a, '000124', 'Oliver', 'Fictional', true),
    (child_a_archived, school_a, '000125', 'Archived', 'Fictional', false),
    (child_a2, school_a2, '000123', 'Second School', 'Fictional', true),
    (child_b, school_b, '000123', 'Other District', 'Fictional', true);
  insert into public.turc_enrollments(school_id, student_id, school_year_id, grade, classroom) values
    (school_a, child_a, year_a, '3', 'Parker'), (school_a, child_a_other, year_a, '4', 'Brooks'),
    (school_b, child_b, year_b, '2', 'Patel');
  insert into public.turc_memberships(user_id, district_id, school_id, role) values
    (district_admin, district_a, null, 'admin'), (school_admin, district_a, school_a, 'admin'),
    (staff_a, district_a, school_a, 'staff'), (staff_b, district_b, school_b, 'staff'),
    (parent_a, district_a, school_a, 'parent');
  insert into public.turc_guardian_links(guardian_user_id, school_id, student_id) values (parent_a, school_a, child_a);

  perform set_config('request.jwt.claim.sub',staff_a::text,true);
  execute 'set local role authenticated';
  begin perform public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"N1","first_name":"New","last_name":"Runner"}]');
    raise exception 'Staff preview allowed'; exception when insufficient_privilege then v_results := v_results || '[{"test":"Staff import preview denied","passed":true}]'; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',school_admin::text,true);
  execute 'set local role authenticated';
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"N1","first_name":"New","last_name":""}]');
  if (preview->>'valid')::boolean or jsonb_array_length(preview->'errors') <> 1 then raise exception 'Invalid row accepted'; end if;
  v_results := v_results || '[{"test":"Invalid row blocks preview","passed":true}]';
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"N1","first_name":"New","last_name":"Runner"},{"student_id":"N1","first_name":"Other","last_name":"Runner"}]');
  if (preview->>'valid')::boolean then raise exception 'Duplicate file IDs accepted'; end if;
  v_results := v_results || '[{"test":"Duplicate IDs block preview","passed":true}]';
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":123,"first_name":"New","last_name":"Runner"}]');
  if (preview->>'valid')::boolean then raise exception 'Numeric ID accepted'; end if;
  v_results := v_results || '[{"test":"Student IDs must remain text","passed":true}]';
  begin perform public.turc_preview_roster_import(school_b,year_b,'[{"student_id":"N1","first_name":"New","last_name":"Runner"}]');
    raise exception 'Cross-school preview allowed'; exception when insufficient_privilege then v_results := v_results || '[{"test":"Cross-school preview denied","passed":true}]'; end;
  select count(*) into before_count from public.turc_students where school_id=school_a;
  preview := public.turc_preview_roster_import(school_a,year_a,
    '[{"student_id":"000123","first_name":"Maya Updated","last_name":"Fictional"},{"student_id":"000999","first_name":"New","last_name":"Runner","grade":"5","classroom":"Reed"}]');
  if not (preview->>'valid')::boolean or (preview->'summary'->>'new')::integer <> 1 or (preview->'summary'->>'updated')::integer <> 1 then raise exception 'Preview summary incorrect: %',preview; end if;
  job := (preview->>'job_id')::uuid;
  select count(*) into v_count from public.turc_students where school_id=school_a;
  if v_count <> before_count or exists(select 1 from public.turc_students where id=child_a and first_name='Maya Updated') then raise exception 'Preview modified students'; end if;
  v_results := v_results || '[{"test":"Preview summarizes changes without student writes","passed":true}]';
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',district_admin::text,true);
  execute 'set local role authenticated';
  begin perform public.turc_commit_roster_import(job); raise exception 'Different Admin committed job';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Import preview belongs to its creator","passed":true}]'; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',parent_a::text,true);
  execute 'set local role authenticated';
  begin perform public.turc_commit_roster_import(job); raise exception 'Parent committed job';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Parent cannot commit an import","passed":true}]'; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',school_admin::text,true);
  execute 'set local role authenticated';
  committed := public.turc_commit_roster_import(job);
  if not (committed->>'committed')::boolean then raise exception 'Commit failed'; end if;
  select count(*) into v_count from public.turc_students where school_id=school_a;
  if v_count <> before_count + 1 then raise exception 'Commit student count incorrect'; end if;
  if not exists(select 1 from public.turc_students where school_id=school_a and external_student_id='000999') then raise exception 'New ID lost leading zeros'; end if;
  if not exists(select 1 from public.turc_enrollments where student_id=child_a and grade='3' and classroom='Parker') then raise exception 'Unmapped optional field overwritten'; end if;
  v_results := v_results || '[{"test":"Commit saves new students and updates together","passed":true},{"test":"Unmapped grade and classroom are preserved","passed":true},{"test":"New Student ID retains leading zeros","passed":true}]';
  select row_version into first_version from public.turc_students where id=child_a;
  committed := public.turc_commit_roster_import(job);
  if not (committed->>'already_committed')::boolean then raise exception 'Retry was not idempotent'; end if;
  select row_version into v_version from public.turc_students where id=child_a;
  if v_version <> first_version then raise exception 'Retry changed version'; end if;
  v_results := v_results || '[{"test":"Commit retry is idempotent","passed":true}]';
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Maya Updated","last_name":"Fictional","grade":"","classroom":""}]');
  perform public.turc_commit_roster_import((preview->>'job_id')::uuid);
  if exists(select 1 from public.turc_enrollments where student_id=child_a and (grade is not null or classroom is not null)) then raise exception 'Mapped blank did not clear field'; end if;
  v_results := v_results || '[{"test":"Mapped blanks clear optional fields","passed":true}]';
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Maya Updated","last_name":"Fictional"}]');
  if (preview->'summary'->>'unchanged')::integer <> 1 then raise exception 'Unchanged row not detected'; end if;
  perform public.turc_commit_roster_import((preview->>'job_id')::uuid);
  v_results := v_results || '[{"test":"Re-import identifies unchanged records","passed":true}]';

  -- A stale preview includes a new student; none of its rows may commit.
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Old Edit","last_name":"Fictional"},{"student_id":"NEW-STALE","first_name":"Must Not","last_name":"Persist"}]');
  job := (preview->>'job_id')::uuid;
  update public.turc_students set first_name='Newer Edit' where id=child_a;
  begin perform public.turc_commit_roster_import(job); raise exception 'Stale commit allowed';
    exception when serialization_failure then v_results := v_results || '[{"test":"Stale student version rejects entire import","passed":true}]'; end;
  if exists(select 1 from public.turc_students where school_id=school_a and external_student_id='NEW-STALE') then raise exception 'Partial stale import leaked'; end if;
  v_results := v_results || '[{"test":"Failed import leaves no partial new students","passed":true}]';
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Newer Edit","last_name":"Fictional","grade":"4"}]');
  job := (preview->>'job_id')::uuid;
  update public.turc_enrollments set grade='2' where student_id=child_a;
  begin perform public.turc_commit_roster_import(job); raise exception 'Stale enrollment commit allowed';
    exception when serialization_failure then v_results := v_results || '[{"test":"Stale enrollment rejects import","passed":true}]'; end;
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Newer Edit","last_name":"Fictional","_expected_version":9999}]');
  if (preview->>'valid')::boolean then raise exception 'Stale edit form accepted'; end if;
  v_results := v_results || '[{"test":"Stale edit form requires refresh","passed":true}]';

  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Newer Edit","last_name":"Fictional"}]');
  job := (preview->>'job_id')::uuid;
  execute 'reset role';
  update turc_private.roster_import_previews set expires_at=now()-interval '1 minute' where job_id=job;
  execute 'set local role authenticated';
  begin perform public.turc_commit_roster_import(job); raise exception 'Expired commit allowed';
    exception when invalid_parameter_value then v_results := v_results || '[{"test":"Expired preview cannot commit","passed":true}]'; end;
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Newer Edit","last_name":"Fictional"}]');
  job := (preview->>'job_id')::uuid;
  update public.turc_school_years set label='2026–2027' where id=year_a;
  begin perform public.turc_commit_roster_import(job); raise exception 'Changed-year commit allowed';
    exception when serialization_failure then v_results := v_results || '[{"test":"Changed school year invalidates preview","passed":true}]'; end;
  preview := public.turc_preview_roster_import(school_a,year_a,'[{"student_id":"000123","first_name":"Newer Edit","last_name":"Fictional"}]');
  job := (preview->>'job_id')::uuid;
  execute 'reset role';
  update public.turc_memberships set active=false where user_id=school_admin;
  execute 'set local role authenticated';
  begin perform public.turc_commit_roster_import(job); raise exception 'Revoked Admin committed';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Revoked Admin cannot commit an existing preview","passed":true}]'; end;
  execute 'reset role';
  perform set_config('turc.test_results',v_results::text,true);
end;
$test$;
select jsonb_array_length(current_setting('turc.test_results')::jsonb) as passed_count,current_setting('turc.test_results')::jsonb as checks;
rollback;
