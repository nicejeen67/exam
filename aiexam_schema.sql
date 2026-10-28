-- =====================================================================
--  AI EXAM (공인중개사 7과목 AI 학습 플랫폼) · Supabase 스키마 (v1)
--  사용법: Supabase 대시보드 → SQL Editor → 이 파일 전체를 붙여넣고 [Run]
--  · 멘토링용 schema.sql 과 같은 프로젝트에 함께 실행해도 됩니다(스키마 ax 로 분리).
--  · 여러 번 실행해도 안전합니다(데이터 유지, 함수만 최신으로 교체).
--
--  구조
--   · 비공개 스키마 ax 에 회원/교안/기출문제/학생 폴더(student_files) 저장
--   · 웹 페이지는 public.ax_* 함수만 호출 → 함수 안에서 로그인·권한 검사
--   · 학생 폴더: student_files.path = '학생아이디/과목명/시험기록/일시_제목.json'
--                                    '학생아이디/과목명/생성모의고사/일시_제목.json'
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists ax;
revoke all on schema ax from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema ax from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema ax from authenticated'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------
create table if not exists ax.subjects (
  id   text primary key,
  name text not null,
  sort int not null default 0
);
insert into ax.subjects(id, name, sort) values
  ('real-estate-intro', '부동산학개론', 1),
  ('real-estate-law', '민법 및 민사특별법', 2),
  ('brokerage-practice', '공인중개사법령 및 중개실무', 3),
  ('real-estate-public-law', '부동산공법', 4),
  ('public-notice-law', '부동산공시법령', 5),
  ('real-estate-tax', '부동산세법', 6),
  ('appraisal-theory', '감정평가론', 7)
on conflict (id) do update set name = excluded.name, sort = excluded.sort;

create table if not exists ax.users (
  id            bigserial primary key,
  username      text not null check (username ~ '^[a-zA-Z0-9_]{4,20}$'),
  password_hash text not null,
  name          text not null check (char_length(name) between 1 and 40),
  role          text not null check (role in ('student', 'professor', 'admin')),
  status        text not null default 'active' check (status in ('active', 'pending', 'rejected')),
  subject_id    text references ax.subjects(id),
  failed_logins int not null default 0,
  locked_until  timestamptz,
  created_at    timestamptz not null default now()
);
create unique index if not exists users_username_lower_idx on ax.users (lower(username));

create table if not exists ax.sessions (
  token_hash text primary key,
  user_id    bigint not null references ax.users(id) on delete cascade,
  expires_at timestamptz not null
);

create table if not exists ax.materials (
  id          bigserial primary key,
  subject_id  text not null references ax.subjects(id),
  week_no     int not null check (week_no between 1 and 15),
  kind        text not null default 'lecture' check (kind in ('lecture', 'exam')),
  title       text not null,
  filename    text not null,
  mime        text not null default 'application/octet-stream',
  size        int not null default 0,
  data        bytea not null,
  uploaded_by bigint references ax.users(id) on delete set null,
  uploader_name text not null default '',
  uploaded_at timestamptz not null default now()
);
create index if not exists materials_subject_idx on ax.materials (subject_id, kind, week_no);

