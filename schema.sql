-- =====================================================================
-- 방과후학교 시스템 : Supabase 데이터베이스 스키마
-- Supabase > SQL Editor 에 이 파일 전체를 붙여넣고 [Run] 하세요.
-- (여러 번 실행해도 기존 데이터는 지워지지 않습니다.)
--
-- 보안 구조
--  * 모든 테이블은 RLS 를 켜고 정책을 두지 않습니다 → 웹에서 테이블 직접 접근 불가
--  * 웹앱은 아래 as_ 로 시작하는 함수(RPC)만 호출합니다
--  * 비밀번호는 pgcrypto(bcrypt) 해시로만 저장합니다
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 테이블 ----------------------------------------------------
create table if not exists as_settings (
  id           int primary key default 1 check (id = 1),
  title        text    not null default '방과후학교',
  start_date   date,
  end_date     date,
  enroll_open  boolean not null default false,   -- 학생 수강신청 가능 여부
  course_open  boolean not null default true,    -- 교사 강좌 개설/수정 가능 여부
  min_students int     not null default 5        -- 폐강 검토 기준 인원
);
insert into as_settings (id) values (1) on conflict do nothing;
-- 전체 공통 설정: 첫 로그인(또는 비밀번호 초기화 후) 때 비밀번호 변경을 강제할지 여부 — 관리자가 화면에서 켜고 끕니다
alter table as_settings add column if not exists force_pw_change boolean not null default true;

create table if not exists as_types (
  code        text primary key,
  name        text  not null,
  days        int[] not null,                    -- 1=월 2=화 3=수 4=목 5=금
  assign_only boolean not null default false,    -- true: 교사가 학생을 지정(학생 신청 불가)
  sort        int   not null default 0
);
alter table as_types add column if not exists active     boolean not null default true;  -- false: 새 강좌 개설 목록에서 숨김
alter table as_types add column if not exists period     text    not null default '';    -- 기본 교시 안내 (예: 8·9교시)
alter table as_types add column if not exists solo_group text;                            -- 같은 묶음 안에서는 한 강좌만 수강 (예: 기초A·기초B)

-- 강좌 유형 (days 는 '기본 요일' 이며, 강좌마다 요일을 따로 고를 수 있습니다)
insert into as_types (code, name, days, assign_only, sort, period, solo_group) values
  ('A',  '자격A',    '{1,2}',       false, 1, '8·9교시 (16:40~18:30)', null),
  ('B',  '자격B',    '{4,5}',       false, 2, '8·9교시 (16:40~18:30)', null),
  ('G',  '금공반',   '{1,2}',       false, 3, '8·9교시 (16:40~18:30)', null),
  ('KA', '기초A',    '{4}',         true,  4, '8교시 (16:40~17:30)',   '기초'),
  ('KB', '기초B',    '{5}',         true,  5, '8교시 (16:40~17:30)',   '기초'),
  ('GM', '공무원반', '{1,2,3,4,5}', true,  6, '8·9교시 (16:40~18:30)', null),
  ('TS', '기술사관', '{1,2,5}',     true,  7, '8·9·10교시',            null)
on conflict (code) do nothing;
-- 이전 버전의 기본 유형 정리: 교시 안내 채우기, 예전 '기초반'·'상경진반'은 숨김(기록은 유지)
update as_types set period = '8·9교시 (16:40~18:30)' where code in ('A','B','G') and period = '';
update as_types set active = false where code in ('K','S');
-- 금공반: 선생님이 수강생을 지정하는 강좌로 변경 (학생 직접 신청 불가)
update as_types set assign_only = true where code = 'G';

-- 방과후학교 운영 단위(예: 2026년 겨울방학, 2027학년도 1학기 …) — 계속 누적됩니다
create table if not exists as_terms (
  id           bigint generated always as identity primary key,
  title        text    not null,
  start_date   date,
  end_date     date,
  enroll_open  boolean not null default false,   -- 학생 수강신청 가능 여부
  course_open  boolean not null default true,    -- 교사 강좌 개설/수정 가능 여부
  min_students int     not null default 5,       -- 폐강 검토 기준 인원
  created_at   timestamptz not null default now()
);

create table if not exists as_teachers (
  id          bigint generated always as identity primary key,
  name        text not null unique,
  pw_hash     text not null,
  is_admin    boolean not null default false,
  must_change boolean not null default true
);

create table if not exists as_students (
  id          bigint generated always as identity primary key,
  grade       int  not null,
  class       int  not null,
  number      int  not null,
  name        text not null,
  pw_hash     text not null,
  must_change boolean not null default true,
  unique (grade, class, number)
);

create table if not exists as_courses (
  id         bigint generated always as identity primary key,
  term_id    bigint references as_terms(id),
  type_code  text   not null references as_types(code),
  title      text   not null,
  teacher_id bigint not null references as_teachers(id),
  room       text   not null default '',
  grades     int[]  not null default '{1,2,3}',
  capacity   int,                                 -- null = 인원 제한 없음
  status     text   not null default 'open' check (status in ('open','closed','cancelled')),
  days       int[],                               -- 수업 요일 (1=월 … 5=금). 강좌마다 지정
  period     text   not null default '',          -- 교시·시간 안내
  dates      date[] not null default '{}',
  created_at timestamptz not null default now()
);

create table if not exists as_enrollments (
  id         bigint generated always as identity primary key,
  course_id  bigint not null references as_courses(id)  on delete cascade,
  student_id bigint not null references as_students(id) on delete cascade,
  assigned   boolean not null default false,      -- true: 교사가 지정
  created_at timestamptz not null default now(),
  unique (course_id, student_id)
);

create table if not exists as_sessions (
  token      uuid primary key default gen_random_uuid(),
  role       text   not null check (role in ('student','teacher')),
  user_id    bigint not null,
  expires_at timestamptz not null
);

-- (이전 버전에서 올라온 경우) 강좌에 운영 단위 칸을 추가하고, 첫 운영 단위를 만듭니다
alter table as_terms add column if not exists course_open_from date;   -- 강좌 개설·수정 허용 기간 시작 (비워 두면 course_open 체크값을 따름)
alter table as_terms add column if not exists course_open_to   date;   -- 강좌 개설·수정 허용 기간 끝
alter table as_terms add column if not exists pay_rate int not null default 35000;  -- 수당 1시간 단가(원), 관리자만 수정
alter table as_courses add column if not exists term_id bigint references as_terms(id);
alter table as_courses add column if not exists pay_account text not null default '';   -- 강사 수당 입금 계좌 (강좌 개설 시 등록)
do $$
declare v bigint; s record;
begin
  if not exists (select 1 from as_terms) then
    select * into s from as_settings where id = 1;
    insert into as_terms (title, enroll_open, course_open, min_students)
    values ('2026년 겨울방학 방과후학교', coalesce(s.enroll_open, false), coalesce(s.course_open, true), coalesce(s.min_students, 5))
    returning id into v;
    update as_courses set term_id = v, dates = '{}' where term_id is null;   -- 기간이 바뀌므로 강의 날짜는 비움
  end if;
end $$;
alter table as_courses alter column term_id set not null;

-- 강좌별 수업 요일·교시 (이전 버전에서 올라온 강좌는 유형의 기본 요일로 채움)
alter table as_courses add column if not exists days   int[];
alter table as_courses add column if not exists period text not null default '';
update as_courses c set days = t.days from as_types t where t.code = c.type_code and c.days is null;

-- 강의계획서 항목: 대상·수준·교재명·수업 목표·회당 시간·날짜별 수업 내용
alter table as_courses add column if not exists target   text  not null default '';
alter table as_courses add column if not exists level    text  not null default '';
alter table as_courses add column if not exists textbook text  not null default '';
alter table as_courses add column if not exists goals    text  not null default '';
alter table as_courses add column if not exists hours    numeric;                         -- 회당 수업 시간
alter table as_courses add column if not exists contents jsonb not null default '{}';    -- {"2027-01-04": "수업 내용", ...}

-- 방과후학교(운영 단위)마다 유형별 실제 수업 날짜 — 강좌 개설 때 강의 날짜의 기본값이 됩니다
create table if not exists as_type_dates (
  term_id   bigint not null references as_terms(id) on delete cascade,
  type_code text   not null references as_types(code),
  dates     date[] not null default '{}',
  primary key (term_id, type_code)
);
alter table as_type_dates enable row level security;

-- 출석 기록: 강좌·학생·날짜·교시(slot)마다 표시 하나 (◯ 출석, / 결석, 과제, 병원, 학원 … 자유 입력)
create table if not exists as_attendance (
  course_id  bigint not null references as_courses(id)  on delete cascade,
  student_id bigint not null references as_students(id) on delete cascade,
  date       date   not null,
  slot       int    not null default 1,
  mark       text   not null,
  primary key (course_id, student_id, date, slot)
);
alter table as_attendance enable row level security;

