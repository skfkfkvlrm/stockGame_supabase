# 🚀 StockGame Supabase (`stockGame_supabase`)

학급 모의투자 플랫폼(`stockGame`)의 차세대 **Supabase 기반 BaaS(Backend-as-a-Service) 백엔드** 프로젝트입니다.  
기존 9개 Spring Cloud 마이크로서비스를 단일 고성능 PostgreSQL 커널 기반의 **PL/pgSQL 체결 엔진, Row Level Security(RLS) 보안 격리, Supabase Realtime 초저지연 브로드캐스트, Deno Edge Functions** 아키텍처로 완전 전환하였습니다.

[![GitHub Repo](https://img.shields.io/badge/GitHub-stockGame__supabase-181717?logo=github)](https://github.com/skfkfkvlrm/stockGame_supabase)
[![Supabase](https://img.shields.io/badge/Supabase-Local_Docker-3ECF8E?logo=supabase)](http://127.0.0.1:54323)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15+-4169E1?logo=postgresql)](http://127.0.0.1:54322)
[![Test Suite](https://img.shields.io/badge/Tests-11%2F11_PASS_(100%25)-brightgreen)]()

---

## 📌 1. 아키텍처 및 포트 구성 (기존 레거시 서버와의 무충돌 공존)

기존 Spring Cloud MSA 서버([`stockGame_mechanism`](https://github.com/skfkfkvlrm/stockGame_mechanism))는 기록 및 히스토리 보존용으로 계속 유지되며, 본 신규 BaaS 시스템은 독립된 포트 대역에서 완전히 격리되어 충돌 없이 병행 구동됩니다.

| 서비스 구분 | 기존 MSA 레거시 (`stockGame_mechanism`) | 신규 Supabase 시스템 (`stockGame_supabase`) | 충돌 여부 |
|:---|:---|:---|:---:|
| **데이터베이스** | MariaDB Container: `3307` | PostgreSQL 15+: `54322` | ✅ 완전 격리 |
| **API Gateway** | Spring Cloud Gateway: `8000` | Supabase Kong Gateway: `54321` | ✅ 완전 격리 |
| **관리 콘솔** | 분리 UI: `5174` | Supabase Studio 대시보드: `54323` | ✅ 완전 격리 |
| **인증 / 세션** | Member Service (JWT): `8081` | Supabase GoTrue Auth: `54321/auth` | ✅ 완전 격리 |
| **실시간 스트리밍** | Stock STOMP WebSocket: `8082` | Supabase Realtime Engine: `54321/realtime` | ✅ 완전 격리 |
| **AI 뉴스 / 스케줄러** | AI News Service: `8086` | Deno Edge Function (`generate-news`) + Ollama | ✅ 완전 격리 |

---

## 🚀 2. 핵심 기술적 혁신 및 특징

### ① DB 커널 레벨 원자적 호가 매칭 엔진 (`place_and_match_order`)
- **결정론적 행 잠금 (Deterministic Row Lock)**: 주문 진입 즉시 해당 종목 행을 `SELECT ... FOR UPDATE`하여 매수-매도자 간 상호 락 획득 순서 꼬임으로 인한 **데드락(`40P01`)을 물리적으로 원천 제거**.
- **가격-시간-ID 타이브레이커**: `ORDER BY price ASC/DESC, id ASC FOR UPDATE`로 인덱스 스캔을 엄격히 직렬화하여 체결 우선순위 보장.
- **지정가 우위 환불**: 매수 희망가보다 저렴한 매도 호가가 존재할 경우, 차액 포인트를 학생 계좌로 즉시 환급.
- **LP 공모 유동성 자동 체결**: 장초기 학생 간 매도 물량이 없을 때 `stocks.publication_balance`와 공모가 기준으로 즉시 원자적 체결.

### ② 원자적 주문 취소 가드 (`cancel_stock_order`)
- 미체결 주문 취소 시 `orders FOR UPDATE` 락 선점 후 `status IN ('PENDING', 'PARTIAL')` 검증 및 프로필 잔액 환불을 단일 트랜잭션으로 격리.
- 동시 다발적 취소 레이스 컨디션에서 **이중 환불 0건** 보장.

### ③ Row Level Security (RLS) 보안 정책
- PostgREST API를 통한 무단 데이터 위변조 완벽 차단:
  - 타 학생 주문 취소 및 수정 시도 원천 차단.
  - `profiles.total_point` 직접 수정(포인트 위조) 차단.
  - `user_holdings` 및 `orders` 직접 INSERT(주식 위조 주입) 차단.
  - 10단계 호가창용 미체결(`PENDING`, `PARTIAL`) 주문 공개 SELECT 허용.

### ④ Supabase GoTrue 연동 자동 트리거 (`handle_new_user`)
- 신규 학생 회원가입 시 `public.profiles` 레코드 자동 생성 및 `point_transactions`에 기초 지원금 **100,000 P** 자동 지급.

---

## 📁 3. 프로젝트 폴더 구조

```text
d:\samuel\java\stockGame_supabase/
├── .env.example                               # 로컬 환경 변수 템플릿
├── .gitignore                                 # 민감 키(.env) 및 임시 파일 제외
├── package.json                               # npm 스크립트 및 Supabase CLI 의존성
├── README.md                                  # 본 문서
├── supabase/
│   ├── config.toml                            # Supabase 프로젝트/포트/스튜디오 설정
│   ├── seed.sql                               # 로컬 개발용 시드 스크립트
│   ├── functions/                             # Deno 기반 Edge Functions
│   │   └── generate-news/                     # 로컬 Ollama(qwen2.5-coder:7b) 연동 시황 뉴스
│   │       └── index.ts
│   └── migrations/                            # PostgreSQL 마이그레이션 DDL
│       ├── 20260906000000_init_stockgame_schema.sql       # 10개 핵심 테이블 스키마
│       ├── 20260906000001_enable_rls_policies.sql        # RLS 보안 정책 및 권한 매트릭스
│       ├── 20260906000002_matching_engine_function.sql   # PL/pgSQL 체결 & 취소 환불 함수
│       ├── 20260906000003_realtime_setup.sql             # Realtime WAL publication 등록
│       ├── 20260906000004_seed_initial_data.sql          # 21개 상장 종목 & 쿠폰 데이터 복제
│       ├── 20260906000005_auth_trigger_and_lp_matching.sql # 가입 트리거 & LP 공모가 매칭
│       └── 20260906000006_concurrency_and_rls_hardening.sql # 선제적 락 & 호가창 RLS 보강
└── tests/
    └── concurrency_stress_test.mjs            # 11종 자동화 동시성 & RLS 보안 침투 테스트
```

---

## 🧪 4. 자동화 동시성 & 보안 침투 테스트 (`11/11 통과`)

본 프로젝트는 고동시성 학생 트레이딩 상황에서의 무결성을 보장하기 위해 자동화 테스트 스위트를 포함하고 있습니다:

```bash
# 동시성 및 RLS 보안 침투 테스트 실행
node tests/concurrency_stress_test.mjs
```

### 테스트 통과 내역 (100.0% PASS):
1. `[PASS]` 타 학생 주문 취소 공격 차단 (RPC 에러 및 PostgREST PATCH 0건 반영)
2. `[PASS]` 직접 `profiles.total_point` 위조 공격 차단 (RLS 방어)
3. `[PASS]` 직접 `user_holdings` 주식 주입 공격 차단 (RLS 방어)
4. `[PASS]` 직접 `orders` 가짜 체결 주문 등록 차단 (RLS 방어)
5. `[PASS]` 단일 주문 동시 이중 취소 레이스 컨디션: 단 1회 환불 원자성 검증
6. `[PASS]` 5명 가상 학생 50건 동시 대규모 교차 매매: 데드락(`40P01`) 0건
7. `[PASS]` 고동시성 체결 정상 처리 (34건 즉시 체결, 잔여분 정상 적치)
8. `[PASS]` 자산 보존 법칙 검증: 마이너스 포인트 계정 0건 (`total_point >= 0`)
9. `[PASS]` 주식 보존 법칙 검증: 마이너스 보유 수량 0건 (`amount >= 0`)

---

## 🛠️ 5. 로컬 구동 가이드 (CLI)

### ① 로컬 Supabase 컨테이너 구동
```bash
# Docker Desktop 실행 상태에서
npx supabase start
```
*구동 완료 시 API Gateway(`54321`), PostgreSQL(`54322`), Studio 대시보드(`54323`) 활성화.*

### ② 로컬 대시보드(Studio) 접속
- 브라우저: `http://127.0.0.1:54323`
- Table Editor를 통해 `stocks`, `orders`, `profiles`, `user_holdings` 실시간 모니터링 가능.

### ③ DB 초기화 및 마이그레이션 재적용
```bash
npx supabase db reset
```

---

## 🔗 6. 관련 레포지토리
- 👨‍🎓 학생 포털 프론트엔드: [stockGame_react](https://github.com/skfkfkvlrm/stockGame_react)
- 👩‍🏫 관리자 포털 프론트엔드: [stockGame_admin_react](https://github.com/skfkfkvlrm/stockGame_admin_react)
- 🏛️ 레거시 보존 백엔드 (v1): [stockGame_mechanism](https://github.com/skfkfkvlrm/stockGame_mechanism)
- 📚 마스터 기획서 및 감사 보고서: [skfkfkvlrm-json-lib](https://github.com/skfkfkvlrm/skfkfkvlrm-json-lib)