create table if not exists ax.exam_questions (
  id          bigserial primary key,
  subject_id  text not null references ax.subjects(id),
  week_no     int not null check (week_no between 1 and 15),
  question    text not null,
  option1 text not null, option2 text not null, option3 text not null, option4 text not null, option5 text not null,
  answer      int not null check (answer between 1 and 5),
  explanation text not null,
  created_by  bigint references ax.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists questions_subject_idx on ax.exam_questions (subject_id, week_no);

-- 학생 폴더 (시험 기록 + 생성한 모의고사)
create table if not exists ax.student_files (
  id             bigserial primary key,
  owner_id       bigint references ax.users(id) on delete set null,
  owner_username text not null,
  owner_name     text not null default '',
  subject_id     text not null references ax.subjects(id),
  kind           text not null check (kind in ('attempt', 'generated')),
  path           text not null,
  title          text not null,
  subtitle       text not null default '',
  total_questions int,
  correct_count  int,
  score          int,
  content        jsonb not null,
  created_at     timestamptz not null default now()
);
create index if not exists student_files_owner_idx on ax.student_files (lower(owner_username), subject_id, kind);
create index if not exists student_files_subject_idx on ax.student_files (subject_id, kind, created_at desc);

alter table ax.subjects       enable row level security;
alter table ax.users          enable row level security;
alter table ax.sessions       enable row level security;
alter table ax.materials      enable row level security;
alter table ax.exam_questions enable row level security;
alter table ax.student_files  enable row level security;
revoke all on all tables in schema ax from public;

-- ---------------------------------------------------------------------
-- 2. 내부 도우미 (웹에서 호출 불가)
-- ---------------------------------------------------------------------
create or replace function ax.fail(msg text) returns void
language plpgsql as $$ begin raise exception using message = msg, errcode = 'P0001'; end $$;

create or replace function ax.auth(p_token text) returns ax.users
language plpgsql security definer set search_path = ax, extensions, public as $$
declare v ax.users;
begin
  if p_token is null or length(p_token) < 32 then
    raise exception using message = '로그인이 필요합니다.', errcode = '28000';
  end if;
  select u.* into v from ax.sessions s join ax.users u on u.id = s.user_id
   where s.token_hash = encode(digest(p_token, 'sha256'), 'hex') and s.expires_at > now();
  if not found or v.status <> 'active' then
    raise exception using message = '로그인이 만료되었습니다. 다시 로그인해 주세요.', errcode = '28000';
  end if;
  return v;
end $$;

-- 해당 과목을 관리(교안·기출 등록, 전체 기록 열람)할 수 있는가
create or replace function ax.can_manage(u ax.users, p_subject text) returns boolean
language sql immutable as $$
  select u.role = 'admin' or (u.role = 'professor' and u.status = 'active' and u.subject_id = p_subject)
$$;

create or replace function ax.user_json(u ax.users) returns jsonb
language sql stable as $$
  select jsonb_build_object('id', u.id, 'username', u.username, 'name', u.name, 'role', u.role,
    'status', u.status, 'subject_id', u.subject_id,
    'subject_name', (select name from ax.subjects s where s.id = u.subject_id),
    'created_at', u.created_at)
$$;

-- 파일 이름에 쓸 수 없는 문자 정리
create or replace function ax.safe_name(t text) returns text
language sql immutable as $$
  select left(regexp_replace(btrim(coalesce(t, '')), '[\\/:*?"<>|\s]+', '_', 'g'), 60)
$$;

create or replace function ax.file_meta(f ax.student_files) returns jsonb
language sql stable as $$
  select jsonb_build_object('id', f.id, 'path', f.path, 'kind', f.kind, 'subject_id', f.subject_id,
    'subject_name', (select name from ax.subjects s where s.id = f.subject_id),
    'title', f.title, 'subtitle', f.subtitle, 'owner_username', f.owner_username, 'student_name', f.owner_name,
    'total_questions', f.total_questions, 'correct_count', f.correct_count, 'score', f.score,
    'question_count', jsonb_array_length(coalesce(f.content->'questions', '[]'::jsonb)),
    'submitted_at', f.created_at, 'created_at', f.created_at)
$$;

create or replace function ax.new_file(me ax.users, p_subject text, p_kind text, p_title text, p_subtitle text,
                                      p_total int, p_correct int, p_score int, p_content jsonb) returns ax.student_files
language plpgsql security definer set search_path = ax, extensions, public as $$
declare v ax.student_files;
        v_subject_name text;
        v_folder text := case when p_kind = 'attempt' then '시험기록' else '생성모의고사' end;
begin
  select name into v_subject_name from ax.subjects where id = p_subject;
  if v_subject_name is null then perform ax.fail('과목 정보가 올바르지 않습니다.'); end if;
  if jsonb_typeof(p_content->'questions') <> 'array' or jsonb_array_length(p_content->'questions') = 0 then
    perform ax.fail('저장할 문제가 없습니다.');
  end if;
  if jsonb_array_length(p_content->'questions') > 200 or pg_column_size(p_content) > 2000000 then
    perform ax.fail('저장할 내용이 너무 큽니다.');
  end if;
  insert into ax.student_files(owner_id, owner_username, owner_name, subject_id, kind, path, title, subtitle,
                               total_questions, correct_count, score, content)
  values (me.id, me.username, me.name, p_subject, p_kind,
          me.username || '/' || v_subject_name || '/' || v_folder || '/'
            || to_char(now() at time zone 'Asia/Seoul', 'YYYYMMDD-HH24MISS-MS') || '_' || ax.safe_name(p_title) || '.json',
          left(coalesce(nullif(btrim(p_title), ''), '모의고사'), 200), left(coalesce(p_subtitle, ''), 200),
          p_total, p_correct, p_score, p_content)
  returning * into v;
  return v;
end $$;

revoke all on all functions in schema ax from public;

-- ---------------------------------------------------------------------
-- 3. 회원 / 로그인
-- ---------------------------------------------------------------------
create or replace function public.ax_subjects() returns jsonb
language sql security definer set search_path = ax, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort), '[]'::jsonb) from ax.subjects
$$;

