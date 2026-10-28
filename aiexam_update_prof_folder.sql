-- =====================================================================
--  AI EXAM 업데이트 · 교수 폴더 (v2)
--  이미 aiexam_schema.sql 을 실행한 프로젝트에서 이 파일을 SQL Editor에 붙여넣고 [Run] 하세요.
--  · 여러 번 실행해도 안전합니다. 기존 회원·교안·시험 기록은 그대로 유지됩니다.
--
--  교수가 교안을 올리면   교수아이디/과목명/교안/01주차/일시_파일명      으로 자동 저장
--  교수가 기출을 등록하면 교수아이디/과목명/기출문제/01주차/문항번호      로 자동 정리
--  (학생 폴더는 기존과 동일:  학생아이디/과목명/시험기록·생성모의고사/…)
-- =====================================================================

-- 1. 교안·기출문제에 "올린 교수 아이디"와 "폴더 경로" 기록
alter table ax.materials      add column if not exists uploader_username text not null default '';
alter table ax.materials      add column if not exists path              text not null default '';
alter table ax.exam_questions add column if not exists creator_username  text not null default '';
alter table ax.exam_questions add column if not exists creator_name      text not null default '';
create index if not exists materials_uploader_idx on ax.materials (lower(uploader_username));
create index if not exists questions_creator_idx  on ax.exam_questions (lower(creator_username));

-- 파일명을 폴더 경로용으로 정리 (확장자 유지)
create or replace function ax.safe_filename(t text) returns text
language sql immutable as $$
  select case when t ~ '\.[A-Za-z0-9]{1,8}$'
              then ax.safe_name(regexp_replace(t, '\.[A-Za-z0-9]{1,8}$', '')) || lower(substring(t from '\.[A-Za-z0-9]{1,8}$'))
              else ax.safe_name(t) end
$$;

create or replace function ax.material_path(p_user text, p_subject text, p_week int, p_at timestamptz, p_filename text) returns text
language sql stable as $$
  select p_user || '/' || coalesce((select name from ax.subjects where id = p_subject), p_subject) || '/교안/'
         || lpad(p_week::text, 2, '0') || '주차/'
         || to_char(p_at at time zone 'Asia/Seoul', 'YYYYMMDD-HH24MISS') || '_' || ax.safe_filename(p_filename)
$$;

-- 기존에 올라가 있던 교안·기출도 교수 폴더로 정리
update ax.materials m set uploader_username = u.username
  from ax.users u where m.uploaded_by = u.id and m.uploader_username = '';
update ax.materials set path = ax.material_path(coalesce(nullif(uploader_username, ''), '(알수없음)'), subject_id, week_no, uploaded_at, filename)
 where path = '';
update ax.exam_questions q set creator_username = u.username, creator_name = u.name
  from ax.users u where q.created_by = u.id and q.creator_username = '';

revoke all on all functions in schema ax from public;

-- 2. 회원가입 안내 문구 (교수 폴더 안내 추가)
create or replace function public.ax_register(p jsonb) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare v_user text := btrim(coalesce(p->>'username', ''));
        v_pw text := coalesce(p->>'password', '');
        v_name text := btrim(coalesce(p->>'name', ''));
        v_role text := coalesce(p->>'role', 'student');
        v_subject text := nullif(p->>'subject_id', '');
begin
  if v_user !~ '^[a-zA-Z0-9_]{4,20}$' then
    perform ax.fail('아이디는 영문, 숫자, 밑줄(_)만 사용해 4~20자로 입력해 주세요. (이 아이디로 폴더가 만들어집니다)');
  end if;
  if char_length(v_pw) < 8 or char_length(v_pw) > 64 then perform ax.fail('비밀번호는 8자 이상 64자 이하로 입력해 주세요.'); end if;
  if v_name = '' or char_length(v_name) > 40 then perform ax.fail('이름을 40자 이내로 입력해 주세요.'); end if;
  if v_role not in ('student', 'professor') then perform ax.fail('가입 유형이 올바르지 않습니다.'); end if;
  if v_role = 'professor' and not exists (select 1 from ax.subjects where id = v_subject) then
    perform ax.fail('담당 과목을 선택해 주세요.');
  end if;
  if exists (select 1 from ax.users where lower(username) = lower(v_user)) then perform ax.fail('이미 사용 중인 아이디입니다.'); end if;

  insert into ax.users(username, password_hash, name, role, status, subject_id)
  values (v_user, crypt(v_pw, gen_salt('bf', 10)), v_name, v_role,
          case when v_role = 'professor' then 'pending' else 'active' end,
          case when v_role = 'professor' then v_subject end);

  return jsonb_build_object('message', case when v_role = 'professor'
    then '교수 가입 신청이 접수되었습니다. 교수 폴더(' || v_user || '/)가 준비되었으며, 관리자 승인 후 로그인할 수 있습니다.'
    else '회원가입이 완료되었습니다. 학생 폴더(' || v_user || '/)가 준비되었습니다. 로그인해 주세요.' end);
end $$;

