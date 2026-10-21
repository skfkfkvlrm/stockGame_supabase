-- ==============================================================================
-- 마이그레이션: 1회용 브라우저 세션 기반 채용담당자 독립 샌드박스 (Step 1)
-- 버전: 20261021000023_recruiter_sandbox_session_and_purge.sql
-- 내용:
--   1. handle_new_user(): recruiter_% 임시 계정 가입 시 1,000,000 P 자동 지급
--   2. reset_demo_account(): recruiter_% 계정의 독립 1,000,000 P 리셋 지원
--   3. place_and_match_order(): recruiter_% 계정에 24/7 상시 개장 및 즉시 체결 적용
--   4. purge_expired_recruiter_sessions(): 7일 이상 경과된 임시 게스트 계정 및 데이터 자동 청소
--   5. pg_cron 스케줄 등록: 매일 04:00 KST (19:00 UTC) 자동 청소 실행
-- ==============================================================================

-- 1. 신규 유저 생성 트리거 함수 확장 (recruiter_% 가입 시 100만 P 지급)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_student_id VARCHAR(100);
    v_name VARCHAR(50);
    v_grade INT;
    v_class_name VARCHAR(50);
    v_class_number INT;
    v_role VARCHAR(20);
    v_initial_point BIGINT := 100000;
    v_grant_desc VARCHAR(100) := '회원가입 축하 기초 투자금 지급';
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

    -- 데모 및 채용담당자 임시 샌드박스 계정은 1,000,000 P 지급
    IF v_student_id = 'demo' OR v_student_id LIKE 'recruiter_%' THEN
        v_initial_point := 1000000;
        v_grant_desc := '채용담당자 데모 체험 기초 시드머니 (1,000,000 P)';
    END IF;

    -- 프로필 등록
    INSERT INTO public.profiles (
        id, student_id, name, grade, class_name, class_number, role, total_point, total_coupon, status
    )
    VALUES (
        NEW.id, v_student_id, v_name, v_grade, v_class_name, v_class_number, v_role, v_initial_point, 0, 'ACTIVE'
    )
    ON CONFLICT (id) DO NOTHING;

    -- 초기 기초 투자금 지급 감사 로그
    INSERT INTO public.point_transactions (
        user_id, amount, balance_after, reason_type, description
    )
    VALUES (
        NEW.id, v_initial_point, v_initial_point, 'INITIAL_GRANT', v_grant_desc
    )
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$function$;

-- 2. 데모/채용담당자 계정 자산 초기화 함수 확장 (recruiter_% 지원)
CREATE OR REPLACE FUNCTION public.reset_demo_account(p_target_student_id character varying DEFAULT NULL::character varying)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id UUID := auth.uid();
    v_student_id VARCHAR(100);
    v_prev_point BIGINT := 0;
    v_cleared_orders INT := 0;
    v_cleared_stocks INT := 0;
    v_cleared_coupons INT := 0;
    v_cleared_transactions INT := 0;
