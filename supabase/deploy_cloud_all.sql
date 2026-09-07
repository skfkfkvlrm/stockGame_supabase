-- ========================================================
-- File: 20260906000000_init_stockgame_schema.sql
-- ========================================================

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


-- ========================================================
-- File: 20260906000001_enable_rls_policies.sql
-- ========================================================

-- ========================================================
-- Migration: 20260906000001_enable_rls_policies.sql
-- Description: Row Level Security (RLS) Policies & Access Control
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- RLS 활성화
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_holdings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_trades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.point_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.news ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_price_history ENABLE ROW LEVEL SECURITY;

-- 관리자 여부 판별 헬퍼 함수
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('ROLE_ADMIN', 'ROLE_TEACHER')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 1. profiles RLS
CREATE POLICY "본인 프로필 조회 허용" ON public.profiles
  FOR SELECT USING (auth.uid() = id OR public.is_admin());

CREATE POLICY "랭킹용 프로필 요약 조회 허용" ON public.profiles
  FOR SELECT USING (true);

CREATE POLICY "관리자 전용 프로필 수정 허용" ON public.profiles
  FOR UPDATE USING (public.is_admin());

-- 2. stocks RLS
CREATE POLICY "종목 정보 누구나 조회 허용" ON public.stocks
  FOR SELECT USING (true);

CREATE POLICY "관리자만 종목 CUD 허용" ON public.stocks
  FOR ALL USING (public.is_admin());

-- 3. user_holdings RLS
CREATE POLICY "본인 보유 주식만 조회 허용" ON public.user_holdings
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

-- 4. orders RLS
CREATE POLICY "본인 주문만 조회 허용" ON public.orders
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

-- 5. order_trades RLS
CREATE POLICY "체결 내역 전체 조회 허용" ON public.order_trades
  FOR SELECT USING (true);

-- 6. point_transactions RLS
CREATE POLICY "본인 포인트 이력만 조회 허용" ON public.point_transactions
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

-- 7. coupons RLS
CREATE POLICY "판매 쿠폰 누구나 조회 허용" ON public.coupons
  FOR SELECT USING (true);

CREATE POLICY "관리자만 쿠폰 CUD 허용" ON public.coupons
  FOR ALL USING (public.is_admin());

-- 8. user_coupons RLS
CREATE POLICY "본인 보유 쿠폰만 조회 허용" ON public.user_coupons
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "본인 쿠폰 사용 처리 허용" ON public.user_coupons
  FOR UPDATE USING (auth.uid() = user_id AND status = 'UNUSED')
  WITH CHECK (status = 'USED');

-- 9. news RLS
CREATE POLICY "뉴스 전체 조회 허용" ON public.news
  FOR SELECT USING (true);

CREATE POLICY "관리자만 뉴스 관리 허용" ON public.news
  FOR ALL USING (public.is_admin());

-- 10. stock_price_history RLS
CREATE POLICY "시세 차트 히스토리 누구나 조회 허용" ON public.stock_price_history
  FOR SELECT USING (true);


-- ========================================================
-- File: 20260906000002_matching_engine_function.sql
-- ========================================================

