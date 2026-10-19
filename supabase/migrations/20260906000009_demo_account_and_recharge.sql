-- ========================================================
-- Migration: 20260906000009_demo_account_and_recharge.sql
-- Description: Recruiter 1-Click Demo Account Seed & One-Touch Point Recharge RPC
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. 채용담당자 전용 학생 데모 계정 시딩 (demo / 1234, 초기 예수금 1,000,000 P)
DO $$
DECLARE
    v_demo_id UUID;
BEGIN
    -- 기존 demo 계정이 있는지 먼저 조회
    SELECT id INTO v_demo_id
    FROM auth.users
    WHERE email IN ('demo@skfkfkvlrm.kr', 'demo@stockgame.local')
    LIMIT 1;

    IF v_demo_id IS NULL THEN
        v_demo_id := '00000000-0000-0000-0000-000000000002';

        INSERT INTO auth.users (
            id, instance_id, email, encrypted_password, email_confirmed_at,
            confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current,
            phone_change, phone_change_token, reauthentication_token,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at, role, aud
        ) VALUES (
            v_demo_id,
            '00000000-0000-0000-0000-000000000000',
            'demo@skfkfkvlrm.kr',
            crypt('1234', gen_salt('bf')),
            NOW(),
            '', '', '', '', '',
            '', '', '',
            '{"provider":"email","providers":["email"]}',
            '{"role":"ROLE_STUDENT","student_id":"demo","studentId":"demo","name":"채용담당자(데모)","grade":3,"class_name":"1반","className":"1반","class_number":99,"classNumber":99,"email_verified":true,"phone_verified":false}',
            NOW(), NOW(),
            'authenticated', 'authenticated'
        );
    END IF;

    -- GoTrue 호환성을 위한 auth.identities 보장
    IF NOT EXISTS (
        SELECT 1 FROM auth.identities WHERE user_id = v_demo_id AND provider = 'email'
    ) THEN
        INSERT INTO auth.identities (
            id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
        ) VALUES (
            v_demo_id,
            v_demo_id,
            v_demo_id::TEXT,
            jsonb_build_object(
                'sub', v_demo_id::TEXT,
                'email', 'demo@skfkfkvlrm.kr',
                'name', '채용담당자(데모)',
                'role', 'ROLE_STUDENT',
                'student_id', 'demo',
                'studentId', 'demo',
                'grade', 3,
                'class_name', '1반',
                'className', '1반',
                'class_number', 99,
                'classNumber', 99,
                'email_verified', true,
                'phone_verified', false
            ),
            'email',
            NOW(), NOW(), NOW()
        );
    END IF;

    -- 프로필 확인 및 데모 초기 포인트(1,000,000 P) 보정
    INSERT INTO public.profiles (
        id, student_id, name, grade, class_name, class_number, role, total_point, total_coupon, status
    ) VALUES (
        v_demo_id, 'demo', '채용담당자(데모)', 3, '1반', 99, 'ROLE_STUDENT', 1000000, 0, 'ACTIVE'
    )
    ON CONFLICT (id) DO UPDATE
    SET student_id = 'demo',
        name = '채용담당자(데모)',
        grade = 3,
        class_name = '1반',
        class_number = 99,
        role = 'ROLE_STUDENT',
        total_point = GREATEST(public.profiles.total_point, 1000000),
        status = 'ACTIVE',
        updated_at = NOW();

    -- 트리거 기본 지급(100,000 P) 이후 데모 추가 시드머니(+900,000 P) 이력이 없으면 원장에 기록
    IF NOT EXISTS (
        SELECT 1 FROM public.point_transactions
        WHERE user_id = v_demo_id AND reason_type = 'DEMO_RECHARGE'
    ) THEN
        INSERT INTO public.point_transactions (
            user_id, amount, balance_after, reason_type, description
        ) VALUES (
            v_demo_id, 900000, 1000000, 'DEMO_RECHARGE', '채용담당자 데모 계정 전용 추가 시드머니 지급 (+900,000 P)'
        );
    END IF;
END $$;

-- 2. 데모 계정 전용 원터치 포인트 충전 RPC 함수 (RLS 우회 SECURITY DEFINER)
CREATE OR REPLACE FUNCTION public.recharge_demo_points(
    p_amount BIGINT DEFAULT 1000000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_student_id VARCHAR(100);
    v_current_point BIGINT;
    v_new_point BIGINT;
BEGIN
    -- 1. 인증 여부 확인
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 2. 충전 요청 금액 유효성 검증 (1 P ~ 10,000,000 P)
    IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 10000000 THEN
        RAISE EXCEPTION '1회 충전 가능 금액은 1 P 이상 10,000,000 P 이하여야 합니다.';
    END IF;

    -- 3. 대상 프로필 배타 잠금(FOR UPDATE) 조회
    SELECT student_id, total_point
    INTO v_student_id, v_current_point
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF v_student_id IS NULL THEN
        RAISE EXCEPTION '사용자 프로필을 찾을 수 없습니다.';
    END IF;

    -- 4. 데모 계정(demo, recruiter) 또는 관리자만 원터치 충전 허용 (일반 학생 악용 원천 차단)
    IF v_student_id NOT IN ('demo', 'recruiter') AND NOT public.is_admin() THEN
        RAISE EXCEPTION '데모 체험 전용 기능입니다. 일반 학생 계정은 사용할 수 없습니다.';
    END IF;

    -- 5. 데모 계정 최대 보유 한도(1억 P) 가드
    IF (v_current_point + p_amount) > 100000000 THEN
        RAISE EXCEPTION '데모 계정 최대 보유 한도(100,000,000 P)를 초과할 수 없습니다. (현재 잔액: % P)', v_current_point;
    END IF;

    v_new_point := v_current_point + p_amount;

    -- 6. 포인트 잔액 업데이트
    UPDATE public.profiles
    SET total_point = v_new_point,
        updated_at = NOW()
    WHERE id = v_user_id;

    -- 7. 포인트 변동 원장(point_transactions) 기록
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
$$;

GRANT EXECUTE ON FUNCTION public.recharge_demo_points(BIGINT) TO authenticated;