create or replace function public.ax_register(p jsonb) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare v_user text := btrim(coalesce(p->>'username', ''));
        v_pw text := coalesce(p->>'password', '');
        v_name text := btrim(coalesce(p->>'name', ''));
        v_role text := coalesce(p->>'role', 'student');
        v_subject text := nullif(p->>'subject_id', '');
begin
  if v_user !~ '^[a-zA-Z0-9_]{4,20}$' then
    perform ax.fail('아이디는 영문, 숫자, 밑줄(_)만 사용해 4~20자로 입력해 주세요. (이 아이디로 학생 폴더가 만들어집니다)');
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
    then '교수 가입 신청이 접수되었습니다. 관리자 승인 후 로그인할 수 있습니다.'
    else '회원가입이 완료되었습니다. 학생 폴더(' || v_user || ')가 준비되었습니다. 로그인해 주세요.' end);
end $$;

create or replace function public.ax_login(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare u ax.users;
        t text := encode(gen_random_bytes(32), 'hex');
begin
  select * into u from ax.users where lower(username) = lower(btrim(coalesce(p_username, '')));
  if not found then
    perform crypt('timing-dummy', gen_salt('bf', 10));
    return jsonb_build_object('error', '아이디 또는 비밀번호가 올바르지 않습니다.');
  end if;
  if u.locked_until is not null and u.locked_until > now() then
    return jsonb_build_object('error', format('로그인 실패가 반복되어 잠시 잠겼습니다. %s분 후 다시 시도해 주세요.',
      greatest(1, ceil(extract(epoch from (u.locked_until - now())) / 60)::int)));
  end if;
  if crypt(coalesce(p_password, ''), u.password_hash) <> u.password_hash then
    update ax.users
       set failed_logins = case when failed_logins + 1 >= 5 then 0 else failed_logins + 1 end,
           locked_until  = case when failed_logins + 1 >= 5 then now() + interval '10 minutes' else locked_until end
     where id = u.id;
    return jsonb_build_object('error', '아이디 또는 비밀번호가 올바르지 않습니다.');
  end if;
  if u.status = 'pending' then return jsonb_build_object('error', '관리자 승인 대기 중인 계정입니다. 승인 후 로그인할 수 있습니다.'); end if;
  if u.status = 'rejected' then return jsonb_build_object('error', '가입이 거부된 계정입니다. 관리자에게 문의해 주세요.'); end if;

  update ax.users set failed_logins = 0, locked_until = null where id = u.id;
  delete from ax.sessions where expires_at < now();
  insert into ax.sessions(token_hash, user_id, expires_at)
  values (encode(digest(t, 'sha256'), 'hex'), u.id, now() + interval '14 days');
  return jsonb_build_object('token', t, 'user', ax.user_json(u));
end $$;

create or replace function public.ax_logout(p_token text) returns jsonb
language sql security definer set search_path = ax, extensions, public as $$
  delete from ax.sessions where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  select jsonb_build_object('ok', true)
$$;

create or replace function public.ax_me(p_token text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
begin return ax.user_json(ax.auth(p_token)); end $$;

create or replace function public.ax_change_password(p_token text, p_current text, p_new text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
begin
  if crypt(coalesce(p_current, ''), me.password_hash) <> me.password_hash then perform ax.fail('현재 비밀번호가 일치하지 않습니다.'); end if;
  if char_length(coalesce(p_new, '')) < 8 or char_length(p_new) > 64 then perform ax.fail('새 비밀번호는 8자 이상 64자 이하로 입력해 주세요.'); end if;
  update ax.users set password_hash = crypt(p_new, gen_salt('bf', 10)) where id = me.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 4. 교안 (주차별 강의자료)
-- ---------------------------------------------------------------------
create or replace function public.ax_materials_list(p_token text, p_subject text, p_kind text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'subject_id', subject_id, 'week_no', week_no,
            'kind', kind, 'title', title, 'filename', filename, 'size', size, 'uploaded_at', uploaded_at,
            'uploader_name', uploader_name) order by week_no, uploaded_at), '[]'::jsonb)
            from ax.materials where subject_id = p_subject and (p_kind is null or kind = p_kind));
end $$;