BEGIN
    -- 1. 인증 및 대상 사용자 식별
    IF v_user_id IS NULL THEN
        IF auth.role() = 'service_role' OR current_user IN ('postgres', 'supabase_admin') THEN
            IF p_target_student_id IS NOT NULL THEN
                SELECT id, student_id, total_point 
                INTO v_user_id, v_student_id, v_prev_point
                FROM public.profiles
                WHERE student_id = p_target_student_id;
            ELSE
                SELECT id, student_id, total_point 
                INTO v_user_id, v_student_id, v_prev_point
                FROM public.profiles
                WHERE student_id = 'demo';
            END IF;
        ELSE
            RAISE EXCEPTION '로그인이 필요합니다.';
        END IF;
    ELSE
        IF (public.is_admin() OR current_user IN ('postgres', 'supabase_admin')) AND p_target_student_id IS NOT NULL THEN
            SELECT id, student_id, total_point 
            INTO v_user_id, v_student_id, v_prev_point
            FROM public.profiles
            WHERE student_id = p_target_student_id;
        ELSE
            SELECT student_id, total_point 
            INTO v_student_id, v_prev_point
            FROM public.profiles
            WHERE id = v_user_id;
        END IF;
    END IF;

    IF v_user_id IS NULL OR v_student_id IS NULL THEN
        RAISE EXCEPTION '사용자 프로필을 찾을 수 없습니다.';
    END IF;

    -- [보안 가드 1] 대상 계정 엄격 제한: demo 또는 recruiter_% 계정만 허용
    IF v_student_id NOT IN ('demo', 'recruiter') AND v_student_id NOT LIKE 'recruiter_%' THEN
        RAISE EXCEPTION '데모 체험 전용 기능입니다. 일반 학생 계정은 초기화할 수 없습니다.';
    END IF;

    -- [보안 가드 2] 호출자 권한 검증
    IF auth.uid() IS NOT NULL AND auth.uid() != v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION '권한이 없습니다.';
    END IF;

    -- 2. 미체결 주문 전량 취소 처리
    WITH cancelled_rows AS (
        UPDATE public.orders
        SET status = 'CANCELLED',
            remain_amount = 0,
            cancelled_at = NOW(),
            updated_at = NOW()
        WHERE user_id = v_user_id
          AND status IN ('PENDING', 'PARTIAL')
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_orders FROM cancelled_rows;

    -- 3. 보유 주식 잔고 전량 초기화
    WITH deleted_stocks AS (
        DELETE FROM public.user_holdings
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_stocks FROM deleted_stocks;

    -- 4. 보유 쿠폰 잔량 전량 초기화
    WITH deleted_coupons AS (
        DELETE FROM public.user_coupons
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_coupons FROM deleted_coupons;

    -- 5. 프로필 예수금 1,000,000 P 복구
    UPDATE public.profiles
    SET total_point = 1000000,
        total_coupon = 0,
        status = 'ACTIVE',
        updated_at = NOW()
    WHERE id = v_user_id;

    -- 6. 과거 포인트 변동 내역 전량 소거
    WITH deleted_tx AS (
        DELETE FROM public.point_transactions
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_transactions FROM deleted_tx;

    -- 7. 신규 기초 시드머니 단일 원장 등록
    INSERT INTO public.point_transactions (
        user_id, amount, balance_after, reason_type, description, created_at
    ) VALUES (
        v_user_id,
        1000000,
        1000000,
        'INITIAL_GRANT',
        '채용담당자 데모 체험 기초 시드머니 (1,000,000 P)',
        NOW()
    );

    RETURN jsonb_build_object(
        'success', true,
        'userId', v_user_id,
        'studentId', v_student_id,
        'totalPoint', 1000000,
        'clearedOrders', v_cleared_orders,
        'clearedStocks', v_cleared_stocks,
        'clearedCoupons', v_cleared_coupons,
        'clearedTransactions', v_cleared_transactions,
        'resetAt', NOW()
    );
END;
$function$;

-- 3. place_and_match_order 데모 판별 조건에 recruiter_% 확장
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
    v_is_demo BOOLEAN := FALSE;
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

    -- 0-1. 데모 및 채용담당자 임시 계정 판별 (student_id = 'demo' OR student_id LIKE 'recruiter_%' OR 고정 UUID)
    SELECT (student_id = 'demo' OR student_id LIKE 'recruiter_%' OR id = '00000000-0000-0000-0000-000000000002'::UUID)
    INTO v_is_demo
    FROM public.profiles
    WHERE id = v_user_id;

    -- 0-2. 시장 운영 상태 검증 (데모/채용담당자 계정은 시간표 및 시장 마감 제한 전면 바이패스)
    IF v_is_demo IS TRUE THEN
        v_is_reservation := FALSE;
    ELSE
        SELECT is_market_open, mode, open_time, close_time, call_auction_start_time, status_code
        INTO v_market_open_check, v_market_mode, v_open_time, v_close_time, v_call_auction_start_time, v_market_status_code
        FROM public.market_settings WHERE id = 1;

        IF v_market_status_code = 'MANUAL_PAUSE' THEN
            RAISE EXCEPTION '현재 시스템 긴급 점검 중이므로 주문을 접수할 수 없습니다.';
        END IF;

        IF COALESCE(v_market_mode, 'AUTO') = 'AUTO' THEN
            v_kst_now := (NOW() AT TIME ZONE 'Asia/Seoul');
            v_kst_day := EXTRACT(DOW FROM v_kst_now);
            v_kst_hhmm := TO_CHAR(v_kst_now, 'HH24:MI');

            IF v_kst_day IN (0, 6) OR v_kst_hhmm < COALESCE(v_open_time, '09:00') OR v_kst_hhmm >= COALESCE(v_close_time, '15:30') THEN
                v_is_reservation := TRUE;
            ELSIF v_kst_hhmm >= COALESCE(v_call_auction_start_time, '15:20') AND v_kst_hhmm < COALESCE(v_close_time, '15:30') THEN
                v_is_reservation := TRUE;
            ELSE
                v_is_reservation := FALSE;
            END IF;
        ELSE
            IF v_market_open_check IS NOT NULL AND (NOT v_market_open_check OR v_market_status_code = 'CLOSED') THEN
                v_is_reservation := TRUE;
            ELSE
                v_is_reservation := FALSE;
            END IF;
        END IF;
    END IF;

    -- 1. 종목 단위 배타적 잠금 선점
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

    IF NOT v_is_demo AND NOT v_is_reservation AND v_market_status NOT IN ('OPEN', 'CONTINUOUS') THEN
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

        UPDATE public.profiles
        SET total_point = total_point - v_required_total,
            updated_at = NOW()
        WHERE id = v_user_id;

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

    -- 3-1. 장 마감 예약 주문인 경우
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

    -- 4. 정규장 실시간 연속 매매 반대 호가 매칭 루프
    IF p_order_type = 'BUY' THEN
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

            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, v_new_order_id, v_match_record.id, v_user_id, v_match_record.user_id, v_trade_price, v_trade_qty, v_trade_total);

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
                    'STOCK_SELL_SETTLEMENT', '[매도 체결] ' || v_stock_name || ' ' || v_trade_qty || '주 정산');

            INSERT INTO public.user_holdings (user_id, stock_id, amount, locked_amount, average_price, total_invested_amount)
            VALUES (v_user_id, p_stock_id, v_trade_qty, 0, v_trade_price, v_trade_total)
            ON CONFLICT (user_id, stock_id) DO UPDATE
            SET total_invested_amount = user_holdings.total_invested_amount + EXCLUDED.total_invested_amount,
                amount = user_holdings.amount + EXCLUDED.amount,
                average_price = (user_holdings.total_invested_amount + EXCLUDED.total_invested_amount) / (user_holdings.amount + EXCLUDED.amount),
                updated_at = NOW();

            IF p_price > v_trade_price THEN
                v_price_diff_refund := (p_price - v_trade_price)::BIGINT * v_trade_qty::BIGINT;
                UPDATE public.profiles
                SET total_point = total_point + v_price_diff_refund,
                    updated_at = NOW()
                WHERE id = v_user_id;

                INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                VALUES (v_user_id, v_price_diff_refund, 
                        (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                        'STOCK_BUY_DIFF_REFUND', '[체결 차액] ' || v_stock_name || ' 환불');
            END IF;

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

        -- 4-D. 데모 및 채용담당자 계정 야간/주말 매도 유동성 즉시 지원
        IF v_is_demo IS TRUE AND v_remain_qty > 0 THEN
            v_lp_qty := v_remain_qty;
            v_lp_price := p_price;
            v_lp_total := v_lp_price::BIGINT * v_lp_qty::BIGINT;

            UPDATE public.stocks
            SET publication_balance = publication_balance + v_lp_qty,
                current_price = v_lp_price,
                updated_at = NOW()
            WHERE id = p_stock_id;

            INSERT INTO public.order_trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, amount, total_trade_amount)
            VALUES (p_stock_id, NULL, v_new_order_id, NULL, v_user_id, v_lp_price, v_lp_qty, v_lp_total);

            UPDATE public.user_holdings
            SET locked_amount = locked_amount - v_lp_qty,
                updated_at = NOW()
            WHERE user_id = v_user_id AND stock_id = p_stock_id;

            UPDATE public.profiles
            SET total_point = total_point + v_lp_total,
                updated_at = NOW()
            WHERE id = v_user_id;

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (v_user_id, v_lp_total, 
                    (SELECT total_point FROM public.profiles WHERE id = v_user_id), 
                    'STOCK_SELL_SETTLEMENT', '[매도 체결] ' || v_stock_name || ' ' || v_lp_qty || '주 정산');

            v_remain_qty := 0;
        END IF;
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
        'remain_amount', v_remain_qty,
        'message', CASE 
                     WHEN v_is_demo THEN '데모 24시간 상시 개장 모드로 주문이 즉시 체결 및 반영되었습니다.'
                     ELSE '주문이 접수되었습니다.'
                   END
    );
END;
$function$;

-- 4. 만료된 채용담당자 임시 세션 자동 청소 프로시저 (기본 7일)
CREATE OR REPLACE FUNCTION public.purge_expired_recruiter_sessions(
    p_interval INTERVAL DEFAULT INTERVAL '7 days'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_purged_count INT := 0;
BEGIN
    WITH target_users AS (
        SELECT id
        FROM public.profiles
        WHERE student_id LIKE 'recruiter_%'
          AND created_at < NOW() - p_interval
    )
    DELETE FROM auth.users
    WHERE id IN (SELECT id FROM target_users);

    GET DIAGNOSTICS v_purged_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'purged_count', v_purged_count,
        'purged_at', NOW()
    );
END;
$$;

-- 5. pg_cron 만료 세션 자동 청소 스케줄 등록 (매일 04:00 KST = 19:00 UTC)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge-expired-recruiter-sessions-job') THEN
        PERFORM cron.unschedule('purge-expired-recruiter-sessions-job');
    END IF;

    PERFORM cron.schedule(
        'purge-expired-recruiter-sessions-job',
        '0 19 * * *',
        'SELECT public.purge_expired_recruiter_sessions(INTERVAL ''7 days'');'
    );
END $$;


-- 6. 데모/채용담당자 원터치 포인트 충전 함수 확장 (recruiter_% 지원)
CREATE OR REPLACE FUNCTION public.recharge_demo_points(p_amount bigint DEFAULT 1000000)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id UUID := auth.uid();
    v_student_id VARCHAR(100);
    v_current_point BIGINT;
    v_new_point BIGINT;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 10000000 THEN
        RAISE EXCEPTION '1회 충전 가능 금액은 1 P 이상 10,000,000 P 이하여야 합니다.';
    END IF;

    SELECT student_id, total_point
    INTO v_student_id, v_current_point
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF v_student_id IS NULL THEN
        RAISE EXCEPTION '사용자 프로필을 찾을 수 없습니다.';
    END IF;

    IF v_student_id NOT IN ('demo', 'recruiter') AND v_student_id NOT LIKE 'recruiter_%' AND NOT public.is_admin() THEN
        RAISE EXCEPTION '데모 체험 전용 기능입니다. 일반 학생 계정은 사용할 수 없습니다.';
    END IF;

    IF (v_current_point + p_amount) > 100000000 THEN
        RAISE EXCEPTION '데모 계정 최대 보유 한도(100,000,000 P)를 초과할 수 없습니다. (현재 잔액: % P)', v_current_point;
    END IF;

    v_new_point := v_current_point + p_amount;

    UPDATE public.profiles
    SET total_point = v_new_point,
        updated_at = NOW()
    WHERE id = v_user_id;

    INSERT INTO public.point_transactions (
        user_id, amount, balance_after, reason_type, description
    ) VALUES (
        v_user_id,
        p_amount,
        v_new_point,
        'DEMO_RECHARGE',
        '채용담당자 데모 원터치 포인트 충전 (+' || trim(to_char(p_amount, '999,999,999')) || ' P)'
    );

    RETURN jsonb_build_object(
        'success', true,
        'userId', v_user_id,
        'studentId', v_student_id,
        'rechargedAmount', p_amount,
        'totalPoint', v_new_point
    );
END;
$function$;
