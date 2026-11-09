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

  -- Every visibility check executes as the actual authenticated database role.
  for v_test in 1..6 loop
    fixture_user := user_ids[v_test];
    v_expected := (array[4,3,2,1,1,0])[v_test];
    v_label := (array['district Admin sees only own district', 'school Admin sees only own school',
      'Staff sees only active assigned-school students', 'other-district Staff is isolated',
      'Parent sees only linked child', 'unassigned user has no student access'])[v_test];
    perform set_config('request.jwt.claim.sub', fixture_user::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub',fixture_user,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into v_count from public.turc_students where id = any(student_ids);
    if v_count <> v_expected then raise exception 'FAILED: % (expected %, got %)', v_label, v_expected, v_count; end if;
    v_results := v_results || jsonb_build_array(jsonb_build_object('test',v_label,'passed',true));
    execute 'reset role';
  end loop;

  -- Unknown/anonymous visitors cannot read student records or authorization helpers.
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  begin perform count(*) from public.turc_students; raise exception 'Anonymous student read succeeded';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Anonymous student access denied","passed":true}]'; end;
  begin perform turc_private.active_user(); raise exception 'Anonymous private helper executed';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Anonymous private helper access denied","passed":true}]'; end;
  execute 'reset role';

  -- Staff write attempts, including self-promotion, must fail or affect zero rows.
  perform set_config('request.jwt.claim.sub', staff_a::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',staff_a,'role','authenticated',
    'user_metadata',jsonb_build_object('role','admin','district_id',district_b))::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.turc_students where school_id = school_b;
  if v_count <> 0 then raise exception 'Forged user metadata granted access'; end if;
  v_results := v_results || '[{"test":"User metadata cannot grant Admin access","passed":true}]';
  begin insert into public.turc_students(school_id, external_student_id, first_name, last_name)
    values (school_a, 'STAFF-WRITE', 'Blocked', 'Fictional'); raise exception 'Staff inserted a student';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Staff student creation denied","passed":true}]'; end;
  update public.turc_students set first_name = 'Tampered' where id = child_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then raise exception 'Staff edited student'; end if;
  v_results := v_results || '[{"test":"Staff student editing denied","passed":true}]';
  update public.turc_memberships set role = 'admin' where user_id = staff_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then raise exception 'Staff self-promoted'; end if;
  v_results := v_results || '[{"test":"Staff self-promotion denied","passed":true}]';
  begin insert into public.turc_memberships(user_id, district_id, school_id, role)
    values (staff_a, district_a, school_a, 'admin'); raise exception 'Staff created Admin membership';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Staff membership insertion denied","passed":true}]'; end;
  begin update public.turc_accounts set active = false where user_id = staff_a; raise exception 'User changed activation';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Account activation is server-owned","passed":true}]'; end;
  begin insert into public.turc_audit_events(relation_name, record_id, operation)
    values ('fake', child_a, 'UPDATE'); raise exception 'Staff forged audit event';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Audit event forgery denied","passed":true}]'; end;
  begin delete from public.turc_students where id = child_a; raise exception 'Staff deleted student';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Direct student deletion denied","passed":true}]'; end;
  execute 'reset role';

  -- School Admin cannot reach a second school or create a district-level Admin.
  perform set_config('request.jwt.claim.sub', school_admin::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',school_admin,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into public.turc_students(school_id, external_student_id, first_name, last_name)
    values (school_a2, 'WRONG-SCHOOL', 'Blocked', 'Fictional'); raise exception 'Admin inserted into other school';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"School Admin cross-school insert denied","passed":true}]'; end;
  begin insert into public.turc_memberships(user_id, district_id, role)
    values (outsider, district_a, 'admin'); raise exception 'School Admin granted district access';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"School Admin district promotion denied","passed":true}]'; end;
  begin update public.turc_students set school_id = school_a2 where id = child_a; raise exception 'Tenant move allowed';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Student tenant movement denied","passed":true}]'; end;
  select row_version into v_version from public.turc_students where id = child_a;
  update public.turc_students set first_name = 'Maya Updated' where id = child_a;
  select count(*) into v_count from public.turc_students where id = child_a and row_version = v_version + 1;
  if v_count <> 1 then raise exception 'Admin update/version failed'; end if;
  v_results := v_results || '[{"test":"School Admin can update own student with server versioning","passed":true}]';
  begin update public.turc_students set row_version = 9999 where id = child_a; raise exception 'Version forged';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Client row-version forgery denied","passed":true}]'; end;
  select count(*) into v_count from public.turc_audit_events
    where record_id = child_a and actor_user_id = school_admin and operation = 'UPDATE' and 'first_name' = any(changed_fields);
  if v_count <> 1 then raise exception 'Admin update was not audited'; end if;
  v_results := v_results || '[{"test":"Authorized changes produce audit records","passed":true}]';
  begin insert into public.turc_import_jobs(school_id, school_year_id, requested_by, request_id, status, row_count)
    values (school_a, year_a, school_admin, gen_random_uuid(), 'committed', 1); raise exception 'Client forged import commit';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Import commit bookkeeping is server-owned","passed":true}]'; end;
  begin insert into public.turc_students(school_id, external_student_id, first_name, last_name)
    values (school_a, '000123', 'Duplicate', 'Fictional'); raise exception 'Duplicate Student ID accepted';
    exception when unique_violation then v_results := v_results || '[{"test":"Duplicate school Student ID rejected","passed":true}]'; end;
  begin insert into public.turc_enrollments(school_id, student_id, school_year_id)
    values (school_a, child_a, year_a2); raise exception 'Cross-school enrollment accepted';
    exception when foreign_key_violation then v_results := v_results || '[{"test":"Cross-school enrollment rejected","passed":true}]'; end;
  begin insert into public.turc_school_years(school_id,label,starts_on,ends_on)
    values (school_a,'Overlap','2027-01-01','2027-12-31'); raise exception 'Overlapping year accepted';
    exception when exclusion_violation then v_results := v_results || '[{"test":"Overlapping school years rejected","passed":true}]'; end;
  begin update public.turc_schools set timezone = 'Fake/Timezone' where id = school_a; raise exception 'Invalid timezone accepted';
    exception when check_violation then v_results := v_results || '[{"test":"Invalid school timezone rejected","passed":true}]'; end;
  select count(*) into v_count from public.turc_students where id = child_a and external_student_id = '000123';
  if v_count <> 1 then raise exception 'Leading zero Student ID changed'; end if;
  v_results := v_results || '[{"test":"Student ID leading zeros preserved","passed":true}]';
  execute 'reset role';

  -- Parent cannot claim a different child, write students, or read roster imports.
  perform set_config('request.jwt.claim.sub', parent_a::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',parent_a,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into public.turc_guardian_links(guardian_user_id, school_id, student_id)
    values (parent_a, school_a, child_a_other); raise exception 'Parent claimed another child';
    exception when insufficient_privilege then v_results := v_results || '[{"test":"Parent cannot self-link a child","passed":true}]'; end;
  update public.turc_students set last_name = 'Tampered' where id = child_a;
  get diagnostics v_count = row_count;
  if v_count <> 0 then raise exception 'Parent edited child identity'; end if;
  v_results := v_results || '[{"test":"Parent student editing denied","passed":true}]';
  select count(*) into v_count from public.turc_enrollments;
  if v_count <> 1 then raise exception 'Parent enrollment visibility incorrect'; end if;
  v_results := v_results || '[{"test":"Parent sees only linked enrollment","passed":true}]';
  select count(*) into v_count from public.turc_audit_events;
  if v_count <> 0 then raise exception 'Parent sees audit records'; end if;
  v_results := v_results || '[{"test":"Parent audit access denied","passed":true}]';
  execute 'reset role';

  -- Revocation takes effect with unchanged JWTs because memberships are read live.
  perform set_config('request.jwt.claim.sub', district_admin::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',district_admin,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  update public.turc_memberships set active = false where user_id = staff_a and school_id = school_a;
  get diagnostics v_count = row_count;
  if v_count <> 1 then raise exception 'District Admin could not revoke Staff'; end if;
  update public.turc_guardian_links set active = false where guardian_user_id = parent_a;
  get diagnostics v_count = row_count;
  if v_count <> 1 then raise exception 'District Admin could not revoke guardian link'; end if;
  execute 'reset role';
  foreach fixture_user in array array[staff_a,parent_a] loop
    perform set_config('request.jwt.claim.sub', fixture_user::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub',fixture_user,'role','authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into v_count from public.turc_students;
    if v_count <> 0 then raise exception 'Revoked user still reads students'; end if;
    execute 'reset role';
  end loop;
  v_results := v_results || '[{"test":"Membership revocation immediately removes Staff access","passed":true},{"test":"Guardian-link revocation immediately removes child access","passed":true}]';

  -- Removing the Parent role also disables a still-active guardian link.
  update public.turc_guardian_links set active = true where guardian_user_id = parent_a;
  update public.turc_memberships set active = false where user_id = parent_a;
  perform set_config('request.jwt.claim.sub', parent_a::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',parent_a,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.turc_students;
  if v_count <> 0 then raise exception 'Parent without membership still reads child'; end if;
  v_results := v_results || '[{"test":"Parent membership revocation disables existing guardian link","passed":true}]';
  execute 'reset role';

  update public.turc_accounts set active = false where user_id = school_admin;
  perform set_config('request.jwt.claim.sub', school_admin::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub',school_admin,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.turc_students;
  if v_count <> 0 then raise exception 'Inactive account retained Admin access'; end if;
  v_results := v_results || '[{"test":"Account deactivation immediately removes Admin access","passed":true}]';
  execute 'reset role';

  perform set_config('turc.test_results', v_results::text, true);
end;
$test$;
select jsonb_array_length(current_setting('turc.test_results')::jsonb) as passed_count,
       current_setting('turc.test_results')::jsonb as checks;
rollback;