create or replace function public.ax_material_upload(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_data bytea;
        v_id bigint;
        v_ext text := lower(substring(coalesce(p->>'filename', '') from '\.([A-Za-z0-9]+)$'));
begin
  if not ax.can_manage(me, p->>'subject_id') then perform ax.fail('담당 교수만 교안을 업로드할 수 있습니다.'); end if;
  if coalesce(v_ext, '') not in ('pdf', 'doc', 'docx', 'txt') then perform ax.fail('PDF, Word(doc/docx), TXT 파일만 업로드할 수 있습니다.'); end if;
  begin
    v_data := decode(p->>'data_b64', 'base64');
  exception when others then
    perform ax.fail('파일을 읽을 수 없습니다.');
  end;
  if v_data is null or length(v_data) = 0 then perform ax.fail('빈 파일은 업로드할 수 없습니다.'); end if;
  if length(v_data) > 8 * 1024 * 1024 then perform ax.fail('교안 파일은 8MB 이하만 업로드할 수 있습니다.'); end if;
  insert into ax.materials(subject_id, week_no, kind, title, filename, mime, size, data, uploaded_by, uploader_name)
  values (p->>'subject_id', (p->>'week_no')::int, coalesce(p->>'kind', 'lecture'),
          left(coalesce(nullif(btrim(p->>'title'), ''), p->>'filename'), 200), left(p->>'filename', 200),
          coalesce(nullif(p->>'mime', ''), 'application/octet-stream'), length(v_data), v_data, me.id, me.name)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.ax_material_delete(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_subject text;
begin
  select subject_id into v_subject from ax.materials where id = p_id;
  if v_subject is null then perform ax.fail('교안을 찾을 수 없습니다.'); end if;
  if not ax.can_manage(me, v_subject) then perform ax.fail('담당 교수만 삭제할 수 있습니다.'); end if;
  delete from ax.materials where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.ax_material_download(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        m ax.materials;
begin
  select * into m from ax.materials where id = p_id;
  if not found then perform ax.fail('교안을 찾을 수 없습니다.'); end if;
  return jsonb_build_object('filename', m.filename, 'mime', m.mime, 'data_b64', replace(encode(m.data, 'base64'), E'\n', ''));
end $$;

-- ---------------------------------------------------------------------
-- 5. 기출문제
-- ---------------------------------------------------------------------
create or replace function public.ax_questions_summary(p_token text, p_subject text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('week_no', week_no, 'count', n) order by week_no), '[]'::jsonb)
            from (select week_no, count(*) n from ax.exam_questions where subject_id = p_subject group by week_no) t);
end $$;

create or replace function public.ax_questions_list(p_token text, p_subject text, p_week int) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'week_no', week_no, 'question', question,
            'option1', option1, 'option2', option2, 'option3', option3, 'option4', option4, 'option5', option5,
            'answer', answer, 'explanation', explanation) order by id), '[]'::jsonb)
            from ax.exam_questions where subject_id = p_subject and (p_week is null or week_no = p_week));
end $$;

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
  insert into ax.exam_questions(subject_id, week_no, question, option1, option2, option3, option4, option5, answer, explanation, created_by)
  values (p->>'subject_id', (p->>'week_no')::int, p->>'question', p->>'option1', p->>'option2', p->>'option3',
          p->>'option4', p->>'option5', (p->>'answer')::int, p->>'explanation', me.id)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- 6. 학생 폴더 (시험 기록 · 생성 모의고사)
