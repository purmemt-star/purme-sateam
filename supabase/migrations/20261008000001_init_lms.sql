-- =====================================================================
-- 푸르메 직원교육 LMS — Supabase 초기 스키마 (PoC v0.1)
-- 기준: PRD v0.1 §10 데이터 모델, 와이어프레임 설계노트 v0.4 가정
-- 실행: Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run (한 번만)
--
-- 원칙
--  * 진도·평가·이수 판정은 서버(DB 함수)에서만 한다. 학습자는 진도/점수 테이블에 직접 쓸 수 없다.
--  * 권한은 RLS로 강제한다: 직원=본인, 부서 교육담당자=소속 부서, 중앙 관리자=전체.
--  * 삭제 대신 비활성·보관. 이수 기록에는 이수 당시 부서를 남긴다.
--  * 평가 정답은 별도 테이블(question_keys)에 두어 학습자에게 노출하지 않는다.
--  * 로그인 ID = 사번. 앱에서 사번을 가상 이메일(사번@staff.internal)로 바꿔 Supabase Auth에 넘긴다.
-- =====================================================================

begin;  -- 중간에 오류가 나면 전체가 취소되어 반쯤 만들어진 상태가 남지 않는다

-- ---------------------------------------------------------------------
-- 0. 열거형
-- ---------------------------------------------------------------------
create type public.app_role       as enum ('learner', 'dept_manager', 'admin');
create type public.account_status as enum ('pending_dept', 'pending_admin', 'active', 'rejected', 'leave', 'inactive');
create type public.course_type    as enum ('required', 'optional');
create type public.course_status  as enum ('draft', 'pending', 'published', 'rejected', 'archived');
create type public.assign_type    as enum ('auto', 'manual', 'self_enrolled');
create type public.question_type  as enum ('single', 'multiple');
create type public.review_status  as enum ('requested', 'approved', 'rejected', 'cancelled');

-- ---------------------------------------------------------------------
-- 1. 기준정보
-- ---------------------------------------------------------------------
create table public.departments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  parent_id   uuid references public.departments(id),
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

create table public.job_types (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  description text,
  is_active   boolean not null default true,
  sort_order  int not null default 0
);

create table public.ranks (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  description text,
  is_active   boolean not null default true,
  sort_order  int not null default 0
);

create table public.categories (          -- 분야(기관 이해·재활의학·재활치료·정서·행동)
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  is_active   boolean not null default true,
  sort_order  int not null default 0
);

