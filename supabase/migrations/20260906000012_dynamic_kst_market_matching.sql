-- ========================================================
-- Migration: 20260906000012_dynamic_kst_market_matching.sql
-- Description: Dynamic KST Business Hours Matching Engine & Off-Hours Call Auction Synchronization
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. market_settings 기본 상태 정상화
UPDATE public.market_settings
SET is_market_open = true,
    status_code = 'OPEN',
    updated_at = NOW()
WHERE id = 1;

-- 2. admin_update_market_settings 함수 고도화 (AUTO 전환 시 is_market_open 동기화)
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
        is_market_open = CASE WHEN p_mode = 'AUTO' THEN true ELSE is_market_open END,
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

-- 3. 체결 엔진 하드닝: KST 동적 시간 판별 및 상시 연속 매매/동시호가 자동 분기
CREATE OR REPLACE FUNCTION public.place_and_match_order(
    p_stock_id bigint,
    p_order_type character varying,
    p_price integer,
    p_amount integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_user_id UUID := auth.uid();
    v_market_open_check BOOLEAN;
    v_market_mode VARCHAR(20);
    v_open_time VARCHAR(10);
    v_close_time VARCHAR(10);
    v_call_auction_start_time VARCHAR(10);
    v_market_status_code VARCHAR(20);
    v_kst_now TIMESTAMP;
    v_kst_day INT;
    v_kst_hhmm VARCHAR(5);

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
    v_is_reservation BOOLEAN := FALSE;
BEGIN
    -- 0. 사용자 인증 확인
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    IF p_amount <= 0 OR p_price <= 0 THEN
        RAISE EXCEPTION '주문 수량과 가격은 0보다 커야 합니다.';
    END IF;

    -- 0-1. 시장 운영 상태 검증 (AUTO 모드 시 KST 동적 시간 판별, MANUAL 모드 시 is_market_open 준수)
    SELECT is_market_open, mode, open_time, close_time, call_auction_start_time, status_code
    INTO v_market_open_check, v_market_mode, v_open_time, v_close_time, v_call_auction_start_time, v_market_status_code
    FROM public.market_settings WHERE id = 1;

    -- 긴급 점검(MANUAL_PAUSE)인 경우에만 주문 차단
    IF v_market_status_code = 'MANUAL_PAUSE' THEN
        RAISE EXCEPTION '현재 시스템 긴급 점검 중이므로 주문을 접수할 수 없습니다.';
    END IF;

    IF COALESCE(v_market_mode, 'AUTO') = 'AUTO' THEN
        -- 한국 표준시(KST, UTC+9) 기준 현재 요일 및 시분 계산
        v_kst_now := (NOW() AT TIME ZONE 'Asia/Seoul');
        v_kst_day := EXTRACT(DOW FROM v_kst_now); -- 0: 일요일, 6: 토요일
        v_kst_hhmm := TO_CHAR(v_kst_now, 'HH24:MI');

        IF v_kst_day IN (0, 6) OR v_kst_hhmm < COALESCE(v_open_time, '09:00') OR v_kst_hhmm >= COALESCE(v_close_time, '15:30') THEN
            -- 정규장 외 시간: 장마감 예약 주문 접수 (다음 개장 시 동시호가 일괄 체결)
            v_is_reservation := TRUE;
        ELSIF v_kst_hhmm >= COALESCE(v_call_auction_start_time, '15:20') AND v_kst_hhmm < COALESCE(v_close_time, '15:30') THEN
            -- 15:20 ~ 15:30: 장마감 직전 동시호가(단일가) 접수 시간 (15:30에 일괄 체결)
            v_is_reservation := TRUE;
        ELSE
            -- 평일 09:00 ~ 15:20: 정규장 실시간 연속 매매 (즉시 체결!)
            v_is_reservation := FALSE;
        END IF;
    ELSE
        -- MANUAL 모드: 관리자 수동 개폐 설정(is_market_open) 준수 (포트폴리오 데모 평가 시 24시간 상시 개장 지원)
        IF v_market_open_check IS NOT NULL AND (NOT v_market_open_check OR v_market_status_code = 'CLOSED') THEN
            v_is_reservation := TRUE;
        ELSE
            v_is_reservation := FALSE;
        END IF;
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

    IF v_stock_status != 'LISTED' THEN
        RAISE EXCEPTION '현재 거래가 중단되었거나 상장폐지된 종목입니다.';
    END IF;

    -- 정규장 개장 중일 때만 종목 market_status 검증
    IF NOT v_is_reservation AND v_market_status NOT IN ('OPEN', 'CONTINUOUS') THEN
        v_is_reservation := TRUE;
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
        VALUES (v_user_id, -v_required_total, v_user_point - v_required_total, 'STOCK_BUY_ESCROW', 
                CASE WHEN v_is_reservation THEN '장 마감 매수 예약 주문 증거금 잠금' ELSE '매수 주문 증거금 잠금' END);

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

    -- 3. 신규 주문 레코드 생성 (PENDING 상태로 저장되어 호가창 및 예약 목록에 즉시 노출)
    INSERT INTO public.orders (user_id, stock_id, order_type, price, amount, remain_amount, status)
    VALUES (v_user_id, p_stock_id, p_order_type, p_price, p_amount, p_amount, 'PENDING')
    RETURNING id INTO v_new_order_id;

    -- ⭐️ 3-1. 장 마감 예약 주문인 경우: 실시간 연속 매매를 건너뛰고 예약 접수 완료 반환!
    IF v_is_reservation THEN
        RETURN jsonb_build_object(
            'order_id', v_new_order_id,
            'status', 'RESERVED',
            'is_reservation', true,
            'ordered_amount', p_amount,
            'matched_amount', 0,
            'remain_amount', p_amount,
            'message', '장 마감 후 예약 주문이 접수되었습니다. 다음 개장 시 동시호가(단일가)로 일괄 체결됩니다.'
        );
    END IF;

    -- 4. 정규장 실시간 연속 매매 반대 호가 매칭 루프 (Price-Time Priority)
    IF p_order_type = 'BUY' THEN
        -- 4-A. 사용자 간 매도 대기 호가 매칭
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

            -- 매도자 정산
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

        -- 4-B. 시스템 초기 발행 잔량(LP) 매수 매칭
        IF v_remain_qty > 0 AND v_pub_balance > 0 AND p_price >= v_pub_price THEN
            v_lp_qty := LEAST(v_remain_qty, v_pub_balance);
            v_lp_price := v_pub_price;
            v_lp_total := v_lp_price::BIGINT * v_lp_qty::BIGINT;

            UPDATE public.stocks
            SET publication_balance = publication_balance - v_lp_qty,
                current_price = v_lp_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, NULL, v_user_id, NULL, v_lp_price, v_lp_qty, v_lp_total);

            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_lp_qty, 0, v_lp_price, v_lp_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

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
        -- 4-C. 사용자 간 매수 대기 호가 매칭
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

            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_match_record.id, v_new_order_id, v_match_record.user_id, v_user_id, v_trade_price, v_trade_qty, v_trade_total);

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

            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_match_record.user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            UPDATE public.orders
            SET remain_amount = remain_amount - v_trade_qty,
                status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                updated_at = NOW()
            WHERE id = v_match_record.id;

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
        'is_reservation', false,
        'ordered_amount', p_amount,
        'matched_amount', p_amount - v_remain_qty,
        'remain_amount', v_remain_qty
    );
END;
$function$;
