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