-- ---------------------------------------------------------------------
-- 2. 사용자 프로필 (auth.users 1:1)
-- ---------------------------------------------------------------------
create table public.profiles (
  id                    uuid primary key references auth.users(id) on delete restrict,
  employee_no           text not null unique,
  full_name             text not null,
  department_id         uuid references public.departments(id),
  job_type_id           uuid references public.job_types(id),
  rank_id               uuid references public.ranks(id),
  hire_date             date,
  role                  public.app_role not null default 'learner',
  status                public.account_status not null default 'pending_dept',
  rejected_reason       text,
  must_change_password  boolean not null default false,
  registered_via        text not null default 'self' check (registered_via in ('self', 'bulk')),
  dept_confirmed_at     timestamptz,
  dept_confirmed_by     uuid references auth.users(id),
  approved_at           timestamptz,
  approved_by           uuid references auth.users(id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index on public.profiles (department_id);
create index on public.profiles (status);

-- ---------------------------------------------------------------------
-- 3. 교육과정·차시·자료·대상 규칙
-- ---------------------------------------------------------------------
create table public.courses (
  id                     uuid primary key default gen_random_uuid(),
  title                  text not null,
  description            text,
  objectives             text[] not null default '{}',
  owner_department_id    uuid not null references public.departments(id),
  instructor             text,
  category_id            uuid references public.categories(id),
  course_type            public.course_type not null default 'required',
  status                 public.course_status not null default 'draft',
  duration_minutes       int check (duration_minutes is null or duration_minutes > 0),  -- 이수증 교육시간
  original_lecture_date  date,                                                         -- 원 강의일
  thumbnail_path         text,
  survey_url             text,                                                         -- 만족도 설문(선택)
  created_by             uuid references auth.users(id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  published_at           timestamptz
);
create index on public.courses (status);
create index on public.courses (owner_department_id);

-- 필수교육 자동 배정 규칙: 과정당 1행. 배열이 비어 있으면 '전체'.
-- 조건 사이는 AND, 같은 조건 안의 항목은 OR.
create table public.course_target_rules (
  course_id       uuid primary key references public.courses(id) on delete cascade,
  department_ids  uuid[] not null default '{}',
  job_type_ids    uuid[] not null default '{}',
  rank_ids        uuid[] not null default '{}',
  updated_at      timestamptz not null default now(),
  updated_by      uuid references auth.users(id)
);

create table public.lessons (
  id                uuid primary key default gen_random_uuid(),
  course_id         uuid not null references public.courses(id) on delete cascade,
  sort_order        int not null default 1,
  title             text not null,
  vimeo_video_id    text not null check (vimeo_video_id ~ '^[0-9]+$'),
  vimeo_hash        text check (vimeo_hash is null or vimeo_hash ~ '^[0-9a-f]+$'),
  duration_seconds  int not null check (duration_seconds > 0),
  unique (course_id, sort_order)
);

create table public.attachments (
  id          uuid primary key default gen_random_uuid(),
  course_id   uuid not null references public.courses(id) on delete cascade,
  file_path   text not null,          -- Supabase Storage 경로
  file_name   text not null,
  size_bytes  bigint,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. 평가 (문항은 공개, 정답은 분리)
-- ---------------------------------------------------------------------
create table public.questions (
  id             uuid primary key default gen_random_uuid(),
  course_id      uuid not null references public.courses(id) on delete cascade,
  sort_order     int not null default 1,
  question_type  public.question_type not null default 'single',
  body           text not null,
  options        jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) >= 2),
  points         int not null default 1 check (points > 0),
  unique (course_id, sort_order)
);

create table public.question_keys (
  question_id      uuid primary key references public.questions(id) on delete cascade,
  correct_options  int[] not null check (cardinality(correct_options) >= 1)   -- 0부터 시작하는 보기 번호
);

-- ---------------------------------------------------------------------
-- 5. 배정·진도·응시·이수
-- ---------------------------------------------------------------------
create table public.assignments (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles(id),
  course_id        uuid not null references public.courses(id),
  assignment_type  public.assign_type not null default 'auto',
  assigned_at      timestamptz not null default now(),
  assigned_by      uuid references auth.users(id),
  unique (user_id, course_id)
);
create index on public.assignments (course_id);

create table public.lesson_progress (
  user_id          uuid not null references public.profiles(id),
  lesson_id        uuid not null references public.lessons(id) on delete cascade,
  watched_segments jsonb not null default '[]',   -- [[시작초, 끝초], ...] 병합된 고유 구간
  watched_seconds  numeric(10,2) not null default 0,
  progress_ratio   numeric(5,4) not null default 0,
  last_position    numeric(10,2) not null default 0,
  max_reached      numeric(10,2) not null default 0,
  updated_at       timestamptz not null default now(),
  primary key (user_id, lesson_id)
);

create table public.quiz_attempts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id),
  course_id     uuid not null references public.courses(id),
  attempt_no    int not null,
  answers       jsonb not null,               -- {"<question_id>": [보기번호...]}
  score         int not null check (score between 0 and 100),
  passed        boolean not null,
  submitted_at  timestamptz not null default now(),
  unique (user_id, course_id, attempt_no)
);

create table public.completions (
  id                          uuid primary key default gen_random_uuid(),
  user_id                     uuid not null references public.profiles(id),
  course_id                   uuid not null references public.courses(id),
  completed_at                timestamptz not null default now(),
  department_id_at_completion uuid references public.departments(id),
  department_name_at_completion text,
  certificate_no              text not null unique,
  unique (user_id, course_id)                 -- 중복 이수 방지
);

create table public.certificate_counters (
  year     int primary key,
  last_no  int not null default 0
);

create table public.certificate_settings (
  id             boolean primary key default true check (id),   -- 단일 행
  org_name       text not null default '[발급기관명]',
  signer         text not null default '[직위] [성명]',
  number_prefix  text not null default 'PRM' check (number_prefix ~ '^[A-Z0-9]{1,10}$'),
  time_format    text not null default 'hm' check (time_format in ('hm', 'h', 'm')),
  show_seal      boolean not null default true,
  seal_path      text,
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id)
);

-- ---------------------------------------------------------------------
-- 6. 콘텐츠 승인·감사로그
-- ---------------------------------------------------------------------
create table public.content_reviews (
  id            uuid primary key default gen_random_uuid(),
  course_id     uuid not null references public.courses(id) on delete cascade,
  requested_by  uuid not null references auth.users(id),
  requested_at  timestamptz not null default now(),
  reviewer_id   uuid references auth.users(id),
  status        public.review_status not null default 'requested',
  reason        text,
  reviewed_at   timestamptz,
  check (status <> 'rejected' or coalesce(length(trim(reason)), 0) > 0)   -- 반려 사유 필수
);
create index on public.content_reviews (course_id);

create table public.audit_logs (
  id           bigint generated always as identity primary key,
  actor_id     uuid,
  action       text not null,
  target_table text not null,
  target_id    text,
  before       jsonb,
  after        jsonb,
  created_at   timestamptz not null default now()
);
create index on public.audit_logs (target_table, target_id);

