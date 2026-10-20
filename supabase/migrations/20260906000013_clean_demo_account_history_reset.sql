-- ==============================================================================
-- Migration: 20260906000013_clean_demo_account_history_reset.sql
-- Description: 채용담당자 데모 계정 초기화 시 자산 변동 이력(point_transactions) 및 시계열 차트 완전 초기화
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.reset_demo_account(
    p_target_student_id VARCHAR(100) DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
        -- service_role 또는 postgres 관리자 직접 호출 시 target_student_id 기반 실행 허용
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
        -- 관리자(ROLE_ADMIN, ROLE_TEACHER)가 특정 데모 계정을 지정하여 리셋하는 경우
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

    -- 프로필 유효성 검증
    IF v_user_id IS NULL OR v_student_id IS NULL THEN
        RAISE EXCEPTION '사용자 프로필을 찾을 수 없습니다.';
    END IF;

    -- [보안 가드 1] 대상 계정 엄격 제한: 대상 계정은 반드시 demo 또는 recruiter 계정이어야 함 (일반 학생 초기화 원천 차단)
    IF v_student_id NOT IN ('demo', 'recruiter') THEN
        RAISE EXCEPTION '데모 체험 전용 기능입니다. 일반 학생 계정은 초기화할 수 없습니다.';
    END IF;

    -- [보안 가드 2] 호출자 권한 검증: 본인 계정이거나 관리자/service_role이어야 함
    IF auth.uid() IS NOT NULL AND auth.uid() != v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION '권한이 없습니다.';
    END IF;

    -- 2. 미체결 주문 전량 취소 처리 (호가창 왜곡 및 주문 잠금 방지)
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

    -- 3. 보유 주식 잔고 전량 초기화 (user_holdings)
    WITH deleted_stocks AS (
        DELETE FROM public.user_holdings
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_stocks FROM deleted_stocks;

    -- 4. 보유 쿠폰 잔량 전량 초기화 (user_coupons)
    WITH deleted_coupons AS (
        DELETE FROM public.user_coupons
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_coupons FROM deleted_coupons;

    -- 5. 프로필 예수금 1,000,000 P 및 쿠폰 0건 복구
    UPDATE public.profiles
    SET total_point = 1000000,
        total_coupon = 0,
        status = 'ACTIVE',
        updated_at = NOW()
    WHERE id = v_user_id;

    -- 6. 과거 포인트 변동 내역 전량 소거 (자산 추이 그래프 및 전일/전월 대비 지표 클린 리셋)
    WITH deleted_tx AS (
        DELETE FROM public.point_transactions
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_transactions FROM deleted_tx;

    -- 7. 신규 기초 시드머니 단일 원장 등록 (깨끗한 1,000,000 P 시작점 형성)
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
$$;

-- 실행 권한 부여
GRANT EXECUTE ON FUNCTION public.reset_demo_account(VARCHAR) TO authenticated, service_role;
