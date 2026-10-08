-- =====================================================================
-- 초기 스키마 실행 전 정리 (새 프로젝트에 다른 템플릿이 먼저 만든 객체 제거)
-- 주의: public.profiles 등에 지켜야 할 데이터가 없을 때만 실행하세요. 되돌릴 수 없습니다.
-- =====================================================================
begin;

-- Supabase 'User Management Starter' 등이 만든 가입 트리거·함수·테이블
drop trigger  if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user() cascade;

-- 이 LMS 스키마가 반쯤 만들어졌다면 함께 정리
drop view  if exists public.v_assignment_status cascade;
drop table if exists public.audit_logs, public.content_reviews, public.certificate_settings,
                     public.certificate_counters, public.completions, public.quiz_attempts,
                     public.lesson_progress, public.assignments, public.question_keys, public.questions,
                     public.attachments, public.lessons, public.course_target_rules, public.courses,
                     public.profiles, public.categories, public.ranks, public.job_types, public.departments cascade;
drop type if exists public.app_role, public.account_status, public.course_type, public.course_status,
                    public.assign_type, public.question_type, public.review_status cascade;

commit;