-- ========================================================
-- Migration: 20260906000002_matching_engine_function.sql
-- Description: Core PL/pgSQL Atomic Limit Order Matching Engine & Cancellation
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. 호가 등록 및 원자적 체결 프로시저
CREATE OR REPLACE FUNCTION public.place_and_match_order(
    p_stock_id BIGINT,
    p_order_type VARCHAR(10),
    p_price INT,
    p_amount INT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_market_status VARCHAR(20);
    v_stock_status VARCHAR(20);
    v_current_stock_price INT;
    v_user_point BIGINT;
    v_user_stock_amount INT;
    v_required_total BIGINT;
    v_new_order_id BIGINT;
    v_remain_qty INT := p_amount;
    v_match_record RECORD;
    v_trade_qty INT;
    v_trade_price INT;
    v_trade_total BIGINT;
    v_price_diff_refund BIGINT;
BEGIN
    -- 1. 사용자 인증 확인
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 2. 종목 및 시장 상태 검증
    SELECT market_status, status, current_price
    INTO v_market_status, v_stock_status, v_current_stock_price
    FROM public.stocks
    WHERE id = p_stock_id;

    IF v_market_status NOT IN ('OPEN', 'CONTINUOUS') OR v_stock_status != 'LISTED' THEN
        RAISE EXCEPTION '현재 거래가 중단되었거나 장이 마감된 종목입니다.';
    END IF;

    -- 3. 잔고 검증 및 사전 자산 잠금 (Escrow Lock)
    IF p_order_type = 'BUY' THEN
        v_required_total := p_price::BIGINT * p_amount::BIGINT;
        SELECT total_point INTO v_user_point
        FROM public.profiles
        WHERE id = v_user_id
        FOR UPDATE;

        IF v_user_point < v_required_total THEN
            RAISE EXCEPTION '가용 포인트(예수금)가 부족합니다. 필요 포인트: % P, 보유 포인트: % P', v_required_total, v_user_point;
        END IF;

        -- 예수금 즉시 차감
        UPDATE public.profiles
        SET total_point = total_point - v_required_total,
            updated_at = NOW()
        WHERE id = v_user_id;

        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_user_id, -v_required_total, v_user_point - v_required_total, 'STOCK_BUY_ESCROW', '매수 주문 증거금 잠금');

    ELSIF p_order_type = 'SELL' THEN
        SELECT amount INTO v_user_stock_amount
        FROM public.user_holdings
        WHERE user_id = v_user_id AND stock_id = p_stock_id
        FOR UPDATE;

        IF v_user_stock_amount IS NULL OR v_user_stock_amount < p_amount THEN
            RAISE EXCEPTION '보유 주식 수량이 부족합니다. 필요: % 주, 보유량: % 주', p_amount, COALESCE(v_user_stock_amount, 0);
        END IF;

        -- 매도 주식 잠금 (가용 잔고 차감, 락 수량 증가)
        UPDATE public.user_holdings
        SET amount = amount - p_amount,
            locked_amount = locked_amount + p_amount,
            updated_at = NOW()
        WHERE user_id = v_user_id AND stock_id = p_stock_id;
    ELSE
        RAISE EXCEPTION '올바르지 않은 주문 유형입니다. (BUY 또는 SELL)';
    END IF;

    -- 4. 신규 주문 레코드 생성 (PENDING)
    INSERT INTO public.orders (user_id, stock_id, order_type, price, amount, remain_amount, status)
    VALUES (v_user_id, p_stock_id, p_order_type, p_price, p_amount, p_amount, 'PENDING')
    RETURNING id INTO v_new_order_id;

    -- 5. 반대 호가 매칭 루프 (Price-Time Priority)
    IF p_order_type = 'BUY' THEN
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'SELL'
              AND status IN ('PENDING', 'PARTIAL')
              AND price <= p_price
              AND user_id != v_user_id
            ORDER BY price ASC, created_at ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price; -- 기존 대기 호가 가격으로 체결
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            -- 5-1. 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, v_match_record.id, v_user_id, v_match_record.user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 5-2. 매도자 정산: 잠긴 주식 영구 차감 및 포인트 입금
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_match_record.user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_match_record.user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_match_record.user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_match_record.user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 5-3. 매수자 주식 잔고 지급 (UPSERT user_holdings)
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 5-4. 지정가 우위 환불 (매수가 < 주문가 시 차액 포인트 즉시 환급)
            IF p_price > v_trade_price THEN
                v_price_diff_refund := (p_price - v_trade_price)::BIGINT * v_trade_qty::BIGINT;
                UPDATE public.profiles
                SET total_point = total_point + v_price_diff_refund,
                    updated_at = NOW()
                WHERE id = v_user_id;

                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '호가 우위 체결 차액 환불');
            END IF;

            -- 5-5. 상대 매도 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 5-6. 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;

    ELSIF p_order_type = 'SELL' THEN
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'BUY'
              AND status IN ('PENDING', 'PARTIAL')
              AND price >= p_price
              AND user_id != v_user_id
            ORDER BY price DESC, created_at ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price; -- 기존 대기 매수 호가 가격으로 체결
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            -- 5-1. 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_match_record.id, v_new_order_id, v_match_record.user_id, v_user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 5-2. 매도자 정산: 잠긴 주식 차감 및 포인트 입금
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 5-3. 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_match_record.user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 5-4. 상대 매수 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 5-5. 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;
    END IF;

    -- 6. 신규 주문 최종 상태 갱신
    UPDATE public.orders
    SET remain_amount = v_remain_qty,
        status = CASE 
                    WHEN v_remain_qty = 0 THEN 'FILLED'
                    WHEN v_remain_qty < p_amount THEN 'PARTIAL'
                    ELSE 'PENDING'
                 END,
        updated_at = NOW()
    WHERE id = v_new_order_id;

    RETURN jsonb_build_object(
        'order_id', v_new_order_id,
        'status', 'SUCCESS',
        'ordered_amount', p_amount,
        'matched_amount', p_amount - v_remain_qty,
        'remain_amount', v_remain_qty
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. 미체결 호가 취소 및 원자적 자산 환불 프로시저
CREATE OR REPLACE FUNCTION public.cancel_stock_order(
    p_order_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_order_record RECORD;
    v_refund_amount BIGINT;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 주문 조회 및 락
    SELECT * INTO v_order_record
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_order_record IS NULL THEN
        RAISE EXCEPTION '해당 주문을 찾을 수 없습니다.';
    END IF;

    IF v_order_record.user_id != v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION '본인의 주문만 취소할 수 있습니다.';
    END IF;

    IF v_order_record.status NOT IN ('PENDING', 'PARTIAL') OR v_order_record.remain_amount <= 0 THEN
        RAISE EXCEPTION '이미 체결되었거나 취소할 수 없는 주문입니다.';
    END IF;

    -- 주문 상태 CANCELLED로 변경
    UPDATE public.orders
    SET status = 'CANCELLED',
        cancelled_at = NOW(),
        updated_at = NOW()
    WHERE id = p_order_id;

    -- 미체결 잔량 자산 복원 (Refund)
    IF v_order_record.order_type = 'BUY' THEN
        v_refund_amount := v_order_record.price::BIGINT * v_order_record.remain_amount::BIGINT;
        
        UPDATE public.profiles
        SET total_point = total_point + v_refund_amount,
            updated_at = NOW()
        WHERE id = v_order_record.user_id;

        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_order_record.user_id, v_refund_amount, 
                (SELECT total_point FROM public.profiles WHERE id = v_order_record.user_id), 
                'STOCK_BUY_CANCEL_REFUND', '미체결 매수 주문 취소 환불');

    ELSIF v_order_record.order_type = 'SELL' THEN
        -- 잠긴 주식을 가용 주식으로 원복
        UPDATE public.user_holdings
        SET amount = amount + v_order_record.remain_amount,
            locked_amount = locked_amount - v_order_record.remain_amount,
            updated_at = NOW()
        WHERE user_id = v_order_record.user_id AND stock_id = v_order_record.stock_id;
    END IF;

    RETURN jsonb_build_object(
        'order_id', p_order_id,
        'status', 'CANCELLED',
        'refund_qty', v_order_record.remain_amount,
        'refund_points', COALESCE(v_refund_amount, 0)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ========================================================
-- File: 20260906000003_realtime_setup.sql
-- ========================================================

-- ========================================================
-- Migration: 20260906000003_realtime_setup.sql
-- Description: Supabase Realtime Publication Configuration
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 실시간 브로드캐스트가 필요한 테이블을 supabase_realtime 발행 목록에 등록
ALTER PUBLICATION supabase_realtime ADD TABLE public.stocks;
ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
ALTER PUBLICATION supabase_realtime ADD TABLE public.order_trades;
ALTER PUBLICATION supabase_realtime ADD TABLE public.news;
ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_holdings;
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_coupons;


-- ========================================================
-- File: 20260906000004_seed_initial_data.sql
-- ========================================================

-- ========================================================
-- Migration: 20260906000004_seed_initial_data.sql
-- Description: Seed Initial Stocks & Coupons Data from Production MariaDB
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. 기초 주식 종목 시드 데이터
INSERT INTO public.stocks (id, name, content, publication_balance, publication_price, current_price, prev_price, high_limit_price, low_limit_price, market_status, status)
VALUES
(1, '새콤달콤', '화가나고 피곤할 땐 새콤달콤', 74, 800, 861, 861, 1119, 603, 'CONTINUOUS', 'LISTED'),
(2, '포켓몬빵', '띠부띠부씰이 들어있는 포켓몬빵', 100, 1500, 1950, 1950, 2535, 1365, 'CONTINUOUS', 'LISTED'),
(3, '바나나우유', '달콤하고 부드러운 항아리 바나나우유', 100, 1400, 1450, 1450, 1885, 1015, 'CONTINUOUS', 'LISTED'),
(4, '쿠키런테크', '전 세계를 달리는 데브시스터즈 쿠키런 개발사', 50, 3000, 3800, 3800, 4940, 2660, 'CONTINUOUS', 'LISTED'),
(5, '크래프톤', '배틀그라운드 글로벌 IP 보유 게임 개발사', 30, 5000, 6100, 6100, 7930, 4270, 'CONTINUOUS', 'LISTED'),
(6, '넥슨게임즈', '메이플스토리, 던파 등 글로벌 메가히트 게임 명가', 50, 2500, 2500, 2500, 3250, 1750, 'CONTINUOUS', 'LISTED'),
(7, '넷마블', '모바일 RPG 및 캐주얼 게임 선도 기업', 100, 2000, 2000, 2000, 2600, 1400, 'CONTINUOUS', 'LISTED'),
(8, '닌텐도', '스위치 신작 게임 스토어 이용권', 20, 10000, 11600, 11600, 15080, 8120, 'CONTINUOUS', 'LISTED'),
(9, '로블록스', '로블록스 게임 로벅스 충전권', 80, 4000, 4000, 4000, 5200, 2800, 'CONTINUOUS', 'LISTED'),
(10, 'SM엔터', '에스파/NCT 등 글로벌 K-POP 테마', 100, 4000, 4000, 4000, 5200, 2800, 'CONTINUOUS', 'LISTED'),
(11, '하이브', '방탄소년단/뉴진스 아티스트 테마', 50, 8000, 9200, 9200, 11960, 6440, 'CONTINUOUS', 'LISTED'),
(12, '치지직/숲', '라이브 스트리밍 및 후원 아이템', 80, 3500, 3500, 3500, 4550, 2450, 'CONTINUOUS', 'LISTED'),
(13, '지우개똥청소기', '책상 위 지우개 가루 자동 청소기', 100, 1200, 1200, 1200, 1560, 840, 'CONTINUOUS', 'LISTED'),
(14, '샤프심연구소', '부러지지 않는 0.5mm 아인 샤프심', 100, 1000, 1000, 1000, 1300, 700, 'CONTINUOUS', 'LISTED'),
(16, '축구공테크', '점심시간 피구/축구 최고급 공', 60, 3500, 3500, 3500, 4550, 2450, 'CONTINUOUS', 'LISTED'),
(17, '배드민턴클럽', '요넥스 고급 배드민턴 라켓셋', 50, 4500, 4500, 4500, 5850, 3150, 'CONTINUOUS', 'LISTED'),
(18, '포켓몬카드', '희귀 홀로그램 갓팩 컬렉션', 40, 6000, 6000, 6000, 7800, 4200, 'CONTINUOUS', 'LISTED'),
(19, 'AI로봇선생님', '24시간 질문받는 챗봇 로봇', 20, 12000, 12000, 12000, 15600, 8400, 'CONTINUOUS', 'LISTED'),
(20, '드론배달소', '교실 창문으로 받아보는 드론 딜리버리', 30, 9000, 9000, 9000, 11700, 6300, 'CONTINUOUS', 'LISTED'),
(21, '스마트책상', '높낮이 조절 및 온열 쿨링 기능 책상', 20, 15000, 15000, 15000, 19500, 10500, 'CONTINUOUS', 'LISTED'),
(22, '쿰척쿰척', '식품 제조', 7000, 500, 500, 500, 650, 350, 'CONTINUOUS', 'LISTED')
ON CONFLICT (id) DO UPDATE
SET current_price = EXCLUDED.current_price,
    prev_price = EXCLUDED.prev_price,
    high_limit_price = EXCLUDED.high_limit_price,
    low_limit_price = EXCLUDED.low_limit_price;

SELECT setval('public.stocks_id_seq', (SELECT MAX(id) FROM public.stocks));

-- 2. 기초 보상 쿠폰 시드 데이터
INSERT INTO public.coupons (id, coupon_code, name, price, status)
VALUES
(1, 'CPN-2026-0001', '자리 변경 쿠폰이당', 50000, 'ON_SALE'),
(2, 'CPN-2026-0002', '청소당번 면제', 3000, 'ON_SALE'),
(3, 'CPN-2026-0003', '자리 뺏기', 100000, 'ON_SALE'),
(30, 'CPN-2026-0004', '쌤 삥뜯기', 500000, 'ON_SALE'),
(31, 'CPN-2026-0005', '자율 동아리 간식권', 25000, 'ON_SALE')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    price = EXCLUDED.price,
    status = EXCLUDED.status;

SELECT setval('public.coupons_id_seq', (SELECT MAX(id) FROM public.coupons));


-- ========================================================
-- File: 20260906000005_auth_trigger_and_lp_matching.sql
-- ========================================================

-- ========================================================
-- Migration: 20260906000005_auth_trigger_and_lp_matching.sql
-- Description: Automatic Profile Generation Trigger & LP Publication Stock Matching
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. 학번 중복 확인 헬퍼 함수
CREATE OR REPLACE FUNCTION public.check_student_id_exists(p_student_id VARCHAR)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.profiles WHERE student_id = p_student_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. auth.users 생성 시 profiles 및 초기 포인트 자동 생성 트리거 함수
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
    v_student_id VARCHAR(100);
    v_name VARCHAR(50);
    v_grade INT;
    v_class_name VARCHAR(50);
    v_class_number INT;
    v_role VARCHAR(20);
BEGIN
    v_student_id := COALESCE(
        NEW.raw_user_meta_data->>'student_id',
        NEW.raw_user_meta_data->>'studentId',
        split_part(NEW.email, '@', 1)
    );
    v_name := COALESCE(NEW.raw_user_meta_data->>'name', '학생');
    v_grade := COALESCE((NEW.raw_user_meta_data->>'grade')::INT, 1);
    v_class_name := COALESCE(
        NEW.raw_user_meta_data->>'class_name',
        NEW.raw_user_meta_data->>'className',
        '1반'
    );
    v_class_number := COALESCE(
        (NEW.raw_user_meta_data->>'class_number')::INT,
        (NEW.raw_user_meta_data->>'classNumber')::INT,
        1
    );
    v_role := COALESCE(NEW.raw_user_meta_data->>'role', 'ROLE_STUDENT');

    -- 프로필 등록 (기초 100,000 포인트)
    INSERT INTO public.profiles (
        id, student_id, name, grade, class_name, class_number, role, total_point, total_coupon, status
    )
    VALUES (
        NEW.id, v_student_id, v_name, v_grade, v_class_name, v_class_number, v_role, 100000, 0, 'ACTIVE'
    )
    ON CONFLICT (id) DO NOTHING;

    -- 초기 기초 투자금 지급 감사 로그
    INSERT INTO public.point_transactions (
        user_id, amount, balance_after, reason_type, description
    )
    VALUES (
        NEW.id, 100000, 100000, 'INITIAL_GRANT', '회원가입 축하 기초 투자금 지급'
    )
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 3. 핵심 호가 매칭 엔진 프로시저 (LP 시스템 발행주 매칭 지원)
CREATE OR REPLACE FUNCTION public.place_and_match_order(
    p_stock_id BIGINT,
    p_order_type VARCHAR(10),
    p_price INT,
    p_amount INT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_market_status VARCHAR(20);
    v_stock_status VARCHAR(20);
    v_current_stock_price INT;
    v_user_point BIGINT;
    v_user_stock_amount INT;
    v_required_total BIGINT;
    v_new_order_id BIGINT;
    v_remain_qty INT := p_amount;
    v_match_record RECORD;
    v_trade_qty INT;
    v_trade_price INT;
    v_trade_total BIGINT;
    v_price_diff_refund BIGINT;
    v_pub_balance INT;
    v_pub_price INT;
    v_lp_qty INT;
    v_lp_price INT;
    v_lp_total BIGINT;
BEGIN
    -- 1. 사용자 인증 확인
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 2. 종목 및 시장 상태 검증
    SELECT market_status, status, current_price
    INTO v_market_status, v_stock_status, v_current_stock_price
    FROM public.stocks
    WHERE id = p_stock_id;

    IF v_market_status NOT IN ('OPEN', 'CONTINUOUS') OR v_stock_status != 'LISTED' THEN
        RAISE EXCEPTION '현재 거래가 중단되었거나 장이 마감된 종목입니다.';
    END IF;

    -- 3. 잔고 검증 및 사전 자산 잠금 (Escrow Lock)
    IF p_order_type = 'BUY' THEN
        v_required_total := p_price::BIGINT * p_amount::BIGINT;
        SELECT total_point INTO v_user_point
        FROM public.profiles
        WHERE id = v_user_id
        FOR UPDATE;

        IF v_user_point < v_required_total THEN
            RAISE EXCEPTION '가용 포인트(예수금)가 부족합니다. 필요 포인트: % P, 보유 포인트: % P', v_required_total, v_user_point;
        END IF;

        -- 예수금 즉시 차감
        UPDATE public.profiles
        SET total_point = total_point - v_required_total,
            updated_at = NOW()
        WHERE id = v_user_id;

        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_user_id, -v_required_total, v_user_point - v_required_total, 'STOCK_BUY_ESCROW', '매수 주문 증거금 잠금');

    ELSIF p_order_type = 'SELL' THEN
        SELECT amount INTO v_user_stock_amount
        FROM public.user_holdings
        WHERE user_id = v_user_id AND stock_id = p_stock_id
        FOR UPDATE;

        IF v_user_stock_amount IS NULL OR v_user_stock_amount < p_amount THEN
            RAISE EXCEPTION '보유 주식 수량이 부족합니다. 필요: % 주, 보유량: % 주', p_amount, COALESCE(v_user_stock_amount, 0);
        END IF;

        -- 매도 주식 잠금 (가용 잔고 차감, 락 수량 증가)
        UPDATE public.user_holdings
        SET amount = amount - p_amount,
            locked_amount = locked_amount + p_amount,
            updated_at = NOW()
        WHERE user_id = v_user_id AND stock_id = p_stock_id;
    ELSE
        RAISE EXCEPTION '올바르지 않은 주문 유형입니다. (BUY 또는 SELL)';
    END IF;

    -- 4. 신규 주문 레코드 생성 (PENDING)
    INSERT INTO public.orders (user_id, stock_id, order_type, price, amount, remain_amount, status)
    VALUES (v_user_id, p_stock_id, p_order_type, p_price, p_amount, p_amount, 'PENDING')
    RETURNING id INTO v_new_order_id;

    -- 5. 반대 호가 매칭 루프 (Price-Time Priority)
    IF p_order_type = 'BUY' THEN
        -- 5-A. 사용자 간 매도 대기 호가 매칭
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'SELL'
              AND status IN ('PENDING', 'PARTIAL')
              AND price <= p_price
              AND user_id != v_user_id
            ORDER BY price ASC, created_at ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price;
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, v_match_record.id, v_user_id, v_match_record.user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 매도자 정산: 잠긴 주식 차감 및 포인트 입금
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_match_record.user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_match_record.user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_match_record.user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_match_record.user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 지정가 우위 차액 환불
            IF p_price > v_trade_price THEN
                v_price_diff_refund := (p_price - v_trade_price)::BIGINT * v_trade_qty::BIGINT;
                UPDATE public.profiles
                SET total_point = total_point + v_price_diff_refund,
                    updated_at = NOW()
                WHERE id = v_user_id;

                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '호가 우위 체결 차액 환불');
            END IF;

            -- 상대 매도 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;

        -- 5-B. 시스템 초기 발행 잔량(LP) 매수 매칭 (잔여 수량이 있고 주문가가 공모가 이상인 경우)
        IF v_remain_qty > 0 THEN
            SELECT publication_balance, publication_price
            INTO v_pub_balance, v_pub_price
            FROM public.stocks
            WHERE id = p_stock_id
            FOR UPDATE;

            IF v_pub_balance > 0 AND p_price >= v_pub_price THEN
                v_lp_qty := LEAST(v_remain_qty, v_pub_balance);
                v_lp_price := v_pub_price;
                v_lp_total := v_lp_price::BIGINT * v_lp_qty::BIGINT;

                -- 발행 잔량 차감 및 현재가 갱신
                UPDATE public.stocks
                SET publication_balance = publication_balance - v_lp_qty,
                    current_price = v_lp_price,
                    updated_at = NOW()
                WHERE id = p_stock_id;

                -- 체결 레코드 삽입 (sell_order_id = NULL, seller_id = NULL)
                INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
                VALUES (p_stock_id, v_new_order_id, NULL, v_user_id, NULL, v_lp_price, v_lp_qty, v_lp_total);

                -- 매수자 주식 잔고 지급
                INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
                VALUES (v_user_id, p_stock_id, v_lp_qty, 0, v_lp_price, v_lp_total)
                ON CONFLICT (user_id, stock_id) DO UPDATE
                SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                    amount = user_holdings.amount + EXCLUDED.amount,
                    average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                    updated_at = NOW();

                -- 지정가 우위 환불 (주문가 > 공모가 시 차액 포인트 즉시 환급)
                IF p_price > v_lp_price THEN
                    v_price_diff_refund := (p_price - v_lp_price)::BIGINT * v_lp_qty::BIGINT;
                    UPDATE public.profiles
                    SET total_point = total_point + v_price_diff_refund,
                        updated_at = NOW()
                    WHERE id = v_user_id;

                    INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                    VALUES (v_user_id, v_price_diff_refund, 
                            (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                            'STOCK_BUY_DIFF_REFUND', '공모 발행가 우위 체결 차액 환불');
                END IF;

                v_remain_qty := v_remain_qty - v_lp_qty;
            END IF;
        END IF;

    ELSIF p_order_type = 'SELL' THEN
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'BUY'
              AND status IN ('PENDING', 'PARTIAL')
              AND price >= p_price
              AND user_id != v_user_id
            ORDER BY price DESC, created_at ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price;
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_match_record.id, v_new_order_id, v_match_record.user_id, v_user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 매도자 정산: 잠긴 주식 차감 및 포인트 입금
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_match_record.user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 상대 매수 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;
    END IF;

    -- 6. 신규 주문 최종 상태 갱신
    UPDATE public.orders
    SET remain_amount = v_remain_qty,
        status = CASE 
                    WHEN v_remain_qty = 0 THEN 'FILLED'
                    WHEN v_remain_qty < p_amount THEN 'PARTIAL'
                    ELSE 'PENDING'
                 END,
        updated_at = NOW()
    WHERE id = v_new_order_id;

    RETURN jsonb_build_object(
        'order_id', v_new_order_id,
        'status', 'SUCCESS',
        'ordered_amount', p_amount,
        'matched_amount', p_amount - v_remain_qty,
        'remain_amount', v_remain_qty
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ========================================================
-- File: 20260906000006_concurrency_and_rls_hardening.sql
-- ========================================================

-- ========================================================
-- Migration: 20260906000006_concurrency_and_rls_hardening.sql
-- Description: Concurrency Hardening (Deadlock Prevention) & RLS Policy Enforcement
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. RLS 정책 보강: 호가창용 미체결 주문 공개 조회 허용 및 불변성 보호
DROP POLICY IF EXISTS "본인 주문만 조회 허용" ON public.orders;
DROP POLICY IF EXISTS "본인 주문 조회 허용" ON public.orders;
DROP POLICY IF EXISTS "호가창용 미체결 주문 공개 조회 허용" ON public.orders;

CREATE POLICY "본인 주문 조회 허용" ON public.orders
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "호가창용 미체결 주문 공개 조회 허용" ON public.orders
  FOR SELECT USING (status IN ('PENDING', 'PARTIAL'));

-- 2. 핵심 체결 엔진 하드닝: Deterministic Lock Ordering & Race Condition 차단
CREATE OR REPLACE FUNCTION public.place_and_match_order(
    p_stock_id BIGINT,
    p_order_type VARCHAR(10),
    p_price INT,
    p_amount INT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_market_status VARCHAR(20);
    v_stock_status VARCHAR(20);
    v_current_stock_price INT;
    v_pub_balance INT;
    v_pub_price INT;
    v_user_point BIGINT;
    v_user_stock_amount INT;
    v_required_total BIGINT;
    v_new_order_id BIGINT;
    v_remain_qty INT := p_amount;
    v_match_record RECORD;
    v_trade_qty INT;
    v_trade_price INT;
    v_trade_total BIGINT;
    v_price_diff_refund BIGINT;
    v_lp_qty INT;
    v_lp_price INT;
    v_lp_total BIGINT;
BEGIN
    -- 1. 사용자 인증 확인
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    IF p_amount <= 0 OR p_price <= 0 THEN
        RAISE EXCEPTION '주문 수량과 가격은 0보다 커야 합니다.';
    END IF;

    -- 2. 종목 단위 배타적 잠금 선점 (Deterministic Lock: 종목을 먼저 잠가 동일 종목 내 동시성 직렬화)
    SELECT market_status, status, current_price, publication_balance, publication_price
    INTO v_market_status, v_stock_status, v_current_stock_price, v_pub_balance, v_pub_price
    FROM public.stocks
    WHERE id = p_stock_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '존재하지 않는 종목입니다. (ID: %)', p_stock_id;
    END IF;

    IF v_market_status NOT IN ('OPEN', 'CONTINUOUS') OR v_stock_status != 'LISTED' THEN
        RAISE EXCEPTION '현재 거래가 중단되었거나 장이 마감된 종목입니다.';
    END IF;

    -- 3. 잔고 검증 및 사전 자산 잠금 (Escrow Lock)
    IF p_order_type = 'BUY' THEN
        v_required_total := p_price::BIGINT * p_amount::BIGINT;
        
        SELECT total_point INTO v_user_point
        FROM public.profiles
        WHERE id = v_user_id
        FOR UPDATE;

        IF v_user_point IS NULL OR v_user_point < v_required_total THEN
            RAISE EXCEPTION '가용 포인트(예수금)가 부족합니다. 필요 포인트: % P, 보유 포인트: % P', v_required_total, COALESCE(v_user_point, 0);
        END IF;

        -- 예수금 즉시 차감
        UPDATE public.profiles
        SET total_point = total_point - v_required_total,
            updated_at = NOW()
        WHERE id = v_user_id;

        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_user_id, -v_required_total, v_user_point - v_required_total, 'STOCK_BUY_ESCROW', '매수 주문 증거금 잠금');

    ELSIF p_order_type = 'SELL' THEN
        SELECT amount INTO v_user_stock_amount
        FROM public.user_holdings
        WHERE user_id = v_user_id AND stock_id = p_stock_id
        FOR UPDATE;

        IF v_user_stock_amount IS NULL OR v_user_stock_amount < p_amount THEN
            RAISE EXCEPTION '보유 주식 수량이 부족합니다. 필요: % 주, 보유량: % 주', p_amount, COALESCE(v_user_stock_amount, 0);
        END IF;

        -- 매도 주식 잠금 (가용 잔고 차감, 락 수량 증가)
        UPDATE public.user_holdings
        SET amount = amount - p_amount,
            locked_amount = locked_amount + p_amount,
            updated_at = NOW()
        WHERE user_id = v_user_id AND stock_id = p_stock_id;
    ELSE
        RAISE EXCEPTION '올바르지 않은 주문 유형입니다. (BUY 또는 SELL)';
    END IF;

    -- 4. 신규 주문 레코드 생성 (PENDING)
    INSERT INTO public.orders (user_id, stock_id, order_type, price, amount, remain_amount, status)
    VALUES (v_user_id, p_stock_id, p_order_type, p_price, p_amount, p_amount, 'PENDING')
    RETURNING id INTO v_new_order_id;

    -- 5. 반대 호가 매칭 루프 (Price-Time Priority, id ASC 보조 정렬로 결정론적 락 획득)
    IF p_order_type = 'BUY' THEN
        -- 5-A. 사용자 간 매도 대기 호가 매칭 (최저가 매도 우선, 동일 가격 시 선접수 id 우선)
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'SELL'
              AND status IN ('PENDING', 'PARTIAL')
              AND price <= p_price
              AND user_id != v_user_id
            ORDER BY price ASC, id ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price;
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            -- 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, v_match_record.id, v_user_id, v_match_record.user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 매도자 정산: 잠긴 주식 차감 및 포인트 입금 (매도자 계정 락 획득)
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_match_record.user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_match_record.user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_match_record.user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_match_record.user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 지정가 우위 차액 환불 (매수가 < 주문가 시 차액 포인트 즉시 환급)
            IF p_price > v_trade_price THEN
                v_price_diff_refund := (p_price - v_trade_price)::BIGINT * v_trade_qty::BIGINT;
                UPDATE public.profiles
                SET total_point = total_point + v_price_diff_refund,
                    updated_at = NOW()
                WHERE id = v_user_id;

                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '호가 우위 체결 차액 환불');
            END IF;

            -- 상대 매도 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;

        -- 5-B. 시스템 초기 발행 잔량(LP) 매수 매칭
        IF v_remain_qty > 0 AND v_pub_balance > 0 AND p_price >= v_pub_price THEN
            v_lp_qty := LEAST(v_remain_qty, v_pub_balance);
            v_lp_price := v_pub_price;
            v_lp_total := v_lp_price::BIGINT * v_lp_qty::BIGINT;

            -- 발행 잔량 차감 및 현재가 갱신
            UPDATE public.stocks
            SET publication_balance = publication_balance - v_lp_qty,
                current_price = v_lp_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            -- 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, NULL, v_user_id, NULL, v_lp_price, v_lp_qty, v_lp_total);

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_lp_qty, 0, v_lp_price, v_lp_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 지정가 우위 차액 환불
            IF p_price > v_lp_price THEN
                v_price_diff_refund := (p_price - v_lp_price)::BIGINT * v_lp_qty::BIGINT;
                UPDATE public.profiles
                SET total_point = total_point + v_price_diff_refund,
                    updated_at = NOW()
                WHERE id = v_user_id;

                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '공모 발행가 우위 체결 차액 환불');
            END IF;

            v_remain_qty := v_remain_qty - v_lp_qty;
        END IF;

    ELSIF p_order_type = 'SELL' THEN
        -- 5-C. 사용자 간 매수 대기 호가 매칭 (최고가 매수 우선, 동일 가격 시 선접수 id 우선)
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'BUY'
              AND status IN ('PENDING', 'PARTIAL')
              AND price >= p_price
              AND user_id != v_user_id
            ORDER BY price DESC, id ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price;
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            -- 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_match_record.id, v_new_order_id, v_match_record.user_id, v_user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 매도자 정산: 잠긴 주식 차감 및 포인트 입금
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_match_record.user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 상대 매수 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;
    END IF;

    -- 6. 신규 주문 최종 상태 갱신
    UPDATE public.orders
    SET remain_amount = v_remain_qty,
        status = CASE 
                    WHEN v_remain_qty = 0 THEN 'FILLED'
                    WHEN v_remain_qty < p_amount THEN 'PARTIAL'
                    ELSE 'PENDING'
                 END,
        updated_at = NOW()
    WHERE id = v_new_order_id;

    RETURN jsonb_build_object(
        'order_id', v_new_order_id,
        'status', 'SUCCESS',
        'ordered_amount', p_amount,
        'matched_amount', p_amount - v_remain_qty,
        'remain_amount', v_remain_qty
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. 주문 취소 프로시저 하드닝: FOR UPDATE 잠금 및 잔고 원자적 환불
CREATE OR REPLACE FUNCTION public.cancel_stock_order(
    p_order_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_order_record RECORD;
    v_refund_amount BIGINT;
    v_cur_point BIGINT;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 주문 행 배타적 잠금 (동시 체결 경합 원천 차단)
    SELECT * INTO v_order_record
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE;

    IF v_order_record IS NULL THEN
        RAISE EXCEPTION '해당 주문을 찾을 수 없습니다. (ID: %)', p_order_id;
    END IF;

    IF v_order_record.user_id != v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION '본인의 주문만 취소할 수 있습니다.';
    END IF;

    IF v_order_record.status NOT IN ('PENDING', 'PARTIAL') OR v_order_record.remain_amount <= 0 THEN
        RAISE EXCEPTION '이미 전량 체결되었거나 취소된 주문입니다. (상태: %, 잔여량: %)', v_order_record.status, v_order_record.remain_amount;
    END IF;

    -- 주문 상태 CANCELLED 갱신
    UPDATE public.orders
    SET status = 'CANCELLED',
        remain_amount = 0,
        cancelled_at = NOW(),
        updated_at = NOW()
    WHERE id = p_order_id;

    -- 미체결 잔량 자산 복원 (Refund)
    IF v_order_record.order_type = 'BUY' THEN
        v_refund_amount := v_order_record.price::BIGINT * v_order_record.remain_amount::BIGINT;
        
        -- 계정 락 획득 후 환불
        SELECT total_point INTO v_cur_point
        FROM public.profiles
        WHERE id = v_order_record.user_id
        FOR UPDATE;

        UPDATE public.profiles
        SET total_point = total_point + v_refund_amount,
            updated_at = NOW()
        WHERE id = v_order_record.user_id;

        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_order_record.user_id, v_refund_amount, 
                v_cur_point + v_refund_amount, 
                'STOCK_BUY_CANCEL_REFUND', '미체결 매수 주문 취소 환불');

    ELSIF v_order_record.order_type = 'SELL' THEN
        -- 잠긴 주식을 가용 잔고로 원복
        UPDATE public.user_holdings
        SET amount = amount + v_order_record.remain_amount,
            locked_amount = locked_amount - v_order_record.remain_amount,
            updated_at = NOW()
        WHERE user_id = v_order_record.user_id AND stock_id = v_order_record.stock_id;
    END IF;

    RETURN jsonb_build_object(
        'order_id', p_order_id,
        'status', 'CANCELLED',
        'refund_qty', v_order_record.remain_amount,
        'refund_points', COALESCE(v_refund_amount, 0)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ========================================================
-- File: 20260906000007_admin_management_and_market_settings.sql
-- ========================================================

-- ========================================================
-- Migration: 20260906000007_admin_management_and_market_settings.sql
-- Description: Admin Governance, Market Control, Delisting Liquidation & Cutover Functions
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. 시장 운영 설정 테이블 (market_settings)
CREATE TABLE IF NOT EXISTS public.market_settings (
    id INT PRIMARY KEY DEFAULT 1,
    is_market_open BOOLEAN NOT NULL DEFAULT true,
    mode VARCHAR(20) NOT NULL DEFAULT 'AUTO' CHECK (mode IN ('AUTO', 'MANUAL')),
    open_time VARCHAR(10) NOT NULL DEFAULT '09:00',
    close_time VARCHAR(10) NOT NULL DEFAULT '15:30',
    call_auction_start_time VARCHAR(10) NOT NULL DEFAULT '15:20',
    operating_days VARCHAR(50) NOT NULL DEFAULT 'MON,TUE,WED,THU,FRI',
    status_code VARCHAR(20) NOT NULL DEFAULT 'OPEN' CHECK (status_code IN ('OPEN', 'CLOSED', 'MANUAL_PAUSE', 'HOLIDAY')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 초기 시드 레코드
INSERT INTO public.market_settings (id, is_market_open, mode, open_time, close_time, call_auction_start_time, status_code)
VALUES (1, true, 'AUTO', '09:00', '15:30', '15:20', 'OPEN')
ON CONFLICT (id) DO NOTHING;

-- 관리자 여부 판별 함수 (service_role 및 ROLE_ADMIN/ROLE_TEACHER 지원)
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  IF auth.role() = 'service_role' THEN
    RETURN true;
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('ROLE_ADMIN', 'ROLE_TEACHER')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RLS 활성화 및 정책
ALTER TABLE public.market_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "누구나 시장 운영 상태 조회 허용" ON public.market_settings;
CREATE POLICY "누구나 시장 운영 상태 조회 허용" ON public.market_settings
    FOR SELECT USING (true);

DROP POLICY IF EXISTS "관리자만 시장 운영 설정 수정 허용" ON public.market_settings;
CREATE POLICY "관리자만 시장 운영 설정 수정 허용" ON public.market_settings
    FOR ALL USING (public.is_admin());

-- Realtime 브로드캐스트 등록
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'market_settings'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.market_settings;
    END IF;
END $$;

-- 2. 교사 관리자 기본 계정 시딩 (admin / 1234, ROLE_ADMIN)
DO $$
DECLARE
    v_admin_id UUID := '00000000-0000-0000-0000-000000000001';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'admin@stockgame.local') THEN
        INSERT INTO auth.users (
            id, instance_id, email, encrypted_password, email_confirmed_at,
            confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current,
            phone_change, phone_change_token, reauthentication_token,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at, role, aud
        ) VALUES (
            v_admin_id,
            '00000000-0000-0000-0000-000000000000',
            'admin@stockgame.local',
            crypt('1234', gen_salt('bf')),
            NOW(),
            '', '', '', '', '',
            '', '', '',
            '{"provider":"email","providers":["email"]}',
            '{"role":"ROLE_ADMIN","student_id":"admin","name":"관리자선생님","grade":1,"class_name":"교무실","class_number":1}',
            NOW(), NOW(),
            'authenticated', 'authenticated'
        );
    END IF;

    -- 프로필 확인 및 롤 보정
    INSERT INTO public.profiles (
        id, student_id, name, grade, class_name, class_number, role, total_point, total_coupon, status
    ) VALUES (
        v_admin_id, 'admin', '관리자선생님', 1, '교무실', 1, 'ROLE_ADMIN', 100000000, 0, 'ACTIVE'
    )
    ON CONFLICT (id) DO UPDATE
    SET role = 'ROLE_ADMIN', name = '관리자선생님';
END $$;

-- 3. 관리자 시장 개폐 토글 함수 (admin_toggle_market)
CREATE OR REPLACE FUNCTION public.admin_toggle_market()
RETURNS JSONB AS $$
DECLARE
    v_rec RECORD;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    SELECT * INTO v_rec FROM public.market_settings WHERE id = 1 FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO public.market_settings (id, is_market_open, mode, status_code)
        VALUES (1, false, 'MANUAL', 'MANUAL_PAUSE')
        RETURNING * INTO v_rec;
    ELSE
        UPDATE public.market_settings
        SET is_market_open = NOT v_rec.is_market_open,
            mode = 'MANUAL',
            status_code = CASE WHEN v_rec.is_market_open THEN 'MANUAL_PAUSE' ELSE 'OPEN' END,
            updated_at = NOW()
        WHERE id = 1
        RETURNING * INTO v_rec;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'marketOpen', v_rec.is_market_open,
        'mode', v_rec.mode,
        'openTime', v_rec.open_time,
        'closeTime', v_rec.close_time,
        'callAuctionStartTime', v_rec.call_auction_start_time,
        'statusCode', v_rec.status_code
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. 관리자 시장 설정 저장 함수 (admin_update_market_settings)
CREATE OR REPLACE FUNCTION public.admin_update_market_settings(
    p_mode VARCHAR DEFAULT 'AUTO',
    p_open_time VARCHAR DEFAULT '09:00',
    p_close_time VARCHAR DEFAULT '15:30',
    p_call_auction_start_time VARCHAR DEFAULT '15:20'
)
RETURNS JSONB AS $$
DECLARE
    v_rec RECORD;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    UPDATE public.market_settings
    SET mode = p_mode,
        open_time = p_open_time,
        close_time = p_close_time,
        call_auction_start_time = p_call_auction_start_time,
        status_code = CASE WHEN p_mode = 'MANUAL' THEN status_code ELSE 'OPEN' END,
        updated_at = NOW()
    WHERE id = 1
    RETURNING * INTO v_rec;

    RETURN jsonb_build_object(
        'success', true,
        'marketOpen', v_rec.is_market_open,
        'mode', v_rec.mode,
        'openTime', v_rec.open_time,
        'closeTime', v_rec.close_time,
        'callAuctionStartTime', v_rec.call_auction_start_time,
        'statusCode', v_rec.status_code
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. 원자적 종목 상장폐지 및 강제 청산 프로시저 (admin_delist_stock)
CREATE OR REPLACE FUNCTION public.admin_delist_stock(
    p_stock_id BIGINT,
    p_compensation_price INT DEFAULT 0,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB AS $$
DECLARE
    v_stock_name VARCHAR(100);
    v_order RECORD;
    v_holding RECORD;
    v_refund_amount BIGINT;
    v_comp_amount BIGINT;
    v_cancelled_orders_count INT := 0;
    v_liquidated_holdings_count INT := 0;
    v_total_compensated_points BIGINT := 0;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    -- 1. 종목 행 배타락 및 존재 확인
    SELECT name INTO v_stock_name FROM public.stocks WHERE id = p_stock_id FOR UPDATE;
    IF v_stock_name IS NULL THEN
        RAISE EXCEPTION '존재하지 않는 종목입니다.';
    END IF;

    -- 2. 종목 상태를 DELISTED로 변경
    UPDATE public.stocks SET status = 'DELISTED' WHERE id = p_stock_id;

    -- 3. 미체결 주문 전액 취소 및 매수 주문 포인트 환불
    FOR v_order IN
        SELECT id, user_id, order_type, price, amount, remain_amount
        FROM public.orders
        WHERE stock_id = p_stock_id AND status IN ('PENDING', 'PARTIAL')
        FOR UPDATE
    LOOP
        IF v_order.order_type = 'BUY' THEN
            v_refund_amount := v_order.remain_amount::BIGINT * v_order.price;
            UPDATE public.profiles
            SET total_point = total_point + v_refund_amount
            WHERE id = v_order.user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            SELECT v_order.user_id, v_refund_amount, total_point, 'REFUND',
                   '[' || v_stock_name || ' 상장폐지] 미체결 매수 주문 취소 환불'
            FROM public.profiles WHERE id = v_order.user_id;
        END IF;

        UPDATE public.orders SET status = 'CANCELLED', remain_amount = 0, cancelled_at = NOW() WHERE id = v_order.id;
        v_cancelled_orders_count := v_cancelled_orders_count + 1;
    END LOOP;

    -- 4. 학생 보유 주식 청산 및 보상금 지급
    FOR v_holding IN
        SELECT id, user_id, amount, locked_amount
        FROM public.user_holdings
        WHERE stock_id = p_stock_id AND (amount > 0 OR locked_amount > 0)
        FOR UPDATE
    LOOP
        IF p_compensation_price > 0 THEN
            v_comp_amount := (v_holding.amount + v_holding.locked_amount)::BIGINT * p_compensation_price;
            UPDATE public.profiles
            SET total_point = total_point + v_comp_amount
            WHERE id = v_holding.user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            SELECT v_holding.user_id, v_comp_amount, total_point, 'COMPENSATION',
                   '[' || v_stock_name || ' 상장폐지] 보유주식(' || (v_holding.amount + v_holding.locked_amount) || '주) 청산 보상금'
            FROM public.profiles WHERE id = v_holding.user_id;

            v_total_compensated_points := v_total_compensated_points + v_comp_amount;
        END IF;

        UPDATE public.user_holdings SET amount = 0, locked_amount = 0 WHERE id = v_holding.id;
        v_liquidated_holdings_count := v_liquidated_holdings_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'stockId', p_stock_id,
        'stockName', v_stock_name,
        'cancelledOrdersCount', v_cancelled_orders_count,
        'liquidatedHoldingsCount', v_liquidated_holdings_count,
        'totalCompensatedPoints', v_total_compensated_points,
        'reason', p_reason
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. 학생 포인트 강제 조정 및 감사 기록 함수 (admin_adjust_student_point)
CREATE OR REPLACE FUNCTION public.admin_adjust_student_point(
    p_user_id UUID,
    p_amount INT,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB AS $$
DECLARE
    v_current_point BIGINT;
    v_new_point BIGINT;
    v_reason_type VARCHAR(20);
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    SELECT total_point INTO v_current_point FROM public.profiles WHERE id = p_user_id FOR UPDATE;
    IF v_current_point IS NULL THEN
        RAISE EXCEPTION '존재하지 않는 학생입니다.';
    END IF;

    IF p_amount < 0 AND (v_current_point + p_amount) < 0 THEN
        RAISE EXCEPTION '차감 후 포인트가 음수가 될 수 없습니다. (현재 잔액: %)', v_current_point;
    END IF;

    v_new_point := v_current_point + p_amount;
    v_reason_type := CASE WHEN p_amount >= 0 THEN 'ADMIN_GRANT' ELSE 'ADMIN_DEDUCT' END;

    UPDATE public.profiles SET total_point = v_new_point WHERE id = p_user_id;

    INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
    VALUES (p_user_id, p_amount, v_new_point, v_reason_type, COALESCE(NULLIF(p_reason, ''), '관리자 포인트 강제 조정'));

    RETURN jsonb_build_object(
        'success', true,
        'userId', p_user_id,
        'adjustedAmount', p_amount,
        'totalPoint', v_new_point
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. 학생 계정 삭제 및 자산 완전 정리 함수 (admin_delete_student)
CREATE OR REPLACE FUNCTION public.admin_delete_student(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_order RECORD;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    -- 대기 중인 주문 취소
    UPDATE public.orders SET status = 'CANCELLED'
    WHERE user_id = p_user_id AND status IN ('PENDING', 'PARTIAL');

    -- profiles 삭제 (CASCADE로 하위 종속 테이블 자동 정리)
    DELETE FROM public.profiles WHERE id = p_user_id;

    -- auth.users 삭제
    DELETE FROM auth.users WHERE id = p_user_id;

    RETURN jsonb_build_object('success', true, 'deletedUserId', p_user_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. 체결 엔진 하드닝: 시장 개폐 가드 탑재 (place_and_match_order 재정의)
CREATE OR REPLACE FUNCTION public.place_and_match_order(
    p_stock_id BIGINT,
    p_order_type VARCHAR(10),
    p_price INT,
    p_amount INT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_market_open_check BOOLEAN;
    v_market_status_code VARCHAR(20);
    v_market_status VARCHAR(20);
    v_stock_status VARCHAR(20);
    v_current_stock_price INT;
    v_pub_balance INT;
    v_pub_price INT;
    v_user_point BIGINT;
    v_user_stock_amount INT;
    v_required_total BIGINT;
    v_new_order_id BIGINT;
    v_remain_qty INT := p_amount;
    v_match_record RECORD;
    v_trade_qty INT;
    v_trade_price INT;
    v_trade_total BIGINT;
    v_price_diff_refund BIGINT;
    v_lp_qty INT;
    v_lp_price INT;
    v_lp_total BIGINT;
BEGIN
    -- 0. 사용자 인증 확인
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    IF p_amount <= 0 OR p_price <= 0 THEN
        RAISE EXCEPTION '주문 수량과 가격은 0보다 커야 합니다.';
    END IF;

    -- 0-1. 시장 운영 상태 검증 (휴장 또는 점검 중 주문 접수 차단)
    SELECT is_market_open, status_code INTO v_market_open_check, v_market_status_code
    FROM public.market_settings WHERE id = 1;

    IF v_market_open_check IS NOT NULL AND (NOT v_market_open_check OR v_market_status_code = 'MANUAL_PAUSE' OR v_market_status_code = 'CLOSED') THEN
        RAISE EXCEPTION '현재 주식 시장이 휴장 또는 점검 중이므로 주문을 제출할 수 없습니다.';
    END IF;

    -- 1. 종목 단위 배타적 잠금 선점 (Deterministic Lock Ordering)
    SELECT market_status, status, current_price, publication_balance, publication_price
    INTO v_market_status, v_stock_status, v_current_stock_price, v_pub_balance, v_pub_price
    FROM public.stocks
    WHERE id = p_stock_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '존재하지 않는 종목입니다. (ID: %)', p_stock_id;
    END IF;

    IF v_market_status NOT IN ('OPEN', 'CONTINUOUS') OR v_stock_status != 'LISTED' THEN
        RAISE EXCEPTION '현재 거래가 중단되었거나 장이 마감된 종목입니다.';
    END IF;

    -- 2. 잔고 검증 및 사전 자산 잠금 (Escrow Lock)
    IF p_order_type = 'BUY' THEN
        v_required_total := p_price::BIGINT * p_amount::BIGINT;
        
        SELECT total_point INTO v_user_point
        FROM public.profiles
        WHERE id = v_user_id
        FOR UPDATE;

        IF v_user_point IS NULL OR v_user_point < v_required_total THEN
            RAISE EXCEPTION '가용 포인트(예수금)가 부족합니다. 필요 포인트: % P, 보유 포인트: % P', v_required_total, COALESCE(v_user_point, 0);
        END IF;

        -- 예수금 즉시 차감
        UPDATE public.profiles
        SET total_point = total_point - v_required_total,
            updated_at = NOW()
        WHERE id = v_user_id;

        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_user_id, -v_required_total, v_user_point - v_required_total, 'STOCK_BUY_ESCROW', '매수 주문 증거금 잠금');

    ELSIF p_order_type = 'SELL' THEN
        SELECT amount INTO v_user_stock_amount
        FROM public.user_holdings
        WHERE user_id = v_user_id AND stock_id = p_stock_id
        FOR UPDATE;

        IF v_user_stock_amount IS NULL OR v_user_stock_amount < p_amount THEN
            RAISE EXCEPTION '보유 주식 수량이 부족합니다. 필요: % 주, 보유량: % 주', p_amount, COALESCE(v_user_stock_amount, 0);
        END IF;

        -- 매도 주식 잠금 (가용 잔고 차감, 락 수량 증가)
        UPDATE public.user_holdings
        SET amount = amount - p_amount,
            locked_amount = locked_amount + p_amount,
            updated_at = NOW()
        WHERE user_id = v_user_id AND stock_id = p_stock_id;
    ELSE
        RAISE EXCEPTION '올바르지 않은 주문 유형입니다. (BUY 또는 SELL)';
    END IF;

    -- 3. 신규 주문 레코드 생성 (PENDING)
    INSERT INTO public.orders (user_id, stock_id, order_type, price, amount, remain_amount, status)
    VALUES (v_user_id, p_stock_id, p_order_type, p_price, p_amount, p_amount, 'PENDING')
    RETURNING id INTO v_new_order_id;

    -- 4. 반대 호가 매칭 루프 (Price-Time Priority)
    IF p_order_type = 'BUY' THEN
        -- 4-A. 사용자 간 매도 대기 호가 매칭 (최저가 매도 우선, 동일 가격 시 선접수 id 우선)
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'SELL'
              AND status IN ('PENDING', 'PARTIAL')
              AND price <= p_price
              AND user_id != v_user_id
            ORDER BY price ASC, id ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price;
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            -- 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, v_match_record.id, v_user_id, v_match_record.user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 매도자 정산: 잠긴 주식 차감 및 포인트 입금 (매도자 계정 락 획득)
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_match_record.user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_match_record.user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_match_record.user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_match_record.user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 지정가 우위 차액 환불 (매수가 < 주문가 시 차액 포인트 즉시 환급)
            IF p_price > v_trade_price THEN
                v_price_diff_refund := (p_price - v_trade_price)::BIGINT * v_trade_qty::BIGINT;
                UPDATE public.profiles
                SET total_point = total_point + v_price_diff_refund,
                    updated_at = NOW()
                WHERE id = v_user_id;

                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '호가 우위 체결 차액 환불');
            END IF;

            -- 상대 매도 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;

        -- 4-B. 시스템 초기 발행 잔량(LP) 매수 매칭
        IF v_remain_qty > 0 AND v_pub_balance > 0 AND p_price >= v_pub_price THEN
            v_lp_qty := LEAST(v_remain_qty, v_pub_balance);
            v_lp_price := v_pub_price;
            v_lp_total := v_lp_price::BIGINT * v_lp_qty::BIGINT;

            -- 발행 잔량 차감 및 현재가 갱신
            UPDATE public.stocks
            SET publication_balance = publication_balance - v_lp_qty,
                current_price = v_lp_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            -- 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, NULL, v_user_id, NULL, v_lp_price, v_lp_qty, v_lp_total);

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_lp_qty, 0, v_lp_price, v_lp_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 지정가 우위 차액 환불
            IF p_price > v_lp_price THEN
                v_price_diff_refund := (p_price - v_lp_price)::BIGINT * v_lp_qty::BIGINT;
                UPDATE public.profiles
                SET total_point = total_point + v_price_diff_refund,
                    updated_at = NOW()
                WHERE id = v_user_id;

                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '공모 발행가 우위 체결 차액 환불');
            END IF;

            v_remain_qty := v_remain_qty - v_lp_qty;
        END IF;

    ELSIF p_order_type = 'SELL' THEN
        -- 4-C. 사용자 간 매수 대기 호가 매칭 (최고가 매수 우선, 동일 가격 시 선접수 id 우선)
        FOR v_match_record IN
            SELECT id, user_id, price, remain_amount
            FROM public.orders
            WHERE stock_id = p_stock_id
              AND order_type = 'BUY'
              AND status IN ('PENDING', 'PARTIAL')
              AND price >= p_price
              AND user_id != v_user_id
            ORDER BY price DESC, id ASC
            FOR UPDATE
        LOOP
            EXIT WHEN v_remain_qty = 0;

            v_trade_qty := LEAST(v_remain_qty, v_match_record.remain_amount);
            v_trade_price := v_match_record.price;
            v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

            -- 체결 레코드 삽입
            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_match_record.id, v_new_order_id, v_match_record.user_id, v_user_id, v_trade_price, v_trade_qty, v_trade_total);

            -- 매도자 정산: 잠긴 주식 차감 및 포인트 입금
            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_trade_qty,
                updated_at = NOW()
            WHERE user_id = v_user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_trade_total,
                updated_at = NOW()
            WHERE id = v_user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                    'STOCK_SELL_SETTLEMENT', '주식 매도 체결 대금 정산');

            -- 매수자 주식 잔고 지급
            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_match_record.user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            -- 상대 매수 주문 상태 업데이트
            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

            -- 종목 현재가 갱신
            UPDATE public.stocks
            SET current_price = v_trade_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            v_remain_qty := v_remain_qty - v_trade_qty;
        END LOOP;
    END IF;

    -- 5. 신규 주문 최종 상태 갱신
    UPDATE public.orders
    SET remain_amount = v_remain_qty,
        status = CASE 
                    WHEN v_remain_qty = 0 THEN 'FILLED'
                    WHEN v_remain_qty < p_amount THEN 'PARTIAL'
                    ELSE 'PENDING'
                 END,
        updated_at = NOW()
    WHERE id = v_new_order_id;

    RETURN jsonb_build_object(
        'order_id', v_new_order_id,
        'status', 'SUCCESS',
        'ordered_amount', p_amount,
        'matched_amount', p_amount - v_remain_qty,
        'remain_amount', v_remain_qty
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 9. 관리자 전용 CUD RLS 정책 보강
DROP POLICY IF EXISTS "관리자 user_holdings 전체 권한 허용" ON public.user_holdings;
CREATE POLICY "관리자 user_holdings 전체 권한 허용" ON public.user_holdings
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "관리자 orders 전체 권한 허용" ON public.orders;
CREATE POLICY "관리자 orders 전체 권한 허용" ON public.orders
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "관리자 point_transactions 전체 권한 허용" ON public.point_transactions;
CREATE POLICY "관리자 point_transactions 전체 권한 허용" ON public.point_transactions
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());


-- ========================================================
-- File: 20260906000008_classroom_session_reset.sql
-- ========================================================

-- Migration: 20260906000008_classroom_session_reset.sql
-- Description: 차기 수업용 교실 모의투자 1-클릭 세션 리셋 Stored Procedure

CREATE OR REPLACE FUNCTION public.admin_reset_classroom_session(
    p_default_point INT DEFAULT 100000,
    p_reset_stock_price BOOLEAN DEFAULT true
)
RETURNS JSONB AS $$
DECLARE
    v_cancelled_orders_count INT := 0;
    v_cleared_holdings_count INT := 0;
    v_reset_students_count INT := 0;
    v_reset_stocks_count INT := 0;
BEGIN
    -- 1. 관리자 권한 검증
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    -- 2. 미체결 주문 일괄 취소 (PENDING, PARTIAL)
    UPDATE public.orders
    SET status = 'CANCELLED',
        remain_amount = 0,
        cancelled_at = NOW()
    WHERE status IN ('PENDING', 'PARTIAL');
    GET DIAGNOSTICS v_cancelled_orders_count = ROW_COUNT;

    -- 3. 학생 보유 주식 일괄 초기화 (수량 0)
    UPDATE public.user_holdings
    SET amount = 0,
        locked_amount = 0,
        average_price = 0,
        total_invested_amount = 0,
        updated_at = NOW()
    WHERE user_id IN (
        SELECT id FROM public.profiles WHERE role = 'ROLE_STUDENT'
    );
    GET DIAGNOSTICS v_cleared_holdings_count = ROW_COUNT;

    -- 4. 학생 프로필 예수금(total_point) 일괄 초기화 (기본 100,000P, 쿠폰 0)
    UPDATE public.profiles
    SET total_point = p_default_point,
        total_coupon = 0,
        updated_at = NOW()
    WHERE role = 'ROLE_STUDENT';
    GET DIAGNOSTICS v_reset_students_count = ROW_COUNT;

    -- 5. 감사 이력 적재
    INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
    SELECT id, p_default_point, p_default_point, 'SESSION_RESET',
           '차기 수업 진행을 위한 교실 모의투자 세션 1-클릭 초기화'
    FROM public.profiles
    WHERE role = 'ROLE_STUDENT';

    -- 6. 종목 시세 및 상하한가 초기 발행가로 원복 (p_reset_stock_price = true 시)
    IF p_reset_stock_price THEN
        UPDATE public.stocks
        SET current_price = publication_price,
            prev_price = publication_price,
            high_limit_price = ROUND(publication_price * 1.3),
            low_limit_price = ROUND(publication_price * 0.7),
            market_status = 'CONTINUOUS',
            status = 'LISTED',
            updated_at = NOW()
        WHERE status != 'DELETED';
        GET DIAGNOSTICS v_reset_stocks_count = ROW_COUNT;
    END IF;

    -- 7. 시장 상태를 정규 휴장 (CLOSED)으로 전환
    UPDATE public.market_settings
    SET is_market_open = false,
        status_code = 'CLOSED',
        updated_at = NOW()
    WHERE id = 1;

    RETURN jsonb_build_object(
        'success', true,
        'defaultPoint', p_default_point,
        'resetStudentsCount', v_reset_students_count,
        'cancelledOrdersCount', v_cancelled_orders_count,
        'clearedHoldingsCount', v_cleared_holdings_count,
        'resetStocksCount', v_reset_stocks_count,
        'marketOpen', false,
        'statusCode', 'CLOSED',
        'resetAt', NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