-- 결강·보강 기록: 원래 수업일(orig_date)을 결강 처리하고, 보강일(new_date)을 나중에라도 넣을 수 있습니다
create table if not exists as_class_changes (
  id         bigint generated always as identity primary key,
  course_id  bigint not null references as_courses(id) on delete cascade,
  orig_date  date   not null,
  new_date   date,                                  -- null = 보강 미정
  reason     text   not null default '',
  content    text   not null default '',            -- 결강한 날의 수업 내용(보강일로 옮겨 감)
  created_by bigint references as_teachers(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (course_id, orig_date)
);
alter table as_class_changes enable row level security;

-- 부관리자: 관리자 메뉴 중 [일정·설정](방과후학교 만들기·기간·유형별 날짜·계정 설정)과 관리자 지정만 빼고 모두 사용
alter table as_teachers add column if not exists is_manager boolean not null default false;

-- 접속 기록: 로그인하거나 30분 이상 지나 다시 들어오면 한 줄씩 남깁니다 (접속 현황 보고용)
create table if not exists as_access_log (
  id      bigint generated always as identity primary key,
  role    text   not null,
  user_id bigint not null,
  at      timestamptz not null default now()
);
create index if not exists as_access_log_at   on as_access_log (at);
create index if not exists as_access_log_user on as_access_log (role, user_id, at desc);
alter table as_access_log enable row level security;
-- 접속 현황 보고를 읽을 때 쓰는 열쇠 (비어 있으면 보고 기능이 꺼져 있음)
alter table as_settings add column if not exists report_key text;

-- 신청 대기: 정원이 찬 강좌에 줄을 서 두면, 자리가 날 때 먼저 선 순서대로 자동 신청됩니다
create table if not exists as_waitlist (
  course_id  bigint not null references as_courses(id)  on delete cascade,
  student_id bigint not null references as_students(id) on delete cascade,
  at         timestamptz not null default now(),
  primary key (course_id, student_id)
);
alter table as_waitlist enable row level security;

-- 변경 기록: 누가 언제 수강생·출석·결강·강좌 상태를 바꿨는지
create table if not exists as_audit (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  role       text,
  user_id    bigint,
  action     text not null,
  course_id  bigint,
  student_id bigint,
  detail     text
);
create index if not exists as_audit_course on as_audit (course_id, id desc);
alter table as_audit enable row level security;

-- 담임 학급 (담임 선생님은 자기 반 학생의 비밀번호를 초기화할 수 있습니다)
alter table as_teachers add column if not exists hr_grade int;
alter table as_teachers add column if not exists hr_class int;

alter table as_terms       enable row level security;
alter table as_settings    enable row level security;
alter table as_types       enable row level security;
alter table as_teachers    enable row level security;
alter table as_students    enable row level security;
alter table as_courses     enable row level security;
alter table as_enrollments enable row level security;
alter table as_sessions    enable row level security;

-- 최초 관리자 계정 (이름: 관리자 / 비밀번호: 2026) — 첫 로그인 때 비밀번호를 바꾸게 됩니다
insert into as_teachers (name, pw_hash, is_admin)
values ('관리자', extensions.crypt('2026', extensions.gen_salt('bf')), true)
on conflict (name) do nothing;

-- 이전 버전 함수 정리 (인자 구성이 바뀐 함수)
drop function if exists as_get_state(uuid);
drop function if exists as_get_roster(uuid);
drop function if exists as_save_settings(uuid, json);

-- ---------- 내부 함수 (웹에서 호출 불가) --------------------------------
drop function if exists as_auth(uuid);          -- 돌려주는 값이 바뀌어 다시 만듭니다
-- o_admin: 관리자 또는 부관리자 / o_super: 관리자(일정·설정까지 가능)
create or replace function as_auth(p_token uuid, out o_role text, out o_uid bigint, out o_admin boolean, out o_super boolean)
language plpgsql security definer set search_path = public, extensions as $$
begin
  select s.role, s.user_id into o_role, o_uid
    from as_sessions s where s.token = p_token and s.expires_at > now();
  if o_role is null then
    raise exception '로그인이 만료되었습니다. 다시 로그인해 주세요.';
  end if;
  o_admin := false; o_super := false;
  if o_role = 'teacher' then
    select t.is_admin or t.is_manager, t.is_admin into o_admin, o_super from as_teachers t where t.id = o_uid;
    if not found then raise exception '로그인이 만료되었습니다. 다시 로그인해 주세요.'; end if;
  else
    perform 1 from as_students s where s.id = o_uid;
    if not found then raise exception '로그인이 만료되었습니다. 다시 로그인해 주세요.'; end if;
  end if;
end $$;

create or replace function as_do_enroll(p_student bigint, p_course bigint, p_self boolean)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  c  as_courses%rowtype;
  ty as_types%rowtype;
  st as_students%rowtype;
  s  as_terms%rowtype;
  n  int;
  other text;
begin
  select * into c from as_courses where id = p_course for update;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  select * into ty from as_types where code = c.type_code;
  select * into st from as_students where id = p_student;
  if not found then raise exception '학생을 찾을 수 없습니다.'; end if;
  select * into s from as_terms where id = c.term_id;

  if c.status = 'cancelled' then raise exception '폐강된 강좌입니다.'; end if;
  if not (st.grade = any (c.grades)) then raise exception '수강 대상 학년이 아닙니다.'; end if;
  if exists (select 1 from as_enrollments where course_id = p_course and student_id = p_student) then
    raise exception '이미 신청한 강좌입니다.';
  end if;

  select c2.title into other
    from as_enrollments e
    join as_courses c2 on c2.id = e.course_id
    join as_types   t2 on t2.code = c2.type_code
   where e.student_id = p_student and c2.term_id = c.term_id
     and c2.status <> 'cancelled' and coalesce(c2.days, t2.days) && coalesce(c.days, ty.days)
   limit 1;
  if other is not null then
    raise exception '요일이 겹치는 강좌(%)를 이미 수강 중입니다.', other;
  end if;

  if ty.solo_group is not null then
    select c2.title into other
      from as_enrollments e
      join as_courses c2 on c2.id = e.course_id
      join as_types   t2 on t2.code = c2.type_code
     where e.student_id = p_student and c2.term_id = c.term_id
       and c2.status <> 'cancelled' and t2.solo_group = ty.solo_group
     limit 1;
    if other is not null then
      raise exception '%반은 한 강좌만 수강할 수 있습니다. (이미 수강 중: %)', ty.solo_group, other;
    end if;
  end if;

  if p_self then
    if not s.enroll_open then raise exception '지금은 수강신청 기간이 아닙니다.'; end if;
    if ty.assign_only then raise exception '이 강좌는 선생님이 학생을 지정하는 강좌입니다.'; end if;
    if c.status <> 'open' then raise exception '신청이 마감된 강좌입니다.'; end if;
    select count(*) into n from as_enrollments where course_id = p_course;
    if c.capacity is not null and n >= c.capacity then raise exception '정원이 가득 찼습니다.'; end if;
  end if;

  insert into as_enrollments (course_id, student_id, assigned) values (p_course, p_student, not p_self);
  delete from as_waitlist where course_id = p_course and student_id = p_student;
end $$;

-- 내부: 변경 기록 한 줄 남기기
create or replace function as_audit_add(p_role text, p_uid bigint, p_action text, p_course bigint, p_student bigint, p_detail text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into as_audit (role, user_id, action, course_id, student_id, detail) values (p_role, p_uid, p_action, p_course, p_student, left(p_detail, 300));
end $$;

-- 내부: 자리가 나면 대기 1순위부터 자동 신청 (요일이 겹치는 등 신청할 수 없게 된 학생은 대기에서 빼고 다음 사람으로)
create or replace function as_promote(p_course bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c as_courses%rowtype; n int; w record;
begin
  loop
    select * into c from as_courses where id = p_course;
    if not found or c.status <> 'open' then return; end if;
    select count(*) into n from as_enrollments where course_id = p_course;
    if c.capacity is not null and n >= c.capacity then return; end if;
    select * into w from as_waitlist where course_id = p_course order by at, student_id limit 1;
    if not found then return; end if;
    delete from as_waitlist where course_id = p_course and student_id = w.student_id;
    begin
      perform as_do_enroll(w.student_id, p_course, false);
      update as_enrollments set assigned = false where course_id = p_course and student_id = w.student_id;
      perform as_audit_add('system', null, '대기→자동 신청', p_course, w.student_id, null);
    exception when others then
      perform as_audit_add('system', null, '대기 취소(신청 불가)', p_course, w.student_id, sqlerrm);
    end;
  end loop;
end $$;

-- 내부: 접속 기록 남기기 (같은 사람은 30분에 한 번만)
create or replace function as_log_access(p_role text, p_uid bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from as_access_log where role = p_role and user_id = p_uid and at > now() - interval '30 minutes') then
    insert into as_access_log (role, user_id) values (p_role, p_uid);
  end if;
end $$;

-- ---------- 로그인 / 비밀번호 -------------------------------------------
create or replace function as_login_student(p_grade int, p_class int, p_number int, p_name text, p_pw text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare st as_students%rowtype; tk uuid;
begin
  select * into st from as_students
   where grade = p_grade and class = p_class and number = p_number and name = btrim(p_name);
  if not found or st.pw_hash <> crypt(p_pw, st.pw_hash) then
    raise exception '학년·반·번호·이름 또는 비밀번호가 맞지 않습니다.';
  end if;
  delete from as_sessions where expires_at < now();
  insert into as_sessions (role, user_id, expires_at)
  values ('student', st.id, now() + interval '12 hours') returning token into tk;
  perform as_log_access('student', st.id);
  return json_build_object('token', tk);
end $$;

create or replace function as_login_teacher(p_name text, p_pw text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t as_teachers%rowtype; tk uuid;
begin
  select * into t from as_teachers where name = btrim(p_name);
  if not found or t.pw_hash <> crypt(p_pw, t.pw_hash) then
    raise exception '이름 또는 비밀번호가 맞지 않습니다.';
  end if;
  delete from as_sessions where expires_at < now();
  insert into as_sessions (role, user_id, expires_at)
  values ('teacher', t.id, now() + interval '12 hours') returning token into tk;
  perform as_log_access('teacher', t.id);
  return json_build_object('token', tk);
end $$;

create or replace function as_logout(p_token uuid) returns void
language sql security definer set search_path = public, extensions as $$
  delete from as_sessions where token = p_token;
$$;

create or replace function as_change_password(p_token uuid, p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; h text;
begin
  select * into a from as_auth(p_token);
  if length(coalesce(p_new, '')) < 4 then raise exception '새 비밀번호는 4자 이상이어야 합니다.'; end if;
  if p_new = '2026' then raise exception '초기 비밀번호(2026)와 다른 비밀번호를 사용해 주세요.'; end if;
  if a.o_role = 'student' then
    select pw_hash into h from as_students where id = a.o_uid;
  else
    select pw_hash into h from as_teachers where id = a.o_uid;
  end if;
  if h <> crypt(p_old, h) then raise exception '현재 비밀번호가 맞지 않습니다.'; end if;
  if a.o_role = 'student' then
    update as_students set pw_hash = crypt(p_new, gen_salt('bf')), must_change = false where id = a.o_uid;
  else
    update as_teachers set pw_hash = crypt(p_new, gen_salt('bf')), must_change = false where id = a.o_uid;
  end if;
end $$;

-- ---------- 조회 --------------------------------------------------------
create or replace function as_get_state(p_token uuid, p_term bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a record; me json;
begin
  select * into a from as_auth(p_token);
  perform as_log_access(a.o_role, a.o_uid);
  if a.o_role = 'student' then
    select json_build_object('role','student','id',s.id,'name',s.name,'grade',s.grade,'class',s.class,
                             'number',s.number,'must_change',s.must_change,'is_admin',false)
      into me from as_students s where s.id = a.o_uid;
  else
    select json_build_object('role','teacher','id',t.id,'name',t.name,'must_change',t.must_change,
                             'is_admin',(t.is_admin or t.is_manager),'is_super',t.is_admin,'is_manager',t.is_manager,'budget_mgr',t.budget_mgr,
                             'hr_grade',t.hr_grade,'hr_class',t.hr_class)
      into me from as_teachers t where t.id = a.o_uid;
  end if;

  return json_build_object(
    'me', me,
    'force_pw', (select x.force_pw_change from as_settings x where x.id = 1),
    'changes', (select coalesce(json_agg(json_build_object('id', ch.id, 'course_id', ch.course_id, 'orig_date', ch.orig_date,
                         'new_date', ch.new_date, 'reason', ch.reason, 'by', te.name, 'at', ch.created_at) order by ch.orig_date), '[]'::json)
                  from as_class_changes ch join as_courses c on c.id = ch.course_id
                  left join as_teachers te on te.id = ch.created_by
                 where c.term_id = p_term),
    'terms', (select coalesce(json_agg(row_to_json(x) order by x.id desc), '[]'::json) from as_terms x),
    'term', (select row_to_json(x) from as_terms x where x.id = p_term),
    'types', (select coalesce(json_agg(row_to_json(t) order by t.sort), '[]'::json) from as_types t),
    'type_dates', (select coalesce(json_agg(json_build_object('type_code', d.type_code, 'dates', d.dates)), '[]'::json)
                     from as_type_dates d where d.term_id = p_term),
    'courses', (
      select coalesce(json_agg(json_build_object(
               'id', c.id, 'type_code', c.type_code, 'title', c.title,
               'teacher_id', c.teacher_id, 'teacher_name', t.name, 'room', c.room,
               'grades', c.grades, 'capacity', c.capacity, 'status', c.status, 'dates', c.dates,
               'days', coalesce(c.days, ty.days), 'period', c.period,
               'target', c.target, 'level', c.level, 'textbook', c.textbook, 'goals', c.goals,
               'hours', c.hours, 'contents', c.contents, 'pay_account', c.pay_account,
               'enrolled', (select count(*) from as_enrollments e where e.course_id = c.id),
               'waiting',  (select count(*) from as_waitlist w where w.course_id = c.id)
             ) order by ty.sort, c.title, c.id), '[]'::json)
        from as_courses c
        join as_types ty   on ty.code = c.type_code
        join as_teachers t on t.id = c.teacher_id
       where c.term_id = p_term),
    'my', case when a.o_role = 'student' then (
            select coalesce(json_agg(json_build_object('course_id', e.course_id, 'assigned', e.assigned)), '[]'::json)
              from as_enrollments e where e.student_id = a.o_uid)
          else '[]'::json end,
    -- 학생 본인의 신청 대기: 강좌와 대기 순번
    'my_wait', case when a.o_role = 'student' then (
            select coalesce(json_agg(json_build_object('course_id', w.course_id,
                     'pos', (select count(*) from as_waitlist w2 where w2.course_id = w.course_id and (w2.at, w2.student_id) <= (w.at, w.student_id)))), '[]'::json)
              from as_waitlist w join as_courses c on c.id = w.course_id where w.student_id = a.o_uid and c.term_id = p_term)
          else '[]'::json end,
    -- 학생 본인의 출석 기록(보기 전용): [강좌, 날짜, 교시, 표시]
    'my_att', case when a.o_role = 'student' then (
            select coalesce(json_agg(json_build_array(x.course_id, x.date, x.slot, x.mark)), '[]'::json)
              from as_attendance x join as_courses c on c.id = x.course_id
             where x.student_id = a.o_uid and c.term_id = p_term)
          else '[]'::json end,
    'teachers', case when a.o_role = 'teacher' then (
            select coalesce(json_agg(json_build_object('id', t.id, 'name', t.name, 'is_admin', t.is_admin, 'is_manager', t.is_manager,
                                     'hr_grade', t.hr_grade, 'hr_class', t.hr_class) order by t.name), '[]'::json) from as_teachers t)
          else '[]'::json end
  );
end $$;

-- 교사용: 전체 학생 명단 + 전체 수강 내역
create or replace function as_get_roster(p_token uuid, p_term bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if a.o_role <> 'teacher' then raise exception '교사만 사용할 수 있습니다.'; end if;
  return json_build_object(
    'students', (select coalesce(json_agg(json_build_object('id', s.id, 'grade', s.grade, 'class', s.class,
                          'number', s.number, 'name', s.name) order by s.grade, s.class, s.number), '[]'::json)
                   from as_students s),
    'enrollments', (select coalesce(json_agg(json_build_object('course_id', e.course_id,
                          'student_id', e.student_id, 'assigned', e.assigned)), '[]'::json)
                      from as_enrollments e join as_courses c on c.id = e.course_id
                     where c.term_id = p_term),
    -- 출석: [강좌, 학생, 날짜, 교시, 표시]
    'attendance', (select coalesce(json_agg(json_build_array(a2.course_id, a2.student_id, a2.date, a2.slot, a2.mark)), '[]'::json)
                     from as_attendance a2 join as_courses c on c.id = a2.course_id
                    where c.term_id = p_term)
  );
end $$;

-- ---------- 학생: 수강신청 ----------------------------------------------
create or replace function as_enroll(p_token uuid, p_course bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if a.o_role <> 'student' then raise exception '학생만 신청할 수 있습니다.'; end if;
  perform as_do_enroll(a.o_uid, p_course, true);
  perform as_audit_add('student', a.o_uid, '수강신청', p_course, a.o_uid, null);
end $$;

create or replace function as_cancel_enroll(p_token uuid, p_course bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; e as_enrollments%rowtype;
begin
  select * into a from as_auth(p_token);
  if a.o_role <> 'student' then raise exception '학생만 취소할 수 있습니다.'; end if;
  select * into e from as_enrollments where course_id = p_course and student_id = a.o_uid;
  if not found then raise exception '신청 내역이 없습니다.'; end if;
  if e.assigned then raise exception '선생님이 지정한 강좌는 직접 취소할 수 없습니다.'; end if;
  if not (select t.enroll_open from as_terms t join as_courses c on c.term_id = t.id where c.id = p_course) then
    raise exception '수강신청 기간이 아니어서 취소할 수 없습니다. 담당 선생님께 문의하세요.';
  end if;
  delete from as_enrollments where id = e.id;
  delete from as_attendance where course_id = p_course and student_id = a.o_uid;
  perform as_audit_add('student', a.o_uid, '신청 취소', p_course, a.o_uid, null);
  perform as_promote(p_course);
end $$;

-- 신청 대기 걸기 / 풀기 (정원이 찬 강좌만)
create or replace function as_wait(p_token uuid, p_course bigint) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype; ty as_types%rowtype; st as_students%rowtype; n int;
begin
  select * into a from as_auth(p_token);
  if a.o_role <> 'student' then raise exception '학생만 대기 신청을 할 수 있습니다.'; end if;
  select * into c from as_courses where id = p_course;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  select * into ty from as_types where code = c.type_code;
  select * into st from as_students where id = a.o_uid;
  if not (select enroll_open from as_terms where id = c.term_id) then raise exception '지금은 수강신청 기간이 아닙니다.'; end if;
  if ty.assign_only then raise exception '이 강좌는 선생님이 학생을 지정하는 강좌입니다.'; end if;
  if c.status <> 'open' then raise exception '신청이 마감된 강좌입니다.'; end if;
  if not (st.grade = any (c.grades)) then raise exception '수강 대상 학년이 아닙니다.'; end if;
  if exists (select 1 from as_enrollments where course_id = p_course and student_id = a.o_uid) then raise exception '이미 신청한 강좌입니다.'; end if;
  select count(*) into n from as_enrollments where course_id = p_course;
  if c.capacity is null or n < c.capacity then raise exception '아직 자리가 있습니다. [신청]을 눌러 주세요.'; end if;
  insert into as_waitlist (course_id, student_id) values (p_course, a.o_uid) on conflict do nothing;
  perform as_audit_add('student', a.o_uid, '대기 신청', p_course, a.o_uid, null);
  return (select count(*) from as_waitlist w where w.course_id = p_course
           and (w.at, w.student_id) <= (select at, student_id from as_waitlist where course_id = p_course and student_id = a.o_uid));
end $$;

create or replace function as_unwait(p_token uuid, p_course bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if a.o_role <> 'student' then raise exception '학생만 사용할 수 있습니다.'; end if;
  delete from as_waitlist where course_id = p_course and student_id = a.o_uid;
  perform as_audit_add('student', a.o_uid, '대기 취소', p_course, a.o_uid, null);
end $$;

-- 지난 학기 강좌 복사 (관리자만): 수강생·출석·결강은 빼고 강좌 틀만 가져오며, 날짜는 days_shift일만큼 옮김
create or replace function as_copy_courses(p_token uuid, p_from bigint, p_to bigint, p_shift int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare a record; n int := 0; c record; v_dates date[]; v_contents jsonb;
begin
  select * into a from as_auth(p_token);
  if not a.o_super then raise exception '관리자만 사용할 수 있습니다.'; end if;
  if not exists (select 1 from as_terms where id = p_to) or not exists (select 1 from as_terms where id = p_from) then
    raise exception '방과후학교를 찾을 수 없습니다.';
  end if;
  for c in select * from as_courses where term_id = p_from and status <> 'cancelled' order by id loop
    v_dates := array(select (d + coalesce(p_shift, 0))::date from unnest(c.dates) d order by 1);
    select coalesce(jsonb_object_agg((((e.k)::date + coalesce(p_shift, 0))::text), e.v), '{}'::jsonb) into v_contents
      from jsonb_each_text(coalesce(c.contents, '{}'::jsonb)) as e(k, v);
    insert into as_courses (term_id, type_code, title, teacher_id, room, grades, capacity, dates, days, period,
                            target, level, textbook, goals, hours, contents, status)
    values (p_to, c.type_code, c.title, c.teacher_id, c.room, c.grades, c.capacity, v_dates, c.days, c.period,
            c.target, c.level, c.textbook, c.goals, c.hours, v_contents, 'open');
    n := n + 1;
  end loop;
  perform as_audit_add('teacher', a.o_uid, '지난 학기 강좌 복사', null, null, p_from || ' → ' || p_to || ' (' || n || '강좌)');
  return n;
end $$;

-- 변경 기록 보기 (관리자·부관리자): 최근 것부터
create or replace function as_get_audit(p_token uuid, p_term bigint, p_limit int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
  return (select coalesce(json_agg(x order by x.id desc), '[]'::json) from (
    select u.id, u.at, u.action, u.detail, c.title as course,
           case u.role when 'teacher' then (select t.name || ' 선생님' from as_teachers t where t.id = u.user_id)
                       when 'student' then (select s.grade || '-' || s.class || ' ' || s.name from as_students s where s.id = u.user_id)
                       else '자동' end as who,
           (select s.grade || '-' || s.class || ' ' || s.number || '번 ' || s.name from as_students s where s.id = u.student_id) as student
      from as_audit u join as_courses c on c.id = u.course_id
     where c.term_id = p_term order by u.id desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) x);
end $$;

-- ---------- 교사: 강좌 개설 / 학생 지정 ----------------------------------
-- 수당 지급표: 강좌별 수업 횟수 = 수업 날짜 - 결강 + 보강, 1회 시간 = 기초반(KA·KB) 1시간·그 외 2시간, 금액 = 시간 × 단가(as_terms.pay_rate, 기본 35,000원)
-- 금액은 저장하지 않고 항상 시간표에서 계산합니다 (관리자·부관리자만 열람)
create or replace function as_get_pay(p_token uuid, p_term bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a record; v_rate int;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자와 부관리자만 열람할 수 있습니다.'; end if;
  select pay_rate into v_rate from as_terms where id = p_term;
  return (select coalesce(json_agg(json_build_object(
            'id', c.id, 'title', c.title, 'teacher', t.name, 'pay_account', c.pay_account, 'type_code', c.type_code,
            'grades_text', (select string_agg(g::text, ',' order by g) from unnest(c.grades) g),
            'grade_min', (select min(g) from unnest(c.grades) g),
            'period', c.period, 'lessons', z.lessons, 'hours', z.lessons * z.hpd, 'amount', z.lessons * z.hpd * coalesce(v_rate, 35000)
          ) order by (select min(g) from unnest(c.grades) g), c.title, c.id), '[]'::json)
    from as_courses c
    join as_teachers t on t.id = c.teacher_id
    cross join lateral (
      select coalesce(array_length(c.dates, 1), 0)
             - (select count(*) from as_class_changes k where k.course_id = c.id)
             + (select count(*) from as_class_changes k where k.course_id = c.id and k.new_date is not null) as lessons,
             case when c.type_code in ('KA','KB') then 1 else 2 end as hpd
    ) z
   where c.term_id = p_term and c.status <> 'cancelled');
end $$;

create or replace function as_save_course(p_token uuid, p_course json) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  a record; v_id bigint; v_teacher bigint; v_term bigint; old as_courses%rowtype;
  v_type text; v_title text; v_grades int[]; v_dates date[]; v_cap int; v_days int[]; v_period text;
  v_target text; v_level text; v_book text; v_goals text; v_hours numeric; v_contents jsonb; v_pay text;
begin
  select * into a from as_auth(p_token);
  if a.o_role <> 'teacher' then raise exception '교사만 사용할 수 있습니다.'; end if;
  v_id    := nullif(p_course->>'id', '')::bigint;
  if v_id is null then
    v_term := nullif(p_course->>'term_id', '')::bigint;
  else
    select term_id into v_term from as_courses where id = v_id;
  end if;
  if not exists (select 1 from as_terms where id = v_term) then
    raise exception '방과후학교(운영 단위)를 찾을 수 없습니다.';
  end if;
  if not a.o_admin and not (select case when t.course_open_from is not null and t.course_open_to is not null
                                       then current_date between t.course_open_from and t.course_open_to
                                       else t.course_open end
                            from as_terms t where t.id = v_term) then
    raise exception '지금은 강좌 개설·수정 기간이 아닙니다.';
  end if;

  v_type  := p_course->>'type_code';
  v_title := btrim(coalesce(p_course->>'title', ''));
  v_cap   := nullif(p_course->>'capacity', '')::int;
  v_grades := array(select x::int  from json_array_elements_text(coalesce(p_course->'grades', '[]'::json)) x order by 1);
  v_dates  := array(select x::date from json_array_elements_text(coalesce(p_course->'dates',  '[]'::json)) x order by 1);
  v_days   := array(select distinct x::int from json_array_elements_text(coalesce(p_course->'days', '[]'::json)) x order by 1);
  v_period := btrim(coalesce(p_course->>'period', ''));
  v_target := btrim(coalesce(p_course->>'target', ''));
  v_level  := btrim(coalesce(p_course->>'level', ''));
  v_book   := btrim(coalesce(p_course->>'textbook', ''));
  v_goals  := coalesce(p_course->>'goals', '');
  v_hours  := nullif(p_course->>'hours', '')::numeric;
  v_pay    := btrim(coalesce(p_course->>'pay_account', ''));
  if v_pay = '' then raise exception '입금 계좌번호를 입력해 주세요.'; end if;
  -- 날짜별 수업 내용: 강의 날짜에 있는 날만 남깁니다
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_contents
    from jsonb_each_text(coalesce((p_course->'contents')::jsonb, '{}'::jsonb)) as e(k, v)
   where k::date = any (v_dates) and btrim(v) <> '';

  if v_title = '' then raise exception '강좌명을 입력해 주세요.'; end if;
  if not exists (select 1 from as_types where code = v_type) then raise exception '강좌 유형을 선택해 주세요.'; end if;
  if coalesce(array_length(v_grades, 1), 0) = 0 then raise exception '수강 학년을 하나 이상 선택해 주세요.'; end if;
  if v_cap is not null and v_cap < 1 then raise exception '정원은 1명 이상이어야 합니다.'; end if;
  if coalesce(array_length(v_days, 1), 0) = 0 then
    select days into v_days from as_types where code = v_type;          -- 요일을 고르지 않으면 유형의 기본 요일
  end if;
  if exists (select 1 from unnest(v_days) d where d < 1 or d > 5) then raise exception '수업 요일은 월~금 중에서 골라 주세요.'; end if;

  v_teacher := case when a.o_admin then nullif(p_course->>'teacher_id', '')::bigint end;

  if v_id is null then
    insert into as_courses (term_id, type_code, title, teacher_id, room, grades, capacity, dates, days, period,
                            target, level, textbook, goals, hours, contents, pay_account)
    values (v_term, v_type, v_title, coalesce(v_teacher, a.o_uid), coalesce(p_course->>'room', ''), v_grades, v_cap, v_dates, v_days, v_period,
            v_target, v_level, v_book, v_goals, v_hours, v_contents, v_pay)
    returning id into v_id;
  else
    select * into old from as_courses where id = v_id for update;
    if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
    if not a.o_admin and old.teacher_id <> a.o_uid then raise exception '본인이 개설한 강좌만 수정할 수 있습니다.'; end if;
    if old.type_code <> v_type and exists (select 1 from as_enrollments where course_id = v_id) then
      raise exception '수강생이 있는 강좌는 유형을 바꿀 수 없습니다.';
    end if;
    if old.days is distinct from v_days and exists (select 1 from as_enrollments where course_id = v_id) then
      raise exception '수강생이 있는 강좌는 수업 요일을 바꿀 수 없습니다.';
    end if;
    update as_courses
       set type_code = v_type, title = v_title, teacher_id = coalesce(v_teacher, old.teacher_id),
           room = coalesce(p_course->>'room', ''), grades = v_grades, capacity = v_cap, dates = v_dates,
           days = v_days, period = v_period,
           target = v_target, level = v_level, textbook = v_book, goals = v_goals, hours = v_hours, contents = v_contents,
           pay_account = v_pay
     where id = v_id;
    -- 강좌 수정에서 날짜를 직접 바꾼 경우 결강·보강 기록을 맞춤
    delete from as_class_changes where course_id = v_id and orig_date = any (v_dates);          -- 결강일을 다시 넣음 → 결강 취소
    update as_class_changes set new_date = null
     where course_id = v_id and new_date is not null and not (new_date = any (v_dates));        -- 보강일을 뺌 → 보강 미정
    delete from as_attendance where course_id = v_id and not (date = any (v_dates));
  end if;
  return v_id;
end $$;

create or replace function as_delete_course(p_token uuid, p_course bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype;
begin
  select * into a from as_auth(p_token);
  select * into c from as_courses where id = p_course;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  if a.o_role <> 'teacher' or (not a.o_admin and c.teacher_id <> a.o_uid) then
    raise exception '본인이 개설한 강좌만 삭제할 수 있습니다.';
  end if;
  if exists (select 1 from as_enrollments where course_id = p_course) then
    raise exception '수강생이 있는 강좌는 삭제할 수 없습니다. 먼저 폐강 처리하거나 수강생을 제외해 주세요.';
  end if;
  delete from as_courses where id = p_course;
end $$;

create or replace function as_assign(p_token uuid, p_course bigint, p_student bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype;
begin
  select * into a from as_auth(p_token);
  select * into c from as_courses where id = p_course;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  if a.o_role <> 'teacher' or (not a.o_admin and c.teacher_id <> a.o_uid) then
    raise exception '담당 교사 또는 관리자만 학생을 지정할 수 있습니다.';
  end if;
  perform as_do_enroll(p_student, p_course, false);
  perform as_audit_add('teacher', a.o_uid, '학생 지정', p_course, p_student, null);
end $$;

create or replace function as_unassign(p_token uuid, p_course bigint, p_student bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype;
begin
  select * into a from as_auth(p_token);
  select * into c from as_courses where id = p_course;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  if a.o_role <> 'teacher' or (not a.o_admin and c.teacher_id <> a.o_uid) then
    raise exception '담당 교사 또는 관리자만 수강생을 제외할 수 있습니다.';
  end if;
  delete from as_enrollments where course_id = p_course and student_id = p_student;
  delete from as_attendance  where course_id = p_course and student_id = p_student;
  delete from as_waitlist where course_id = p_course and student_id = p_student;
  perform as_audit_add('teacher', a.o_uid, '수강생 제외', p_course, p_student, null);
  perform as_promote(p_course);
end $$;

-- 출석 표시 저장: p_items = [{"s": 학생id, "d": "2026-09-07", "slot": 1, "m": "◯"}, …]  (m 이 비면 지움)
create or replace function as_set_attendance(p_token uuid, p_course bigint, p_items json) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype; n int := 0; it record;
begin
  select * into a from as_auth(p_token);
  select * into c from as_courses where id = p_course;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  if a.o_role <> 'teacher' or (not a.o_admin and c.teacher_id <> a.o_uid) then
    raise exception '담당 교사 또는 관리자만 출석을 입력할 수 있습니다.';
  end if;
  for it in
    select x.s, x.d, coalesce(x.slot, 1) as slot, btrim(coalesce(x.m, '')) as m
      from json_to_recordset(p_items) as x(s bigint, d date, slot int, m text)
  loop
    if not exists (select 1 from as_enrollments where course_id = p_course and student_id = it.s) then
      raise exception '수강생이 아닌 학생이 포함되어 있습니다.';
    end if;
    if it.m = '' then
      delete from as_attendance where course_id = p_course and student_id = it.s and date = it.d and slot = it.slot;
    else
      insert into as_attendance (course_id, student_id, date, slot, mark)
      values (p_course, it.s, it.d, it.slot, left(it.m, 20))
      on conflict (course_id, student_id, date, slot) do update set mark = excluded.mark;
    end if;
    n := n + 1;
  end loop;
  perform as_audit_add('teacher', a.o_uid, '출석 입력', p_course, null,
    n || '칸 · ' || coalesce((select string_agg(distinct to_char(x.d, 'FMMM/FMDD'), ', ') from json_to_recordset(p_items) as x(d date)), ''));
  return n;
end $$;

-- ---------- 결강 · 보강 ----------------------------------------------------
-- 내부: 보강일 넣기/바꾸기/없애기 (p_new 가 null 이면 보강 미정으로)
create or replace function as_do_makeup(p_change bigint, p_new date) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare ch as_class_changes%rowtype; c as_courses%rowtype; v_txt text;
begin
  select * into ch from as_class_changes where id = p_change for update;
  select * into c from as_courses where id = ch.course_id for update;
  v_txt := ch.content;
  if ch.new_date is not null then                        -- 기존 보강일 걷어내기
    v_txt := coalesce(nullif(c.contents->>ch.new_date::text, ''), v_txt);
    c.dates := array_remove(c.dates, ch.new_date);
    c.contents := c.contents - ch.new_date::text;
    delete from as_attendance where course_id = c.id and date = ch.new_date;
  end if;
  if p_new is not null then
    if p_new = ch.orig_date then raise exception '보강 날짜가 결강한 날과 같습니다.'; end if;
    if p_new = any (c.dates) then raise exception '그 날은 이미 이 강좌의 수업일입니다.'; end if;
    if exists (select 1 from as_class_changes where course_id = c.id and orig_date = p_new) then
      raise exception '그 날은 결강 처리된 날입니다.';
    end if;
    c.dates := array(select d from unnest(c.dates || p_new) d order by d);
    if v_txt <> '' then c.contents := c.contents || jsonb_build_object(p_new::text, v_txt); end if;
  end if;
  update as_courses set dates = c.dates, contents = c.contents where id = c.id;
  update as_class_changes set new_date = p_new, content = v_txt where id = p_change;
end $$;

-- 결강 처리 (보강 날짜는 함께 넣어도 되고 비워 두어도 됨)
create or replace function as_cancel_class(p_token uuid, p_course bigint, p_date date, p_reason text, p_new date) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype; v_id bigint;
begin
  select * into a from as_auth(p_token);
  select * into c from as_courses where id = p_course for update;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  if a.o_role <> 'teacher' or (not a.o_admin and c.teacher_id <> a.o_uid) then
    raise exception '담당 교사 또는 관리자만 결강·보강을 처리할 수 있습니다.';
  end if;
  if not (p_date = any (c.dates)) then raise exception '이 강좌의 수업일이 아닙니다.'; end if;
  if exists (select 1 from as_class_changes where course_id = p_course and new_date = p_date) then
    raise exception '보강일입니다. 보강 날짜를 바꾸거나 없애 주세요.';
  end if;
  insert into as_class_changes (course_id, orig_date, reason, content, created_by)
  values (p_course, p_date, btrim(coalesce(p_reason, '')), coalesce(c.contents->>p_date::text, ''), a.o_uid)
  returning id into v_id;
  update as_courses set dates = array_remove(dates, p_date), contents = contents - p_date::text where id = p_course;
  delete from as_attendance where course_id = p_course and date = p_date;
  if p_new is not null then perform as_do_makeup(v_id, p_new); end if;
  return v_id;
  perform as_audit_add('teacher', a.o_uid, '결강 처리', p_course, null, to_char(p_date, 'FMMM/FMDD') || coalesce(' → 보강 ' || to_char(p_new, 'FMMM/FMDD'), ' (보강 미정)') || coalesce(' · ' || p_reason, ''));
end $$;

-- 보강 날짜 넣기·바꾸기·없애기
create or replace function as_set_makeup(p_token uuid, p_change bigint, p_new date) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype;
begin
  select * into a from as_auth(p_token);
  select c2.* into c from as_courses c2 join as_class_changes ch on ch.course_id = c2.id where ch.id = p_change;
  if not found then raise exception '결강 기록을 찾을 수 없습니다.'; end if;
  if a.o_role <> 'teacher' or (not a.o_admin and c.teacher_id <> a.o_uid) then
    raise exception '담당 교사 또는 관리자만 결강·보강을 처리할 수 있습니다.';
  end if;
  perform as_do_makeup(p_change, p_new);
end $$;

-- 결강 취소: 원래 수업일로 되돌림 (보강일이 있으면 함께 없앰)
create or replace function as_undo_cancel(p_token uuid, p_change bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; c as_courses%rowtype; ch as_class_changes%rowtype;
begin
  select * into a from as_auth(p_token);
  select c2.* into c from as_courses c2 join as_class_changes x on x.course_id = c2.id where x.id = p_change;
  if not found then raise exception '결강 기록을 찾을 수 없습니다.'; end if;
  if a.o_role <> 'teacher' or (not a.o_admin and c.teacher_id <> a.o_uid) then
    raise exception '담당 교사 또는 관리자만 결강·보강을 처리할 수 있습니다.';
  end if;
  perform as_do_makeup(p_change, null);
  select * into ch from as_class_changes where id = p_change;
  update as_courses
     set dates = array(select d from unnest(dates || ch.orig_date) d order by d),
         contents = case when ch.content <> '' then contents || jsonb_build_object(ch.orig_date::text, ch.content) else contents end
   where id = c.id;
  delete from as_class_changes where id = p_change;
end $$;

-- ---------- 관리자 ------------------------------------------------------
create or replace function as_set_course_status(p_token uuid, p_course bigint, p_status text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
  if p_status not in ('open', 'closed', 'cancelled') then raise exception '잘못된 상태입니다.'; end if;
  update as_courses set status = p_status where id = p_course;
  if not found then raise exception '강좌를 찾을 수 없습니다.'; end if;
  if p_status = 'cancelled' then
    delete from as_enrollments where course_id = p_course;   -- 폐강: 수강생이 다른 강좌를 신청할 수 있게 비움
    delete from as_attendance  where course_id = p_course;
  end if;
  perform as_audit_add('teacher', a.o_uid, '강좌 상태 변경', p_course, null, p_status);
  if p_status = 'cancelled' then delete from as_waitlist where course_id = p_course; end if;
  if p_status = 'open' then perform as_promote(p_course); end if;
end $$;

-- 방과후학교(운영 단위) 만들기·수정: id 가 없으면 새로 만듭니다
create or replace function as_save_term(p_token uuid, p_term json) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare a record; v_id bigint; v_s date; v_e date; v_title text;
begin
  select * into a from as_auth(p_token);
  if not a.o_super then raise exception '관리자만 사용할 수 있습니다. (부관리자는 사용할 수 없는 기능)'; end if;
  v_id    := nullif(p_term->>'id', '')::bigint;
  v_title := btrim(coalesce(p_term->>'title', ''));
  v_s := nullif(p_term->>'start_date', '')::date;
  v_e := nullif(p_term->>'end_date', '')::date;
  if v_title = '' then raise exception '이름을 입력해 주세요. (예: 2027학년도 1학기 방과후학교)'; end if;
  if v_s is not null and v_e is not null and v_e < v_s then
    raise exception '종료일이 시작일보다 빠릅니다.';
  end if;
  if v_id is null then
    insert into as_terms (title, start_date, end_date) values (v_title, v_s, v_e) returning id into v_id;
  else
    update as_terms set
      title        = v_title,
      start_date   = v_s,
      end_date     = v_e,
      enroll_open  = coalesce((p_term->>'enroll_open')::boolean, enroll_open),
      course_open  = coalesce((p_term->>'course_open')::boolean, course_open),
      course_open_from = case when (p_term::jsonb) ? 'course_open_from' then nullif(p_term->>'course_open_from', '')::date else course_open_from end,
      course_open_to   = case when (p_term::jsonb) ? 'course_open_to'   then nullif(p_term->>'course_open_to', '')::date   else course_open_to   end,
      min_students = coalesce(nullif(p_term->>'min_students', '')::int, min_students),
      pay_rate     = coalesce(nullif(p_term->>'pay_rate', '')::int, pay_rate)
    where id = v_id;
    if not found then raise exception '방과후학교를 찾을 수 없습니다.'; end if;
  end if;
  return v_id;
end $$;

-- 첫 로그인 비밀번호 변경 강제 켜기/끄기 (관리자)
create or replace function as_set_force_pw(p_token uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_super then raise exception '관리자만 사용할 수 있습니다. (부관리자는 사용할 수 없는 기능)'; end if;
  update as_settings set force_pw_change = coalesce(p_on, true) where id = 1;
end $$;

-- 유형별 실제 수업 날짜 저장 (관리자)
create or replace function as_set_type_dates(p_token uuid, p_term bigint, p_type text, p_dates json) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; v date[];
begin
  select * into a from as_auth(p_token);
  if not a.o_super then raise exception '관리자만 사용할 수 있습니다. (부관리자는 사용할 수 없는 기능)'; end if;
  v := array(select distinct x::date from json_array_elements_text(coalesce(p_dates, '[]'::json)) x order by 1);
  insert into as_type_dates (term_id, type_code, dates) values (p_term, p_type, v)
  on conflict (term_id, type_code) do update set dates = excluded.dates;
end $$;

create or replace function as_delete_term(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_super then raise exception '관리자만 사용할 수 있습니다. (부관리자는 사용할 수 없는 기능)'; end if;
  if exists (select 1 from as_courses where term_id = p_id) then
    raise exception '강좌가 있는 방과후학교는 삭제할 수 없습니다. 지난 기록은 그대로 보관됩니다.';
  end if;
  delete from as_terms where id = p_id;
end $$;

-- 학생 명단 일괄 등록: [{grade,class,number,name}, ...]  (같은 학년·반·번호는 이름만 갱신)
create or replace function as_import_students(p_token uuid, p_rows json) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare a record; h text; n int;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
  h := crypt('2026', gen_salt('bf'));
  insert into as_students (grade, class, number, name, pw_hash)
  select distinct on (x.grade, x.class, x.number) x.grade, x.class, x.number, btrim(x.name), h
    from json_to_recordset(p_rows) as x(grade int, class int, number int, name text)
   where x.grade is not null and x.class is not null and x.number is not null and btrim(coalesce(x.name, '')) <> ''
  on conflict (grade, class, number) do update set name = excluded.name;
  get diagnostics n = row_count;
  return n;
end $$;

-- 교사 명단 일괄 등록: [{name}, ...]  (이미 있는 이름은 건너뜀)
create or replace function as_import_teachers(p_token uuid, p_rows json) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare a record; h text; n int;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
  h := crypt('2026', gen_salt('bf'));
  insert into as_teachers (name, pw_hash)
  select distinct btrim(x.name), h
    from json_to_recordset(p_rows) as x(name text)
   where btrim(coalesce(x.name, '')) <> ''
  on conflict (name) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- 비밀번호 초기화(2026): 관리자는 누구나, 담임 선생님은 자기 반 학생만
create or replace function as_reset_password(p_token uuid, p_role text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record; h text; st as_students%rowtype;
begin
  select * into a from as_auth(p_token);
  if a.o_role <> 'teacher' then raise exception '교사만 사용할 수 있습니다.'; end if;
  h := crypt('2026', gen_salt('bf'));
  if p_role = 'student' then
    select * into st from as_students where id = p_id;
    if not found then raise exception '대상을 찾을 수 없습니다.'; end if;
    if not a.o_admin and not exists (
         select 1 from as_teachers t
          where t.id = a.o_uid and t.hr_grade = st.grade and t.hr_class = st.class) then
      raise exception '관리자 또는 해당 학급 담임 선생님만 초기화할 수 있습니다.';
    end if;
    update as_students set pw_hash = h, must_change = true where id = p_id;
  elsif p_role = 'teacher' then
    if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
    if not a.o_super and exists (select 1 from as_teachers where id = p_id and is_admin) then
      raise exception '관리자 계정의 비밀번호는 관리자만 초기화할 수 있습니다.';
    end if;
    update as_teachers set pw_hash = h, must_change = true where id = p_id;
    if not found then raise exception '대상을 찾을 수 없습니다.'; end if;
  else
    raise exception '잘못된 요청입니다.';
  end if;
  delete from as_sessions where role = p_role and user_id = p_id;
end $$;

-- 부관리자 지정/해제 (관리자만)
create or replace function as_set_manager(p_token uuid, p_id bigint, p_on boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_super then raise exception '관리자만 사용할 수 있습니다. (부관리자는 사용할 수 없는 기능)'; end if;
  update as_teachers set is_manager = coalesce(p_on, false) where id = p_id;
  if not found then raise exception '대상을 찾을 수 없습니다.'; end if;
end $$;

-- 담임 학급 지정 (학년·반을 비우면 담임 해제)
create or replace function as_set_homeroom(p_token uuid, p_id bigint, p_grade int, p_class int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
  if (p_grade is null) <> (p_class is null) then raise exception '학년과 반을 함께 지정해 주세요.'; end if;
  update as_teachers set hr_grade = p_grade, hr_class = p_class where id = p_id;
  if not found then raise exception '대상을 찾을 수 없습니다.'; end if;
end $$;

create or replace function as_delete_student(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
  delete from as_students where id = p_id;
  delete from as_sessions where role = 'student' and user_id = p_id;
end $$;

create or replace function as_delete_teacher(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_admin then raise exception '관리자만 사용할 수 있습니다.'; end if;
  if p_id = a.o_uid then raise exception '본인 계정은 삭제할 수 없습니다.'; end if;
  if not a.o_super and exists (select 1 from as_teachers where id = p_id and is_admin) then
    raise exception '관리자 계정은 관리자만 삭제할 수 있습니다.';
  end if;
  if exists (select 1 from as_courses where teacher_id = p_id) then
    raise exception '개설한 강좌가 있는 교사는 삭제할 수 없습니다. 강좌 담당 교사를 먼저 바꿔 주세요.';
  end if;
  delete from as_teachers where id = p_id;
  delete from as_sessions where role = 'teacher' and user_id = p_id;
end $$;

create or replace function as_set_admin(p_token uuid, p_id bigint, p_admin boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not a.o_super then raise exception '관리자만 사용할 수 있습니다. (부관리자는 사용할 수 없는 기능)'; end if;
  if p_id = a.o_uid and not p_admin then raise exception '본인의 관리자 권한은 해제할 수 없습니다.'; end if;
  update as_teachers set is_admin = p_admin where id = p_id;
end $$;

-- ---------- 접속 현황 보고 (예약 작업이 호출) --------------------------------
-- p_day: 'today' = 오늘(한국 시간 0시~지금), 'yesterday' = 어제 하루, 'auto' = 낮 12시 전이면 어제, 이후면 오늘
-- 카카오톡 한 통(200자)에 맞춘 문장 목록(messages)을 돌려줍니다.
create or replace function as_access_report(p_key text, p_day text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_now timestamp := now() at time zone 'Asia/Seoul';
  v_day text := coalesce(p_day, 'auto');
  v_date date; v_from timestamptz; v_to timestamptz;
  g1 int; g2 int; g3 int; v_tn int; v_head text; v_msg text; v_item text; msgs text[] := '{}'; r record;
  v_dow text; v_nc int; v_miss int; v_names text; v_abs int; v_x text;
begin
  if coalesce(p_key, '') = '' or p_key is distinct from (select report_key from as_settings where id = 1) then
    return json_build_object('status', 'denied');
  end if;
  if v_day = 'auto' then v_day := case when extract(hour from v_now) < 12 then 'yesterday' else 'today' end; end if;
  v_date := v_now::date - case when v_day = 'yesterday' then 1 else 0 end;
  v_from := v_date::timestamp at time zone 'Asia/Seoul';
  v_to   := v_from + interval '1 day';
  v_dow  := (array['일','월','화','수','목','금','토'])[extract(dow from v_date)::int + 1];

  select count(distinct s.id) filter (where s.grade = 1), count(distinct s.id) filter (where s.grade = 2),
         count(distinct s.id) filter (where s.grade = 3)
    into g1, g2, g3
    from as_access_log l join as_students s on s.id = l.user_id
   where l.role = 'student' and l.at >= v_from and l.at < v_to;
  select count(distinct l.user_id) into v_tn from as_access_log l join as_teachers t on t.id = l.user_id
   where l.role = 'teacher' and l.at >= v_from and l.at < v_to;

  v_head := '[방과후학교] ' || to_char(v_date, 'FMMM/FMDD') || '(' || v_dow || ') 접속 현황'
         || case when v_day = 'yesterday' then ' · 어제 하루' else ' · ' || to_char(v_now, 'HH24:MI') || ' 기준' end;
  v_msg := v_head || E'\n학생 — 1학년 ' || g1 || '명, 2학년 ' || g2 || '명, 3학년 ' || g3 || '명 (계 ' || (g1 + g2 + g3) || '명)'
        || E'\n교사 — ' || case when v_tn = 0 then '접속 없음' else v_tn || '명 접속' end;
  if v_tn > 0 then v_msg := v_msg || E'\n'; end if;
  for r in
    select t.name, count(*) as n from as_access_log l join as_teachers t on t.id = l.user_id
     where l.role = 'teacher' and l.at >= v_from and l.at < v_to
     group by t.name order by count(*) desc, t.name
  loop
    v_item := r.name || ' ' || r.n || '회';
    if length(v_msg) + length(v_item) + 2 > 195 then            -- 한 통에 200자 제한 → 다음 통으로
      msgs := msgs || v_msg;
      v_msg := '[방과후학교] 교사 접속 (이어서)' || E'\n' || v_item;
    else
      v_msg := v_msg || case when right(v_msg, 1) = E'\n' then '' else ', ' end || v_item;
    end if;
  end loop;
  msgs := msgs || v_msg;

  -- 그날 수업·출석 요약 (수업이 있는 날만)
  select count(*), count(*) filter (where not exists (select 1 from as_attendance a where a.course_id = c.id and a.date = v_date)),
         string_agg(c.title, ', ' order by c.title) filter (where not exists (select 1 from as_attendance a where a.course_id = c.id and a.date = v_date))
    into v_nc, v_miss, v_names
    from as_courses c
   where c.status <> 'cancelled' and v_date = any (c.dates) and exists (select 1 from as_enrollments e where e.course_id = c.id);
  if v_nc > 0 then
    select count(distinct a.student_id) into v_abs from as_attendance a where a.date = v_date and a.mark = '/';
    v_x := '[방과후학교] ' || to_char(v_date, 'FMMM/FMDD') || '(' || v_dow || ') 수업 ' || v_nc || '강좌 · 결석 ' || v_abs || '명'
        || E'\n출석 미입력 ' || v_miss || '강좌' || case when v_miss > 0 then ': ' || v_names else '' end;
    if length(v_x) > 195 then v_x := left(v_x, 192) || '…'; end if;
    msgs := msgs || v_x;
  end if;
  -- 수강신청이 열려 있는 방과후학교의 신청 현황
  for r in
    select t.title,
           (select count(distinct e.student_id) from as_enrollments e join as_courses c on c.id = e.course_id where c.term_id = t.id and c.status <> 'cancelled') as st,
           (select count(*) from as_courses c where c.term_id = t.id and c.status = 'open' and c.capacity is not null
               and (select count(*) from as_enrollments e where e.course_id = c.id) >= c.capacity) as fl,
           (select count(*) from as_waitlist w join as_courses c on c.id = w.course_id where c.term_id = t.id) as wt
      from as_terms t where t.enroll_open order by t.id
  loop
    msgs := msgs || left('[방과후학교] 수강신청 중 — ' || r.title || E'\n신청 ' || r.st || '명 / 전체 ' || (select count(*) from as_students) || '명 · 정원 마감 ' || r.fl || '강좌 · 대기 ' || r.wt || '명', 195);
  end loop;
  return json_build_object('status', 'ok', 'day', v_day, 'date', v_date, 'students', json_build_object('1', g1, '2', g2, '3', g3),
                           'teachers', v_tn, 'messages', to_json(msgs));
end $$;

-- ---------- 권한 --------------------------------------------------------
-- 내부 함수는 웹(anon)에서 직접 호출하지 못하게 막습니다.
revoke execute on function as_auth(uuid)                         from public, anon, authenticated;
revoke execute on function as_do_enroll(bigint, bigint, boolean) from public, anon, authenticated;
revoke execute on function as_do_makeup(bigint, date)            from public, anon, authenticated;
revoke execute on function as_log_access(text, bigint)           from public, anon, authenticated;
revoke execute on function as_audit_add(text, bigint, text, bigint, bigint, text) from public, anon, authenticated;
revoke execute on function as_promote(bigint)                    from public, anon, authenticated;


-- ===== 예산 담당자: 예산 편성 · 예산 집행 =====
alter table as_teachers add column if not exists budget_mgr boolean not null default false;  -- 예산 담당자 여부
update as_teachers set budget_mgr = true where name in ('김지언', '김재홍') or is_manager;  -- 부관리자는 모두 담당자

create table if not exists as_budget_plans (
  id         bigint generated always as identity primary key,
  name       text   not null,              -- 사업명
  plan_date  date,                         -- 날짜
  allocated  bigint not null default 0,    -- 내려온 예산(원)
  note       text   not null default '',   -- 비고
  created_at timestamptz not null default now()
);
create table if not exists as_budget_execs (
  id         bigint generated always as identity primary key,
  plan_id    bigint not null references as_budget_plans(id) on delete cascade,
  detail     text   not null,              -- 세부항목
  exec_date  date,                         -- 날짜
  amount     bigint not null default 0,    -- 집행 예산(원)
  note       text   not null default '',   -- 비고
  created_at timestamptz not null default now()
);
alter table as_budget_plans enable row level security;
alter table as_budget_execs enable row level security;

create or replace function as_budget_check(p_token uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  select * into a from as_auth(p_token);
  if not (a.o_role = 'teacher' and exists (select 1 from as_teachers t
            where t.id = a.o_uid and (t.budget_mgr or t.is_admin or t.is_manager))) then
    raise exception '예산 담당자만 사용할 수 있습니다.';
  end if;
end $$;

create or replace function as_budget_get(p_token uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform as_budget_check(p_token);
  return json_build_object(
    'plans', (select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'plan_date', p.plan_date,
                                'allocated', p.allocated, 'note', p.note) order by p.plan_date nulls last, p.id), '[]'::json)
              from as_budget_plans p),
    'execs', (select coalesce(json_agg(x order by x.plan_id, x.exec_date nulls last, x.id), '[]'::json) from (
                select e.id, e.plan_id, e.detail, e.exec_date, e.amount, e.note,
                       p.allocated - sum(e.amount) over (partition by e.plan_id order by e.exec_date nulls last, e.id
                                                         rows between unbounded preceding and current row) as balance
                from as_budget_execs e join as_budget_plans p on p.id = e.plan_id) x));
end $$;

create or replace function as_budget_save_plan(p_token uuid, p_plan json) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_name text; v_alloc bigint;
begin
  perform as_budget_check(p_token);
  v_id    := nullif(p_plan->>'id', '')::bigint;
  v_name  := btrim(coalesce(p_plan->>'name', ''));
  v_alloc := coalesce(nullif(p_plan->>'allocated', '')::bigint, 0);
  if v_name = '' then raise exception '사업명을 입력해 주세요.'; end if;
  if v_alloc < 0 then raise exception '예산은 0원 이상이어야 합니다.'; end if;
  if v_id is null then
    insert into as_budget_plans (name, plan_date, allocated, note)
    values (v_name, nullif(p_plan->>'plan_date', '')::date, v_alloc, btrim(coalesce(p_plan->>'note', '')))
    returning id into v_id;
  else
    update as_budget_plans set name = v_name, plan_date = nullif(p_plan->>'plan_date', '')::date,
           allocated = v_alloc, note = btrim(coalesce(p_plan->>'note', ''))
     where id = v_id;
    if not found then raise exception '사업을 찾을 수 없습니다.'; end if;
  end if;
  return v_id;
end $$;

create or replace function as_budget_save_exec(p_token uuid, p_exec json) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_plan bigint; v_detail text; v_amt bigint; v_alloc bigint; v_spent bigint;
begin
  perform as_budget_check(p_token);
  v_id     := nullif(p_exec->>'id', '')::bigint;
  v_plan   := nullif(p_exec->>'plan_id', '')::bigint;
  v_detail := btrim(coalesce(p_exec->>'detail', ''));
  v_amt    := coalesce(nullif(p_exec->>'amount', '')::bigint, 0);
  select allocated into v_alloc from as_budget_plans where id = v_plan;
  if v_alloc is null then raise exception '사업명을 선택해 주세요.'; end if;
  if v_detail = '' then raise exception '세부항목을 입력해 주세요.'; end if;
  if v_amt <= 0 then raise exception '집행 예산을 입력해 주세요.'; end if;
  select coalesce(sum(amount), 0) into v_spent from as_budget_execs
   where plan_id = v_plan and (v_id is null or id <> v_id);
  if v_spent + v_amt > v_alloc then
    raise exception '편성된 예산을 초과합니다. (잔액 %원)', v_alloc - v_spent;
  end if;
  if v_id is null then
    insert into as_budget_execs (plan_id, detail, exec_date, amount, note)
    values (v_plan, v_detail, nullif(p_exec->>'exec_date', '')::date, v_amt, btrim(coalesce(p_exec->>'note', '')))
    returning id into v_id;
  else
    update as_budget_execs set plan_id = v_plan, detail = v_detail, exec_date = nullif(p_exec->>'exec_date', '')::date,
           amount = v_amt, note = btrim(coalesce(p_exec->>'note', ''))
     where id = v_id;
    if not found then raise exception '집행 내역을 찾을 수 없습니다.'; end if;
  end if;
  return v_id;
end $$;

create or replace function as_budget_delete(p_token uuid, p_kind text, p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform as_budget_check(p_token);
  if p_kind = 'plan' then delete from as_budget_plans where id = p_id;
  elsif p_kind = 'exec' then delete from as_budget_execs where id = p_id;
  else raise exception '잘못된 요청입니다.'; end if;
end $$;

revoke execute on function as_budget_check(uuid) from public, anon, authenticated;

-- 웹(API)이 바뀐 함수를 바로 알아보도록 새로 읽게 합니다
notify pgrst, 'reload schema';
