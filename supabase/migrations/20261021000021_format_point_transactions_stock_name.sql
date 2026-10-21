-- ==============================================================================
-- 마이그레이션: 포인트 변동 내역 종목명 및 거래 행위 중심 표기 개편 (A안)
-- 버전: 20261021000021_format_point_transactions_stock_name.sql
-- 내용: 
--   1. place_and_match_order: [매수 주문/예약] 종목명 N주, [매도 체결] 종목명 N주 정산, [체결 차액] 종목명 환불
--   2. cancel_stock_order: [주문 취소] 종목명 N주 환불
--   3. execute_call_auction: [동시호가 매도] 종목명 N주 정산, [체결 차액] 종목명 동시호가 환불
--   4. admin_delete_student_account: [계정 정리] 종목명 N주 환불
--   5. 과거 누적 내역(point_transactions) A안으로 소급 백필 (Backfill)
-- ==============================================================================

-- 1. place_and_match_order 하드닝 (종목명 및 수량 바인딩)
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

    v_stock_name VARCHAR(100);
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
        -- MANUAL 모드: 관리자 수동 개폐 설정(is_market_open) 준수
        IF v_market_open_check IS NOT NULL AND (NOT v_market_open_check OR v_market_status_code = 'CLOSED') THEN
            v_is_reservation := TRUE;
        ELSE
            v_is_reservation := FALSE;
        END IF;
    END IF;

    -- 1. 종목 단위 배타적 잠금 선점 (종목명 함께 조회)
    SELECT name, market_status, status, current_price, publication_balance, publication_price
    INTO v_stock_name, v_market_status, v_stock_status, v_current_stock_price, v_pub_balance, v_pub_price
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

        -- ⭐️ A안 표기: [매수 주문] 또는 [매수 예약] 종목명 N주
        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_user_id, -v_required_total, v_user_point - v_required_total, 'STOCK_BUY_ESCROW', 
                CASE 
                    WHEN v_is_reservation THEN '[매수 예약] ' || v_stock_name || ' ' || p_amount || '주'
                    ELSE '[매수 주문] ' || v_stock_name || ' ' || p_amount || '주'
                END);

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

    -- 3. 신규 주문 레코드 생성
    INSERT INTO public.orders (user_id, stock_id, order_type, price, amount, remain_amount, status)
    VALUES (v_user_id, p_stock_id, p_order_type, p_price, p_amount, p_amount, 'PENDING')
    RETURNING id INTO v_new_order_id;

    -- 3-1. 장 마감 예약 주문인 경우: 예약 접수 완료 반환
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

            -- ⭐️ A안 표기: [매도 체결] 종목명 N주 정산
            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_match_record.user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_match_record.user_id), 
                    'STOCK_SELL_SETTLEMENT', '[매도 체결] ' || v_stock_name || ' ' || v_trade_qty || '주 정산');

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

                -- ⭐️ A안 표기: [체결 차액] 종목명 환불
                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '[체결 차액] ' || v_stock_name || ' 환불');
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
                        'STOCK_BUY_DIFF_REFUND', '[체결 차액] ' || v_stock_name || ' 공모 우위 환불');
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

            -- ⭐️ A안 표기: [매도 체결] 종목명 N주 정산
            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_user_id, v_trade_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                    'STOCK_SELL_SETTLEMENT', '[매도 체결] ' || v_stock_name || ' ' || v_trade_qty || '주 정산');

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


