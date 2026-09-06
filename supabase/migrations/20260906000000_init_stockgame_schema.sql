-- ========================================================
-- Migration: 20260906000000_init_stockgame_schema.sql
-- Description: StockGame Core Database Schema Initialization
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. 사용자 프로필 테이블 (profiles: auth.users와 1:1 외래키 매핑)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    student_id VARCHAR(100) NOT NULL UNIQUE,                                -- 로그인 아이디 / 학번
    name VARCHAR(50) NOT NULL,                                              -- 학생 성명
    grade INT NOT NULL CHECK (grade BETWEEN 1 AND 6),                       -- 학년 (1~6학년)
    class_name VARCHAR(50) NOT NULL,                                        -- 학급 (예: '1반', '2반')
    class_number INT NOT NULL CHECK (class_number > 0),                     -- 출석 번호
    register_year INT NOT NULL DEFAULT EXTRACT(YEAR FROM CURRENT_DATE),    -- 학급 등록 년도
    role VARCHAR(20) NOT NULL DEFAULT 'ROLE_STUDENT' CHECK (role IN ('ROLE_STUDENT', 'ROLE_TEACHER', 'ROLE_ADMIN')),
    total_point BIGINT NOT NULL DEFAULT 100000 CHECK (total_point >= 0),   -- 가용 현금 포인트 (예수금, 기본 10만)
    total_coupon INT NOT NULL DEFAULT 0 CHECK (total_coupon >= 0),          -- 보유 미사용 쿠폰 수
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'SUSPENDED', 'DELETED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_profiles_student_id ON public.profiles (student_id);
CREATE INDEX IF NOT EXISTS idx_profiles_ranking ON public.profiles (total_point DESC, student_id ASC);
CREATE INDEX IF NOT EXISTS idx_profiles_class ON public.profiles (grade, class_name, class_number);

