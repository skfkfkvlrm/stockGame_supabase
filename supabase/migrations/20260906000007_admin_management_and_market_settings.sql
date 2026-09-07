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