-- ---------------------------------------------------------------------
create or replace function public.ax_attempt_save(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        f ax.student_files;
begin
  f := ax.new_file(me, p->>'subject_id', 'attempt', p->>'title', coalesce(p->>'subtitle', ''),
                   (p->>'total_questions')::int, (p->>'correct_count')::int, (p->>'score')::int,
                   jsonb_build_object('questions', coalesce(p->'questions', '[]'::jsonb)));
  return ax.file_meta(f);
end $$;

create or replace function public.ax_generated_save(p_token text, p jsonb) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        f ax.student_files;
begin
  f := ax.new_file(me, p->>'subject_id', 'generated', p->>'title', coalesce(p->>'subtitle', ''),
                   jsonb_array_length(coalesce(p->'questions', '[]'::jsonb)), null, null,
                   jsonb_build_object('questions', coalesce(p->'questions', '[]'::jsonb)));
  return ax.file_meta(f);
end $$;

-- 시험 기록 목록 (scope: mine | all — all 은 담당 교수·관리자)
create or replace function public.ax_attempts_list(p_token text, p_subject text, p_scope text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_all boolean := p_scope = 'all' and ax.can_manage(me, p_subject);
begin
  return (select coalesce(jsonb_agg(ax.file_meta(f) order by f.created_at desc), '[]'::jsonb)
            from ax.student_files f
           where f.kind = 'attempt' and f.subject_id = p_subject and (v_all or f.owner_id = me.id));
end $$;

-- 폴더 파일 1개 (본인 · 해당 과목 담당 교수 · 관리자)
create or replace function public.ax_file_get(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        f ax.student_files;
begin
  select * into f from ax.student_files where id = p_id;
  if not found or not (f.owner_id = me.id or ax.can_manage(me, f.subject_id)) then
    perform ax.fail('파일을 찾을 수 없거나 열람 권한이 없습니다.');
  end if;
  return ax.file_meta(f) || jsonb_build_object('questions', f.content->'questions');
end $$;

create or replace function public.ax_file_delete(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
begin
  delete from ax.student_files where id = p_id and (owner_id = me.id or me.role = 'admin');
  if not found then perform ax.fail('삭제할 수 없는 파일입니다.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 학생 폴더 목록: p_username 이 비어 있으면 본인 폴더
--   관리자: 누구의 폴더든 / 교수: 담당 과목 파일만 / 학생: 본인 것만
create or replace function public.ax_folder(p_token text, p_username text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
        v_target text := coalesce(nullif(btrim(p_username), ''), me.username);
        v_owner ax.users;
begin
  if lower(v_target) <> lower(me.username) and me.role = 'student' then
    perform ax.fail('다른 학생의 폴더는 열람할 수 없습니다.');
  end if;
  select * into v_owner from ax.users where lower(username) = lower(v_target);
  return jsonb_build_object(
    'username', coalesce(v_owner.username, v_target),
    'name', coalesce(v_owner.name, (select owner_name from ax.student_files where lower(owner_username) = lower(v_target) limit 1), ''),
    'subjects', public.ax_subjects(),
    'files', (select coalesce(jsonb_agg(ax.file_meta(f) order by f.created_at desc), '[]'::jsonb)
                from ax.student_files f
               where lower(f.owner_username) = lower(v_target)
                 and (lower(v_target) = lower(me.username) or me.role = 'admin' or ax.can_manage(me, f.subject_id))));
end $$;

-- ---------------------------------------------------------------------
-- 7. 관리자 (교수 승인 · 회원 관리)
-- ---------------------------------------------------------------------
create or replace function ax.require_admin(p_token text) returns ax.users
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.auth(p_token);
begin
  if me.role <> 'admin' then perform ax.fail('관리자만 사용할 수 있습니다.'); end if;
  return me;
end $$;
revoke all on function ax.require_admin(text) from public;

create or replace function public.ax_admin_users(p_token text, p_kind text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.require_admin(p_token);
begin
  return (select coalesce(jsonb_agg(ax.user_json(u) || jsonb_build_object(
            'file_count', (select count(*) from ax.student_files f where f.owner_id = u.id)) order by u.created_at desc), '[]'::jsonb)
            from ax.users u
           where (p_kind = 'pending-professors' and u.role = 'professor' and u.status = 'pending')
              or (p_kind = 'professors' and u.role = 'professor')
              or (p_kind = 'students' and u.role = 'student')
              or (p_kind = 'admins' and u.role = 'admin'));
end $$;

create or replace function public.ax_admin_approve(p_token text, p_user_id bigint, p_subject text) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.require_admin(p_token);
begin
  if not exists (select 1 from ax.subjects where id = p_subject) then perform ax.fail('과목을 선택해 주세요.'); end if;
  update ax.users set status = 'active', subject_id = p_subject where id = p_user_id and role = 'professor';
  if not found then perform ax.fail('교수 계정을 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.ax_admin_reject(p_token text, p_user_id bigint) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.require_admin(p_token);
begin
  update ax.users set status = 'rejected' where id = p_user_id and role = 'professor';
  delete from ax.sessions where user_id = p_user_id;
  return jsonb_build_object('ok', true);
end $$;

-- 계정 삭제: 학생 폴더(시험 기록)는 아이디 이름 그대로 보존
create or replace function public.ax_admin_delete_user(p_token text, p_user_id bigint) returns jsonb
language plpgsql security definer set search_path = ax, extensions, public as $$
declare me ax.users := ax.require_admin(p_token);
begin
  if p_user_id = me.id then perform ax.fail('본인 계정은 삭제할 수 없습니다.'); end if;
  delete from ax.users where id = p_user_id;
  if not found then perform ax.fail('계정을 찾을 수 없습니다.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 8. 실행 권한: 웹(anon)은 public.ax_* 함수만 호출
-- ---------------------------------------------------------------------
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

-- =====================================================================
--  [관리자 지정] 웹에서 회원가입(학생으로)한 뒤, 아이디를 바꿔 한 번 실행하세요.
--    update ax.users set role = 'admin', status = 'active', subject_id = null where username = '내아이디';
--  [교수 승인]은 관리자 화면(admin.html)에서 버튼으로 처리합니다.
-- =====================================================================


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