-- 2. 주식 종목 마스터 테이블 (stocks)
CREATE TABLE IF NOT EXISTS public.stocks (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,                                      -- 종목명
    content VARCHAR(255) NULL,                                              -- 종목 상세 설명
    publication_balance INT NOT NULL DEFAULT 0,                             -- 발행 주식 총 잔여 물량
    publication_price INT NOT NULL CHECK (publication_price > 0),          -- 최초 공모/상장 발행가
    current_price INT NOT NULL CHECK (current_price > 0),                  -- 현재가
    prev_price INT NOT NULL CHECK (prev_price > 0),                        -- 전일 종가
    high_limit_price INT NOT NULL,                                          -- 상한가 (+30%)
    low_limit_price INT NOT NULL,                                           -- 하한가 (-30%)
    market_status VARCHAR(20) NOT NULL DEFAULT 'OPEN' CHECK (market_status IN ('OPEN', 'CLOSED', 'CONTINUOUS')),
    status VARCHAR(20) NOT NULL DEFAULT 'LISTED' CHECK (status IN ('LISTED', 'DELISTED', 'SUSPENDED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stocks_status ON public.stocks (status, market_status);
CREATE INDEX IF NOT EXISTS idx_stocks_name ON public.stocks (name);

-- 3. 학생 종목별 보유 잔고 테이블 (user_holdings)
CREATE TABLE IF NOT EXISTS public.user_holdings (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    stock_id BIGINT NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
    amount INT NOT NULL DEFAULT 0 CHECK (amount >= 0),                     -- 보유 가용 수량
    locked_amount INT NOT NULL DEFAULT 0 CHECK (locked_amount >= 0),       -- 매도 호가창에 잠긴 수량 (Escrow)
    average_price INT NOT NULL DEFAULT 0 CHECK (average_price >= 0),       -- 평균 매입 단가
    total_invested_amount BIGINT NOT NULL DEFAULT 0,                       -- 총 매입 원금
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uk_user_stock UNIQUE (user_id, stock_id)
);

CREATE INDEX IF NOT EXISTS idx_user_holdings_user ON public.user_holdings (user_id);
CREATE INDEX IF NOT EXISTS idx_user_holdings_stock ON public.user_holdings (stock_id);

-- 4. 주식 주문 요청 테이블 (orders)
CREATE TABLE IF NOT EXISTS public.orders (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    stock_id BIGINT NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
    order_type VARCHAR(10) NOT NULL CHECK (order_type IN ('BUY', 'SELL')),
    price INT NOT NULL CHECK (price > 0),
    amount INT NOT NULL CHECK (amount > 0),
    remain_amount INT NOT NULL CHECK (remain_amount >= 0),
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'PARTIAL', 'FILLED', 'CANCELLED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    cancelled_at TIMESTAMPTZ NULL
);

-- 호가 매칭 엔진 최적화 복합 인덱스 (Price-Time Priority)
CREATE INDEX IF NOT EXISTS idx_orders_matching ON public.orders (stock_id, status, order_type, price, created_at);
CREATE INDEX IF NOT EXISTS idx_orders_user_active ON public.orders (user_id, status);

-- 5. 주식 체결 거래 내역 테이블 (order_trades)
CREATE TABLE IF NOT EXISTS public.order_trades (
    id BIGSERIAL PRIMARY KEY,
    stock_id BIGINT NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
    buy_order_id BIGINT NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    sell_order_id BIGINT NULL REFERENCES public.orders(id) ON DELETE SET NULL, -- 시스템 발행주 매수 시 NULL
    buyer_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    seller_id UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    price INT NOT NULL CHECK (price > 0),
    amount INT NOT NULL CHECK (amount > 0),
    total_trade_amount BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trades_stock_recent ON public.order_trades (stock_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trades_buyer ON public.order_trades (buyer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trades_seller ON public.order_trades (seller_id, created_at DESC);

-- 6. 포인트 변동 내역 테이블 (point_transactions)
CREATE TABLE IF NOT EXISTS public.point_transactions (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL,                                                -- 변동 금액 (+입금/정산/환불, -출금/매수)
    balance_after BIGINT NOT NULL,                                         -- 변동 후 잔액
    reason_type VARCHAR(50) NOT NULL,                                      -- 사유 코드
    description VARCHAR(255) NULL,                                         -- 설명
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_point_tx_user ON public.point_transactions (user_id, created_at DESC);

-- 7. 상점 쿠폰 마스터 테이블 (coupons)
CREATE TABLE IF NOT EXISTS public.coupons (
    id BIGSERIAL PRIMARY KEY,
    coupon_code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    price INT NOT NULL CHECK (price >= 0),
    status VARCHAR(20) NOT NULL DEFAULT 'ON_SALE' CHECK (status IN ('ON_SALE', 'SOLD_OUT', 'STOPPED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 8. 학생 보유 쿠폰 테이블 (user_coupons)
CREATE TABLE IF NOT EXISTS public.user_coupons (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    coupon_id BIGINT NOT NULL REFERENCES public.coupons(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    purchase_price INT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'UNUSED' CHECK (status IN ('UNUSED', 'USED', 'CANCELLED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    used_at TIMESTAMPTZ NULL
);

CREATE INDEX IF NOT EXISTS idx_user_coupons_user ON public.user_coupons (user_id, status);

-- 9. AI 시황 뉴스 테이블 (news)
CREATE TABLE IF NOT EXISTS public.news (
    id BIGSERIAL PRIMARY KEY,
    stock_id BIGINT NULL REFERENCES public.stocks(id) ON DELETE SET NULL,
    headline VARCHAR(200) NOT NULL,
    content TEXT NOT NULL,
    sentiment VARCHAR(20) NOT NULL DEFAULT 'NEUTRAL' CHECK (sentiment IN ('POSITIVE', 'NEGATIVE', 'NEUTRAL')),
    impact_rate NUMERIC(5, 2) NOT NULL DEFAULT 0.0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_news_recent ON public.news (created_at DESC);

-- 10. 시세 일별/시계열 히스토리 (stock_price_history: OHLCV)
CREATE TABLE IF NOT EXISTS public.stock_price_history (
    id BIGSERIAL PRIMARY KEY,
    stock_id BIGINT NOT NULL REFERENCES public.stocks(id) ON DELETE CASCADE,
    base_date DATE NOT NULL,
    open_price INT NOT NULL,
    high_price INT NOT NULL,
    low_price INT NOT NULL,
    close_price INT NOT NULL,
    volume BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uk_stock_price_history UNIQUE (stock_id, base_date)
);

CREATE INDEX IF NOT EXISTS idx_price_history ON public.stock_price_history (stock_id, base_date DESC);