-- 3. 교안 업로드 → 교수 폴더에 저장
create or replace function public.ax_material_upload(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_data bytea;
        v_id bigint;
        v_path text;
        v_week int := (p->>'week_no')::int;
        v_ext text := lower(substring(coalesce(p->>'filename', '') from '\.([A-Za-z0-9]+)$'));
begin
  if not ax.can_manage(me, p->>'subject_id') then perform ax.fail('담당 교수만 교안을 업로드할 수 있습니다.'); end if;
  if v_week is null or v_week not between 1 and 15 then perform ax.fail('주차(1~15)를 선택해 주세요.'); end if;
  if coalesce(v_ext, '') not in ('pdf', 'doc', 'docx', 'txt') then perform ax.fail('PDF, Word(doc/docx), TXT 파일만 업로드할 수 있습니다.'); end if;
  begin
    v_data := decode(p->>'data_b64', 'base64');
  exception when others then
    perform ax.fail('파일을 읽을 수 없습니다.');
  end;
  if v_data is null or length(v_data) = 0 then perform ax.fail('빈 파일은 업로드할 수 없습니다.'); end if;
  if length(v_data) > 8 * 1024 * 1024 then perform ax.fail('교안 파일은 8MB 이하만 업로드할 수 있습니다.'); end if;
  v_path := ax.material_path(me.username, p->>'subject_id', v_week, now(), p->>'filename');
  insert into ax.materials(subject_id, week_no, kind, title, filename, mime, size, data, uploaded_by, uploader_name, uploader_username, path)
  values (p->>'subject_id', v_week, coalesce(p->>'kind', 'lecture'),
          left(coalesce(nullif(btrim(p->>'title'), ''), p->>'filename'), 200), left(p->>'filename', 200),
          coalesce(nullif(p->>'mime', ''), 'application/octet-stream'), length(v_data), v_data, me.id, me.name, me.username, v_path)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'path', v_path);
end $$;

-- 교안 목록에도 경로·올린 사람 아이디 포함
create or replace function public.ax_materials_list(p_token text, p_subject text, p_kind text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'subject_id', subject_id, 'week_no', week_no,
            'kind', kind, 'title', title, 'filename', filename, 'size', size, 'uploaded_at', uploaded_at,
            'uploader_name', uploader_name, 'uploader_username', uploader_username, 'path', path)
            order by week_no, uploaded_at), '[]'::jsonb)
            from ax.materials where subject_id = p_subject and (p_kind is null or kind = p_kind));
end $$;

-- 4. 기출문제 등록 → 교수 폴더에 기록
create or replace function public.ax_question_add(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_id bigint;
begin
  if not ax.can_manage(me, p->>'subject_id') then perform ax.fail('담당 교수만 기출문제를 등록할 수 있습니다.'); end if;
  if coalesce(btrim(p->>'question'), '') = '' or coalesce(btrim(p->>'explanation'), '') = ''
     or coalesce(btrim(p->>'option1'), '') = '' or coalesce(btrim(p->>'option2'), '') = '' or coalesce(btrim(p->>'option3'), '') = ''
     or coalesce(btrim(p->>'option4'), '') = '' or coalesce(btrim(p->>'option5'), '') = '' then
    perform ax.fail('문항·보기 5개·해설을 모두 입력해 주세요.');
  end if;
  insert into ax.exam_questions(subject_id, week_no, question, option1, option2, option3, option4, option5,
                                answer, explanation, created_by, creator_username, creator_name)
  values (p->>'subject_id', (p->>'week_no')::int, p->>'question', p->>'option1', p->>'option2', p->>'option3',
          p->>'option4', p->>'option5', (p->>'answer')::int, p->>'explanation', me.id, me.username, me.name)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- 기출문제 삭제 (해당 과목 담당 교수 · 관리자)
create or replace function public.ax_question_delete(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_subject text;
begin
  select subject_id into v_subject from ax.exam_questions where id = p_id;
  if v_subject is null then perform ax.fail('문제를 찾을 수 없습니다.'); end if;
  if not ax.can_manage(me, v_subject) then perform ax.fail('담당 교수만 삭제할 수 있습니다.'); end if;
  delete from ax.exam_questions where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 5. 교수 폴더 조회
--    p_username 비우면 본인 폴더 / 관리자는 다른 교수 폴더도 열람 가능
create or replace function public.ax_prof_folder(p_token text, p_username text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_target text := coalesce(nullif(btrim(p_username), ''), me.username);
        v_owner ax.users;
begin
  if me.role = 'student' then perform ax.fail('교수 폴더는 교수·관리자만 사용할 수 있습니다.'); end if;
  if lower(v_target) <> lower(me.username) and me.role <> 'admin' then
    perform ax.fail('다른 교수의 폴더는 관리자만 열람할 수 있습니다.');
  end if;
  select * into v_owner from ax.users where lower(username) = lower(v_target);
  return jsonb_build_object(
    'username', coalesce(v_owner.username, v_target),
    'name', coalesce(v_owner.name, ''),
    'role', v_owner.role,
    'subject_id', v_owner.subject_id,
    'subject_name', (select name from ax.subjects where id = v_owner.subject_id),
    'subjects', public.ax_subjects(),
    'materials', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', m.id, 'path', m.path, 'subject_id', m.subject_id,
                    'subject_name', (select name from ax.subjects s where s.id = m.subject_id),
                    'week_no', m.week_no, 'title', m.title, 'filename', m.filename, 'size', m.size,
                    'uploaded_at', m.uploaded_at) order by m.subject_id, m.week_no, m.uploaded_at desc), '[]'::jsonb)
                  from ax.materials m where lower(m.uploader_username) = lower(v_target)),
    'questions', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', q.id, 'subject_id', q.subject_id,
                    'subject_name', (select name from ax.subjects s where s.id = q.subject_id),
                    'week_no', q.week_no, 'question', q.question,
                    'options', jsonb_build_array(q.option1, q.option2, q.option3, q.option4, q.option5),
                    'answer', q.answer, 'explanation', q.explanation, 'created_at', q.created_at)
                    order by q.subject_id, q.week_no, q.id), '[]'::jsonb)
                  from ax.exam_questions q where lower(q.creator_username) = lower(v_target)));
end $$;

-- 6. 실행 권한 (새 함수 포함) 다시 부여
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'ax\_%'
  loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon', r.sig); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('grant execute on function %s to authenticated', r.sig); end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