-- 2. cancel_stock_order 하드닝 (종목명 및 수량 바인딩)
CREATE OR REPLACE FUNCTION public.cancel_stock_order(
    p_order_id BIGINT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_order_record RECORD;
    v_refund_amount BIGINT;
    v_cur_point BIGINT;
    v_stock_name VARCHAR(100);
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

    -- 종목명 조회
    SELECT name INTO v_stock_name
    FROM public.stocks
    WHERE id = v_order_record.stock_id;

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

        -- ⭐️ A안 표기: [주문 취소] 종목명 N주 환불
        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (v_order_record.user_id, v_refund_amount, 
                v_cur_point + v_refund_amount, 
                'STOCK_BUY_CANCEL_REFUND', 
                '[주문 취소] ' || COALESCE(v_stock_name, '주식') || ' ' || v_order_record.remain_amount || '주 환불');

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


-- 3. execute_call_auction 하드닝 (종목명 및 수량 바인딩)
CREATE OR REPLACE FUNCTION public.execute_call_auction(
    p_stock_id BIGINT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_stock RECORD;
    v_cand RECORD;
    v_max_buy INT;
    v_min_sell INT;
    v_cum_buy BIGINT;
    v_cum_sell BIGINT;
    v_exec_vol BIGINT;
    v_imbalance BIGINT;
    v_dist_cur INT;
    
    v_best_price INT;
    v_best_vol BIGINT;
    v_best_imbalance BIGINT;
    v_best_dist INT;
    
    v_buy_ord RECORD;
    v_sell_ord RECORD;
    v_trade_qty INT;
    v_trade_price INT;
    v_trade_total BIGINT;
    v_price_diff BIGINT;
    
    v_stock_trades_count INT;
    v_stock_trades_vol BIGINT;
    
    v_total_matched_stocks INT := 0;
    v_grand_trades_count INT := 0;
    v_grand_volume BIGINT := 0;
    v_results JSONB := '[]'::JSONB;
BEGIN
    FOR v_stock IN 
        SELECT id, name, current_price 
        FROM public.stocks 
        WHERE status = 'LISTED' 
          AND (p_stock_id IS NULL OR id = p_stock_id)
        ORDER BY id
        FOR UPDATE
    LOOP
        v_best_price := NULL;
        v_best_vol := 0;
        v_best_imbalance := 999999999;
        v_best_dist := 999999999;
        v_stock_trades_count := 0;
        v_stock_trades_vol := 0;

        SELECT MAX(price) INTO v_max_buy 
        FROM public.orders 
        WHERE stock_id = v_stock.id 
          AND order_type = 'BUY' 
          AND status IN ('PENDING', 'PARTIAL') 
          AND remain_amount > 0;

        SELECT MIN(price) INTO v_min_sell 
        FROM public.orders 
        WHERE stock_id = v_stock.id 
          AND order_type = 'SELL' 
          AND status IN ('PENDING', 'PARTIAL') 
          AND remain_amount > 0;

        IF v_max_buy IS NOT NULL AND v_min_sell IS NOT NULL AND v_max_buy >= v_min_sell THEN
            FOR v_cand IN 
                SELECT DISTINCT price 
                FROM public.orders 
                WHERE stock_id = v_stock.id 
                  AND status IN ('PENDING', 'PARTIAL') 
                  AND remain_amount > 0 
                  AND price >= v_min_sell 
                  AND price <= v_max_buy
                ORDER BY price ASC
            LOOP
                SELECT COALESCE(SUM(remain_amount), 0) INTO v_cum_buy 
                FROM public.orders 
                WHERE stock_id = v_stock.id 
                  AND order_type = 'BUY' 
                  AND status IN ('PENDING', 'PARTIAL') 
                  AND price >= v_cand.price;

                SELECT COALESCE(SUM(remain_amount), 0) INTO v_cum_sell 
                FROM public.orders 
                WHERE stock_id = v_stock.id 
                  AND order_type = 'SELL' 
                  AND status IN ('PENDING', 'PARTIAL') 
                  AND price <= v_cand.price;

                v_exec_vol := LEAST(v_cum_buy, v_cum_sell);
                v_imbalance := ABS(v_cum_buy - v_cum_sell);
                v_dist_cur := ABS(v_cand.price - v_stock.current_price);

                IF v_exec_vol > v_best_vol THEN
                    v_best_vol := v_exec_vol;
                    v_best_imbalance := v_imbalance;
                    v_best_dist := v_dist_cur;
                    v_best_price := v_cand.price;
                ELSIF v_exec_vol = v_best_vol AND v_exec_vol > 0 THEN
                    IF v_imbalance < v_best_imbalance THEN
                        v_best_imbalance := v_imbalance;
                        v_best_dist := v_dist_cur;
                        v_best_price := v_cand.price;
                    ELSIF v_imbalance = v_best_imbalance THEN
                        IF v_dist_cur < v_best_dist THEN
                            v_best_dist := v_dist_cur;
                            v_best_price := v_cand.price;
                        END IF;
                    END IF;
                END IF;
            END LOOP;
        END IF;

        IF v_best_price IS NOT NULL AND v_best_vol > 0 THEN
            FOR v_buy_ord IN 
                SELECT id, user_id, price, remain_amount 
                FROM public.orders 
                WHERE stock_id = v_stock.id 
                  AND order_type = 'BUY' 
                  AND status IN ('PENDING', 'PARTIAL') 
                  AND price >= v_best_price 
                ORDER BY price DESC, created_at ASC 
                FOR UPDATE
            LOOP
                EXIT WHEN v_best_vol = 0;

                FOR v_sell_ord IN 
                    SELECT id, user_id, price, remain_amount 
                    FROM public.orders 
                    WHERE stock_id = v_stock.id 
                      AND order_type = 'SELL' 
                      AND status IN ('PENDING', 'PARTIAL') 
                      AND price <= v_best_price 
                      AND user_id != v_buy_ord.user_id 
                    ORDER BY price ASC, created_at ASC 
                    FOR UPDATE
                LOOP
                    EXIT WHEN v_buy_ord.remain_amount = 0 OR v_best_vol = 0;

                    v_trade_qty := LEAST(v_buy_ord.remain_amount, v_sell_ord.remain_amount, v_best_vol);
                    IF v_trade_qty <= 0 THEN 
                        CONTINUE; 
                    END IF;

                    v_trade_price := v_best_price;
                    v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

                    INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount, created_at)
                    VALUES (v_stock.id, v_buy_ord.id, v_sell_ord.id, v_buy_ord.user_id, v_sell_ord.user_id, v_trade_price, v_trade_qty, v_trade_total, NOW());

                    UPDATE public.user_holdings
                    SET locked_amount = locked_amount - v_trade_qty,
                        updated_at = NOW()
                    WHERE user_id = v_sell_ord.user_id AND stock_id = v_stock.id;

                    UPDATE public.profiles
                    SET total_point = total_point + v_trade_total,
                        updated_at = NOW()
                    WHERE id = v_sell_ord.user_id;

                    -- ⭐️ A안 표기: [동시호가 매도] 종목명 N주 정산
                    INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                    VALUES (v_sell_ord.user_id, v_trade_total,
                            (SELECT total_point FROM public.profiles WHERE id = v_sell_ord.user_id),
                            'STOCK_SELL_SETTLEMENT', '[동시호가 매도] ' || v_stock.name || ' ' || v_trade_qty || '주 정산');

                    INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
                    VALUES (v_buy_ord.user_id, v_stock.id, v_trade_qty, 0, v_trade_price, v_trade_total)
                    ON CONFLICT (user_id, stock_id) DO UPDATE
                    SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                        amount = user_holdings.amount + EXCLUDED.amount,
                        average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                        updated_at = NOW();

                    IF v_buy_ord.price > v_best_price THEN
                        v_price_diff := (v_buy_ord.price - v_best_price)::BIGINT * v_trade_qty::BIGINT;
                        UPDATE public.profiles
                        SET total_point = total_point + v_price_diff,
                            updated_at = NOW()
                        WHERE id = v_buy_ord.user_id;

                        -- ⭐️ A안 표기: [체결 차액] 종목명 동시호가 환불
                        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                        VALUES (v_buy_ord.user_id, v_price_diff,
                                (SELECT total_point FROM public.profiles WHERE id = v_buy_ord.user_id),
                                'STOCK_BUY_DIFF_REFUND', '[체결 차액] ' || v_stock.name || ' 동시호가 환불');
                    END IF;

                    UPDATE public.orders
                    SET remain_amount = remain_amount - v_trade_qty,
                        status = CASE WHEN remain_amount - v_trade_qty = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                        updated_at = NOW()
                    WHERE id = v_sell_ord.id;

                    v_buy_ord.remain_amount := v_buy_ord.remain_amount - v_trade_qty;
                    UPDATE public.orders
                    SET remain_amount = v_buy_ord.remain_amount,
                        status = CASE WHEN v_buy_ord.remain_amount = 0 THEN 'FILLED' ELSE 'PARTIAL' END,
                        updated_at = NOW()
                    WHERE id = v_buy_ord.id;

                    v_best_vol := v_best_vol - v_trade_qty;
                    v_stock_trades_count := v_stock_trades_count + 1;
                    v_stock_trades_vol := v_stock_trades_vol + v_trade_qty;
                END LOOP;
            END LOOP;

            UPDATE public.stocks 
            SET current_price = v_best_price,
                updated_at = NOW() 
            WHERE id = v_stock.id;

            v_total_matched_stocks := v_total_matched_stocks + 1;
            v_grand_trades_count := v_grand_trades_count + v_stock_trades_count;
            v_grand_volume := v_grand_volume + v_stock_trades_vol;

            v_results := v_results || jsonb_build_object(
                'stock_id', v_stock.id,
                'stock_name', v_stock.name,
                'matched_price', v_best_price,
                'trades_count', v_stock_trades_count,
                'volume', v_stock_trades_vol
            );
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'matched_stocks_count', v_total_matched_stocks,
        'grand_trades_count', v_grand_trades_count,
        'grand_volume', v_grand_volume,
        'details', v_results
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4. admin_delete_student_account 하드닝 (종목명 바인딩)
CREATE OR REPLACE FUNCTION public.admin_delete_student_account(
    p_user_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_admin_id UUID := auth.uid();
    v_student RECORD;
    v_order RECORD;
    v_refund_amount BIGINT;
    v_cancelled_orders_count INT := 0;
    v_stock_name VARCHAR(100);
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '학생 계정 삭제 권한이 없습니다. (관리자 전용)';
    END IF;

    SELECT id, student_id, role, status INTO v_student
    FROM public.profiles WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '존재하지 않는 학생입니다.';
    END IF;

    IF v_student.role IN ('ROLE_ADMIN', 'ROLE_TEACHER') OR v_student.student_id = 'admin' THEN
        RAISE EXCEPTION '관리자 계정은 삭제할 수 없습니다.';
    END IF;

    -- 대기 중인 미체결 주문 취소 및 자산 복원
    FOR v_order IN
        SELECT id, order_type, price, remain_amount, stock_id
        FROM public.orders
        WHERE user_id = p_user_id AND status IN ('PENDING', 'PARTIAL')
        FOR UPDATE
    LOOP
        UPDATE public.orders
        SET status = 'CANCELLED',
            remain_amount = 0,
            cancelled_at = NOW(),
            updated_at = NOW()
        WHERE id = v_order.id;

        IF v_order.order_type = 'BUY' THEN
            v_refund_amount := v_order.price::BIGINT * v_order.remain_amount::BIGINT;
            UPDATE public.profiles
            SET total_point = total_point + v_refund_amount,
                updated_at = NOW()
            WHERE id = p_user_id;

            SELECT name INTO v_stock_name FROM public.stocks WHERE id = v_order.stock_id;

            -- ⭐️ A안 표기: [계정 정리] 종목명 N주 환불
            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (p_user_id, v_refund_amount,
                    (SELECT total_point FROM public.profiles WHERE id = p_user_id),
                    'STOCK_BUY_CANCEL_REFUND', '[계정 정리] ' || COALESCE(v_stock_name, '주식') || ' ' || v_order.remain_amount || '주 환불');
        ELSIF v_order.order_type = 'SELL' THEN
            UPDATE public.user_holdings
            SET amount = amount + v_order.remain_amount,
                locked_amount = locked_amount - v_order.remain_amount,
                updated_at = NOW()
            WHERE user_id = p_user_id AND stock_id = v_order.stock_id;
        END IF;

        v_cancelled_orders_count := v_cancelled_orders_count + 1;
    END LOOP;

    -- 비파괴적 Soft Delete 처리
    UPDATE public.profiles
    SET status = 'DELETED',
        updated_at = NOW()
    WHERE id = p_user_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', '학생 계정이 정상적으로 삭제(비활성화) 처리되었습니다.',
        'user_id', p_user_id,
        'student_id', v_student.student_id,
        'cancelled_orders', v_cancelled_orders_count
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 5. 과거 포인트 변동 내역(point_transactions) A안으로 소급 백필 (Backfill)
DO $$
DECLARE
    r RECORD;
    v_new_desc VARCHAR(255);
BEGIN
    FOR r IN
        SELECT pt.id, pt.user_id, pt.amount, pt.description, pt.created_at, pt.reason_type,
               m_trade.formatted_desc AS trade_desc,
               m_order.formatted_desc AS order_desc,
               m_cancel.formatted_desc AS cancel_desc
        FROM public.point_transactions pt
        LEFT JOIN LATERAL (
            SELECT CASE 
                       WHEN pt.description LIKE '%동시호가%' THEN '[동시호가 매도] ' || s.name || ' ' || ot.amount || '주 정산'
                       ELSE '[매도 체결] ' || s.name || ' ' || ot.amount || '주 정산'
                   END AS formatted_desc
            FROM public.order_trades ot
            JOIN public.stocks s ON s.id = ot.stock_id
            WHERE ot.seller_id = pt.user_id
              AND ot.total_trade_amount = pt.amount
              AND pt.reason_type = 'STOCK_SELL_SETTLEMENT'
              AND ABS(EXTRACT(EPOCH FROM (ot.created_at - pt.created_at))) < 120
            ORDER BY ABS(EXTRACT(EPOCH FROM (ot.created_at - pt.created_at))) ASC
            LIMIT 1
        ) m_trade ON true
        LEFT JOIN LATERAL (
            SELECT CASE 
                       WHEN pt.description LIKE '%예약%' THEN '[매수 예약] ' || s.name || ' ' || o.amount || '주'
                       ELSE '[매수 주문] ' || s.name || ' ' || o.amount || '주'
                   END AS formatted_desc
            FROM public.orders o
            JOIN public.stocks s ON s.id = o.stock_id
            WHERE o.user_id = pt.user_id
              AND o.order_type = 'BUY'
              AND (o.price * o.amount) = ABS(pt.amount)
              AND pt.reason_type = 'STOCK_BUY_ESCROW'
              AND ABS(EXTRACT(EPOCH FROM (o.created_at - pt.created_at))) < 120
            ORDER BY ABS(EXTRACT(EPOCH FROM (o.created_at - pt.created_at))) ASC
            LIMIT 1
        ) m_order ON true
        LEFT JOIN LATERAL (
            SELECT '[주문 취소] ' || s.name || ' ' || o.amount || '주 환불' AS formatted_desc
            FROM public.orders o
            JOIN public.stocks s ON s.id = o.stock_id
            WHERE o.user_id = pt.user_id
              AND o.order_type = 'BUY'
              AND (o.price * o.amount) = pt.amount
              AND pt.reason_type = 'STOCK_BUY_CANCEL_REFUND'
              AND (
                  (o.cancelled_at IS NOT NULL AND ABS(EXTRACT(EPOCH FROM (o.cancelled_at - pt.created_at))) < 120)
                  OR ABS(EXTRACT(EPOCH FROM (o.created_at - pt.created_at))) < 120
              )
            ORDER BY ABS(EXTRACT(EPOCH FROM (COALESCE(o.cancelled_at, o.created_at) - pt.created_at))) ASC
            LIMIT 1
        ) m_cancel ON true
        WHERE pt.description IN (
            '매수 주문 증거금 잠금',
            '장 마감 매수 예약 주문 증거금 잠금',
            '주식 매도 체결 대금 정산',
            '동시호가 단일가 매도 대금 정산',
            '미체결 매수 주문 취소 환불'
        )
    LOOP
        v_new_desc := COALESCE(
            r.trade_desc,
            r.order_desc,
            r.cancel_desc,
            -- 매칭되지 않는 초기 시드 데이터는 일반 A안 표준 태그로 변환
            CASE 
                WHEN r.description = '매수 주문 증거금 잠금' THEN '[매수 주문] 주식 매수 증거금'
                WHEN r.description = '장 마감 매수 예약 주문 증거금 잠금' THEN '[매수 예약] 주식 매수 증거금'
                WHEN r.description = '주식 매도 체결 대금 정산' THEN '[매도 체결] 주식 매도 정산'
                WHEN r.description = '동시호가 단일가 매도 대금 정산' THEN '[동시호가 매도] 주식 매도 정산'
                WHEN r.description = '미체결 매수 주문 취소 환불' THEN '[주문 취소] 주식 주문 환불'
                ELSE r.description
            END
        );

        UPDATE public.point_transactions
        SET description = v_new_desc
        WHERE id = r.id;
    END LOOP;
END $$;
