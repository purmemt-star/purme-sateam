# 푸르메 직원교육 LMS

푸르메재단 넥슨어린이재활병원 직원교육 LMS 저장소입니다. 지금은 기획 문서와 **Vimeo 진도 PoC** 페이지가 들어 있습니다.

- 기술 스택(결정): Vercel + Supabase + Vimeo Starter
- 기획 문서: [`docs/`](docs/) — PRD, 디자인 브리프, 와이어프레임 설계 노트, 배포 준비 로드맵

## Vimeo 진도 PoC

영상 1개로 LMS의 핵심 규칙이 Vimeo에서 실제로 되는지 확인하는 정적 페이지입니다.

| 확인 항목 | 방식 |
|---|---|
| 진도 계산 | 연속 재생으로 지나간 **고유 구간**만 합산 (다시 본 구간·건너뛴 구간 제외) |
| 건너뛰기 차단 | 첫 학습 중 최대 도달 지점보다 앞으로 이동하면 되돌림 |
| 속도 고정 | 플레이어 속도 메뉴 숨김 + 1.0x가 아니면 되돌림 |
| 이어보기 | 5초마다·일시정지·탭 숨김 시 위치 저장, 다시 열면 그 위치로 |
| 80% 판정 | 80% 도달 시 "평가 응시 가능" |
| 이수 후 자유 재생 | "평가 통과로 이수 처리(가정)" 후 건너뛰기·속도 제한 해제 |
| 네트워크 끊김 | 오프라인 동안 저장을 대기열에 두고 재연결 시 반영 |

기록은 브라우저 저장소(localStorage)에만 남습니다. 실제 LMS에서는 같은 데이터를 Supabase에 저장하고 판정은 서버에서 합니다.

### 배포 (Vercel)

빌드 과정이 없는 정적 사이트입니다.

1. Vercel에서 이 저장소를 Import (이미 연동되어 있으면 push만 하면 자동 배포)
2. Framework Preset: **Other**, Build Command: 비움, Output Directory: 비움(루트)
3. 배포 주소(예: `purme-edu.vercel.app`)를 Vimeo 영상의 **허용 도메인**에 추가 — 도메인 제한을 켠 경우에만 필요

`docs/`는 `.vercelignore`로 배포에서 제외됩니다. 검색엔진 노출은 `noindex`로 막았습니다.

### 사용법

1. 배포 주소를 열고 Vimeo 영상 링크(또는 숫자 ID)를 넣고 **불러오기**
   - 비공개 영상은 해시가 붙은 링크(`vimeo.com/영상ID/해시`)를 넣어야 합니다.
   - 주소 뒤에 `?v=영상ID`를 붙이면 바로 열립니다.
2. 페이지 아래 **점검표**를 기기·브라우저별로 체크합니다 (PC Chrome·Edge, 태블릿 Samsung Internet).
3. **결과 복사**로 점검 결과와 이벤트 기록을 복사해 공유합니다.

### 저장소에 올리지 않는 것

- 영상 ID·비공개 해시, 직원 명단, 강사 실명이 들어간 자료
- Supabase 키 등 비밀값 (`.env`는 `.gitignore`로 제외)

## Supabase 스키마

`supabase/migrations/20261008000001_init_lms.sql` — PRD §10 데이터 모델, RLS, 서버 판정 함수, 기준정보 초기값.

- 실행: Supabase 대시보드 → SQL Editor → 파일 전체 붙여넣기 → Run (새 프로젝트에서 한 번)
- 진도 저장(`save_progress`), 평가 채점·자동 이수(`submit_quiz`), 가입 2단계 승인, 콘텐츠 승인, 필수교육 자동 배정은 모두 DB 함수에서 처리
- 권한: 직원=본인, 부서 교육담당자=소속 부서, 중앙 관리자=전체 (RLS). 평가 정답은 학습자에게 보이지 않음
- 로그인: 앱이 사번을 `사번@staff.internal` 가상 이메일로 바꿔 Supabase Auth 사용

## 구조

```text
index.html, poc.css, poc.js   Vimeo 진도 PoC (정적)
assets/purme-logo.png         병원 로고 (저해상도 임시본)
vercel.json                   정적 배포 설정 (noindex 등 헤더)
supabase/migrations/           DB 스키마·RLS·함수 (SQL)
docs/                         기획 문서 (배포 제외)
```