-- =====================================================================
-- 7. 권한 도우미 함수 (RLS에서 사용)
-- =====================================================================
create or replace function public.my_role() returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and status = 'active'
$$;

create or replace function public.my_department() returns uuid
language sql stable security definer set search_path = public as $$
  select department_id from public.profiles where id = auth.uid() and status = 'active'
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'active')
$$;

-- 부서 교육담당자이고 해당 부서가 내 부서인가
create or replace function public.manages_department(p_dept uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'dept_manager' and public.my_department() = p_dept, false)
$$;

-- 이 사용자를 볼 수 있는가 (본인 / 같은 부서 담당자 / 관리자)
create or replace function public.can_see_user(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user = auth.uid()
      or public.is_admin()
      or exists (select 1 from public.profiles p where p.id = p_user and public.manages_department(p.department_id))
$$;

-- 이 과정을 볼 수 있는가 (게시 과정은 활성 직원 전체 / 담당 부서 / 관리자)
create or replace function public.can_see_course(p_course uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.courses c
    where c.id = p_course
      and ( public.is_admin()
         or public.manages_department(c.owner_department_id)
         or (c.status = 'published' and public.is_active_user()) )
  )
$$;

-- 이 과정을 편집할 수 있는가 (관리자 / 담당 부서의 초안·반려 과정)
create or replace function public.can_edit_course(p_course uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.courses c
    where c.id = p_course
      and ( public.is_admin()
         or (public.manages_department(c.owner_department_id) and c.status in ('draft', 'rejected')) )
  )
$$;

-- =====================================================================
-- 8. 공통 트리거: updated_at, 감사로그
-- =====================================================================
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create trigger trg_profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger trg_courses_touch before update on public.courses
  for each row execute function public.touch_updated_at();

create or replace function public.write_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_logs (actor_id, action, target_table, target_id, before, after)
  values (auth.uid(), tg_op, tg_table_name,
          coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'id',
                   (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'course_id'),
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

-- 승인·게시·권한·이수·기준정보 변경 기록 (PRD ADMIN-02)
create trigger trg_audit_profiles      after update            on public.profiles             for each row execute function public.write_audit();
create trigger trg_audit_courses       after insert or update  on public.courses              for each row execute function public.write_audit();
create trigger trg_audit_rules         after insert or update  on public.course_target_rules  for each row execute function public.write_audit();
create trigger trg_audit_reviews       after insert or update  on public.content_reviews      for each row execute function public.write_audit();
create trigger trg_audit_completions   after insert or delete  on public.completions          for each row execute function public.write_audit();
create trigger trg_audit_cert_settings after update            on public.certificate_settings for each row execute function public.write_audit();
create trigger trg_audit_departments   after insert or update  on public.departments          for each row execute function public.write_audit();

-- =====================================================================
-- 9. 가입: auth.users 생성 시 프로필 자동 생성
--    앱의 signUp 호출에 options.data 로 아래 값을 넘긴다:
--    employee_no, full_name, department_id, job_type_id, rank_id, hire_date
--    (관리자 CSV 일괄등록은 서버에서 registered_via='bulk' 로 넘기면 바로 활성)
-- =====================================================================
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  bulk boolean := coalesce(new.raw_app_meta_data ->> 'registered_via', '') = 'bulk';
begin
  insert into public.profiles (id, employee_no, full_name, department_id, job_type_id, rank_id, hire_date,
                               status, registered_via, must_change_password)
  values (new.id,
          coalesce(m ->> 'employee_no', split_part(new.email, '@', 1)),
          coalesce(m ->> 'full_name', ''),
          nullif(m ->> 'department_id', '')::uuid,
          nullif(m ->> 'job_type_id', '')::uuid,
          nullif(m ->> 'rank_id', '')::uuid,
          nullif(m ->> 'hire_date', '')::date,
          case when bulk then 'active'::public.account_status else 'pending_dept'::public.account_status end,
          case when bulk then 'bulk' else 'self' end,
          bulk);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- =====================================================================
-- 10. 필수교육 자동 배정
-- =====================================================================
create or replace function public.rule_matches(r public.course_target_rules, p public.profiles) returns boolean
language sql immutable as $$
  select (cardinality(r.department_ids) = 0 or p.department_id = any (r.department_ids))
     and (cardinality(r.job_type_ids)   = 0 or p.job_type_id   = any (r.job_type_ids))
     and (cardinality(r.rank_ids)       = 0 or p.rank_id       = any (r.rank_ids))
$$;

-- 한 직원에게 해당하는 게시된 필수과정을 모두 배정 (이미 있으면 건너뜀)
create or replace function public.assign_required_for_user(p_user uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.assignments (user_id, course_id, assignment_type)
  select p.id, c.id, 'auto'
  from public.profiles p
  join public.courses c on c.status = 'published' and c.course_type = 'required'
  left join public.course_target_rules r on r.course_id = c.id
  where p.id = p_user and p.status = 'active'
    and (r.course_id is null or public.rule_matches(r, p))
  on conflict (user_id, course_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- 한 과정을 대상 직원 전체에게 배정 (게시 시, 또는 규칙 변경 후 '기존 직원에게도 배정' 선택 시)
create or replace function public.assign_course_to_targets(p_course uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception '중앙 관리자만 실행할 수 있습니다';
  end if;
  insert into public.assignments (user_id, course_id, assignment_type)
  select p.id, c.id, 'auto'
  from public.courses c
  left join public.course_target_rules r on r.course_id = c.id
  join public.profiles p on p.status = 'active' and (r.course_id is null or public.rule_matches(r, p))
  where c.id = p_course and c.status = 'published' and c.course_type = 'required'
  on conflict (user_id, course_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- 계정이 활성화되면 자동 배정
create or replace function public.on_profile_activated() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active') then
    perform public.assign_required_for_user(new.id);
  end if;
  return new;
end $$;
create trigger trg_profile_activated after insert or update of status on public.profiles
  for each row execute function public.on_profile_activated();

-- 부서 이동 시 새 부서 규칙에 맞는 과정 추가 배정 (기존 이수 기록은 유지)
create or replace function public.on_profile_org_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and (new.department_id, new.job_type_id, new.rank_id)
       is distinct from (old.department_id, old.job_type_id, old.rank_id) then
    perform public.assign_required_for_user(new.id);
  end if;
  return new;
end $$;
create trigger trg_profile_org_changed after update of department_id, job_type_id, rank_id on public.profiles
  for each row execute function public.on_profile_org_changed();

-- 과정이 게시되면 대상 직원에게 자동 배정
create or replace function public.on_course_published() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'published' and old.status is distinct from 'published' then
    new.published_at := coalesce(new.published_at, now());
  end if;
  return new;
end $$;
create trigger trg_course_published_ts before update of status on public.courses
  for each row execute function public.on_course_published();

create or replace function public.after_course_published() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'published' and old.status is distinct from 'published' then
    insert into public.assignments (user_id, course_id, assignment_type)
    select p.id, new.id, 'auto'
    from public.profiles p
    left join public.course_target_rules r on r.course_id = new.id
    where new.course_type = 'required' and p.status = 'active'
      and (r.course_id is null or public.rule_matches(r, p))
    on conflict (user_id, course_id) do nothing;
  end if;
  return new;
end $$;
create trigger trg_course_published after update of status on public.courses
  for each row execute function public.after_course_published();

-- =====================================================================
-- 11. 가입 2단계 승인 (부서 확인 → 중앙 최종 승인)
-- =====================================================================
create or replace function public.dept_confirm_signup(p_user uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare d uuid;
begin
  select department_id into d from public.profiles where id = p_user and status = 'pending_dept';
  if not found then raise exception '부서 확인 대기 상태가 아닙니다'; end if;
  if not (public.manages_department(d) or public.is_admin()) then raise exception '권한이 없습니다'; end if;
  if not p_approve and coalesce(length(trim(p_reason)), 0) = 0 then raise exception '반려 사유를 입력하세요'; end if;
  update public.profiles
     set status = case when p_approve then 'pending_admin'::account_status else 'rejected' end,
         rejected_reason = case when p_approve then null else p_reason end,
         dept_confirmed_at = now(), dept_confirmed_by = auth.uid()
   where id = p_user;
end $$;

create or replace function public.admin_approve_signup(p_users uuid[], p_approve boolean, p_reason text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception '중앙 관리자만 승인할 수 있습니다'; end if;
  if not p_approve and coalesce(length(trim(p_reason)), 0) = 0 then raise exception '반려 사유를 입력하세요'; end if;
  update public.profiles
     set status = case when p_approve then 'active'::account_status else 'rejected' end,
         rejected_reason = case when p_approve then null else p_reason end,
         approved_at = now(), approved_by = auth.uid()
   where id = any (p_users) and status = 'pending_admin';
  get diagnostics n = row_count;
  return n;   -- 활성화 트리거가 필수교육을 자동 배정한다
end $$;

-- 반려된 직원이 정보를 고쳐 재신청
create or replace function public.resubmit_signup(p_department uuid, p_job_type uuid, p_rank uuid, p_hire_date date)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
     set department_id = p_department, job_type_id = p_job_type, rank_id = p_rank, hire_date = p_hire_date,
         status = 'pending_dept', rejected_reason = null
   where id = auth.uid() and status = 'rejected';
  if not found then raise exception '반려 상태에서만 재신청할 수 있습니다'; end if;
end $$;

-- =====================================================================
-- 12. 콘텐츠 승인 요청·검토
-- =====================================================================
create or replace function public.request_course_review(p_course uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare c public.courses; rid uuid;
begin
  select * into c from public.courses where id = p_course;
  if not found then raise exception '과정이 없습니다'; end if;
  if not (public.manages_department(c.owner_department_id) or public.is_admin()) then raise exception '권한이 없습니다'; end if;
  if c.status not in ('draft', 'rejected') then raise exception '초안·반려 상태에서만 요청할 수 있습니다'; end if;
  if not exists (select 1 from public.lessons where course_id = p_course) then raise exception '영상(차시)을 1개 이상 등록하세요'; end if;
  if not exists (select 1 from public.questions where course_id = p_course) then raise exception '평가문항을 1개 이상 등록하세요'; end if;
  if exists (select 1 from public.questions q left join public.question_keys k on k.question_id = q.id
             where q.course_id = p_course and k.question_id is null) then raise exception '정답이 지정되지 않은 문항이 있습니다'; end if;
  update public.courses set status = 'pending' where id = p_course;
  insert into public.content_reviews (course_id, requested_by) values (p_course, auth.uid()) returning id into rid;
  return rid;
end $$;

create or replace function public.review_course(p_course uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '중앙 관리자만 검토할 수 있습니다'; end if;
  if not p_approve and coalesce(length(trim(p_reason)), 0) = 0 then raise exception '반려 사유를 입력하세요'; end if;
  update public.content_reviews
     set status = case when p_approve then 'approved'::review_status else 'rejected' end,
         reason = p_reason, reviewer_id = auth.uid(), reviewed_at = now()
   where course_id = p_course and status = 'requested';
  if not found then raise exception '검토 대기 중인 요청이 없습니다'; end if;
  update public.courses
     set status = case when p_approve then 'published'::course_status else 'rejected' end
   where id = p_course;   -- 게시 트리거가 대상 직원에게 자동 배정한다
end $$;

-- =====================================================================
-- 13. 진도 저장 (서버 검증·구간 병합)
--     앱은 재생 중 몇 초마다 새로 본 구간과 현재 위치를 보낸다.
-- =====================================================================
create or replace function public.merge_segments(p_segs jsonb, p_max numeric) returns jsonb
language plpgsql immutable as $$
declare
  result jsonb := '[]'; s numeric; e numeric; cs numeric; ce numeric; rec record;
begin
  for rec in
    select greatest(0, least((x ->> 0)::numeric, p_max)) a, greatest(0, least((x ->> 1)::numeric, p_max)) b
    from jsonb_array_elements(coalesce(p_segs, '[]')) x
    where jsonb_typeof(x) = 'array' and jsonb_array_length(x) = 2
    order by 1
  loop
    s := rec.a; e := rec.b;
    continue when e <= s;
    if cs is null then cs := s; ce := e;
    elsif s <= ce + 0.25 then ce := greatest(ce, e);
    else result := result || jsonb_build_array(jsonb_build_array(cs, ce)); cs := s; ce := e;
    end if;
  end loop;
  if cs is not null then result := result || jsonb_build_array(jsonb_build_array(cs, ce)); end if;
  return result;
end $$;

create or replace function public.save_progress(p_lesson uuid, p_new_segments jsonb, p_position numeric)
returns public.lesson_progress
language plpgsql security definer set search_path = public as $$
declare
  l public.lessons; cur public.lesson_progress; merged jsonb; total numeric; done boolean;
  frontier numeric; accepted jsonb := '[]'; rec record; res public.lesson_progress;
begin
  if not public.is_active_user() then raise exception '활성 계정만 학습할 수 있습니다'; end if;
  select * into l from public.lessons where id = p_lesson;
  if not found then raise exception '차시가 없습니다'; end if;
  if not exists (select 1 from public.assignments where user_id = auth.uid() and course_id = l.course_id) then
    raise exception '배정·신청된 과정이 아닙니다';
  end if;

  select * into cur from public.lesson_progress where user_id = auth.uid() and lesson_id = p_lesson;
  done := exists (select 1 from public.completions where user_id = auth.uid() and course_id = l.course_id);
  frontier := coalesce(cur.max_reached, 0);

  -- 구간을 시작 순서대로 보며, 지금까지 도달한 지점 + 5초 안에서 시작하는 구간만 인정한다.
  -- (이수 전 건너뛰기 방지 서버 검증. 이수 후에는 모두 인정)
  for rec in
    select greatest(0, least((x ->> 0)::numeric, l.duration_seconds)) a,
           greatest(0, least((x ->> 1)::numeric, l.duration_seconds)) b
    from jsonb_array_elements(coalesce(p_new_segments, '[]')) x
    where jsonb_typeof(x) = 'array' and jsonb_array_length(x) = 2
    order by 1
  loop
    continue when rec.b <= rec.a;
    if done or rec.a <= frontier + 5 then
      accepted := accepted || jsonb_build_array(jsonb_build_array(rec.a, rec.b));
      if rec.a <= frontier + 5 then frontier := greatest(frontier, rec.b); end if;
    end if;
  end loop;

  merged := public.merge_segments(coalesce(cur.watched_segments, '[]') || accepted, l.duration_seconds);
  select coalesce(sum((x ->> 1)::numeric - (x ->> 0)::numeric), 0) into total from jsonb_array_elements(merged) x;

  insert into public.lesson_progress as lp (user_id, lesson_id, watched_segments, watched_seconds, progress_ratio,
                                            last_position, max_reached, updated_at)
  values (auth.uid(), p_lesson, merged, total, least(1, total / l.duration_seconds),
          greatest(0, least(coalesce(p_position, 0), l.duration_seconds)), frontier, now())
  on conflict (user_id, lesson_id) do update
     set watched_segments = excluded.watched_segments,
         watched_seconds  = excluded.watched_seconds,
         progress_ratio   = excluded.progress_ratio,
         last_position    = excluded.last_position,
         max_reached      = greatest(lp.max_reached, excluded.max_reached),
         updated_at       = now()
  returning * into res;
  return res;
end $$;

-- 과정 시청 기준(모든 차시 80% 이상) 충족 여부
create or replace function public.course_watch_met(p_user uuid, p_course uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.lessons where course_id = p_course)
     and not exists (
       select 1 from public.lessons l
       left join public.lesson_progress lp on lp.lesson_id = l.id and lp.user_id = p_user
       where l.course_id = p_course and coalesce(lp.progress_ratio, 0) < 0.8
     )
$$;

-- =====================================================================
-- 14. 평가 제출·채점·자동 이수 (60점 이상, 재응시 무제한)
-- =====================================================================
create or replace function public.next_certificate_no() returns text
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from now() at time zone 'Asia/Seoul'); n int; pfx text;
begin
  insert into public.certificate_counters (year, last_no) values (y, 1)
  on conflict (year) do update set last_no = certificate_counters.last_no + 1
  returning last_no into n;
  select number_prefix into pfx from public.certificate_settings where id;
  return coalesce(pfx, 'PRM') || '-' || y || '-' || lpad(n::text, 6, '0');
end $$;

create or replace function public.submit_quiz(p_course uuid, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); total_pts int; got_pts int; score int; passed boolean; n int; cert text; prof public.profiles;
begin
  if not public.is_active_user() then raise exception '활성 계정만 응시할 수 있습니다'; end if;
  if not exists (select 1 from public.assignments where user_id = uid and course_id = p_course) then
    raise exception '배정·신청된 과정이 아닙니다';
  end if;
  if not public.course_watch_met(uid, p_course) then raise exception '영상 시청률 80%%를 충족한 뒤 응시할 수 있습니다'; end if;

  select coalesce(sum(q.points), 0),
         coalesce(sum(q.points) filter (where
           (select array_agg(v::int order by v::int) from jsonb_array_elements_text(coalesce(p_answers -> q.id::text, '[]')) v)
           = (select array_agg(c order by c) from unnest(k.correct_options) c)), 0)
    into total_pts, got_pts
  from public.questions q join public.question_keys k on k.question_id = q.id
  where q.course_id = p_course;

  if total_pts = 0 then raise exception '평가문항이 없습니다'; end if;
  score  := round(got_pts * 100.0 / total_pts);
  passed := score >= 60;

  select coalesce(max(attempt_no), 0) + 1 into n from public.quiz_attempts where user_id = uid and course_id = p_course;
  insert into public.quiz_attempts (user_id, course_id, attempt_no, answers, score, passed)
  values (uid, p_course, n, p_answers, score, passed);

  if passed and not exists (select 1 from public.completions where user_id = uid and course_id = p_course) then
    select * into prof from public.profiles where id = uid;
    cert := public.next_certificate_no();
    insert into public.completions (user_id, course_id, department_id_at_completion, department_name_at_completion, certificate_no)
    values (uid, p_course, prof.department_id, (select name from public.departments where id = prof.department_id), cert)
    on conflict (user_id, course_id) do nothing;
  end if;

  -- 불합격 시 정답은 돌려주지 않고 틀린 문항 수만 알린다
  return jsonb_build_object('attempt_no', n, 'score', score, 'passed', passed,
                            'wrong_count', (select count(*) from public.questions q join public.question_keys k on k.question_id = q.id
                                            where q.course_id = p_course and
                                            (select array_agg(v::int order by v::int) from jsonb_array_elements_text(coalesce(p_answers -> q.id::text, '[]')) v)
                                            is distinct from (select array_agg(c order by c) from unnest(k.correct_options) c)),
                            'certificate_no', (select certificate_no from public.completions where user_id = uid and course_id = p_course));
end $$;

-- =====================================================================
-- 15. 선택교육 신청
-- =====================================================================
create or replace function public.enroll_optional(p_course uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_active_user() then raise exception '활성 계정만 신청할 수 있습니다'; end if;
  if not exists (select 1 from public.courses where id = p_course and status = 'published' and course_type = 'optional') then
    raise exception '신청할 수 있는 선택교육이 아닙니다';
  end if;
  insert into public.assignments (user_id, course_id, assignment_type, assigned_by)
  values (auth.uid(), p_course, 'self_enrolled', auth.uid())
  on conflict (user_id, course_id) do nothing;
end $$;

-- =====================================================================
-- 16. 이수현황 뷰 (호출자 권한으로 실행 → RLS 그대로 적용)
--     화면 통계와 엑셀 출력은 이 뷰 하나를 기준으로 한다.
-- =====================================================================
create or replace view public.v_assignment_status with (security_invoker = true) as
select a.user_id, p.employee_no, p.full_name, p.department_id, d.name as department_name,
       jt.name as job_type_name, a.course_id, c.title as course_title, a.assignment_type, a.assigned_at,
       coalesce((select avg(coalesce(lp.progress_ratio, 0)) from public.lessons l
                 left join public.lesson_progress lp on lp.lesson_id = l.id and lp.user_id = a.user_id
                 where l.course_id = a.course_id), 0) as watch_ratio,
       (select max(score) from public.quiz_attempts qa where qa.user_id = a.user_id and qa.course_id = a.course_id) as best_score,
       cm.completed_at, cm.certificate_no,
       case when cm.id is not null then 'completed'
            when exists (select 1 from public.lesson_progress lp join public.lessons l on l.id = lp.lesson_id
                         where lp.user_id = a.user_id and l.course_id = a.course_id and lp.watched_seconds > 0)
              or exists (select 1 from public.quiz_attempts qa where qa.user_id = a.user_id and qa.course_id = a.course_id)
            then 'in_progress' else 'not_started' end as status
from public.assignments a
join public.profiles p on p.id = a.user_id
join public.courses c on c.id = a.course_id
left join public.departments d on d.id = p.department_id
left join public.job_types jt on jt.id = p.job_type_id
left join public.completions cm on cm.user_id = a.user_id and cm.course_id = a.course_id;

-- =====================================================================
-- 17. RLS
-- =====================================================================
alter table public.departments          enable row level security;
alter table public.job_types            enable row level security;
alter table public.ranks                enable row level security;
alter table public.categories           enable row level security;
alter table public.profiles             enable row level security;
alter table public.courses              enable row level security;
alter table public.course_target_rules  enable row level security;
alter table public.lessons              enable row level security;
alter table public.attachments          enable row level security;
alter table public.questions            enable row level security;
alter table public.question_keys        enable row level security;
alter table public.assignments          enable row level security;
alter table public.lesson_progress      enable row level security;
alter table public.quiz_attempts        enable row level security;
alter table public.completions          enable row level security;
alter table public.certificate_counters enable row level security;
alter table public.certificate_settings enable row level security;
alter table public.content_reviews      enable row level security;
alter table public.audit_logs           enable row level security;

-- 기준정보: 로그인 사용자 읽기(가입 화면 선택지), 관리자만 쓰기. 가입 전(anon) 화면용으로 활성 항목만 공개.
create policy ref_read_dept  on public.departments for select to anon, authenticated using (is_active);
create policy ref_read_job   on public.job_types   for select to anon, authenticated using (is_active);
create policy ref_read_rank  on public.ranks       for select to anon, authenticated using (is_active);
create policy ref_read_cat   on public.categories  for select to authenticated using (true);
create policy ref_write_dept on public.departments for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy ref_write_job  on public.job_types   for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy ref_write_rank on public.ranks       for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy ref_write_cat  on public.categories  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 프로필: 본인 / 같은 부서 담당자 / 관리자 읽기. 수정은 관리자만(가입 승인·재신청은 함수로).
create policy prof_read   on public.profiles for select to authenticated using (public.can_see_user(id));
create policy prof_admin  on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- 과정
create policy course_read   on public.courses for select to authenticated using (public.can_see_course(id));
create policy course_insert on public.courses for insert to authenticated
  with check (public.is_admin() or (public.manages_department(owner_department_id) and status = 'draft'));
create policy course_update on public.courses for update to authenticated
  using (public.can_edit_course(id))
  with check (public.is_admin() or (public.manages_department(owner_department_id) and status in ('draft', 'rejected')));

-- 과정 하위 항목: 볼 수 있으면 읽기, 편집 가능하면 쓰기
create policy rule_read    on public.course_target_rules for select to authenticated using (public.can_see_course(course_id));
create policy rule_write   on public.course_target_rules for all    to authenticated using (public.can_edit_course(course_id)) with check (public.can_edit_course(course_id));
create policy lesson_read  on public.lessons     for select to authenticated using (public.can_see_course(course_id));
create policy lesson_write on public.lessons     for all    to authenticated using (public.can_edit_course(course_id)) with check (public.can_edit_course(course_id));
create policy att_read     on public.attachments for select to authenticated using (public.can_see_course(course_id));
create policy att_write    on public.attachments for all    to authenticated using (public.can_edit_course(course_id)) with check (public.can_edit_course(course_id));
create policy q_read       on public.questions   for select to authenticated using (public.can_see_course(course_id));
create policy q_write      on public.questions   for all    to authenticated using (public.can_edit_course(course_id)) with check (public.can_edit_course(course_id));
-- 정답: 학습자는 못 봄. 관리자·담당 부서만.
create policy key_read on public.question_keys for select to authenticated
  using (exists (select 1 from public.questions q join public.courses c on c.id = q.course_id
                 where q.id = question_id and (public.is_admin() or public.manages_department(c.owner_department_id))));
create policy key_write on public.question_keys for all to authenticated
  using (exists (select 1 from public.questions q where q.id = question_id and public.can_edit_course(q.course_id)))
  with check (exists (select 1 from public.questions q where q.id = question_id and public.can_edit_course(q.course_id)));

-- 배정·진도·응시·이수: 읽기만(본인/부서 담당/관리자). 쓰기는 함수 경유. 관리자 수동 배정만 직접 허용.
create policy asg_read   on public.assignments     for select to authenticated using (public.can_see_user(user_id));
create policy asg_admin  on public.assignments     for insert to authenticated with check (public.is_admin());
create policy prog_read  on public.lesson_progress for select to authenticated using (public.can_see_user(user_id));
create policy quiz_read  on public.quiz_attempts   for select to authenticated using (public.can_see_user(user_id));
create policy comp_read  on public.completions     for select to authenticated using (public.can_see_user(user_id));

-- 이수증 설정: 읽기 전체, 수정 관리자
create policy cert_read  on public.certificate_settings for select to authenticated using (true);
create policy cert_write on public.certificate_settings for update to authenticated using (public.is_admin()) with check (public.is_admin());
-- certificate_counters: 정책 없음 = 함수만 접근

-- 콘텐츠 승인: 담당 부서·관리자 읽기 (쓰기는 함수)
create policy review_read on public.content_reviews for select to authenticated
  using (public.is_admin() or exists (select 1 from public.courses c where c.id = course_id and public.manages_department(c.owner_department_id)));

-- 감사로그: 관리자 읽기만
create policy audit_read on public.audit_logs for select to authenticated using (public.is_admin());

-- 함수 실행 권한: 내부용 함수(배정·이수번호 발급 등)는 막고, 앱이 부르는 함수만 로그인 사용자에게 연다
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
grant execute on function
  public.save_progress(uuid, jsonb, numeric), public.submit_quiz(uuid, jsonb), public.enroll_optional(uuid),
  public.dept_confirm_signup(uuid, boolean, text), public.admin_approve_signup(uuid[], boolean, text),
  public.resubmit_signup(uuid, uuid, uuid, date), public.request_course_review(uuid), public.review_course(uuid, boolean, text),
  public.assign_course_to_targets(uuid), public.course_watch_met(uuid, uuid),
  public.my_role(), public.my_department(), public.is_admin(), public.is_active_user(),
  public.manages_department(uuid), public.can_see_user(uuid), public.can_see_course(uuid), public.can_edit_course(uuid)
to authenticated;

-- =====================================================================
-- 18. 기준정보 초기값
-- =====================================================================
insert into public.departments (name, sort_order) values
  ('재활의학과', 1), ('재활치료센터', 2), ('정신건강의학과', 3), ('간호부', 4), ('행정부', 5);

insert into public.job_types (name, description, sort_order) values
  ('의사직', '전문의·전공의', 1), ('치료직', '물리·작업·언어·정서행동 치료사', 2), ('간호직', '간호사·간호조무사', 3),
  ('심리직', '임상심리사', 4), ('행정직', '원무·총무·교육', 5), ('사회복지직', '의료사회복지사', 6);

insert into public.ranks (name, sort_order) values
  ('사원', 1), ('주임', 2), ('대리', 3), ('팀장', 4), ('수간호사', 5), ('부장', 6);

insert into public.categories (name, sort_order) values
  ('기관 이해', 1), ('재활의학', 2), ('재활치료', 3), ('정서·행동', 4);

insert into public.certificate_settings (id) values (true);

commit;
