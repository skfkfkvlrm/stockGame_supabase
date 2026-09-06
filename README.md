# 🚀 StockGame Supabase (`stockGame_supabase`)

학급 모의투자 플랫폼(`stockGame`)의 차세대 **Supabase 기반 BaaS(Backend-as-a-Service)** 프로젝트입니다.

---

## 📌 1. 아키텍처 및 포트 구성 (기존 서버와의 공존 원칙)

기존 Spring Cloud MSA 서버(`stockGame_mechanism`)는 기록 및 백업용으로 계속 유지되며, 본 프로젝트는 독립된 포트 대역에서 완전히 격리되어 안전하게 동작합니다.

| 서비스 구분 | 기존 MSA 시스템 (`stockGame_mechanism`) | 신규 Supabase 시스템 (`stockGame_supabase`) | 포트 충돌 여부 |
|:---|:---|:---|:---:|
| **데이터베이스** | MariaDB Container: `3307` | PostgreSQL 15+: `54322` | ✅ 무충돌 |
| **API Gateway / Kong** | Spring Cloud Gateway: `8000` | Supabase Kong API: `54321` | ✅ 무충돌 |
| **관리 콘솔** | 별도 웹 UI: `5174` | Supabase Studio 대시보드: `54323` | ✅ 무충돌 |
| **인증 / 세션** | Member Service: `8081` | Supabase GoTrue Auth: `54321/auth` | ✅ 무충돌 |
| **실시간 스트리밍** | Stock STOMP WebSocket: `8082` | Supabase Realtime Engine: `54321/realtime` | ✅ 무충돌 |
| **스케줄러 & AI 뉴스** | AI News Service: `8086` | Supabase Edge Function (`generate-news`) | ✅ 무충돌 |

---

## 📁 2. 프로젝트 폴더 구조

```text
d:\samuel\java\stockGame_supabase/
├── .env.example                               # 로컬 환경 변수 예시
├── package.json                               # npm 스크립트 및 Supabase CLI 의존성
├── README.md                                  # 프로젝트 설명서
└── supabase/
    ├── config.toml                            # Supabase CLI 프로젝트 설정 (포트, 스튜디오)
    ├── seed.sql                               # 로컬 개발용 시드 스크립트
    ├── functions/                             # Deno 기반 Edge Functions
    │   └── generate-news/                     # 로컬 Ollama(qwen2.5-coder:7b) 연동 시황 뉴스 생성
    │       └── index.ts
    └── migrations/                            # PostgreSQL 마이그레이션 DDL
        ├── 20260906000000_init_stockgame_schema.sql       # 10개 핵심 테이블 스키마
        ├── 20260906000001_enable_rls_policies.sql        # RLS 보안 정책 및 권한 매트릭스
        ├── 20260906000002_matching_engine_function.sql   # PL/pgSQL 원자적 호가 체결 & 취소 환불 프로시저
        ├── 20260906000003_realtime_setup.sql             # Realtime publication 등록
        └── 20260906000004_seed_initial_data.sql          # 기존 MariaDB 상장 종목 21개 & 쿠폰 데이터 복제
```

---

## 🛠️ 3. 로컬 Supabase 구동 가이드 (CLI)

### ① 의존성 확인 및 초기 구동
Docker 데스크탑이 실행된 상태에서 아래 명령어를 실행합니다:
```bash
# 로컬 Supabase 컨테이너 시작
npx supabase start
```
*구동이 완료되면 터미널에 API URL, GraphQL URL, DB 접속 URL, Studio URL, Anon Key, Service Role Key가 출력됩니다.*

### ② 로컬 대시보드(Studio) 접속
- 브라우저에서 `http://127.0.0.1:54323` 접속
- Table Editor에서 `stocks`, `orders`, `profiles`, `user_holdings` 테이블 확인 가능
- SQL Editor에서 직접 호가 주문 RPC 테스트 가능

### ③ 마이그레이션 초기화 (DB Reset)
```bash
# 모든 마이그레이션 및 시드 데이터를 재적용
npx supabase db reset
```

### ④ 컨테이너 중지
```bash
npx supabase stop
```

---

## 💡 4. 핵심 프로시저 호출 테스트 (SQL Editor)

### 매수 주문 접수 및 자동 체결 (`place_and_match_order`)
```sql
-- 1번 종목(새콤달콤)을 860원에 10주 매수
SELECT public.place_and_match_order(
    1,          -- stock_id
    'BUY',      -- order_type
    860,        -- price
    10          -- amount
);
```

### 미체결 주문 취소 및 자산 환불 (`cancel_stock_order`)
```sql
-- 주문번호 123번 취소 (예수금 포인트 또는 락 걸린 주식 즉시 환불)
SELECT public.cancel_stock_order(123);
```

---

## 🔗 5. 관련 문서
- 📄 [Supabase 전환 상세 기획서 (PRD)](../skfkfkvlrm-json-lib/docs/110_artifacts/2026-09-06_stockgame_supabase_prd.md)
- 📋 [Supabase 전환 아키텍처 가이드](../skfkfkvlrm-json-lib/docs/110_artifacts/2026-09-06_stockgame_supabase_migration_architecture.md)
