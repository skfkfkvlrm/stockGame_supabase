-- ========================================================
-- Migration: 20261020000015_demo_session_rollback_and_full_sync.sql
-- Description: Demo Session Logical Rollback, Soft Delete & Full Dual-Backend Sync
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- Projects: stockGame_supabase (Remote ID: ulgbshgzwmnytejfutsb)
-- ========================================================

-- 1. 학생 계정 비파괴적 Soft Delete 재정의 (admin_delete_student)
-- 물리 삭제(DELETE FROM profiles/auth.users)를 전면 배제하고, 미체결 주문 취소/환불 후 status = 'DELETED' 전환
CREATE OR REPLACE FUNCTION public.admin_delete_student(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_order RECORD;
    v_student RECORD;
    v_refund_amount BIGINT;
    v_cancelled_orders_count INT := 0;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    SELECT id, student_id, role, status INTO v_student
    FROM public.profiles WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '존재하지 않는 학생입니다.';
    END IF;

    IF v_student.role IN ('ROLE_ADMIN', 'ROLE_TEACHER') OR v_student.student_id = 'admin' THEN
        RAISE EXCEPTION '관리자 계정은 삭제할 수 없습니다.';
    END IF;

    -- 대기 중인 미체결 주문 취소 및 자산 복원 (호가창 왜곡 방지 및 잠금 해제)
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

            INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
            VALUES (p_user_id, v_refund_amount,
                    (SELECT total_point FROM public.profiles WHERE id = p_user_id),
                    'STOCK_BUY_CANCEL_REFUND', '계정 삭제 처리에 따른 미체결 매수 주문 취소 환불');
        ELSIF v_order.order_type = 'SELL' THEN
            UPDATE public.user_holdings
            SET amount = amount + v_order.remain_amount,
                locked_amount = locked_amount - v_order.remain_amount,
                updated_at = NOW()
            WHERE user_id = p_user_id AND stock_id = v_order.stock_id;
        END IF;

        v_cancelled_orders_count := v_cancelled_orders_count + 1;
    END LOOP;

    -- 비파괴적 Soft Delete 처리 (보유 주식, 체결 내역, 포인트 무손실 보존)
    UPDATE public.profiles
    SET status = 'DELETED',
        updated_at = NOW()
    WHERE id = p_user_id;

    RETURN jsonb_build_object(
        'success', true,
        'deletedUserId', p_user_id,
        'studentId', v_student.student_id,
        'cancelledOrdersCount', v_cancelled_orders_count,
        'status', 'DELETED'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 2. 관리자 데모 세션 롤백 RPC 신설 (rollback_admin_demo_session)
-- 관리자 로그아웃 시 세션 중 변경된 데이터(학생 삭제, 종목 상폐, 쿠폰 삭제, 관리자 포인트 강제 조정, 시장 폐장)를 안전하게 원상복구
CREATE OR REPLACE FUNCTION public.rollback_admin_demo_session()
RETURNS JSONB AS $$
DECLARE
    v_restored_students INT := 0;
    v_restored_stocks INT := 0;
    v_restored_coupons INT := 0;
    v_reversed_adjustments INT := 0;
    r RECORD;
BEGIN
    IF NOT public.is_admin() AND current_user NOT IN ('postgres', 'supabase_admin') AND auth.role() != 'service_role' THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    -- 2-1. Soft Delete 된 학생 계정 전체 ACTIVE 복원 (보유 주식과 포인트가 그대로 보존되어 즉시 정상화)
    WITH restored_st AS (
        UPDATE public.profiles
        SET status = 'ACTIVE', updated_at = NOW()
        WHERE status = 'DELETED'
        RETURNING id
    )
    SELECT COUNT(*) INTO v_restored_students FROM restored_st;

    -- 2-2. 기본 시드 종목 22종 상태 복원 (LISTED / CONTINUOUS) - 체결된 현재가는 보존
    WITH restored_sk AS (
        UPDATE public.stocks
        SET status = 'LISTED',
            market_status = 'CONTINUOUS',
            updated_at = NOW()
        WHERE id IN (1,2,3,4,5,6,7,8,9,10,11,12,13,14,16,17,18,19,20,21,22)
          AND (status != 'LISTED' OR market_status != 'CONTINUOUS')
        RETURNING id
    )
    SELECT COUNT(*) INTO v_restored_stocks FROM restored_sk;

    -- 2-3. 기본 시드 쿠폰 5종 판매 상태 복원 (ON_SALE)
    WITH restored_cp AS (
        UPDATE public.coupons
        SET status = 'ON_SALE', updated_at = NOW()
        WHERE id IN (1, 2, 3, 30, 31) AND status != 'ON_SALE'
        RETURNING id
    )
    SELECT COUNT(*) INTO v_restored_coupons FROM restored_cp;

    -- 2-4. 관리자 수동 포인트 강제 조정분 정밀 역산 롤백 (순 조정액이 0이 아닌 학생만, 멱등성 보장)
    FOR r IN
        SELECT user_id, SUM(amount) AS net_adj
        FROM public.point_transactions
        WHERE reason_type IN ('ADMIN_GRANT', 'ADMIN_DEDUCT', 'ADMIN_ROLLBACK')
           OR description LIKE '관리자%'
        GROUP BY user_id
        HAVING SUM(amount) != 0
    LOOP
        UPDATE public.profiles
        SET total_point = GREATEST(0, total_point - r.net_adj),
            updated_at = NOW()
        WHERE id = r.user_id;

        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
        VALUES (
            r.user_id,
            -r.net_adj,
            (SELECT total_point FROM public.profiles WHERE id = r.user_id),
            'ADMIN_ROLLBACK',
            '관리자 데모 세션 종료에 따른 포인트 수동 조정분 원상복구 역산'
        );

        v_reversed_adjustments := v_reversed_adjustments + 1;
    END LOOP;

    -- 2-5. 시장 운영 설정 복원 (자동 개장 및 정상 영업 상태)
    UPDATE public.market_settings
    SET mode = 'AUTO',
        is_market_open = true,
        status_code = 'OPEN',
        updated_at = NOW()
    WHERE id = 1;

    RETURN jsonb_build_object(
        'success', true,
        'restoredStudents', v_restored_students,
        'restoredStocks', v_restored_stocks,
        'restoredCoupons', v_restored_coupons,
        'reversedPointAdjustments', v_reversed_adjustments,
        'rolledBackAt', NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 3. 학생 데모 계정 리셋 RPC 최신화 (reset_demo_account)
-- demo 및 recruiter 전용, status = 'ACTIVE' 복구 및 타 계정 체결/자산 데이터 침해 Zero 보장
CREATE OR REPLACE FUNCTION public.reset_demo_account(
    p_target_student_id VARCHAR DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_student_id VARCHAR(100);
    v_prev_point BIGINT := 0;
    v_cleared_orders INT := 0;
    v_cleared_stocks INT := 0;
    v_cleared_coupons INT := 0;
    v_cleared_transactions INT := 0;
BEGIN
    -- 인증 및 대상 사용자 식별
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

    -- [보안 가드 1] demo 또는 recruiter 계정만 리셋 허용
    IF v_student_id NOT IN ('demo', 'recruiter') THEN
        RAISE EXCEPTION '데모 체험 전용 기능입니다. 일반 학생 계정은 초기화할 수 없습니다.';
    END IF;

    -- [보안 가드 2] 호출자 권한 검증
    IF auth.uid() IS NOT NULL AND auth.uid() != v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION '권한이 없습니다.';
    END IF;

    -- 미체결 주문 취소
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

    -- 보유 주식 초기화 (demo 본인 계정만)
    WITH deleted_stocks AS (
        DELETE FROM public.user_holdings
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_stocks FROM deleted_stocks;

    -- 보유 쿠폰 초기화 (demo 본인 계정만)
    WITH deleted_coupons AS (
        DELETE FROM public.user_coupons
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_coupons FROM deleted_coupons;

    -- 프로필 예수금 1,000,000 P 및 status = 'ACTIVE' 복구
    UPDATE public.profiles
    SET total_point = 1000000,
        total_coupon = 0,
        status = 'ACTIVE',
        updated_at = NOW()
    WHERE id = v_user_id;

    -- 과거 포인트 거래 내역 소거
    WITH deleted_tx AS (
        DELETE FROM public.point_transactions
        WHERE user_id = v_user_id
        RETURNING id
    )
    SELECT COUNT(*) INTO v_cleared_transactions FROM deleted_tx;

    -- 기초 시드머니 원장 단일 등록
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
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4. 원격 배포 RPC 5종 로컬 Git 마이그레이션 정식 수록 (Git 형상 관리 동기화)

-- 4-1. 상점 쿠폰 구매 (buy_coupon)
CREATE OR REPLACE FUNCTION public.buy_coupon(p_coupon_id BIGINT)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_points BIGINT;
    v_name VARCHAR(100);
    v_price INT;
    v_status VARCHAR(20);
    v_purchase_id BIGINT;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 1. 쿠폰 정보 조회
    SELECT name, price, status INTO v_name, v_price, v_status
    FROM public.coupons
    WHERE id = p_coupon_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '존재하지 않는 쿠폰입니다.';
    END IF;

    IF v_status != 'ON_SALE' THEN
        RAISE EXCEPTION '현재 판매 중이 아닌 쿠폰입니다.';
    END IF;

    -- 2. 사용자 잔고 비관적 락(FOR UPDATE)
    SELECT total_point INTO v_points
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF v_points < v_price THEN
        RAISE EXCEPTION '보유 포인트가 부족합니다. (필요: % P, 보유: % P)', v_price, v_points;
    END IF;

    -- 3. 포인트 차감 및 프로필 쿠폰 수 갱신
    UPDATE public.profiles
    SET total_point = total_point - v_price,
        total_coupon = total_coupon + 1,
        updated_at = NOW()
    WHERE id = v_user_id;

    -- 4. 학생 보유 쿠폰함에 추가
    INSERT INTO public.user_coupons (user_id, coupon_id, name, purchase_price, status, created_at)
    VALUES (v_user_id, p_coupon_id, v_name, v_price, 'UNUSED', NOW())
    RETURNING id INTO v_purchase_id;

    -- 5. 포인트 변동 감사 이력 기록
    INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
    VALUES (v_user_id, -v_price, v_points - v_price, 'COUPON_PURCHASE', '상점 쿠폰 구매: ' || v_name);

    RETURN jsonb_build_object(
        'success', true,
        'message', v_name || ' 쿠폰을 성공적으로 구매했습니다!',
        'purchaseId', v_purchase_id,
        'remainingPoint', v_points - v_price
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4-2. 보유 쿠폰 사용 처리 (use_coupon)
CREATE OR REPLACE FUNCTION public.use_coupon(p_purchase_id BIGINT)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_name VARCHAR(100);
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    UPDATE public.user_coupons
    SET status = 'USED',
        used_at = NOW()
    WHERE id = p_purchase_id AND user_id = v_user_id AND status = 'UNUSED'
    RETURNING name INTO v_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION '사용 가능한 쿠폰을 찾을 수 없거나 이미 사용 처리된 쿠폰입니다.';
    END IF;

    -- 프로필 내 미사용 쿠폰 수 차감
    UPDATE public.profiles
    SET total_coupon = GREATEST(0, total_coupon - 1),
        updated_at = NOW()
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', v_name || ' 쿠폰 사용 처리가 완료되었습니다.'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4-3. 전교생 랭킹 산정 (get_student_rankings) - 총 순자산(현금 + 주식평가액) 기준 정렬
CREATE OR REPLACE FUNCTION public.get_student_rankings()
RETURNS TABLE(
    id UUID,
    rank BIGINT,
    student_id TEXT,
    name TEXT,
    grade INT,
    class_name TEXT,
    class_number INT,
    total_point BIGINT,
    total_asset BIGINT,
    total_coupon INT
) AS $$
BEGIN
    RETURN QUERY
    WITH stock_eval AS (
        SELECT 
            uh.user_id,
            COALESCE(SUM((uh.amount + uh.locked_amount) * s.current_price), 0)::BIGINT AS eval_total
        FROM public.user_holdings uh
        JOIN public.stocks s ON uh.stock_id = s.id
        GROUP BY uh.user_id
    )
    SELECT 
        p.id,
        ROW_NUMBER() OVER (ORDER BY (p.total_point + COALESCE(se.eval_total, 0)) DESC, p.student_id ASC) AS rank,
        p.student_id::TEXT,
        p.name::TEXT,
        p.grade,
        p.class_name::TEXT,
        p.class_number,
        p.total_point::BIGINT,
        (p.total_point + COALESCE(se.eval_total, 0))::BIGINT AS total_asset,
        p.total_coupon
    FROM public.profiles p
    LEFT JOIN stock_eval se ON p.id = se.user_id
    WHERE p.role = 'ROLE_STUDENT' 
      AND p.status = 'ACTIVE'
      AND p.student_id NOT ILIKE '%test%'
      AND p.name NOT ILIKE '%테스트%'
      AND p.name NOT ILIKE '%검증%'
    ORDER BY rank ASC
    LIMIT 100;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4-4. 장마감/장개시 동시호가 단일가 일괄 매칭 체결 (execute_call_auction)
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

        IF v_max_buy IS NULL OR v_min_sell IS NULL OR v_max_buy < v_min_sell THEN
            CONTINUE;
        END IF;

        FOR v_cand IN
            SELECT DISTINCT price AS cand_price
            FROM public.orders
            WHERE stock_id = v_stock.id
              AND status IN ('PENDING', 'PARTIAL')
              AND remain_amount > 0
              AND price BETWEEN v_min_sell AND v_max_buy
            ORDER BY cand_price ASC
        LOOP
            SELECT COALESCE(SUM(remain_amount), 0) INTO v_cum_buy
            FROM public.orders
            WHERE stock_id = v_stock.id
              AND order_type = 'BUY'
              AND status IN ('PENDING', 'PARTIAL')
              AND remain_amount > 0
              AND price >= v_cand.cand_price;

            SELECT COALESCE(SUM(remain_amount), 0) INTO v_cum_sell
            FROM public.orders
            WHERE stock_id = v_stock.id
              AND order_type = 'SELL'
              AND status IN ('PENDING', 'PARTIAL')
              AND remain_amount > 0
              AND price <= v_cand.cand_price;

            v_exec_vol := LEAST(v_cum_buy, v_cum_sell);
            v_imbalance := ABS(v_cum_buy - v_cum_sell);
            v_dist_cur := ABS(v_cand.cand_price - v_stock.current_price);

            IF v_best_price IS NULL
               OR v_exec_vol > v_best_vol
               OR (v_exec_vol = v_best_vol AND v_imbalance < v_best_imbalance)
               OR (v_exec_vol = v_best_vol AND v_imbalance = v_best_imbalance AND v_dist_cur < v_best_dist) THEN
                v_best_price := v_cand.cand_price;
                v_best_vol := v_exec_vol;
                v_best_imbalance := v_imbalance;
                v_best_dist := v_dist_cur;
            END IF;
        END LOOP;

        IF v_best_price IS NOT NULL AND v_best_vol > 0 THEN
            FOR v_buy_ord IN
                SELECT id, user_id, price, remain_amount
                FROM public.orders
                WHERE stock_id = v_stock.id
                  AND order_type = 'BUY'
                  AND status IN ('PENDING', 'PARTIAL')
                  AND remain_amount > 0
                  AND price >= v_best_price
                ORDER BY price DESC, id ASC
                FOR UPDATE
            LOOP
                FOR v_sell_ord IN
                    SELECT id, user_id, price, remain_amount
                    FROM public.orders
                    WHERE stock_id = v_stock.id
                      AND order_type = 'SELL'
                      AND status IN ('PENDING', 'PARTIAL')
                      AND remain_amount > 0
                      AND price <= v_best_price
                      AND user_id != v_buy_ord.user_id
                    ORDER BY price ASC, id ASC
                    FOR UPDATE
                LOOP
                    EXIT WHEN v_buy_ord.remain_amount = 0;

                    v_trade_qty := LEAST(v_buy_ord.remain_amount, v_sell_ord.remain_amount);
                    v_trade_price := v_best_price;
                    v_trade_total := v_trade_price::BIGINT * v_trade_qty::BIGINT;

                    INSERT INTO public.order_trades (
                        stock_id, buy_order_id, sell_order_id, buyer_id, seller_id,
                        price, amount, total_trade_amount, created_at
                    ) VALUES (
                        v_stock.id, v_buy_ord.id, v_sell_ord.id, v_buy_ord.user_id, v_sell_ord.user_id,
                        v_trade_price, v_trade_qty, v_trade_total, NOW()
                    );

                    UPDATE public.user_holdings
                    SET locked_amount = locked_amount - v_trade_qty,
                        updated_at = NOW()
                    WHERE user_id = v_sell_ord.user_id AND stock_id = v_stock.id;

                    UPDATE public.profiles
                    SET total_point = total_point + v_trade_total,
                        updated_at = NOW()
                    WHERE id = v_sell_ord.user_id;

                    INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                    VALUES (v_sell_ord.user_id, v_trade_total,
                            (SELECT total_point FROM public.profiles WHERE id = v_sell_ord.user_id),
                            'STOCK_SELL_SETTLEMENT', '동시호가 단일가 매도 대금 정산');

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

                        INSERT INTO public.point_transactions (user_id, amount, balance_after, reason_type, description)
                        VALUES (v_buy_ord.user_id, v_price_diff,
                                (SELECT total_point FROM public.profiles WHERE id = v_buy_ord.user_id),
                                'STOCK_BUY_DIFF_REFUND', '동시호가 단일가 우위 체결 차액 환불');
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

                    v_stock_trades_count := v_stock_trades_count + 1;
                    v_stock_trades_vol := v_stock_trades_vol + v_trade_qty;
                END LOOP;
            END LOOP;

            IF v_stock_trades_count > 0 THEN
                UPDATE public.stocks
                SET prev_price = current_price,
                    current_price = v_best_price,
                    updated_at = NOW()
                WHERE id = v_stock.id;

                v_total_matched_stocks := v_total_matched_stocks + 1;
                v_grand_trades_count := v_grand_trades_count + v_stock_trades_count;
                v_grand_volume := v_grand_volume + v_stock_trades_vol;

                v_results := v_results || jsonb_build_object(
                    'stock_id', v_stock.id,
                    'stock_name', v_stock.name,
                    'clearing_price', v_best_price,
                    'trades_count', v_stock_trades_count,
                    'volume', v_stock_trades_vol
                );
            END IF;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'total_stocks_matched', v_total_matched_stocks,
        'total_trades_count', v_grand_trades_count,
        'total_volume', v_grand_volume,
        'matched_stocks', v_results,
        'message', CASE 
            WHEN v_grand_trades_count > 0 
            THEN format('동시호가 단일가 일괄 체결 완료: 총 %s개 종목, %s건 체결 (총 %s주 거래)', v_total_matched_stocks, v_grand_trades_count, v_grand_volume)
            ELSE '현재 체결 가능한 동시호가 교차 주문이 없습니다.'
        END
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4-5. 시황/기업 뉴스 생성 템플릿 함수 (generate_ai_news)
CREATE OR REPLACE FUNCTION public.generate_ai_news(
    p_stock_id BIGINT DEFAULT NULL,
    p_sentiment VARCHAR DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_stock_id BIGINT;
    v_stock_name VARCHAR(100);
    v_sentiment VARCHAR(20);
    v_headline VARCHAR(200);
    v_content TEXT;
    v_impact_rate NUMERIC(5,2);
    v_news_id BIGINT;
    v_idx INT;
BEGIN
    IF p_stock_id IS NOT NULL THEN
        SELECT id, name INTO v_stock_id, v_stock_name
        FROM public.stocks WHERE id = p_stock_id;
    ELSE
        SELECT id, name INTO v_stock_id, v_stock_name
        FROM public.stocks WHERE status = 'LISTED'
        ORDER BY RANDOM() LIMIT 1;
    END IF;

    IF p_sentiment IS NOT NULL AND p_sentiment IN ('POSITIVE', 'NEGATIVE', 'NEUTRAL') THEN
        v_sentiment := p_sentiment;
    ELSE
        IF RANDOM() < 0.6 THEN
            v_sentiment := 'POSITIVE';
        ELSE
            v_sentiment := 'NEGATIVE';
        END IF;
    END IF;

    IF v_sentiment = 'POSITIVE' THEN
        v_impact_rate := ROUND((RANDOM() * 3.0 + 1.5)::NUMERIC, 1);
        v_idx := FLOOR(RANDOM() * 5);
        CASE v_idx
            WHEN 0 THEN
                v_headline := '[호재] ' || COALESCE(v_stock_name, '시장') || ', 신규 수요 급증으로 투자 관심 집중';
                v_content := COALESCE(v_stock_name, '해당 종목') || '에 대한 학생들의 참여가 활발해지며 긍정적인 투자 심리가 확산되고 있습니다.';
            WHEN 1 THEN
                v_headline := '[특징주] ' || COALESCE(v_stock_name, '시장') || ', 쉬는 시간 매점 및 학급 인기 1위 등극';
                v_content := '신규 물량 입고와 함께 ' || COALESCE(v_stock_name, '종목') || '의 선호도가 급상승하며 주목받고 있습니다.';
            WHEN 2 THEN
                v_headline := '[기업이슈] ' || COALESCE(v_stock_name, '시장') || ', 혁신적인 품질 개선에 실적 기대감 고조';
                v_content := '업그레이드된 기능과 편의성이 입소문을 타며 학급 내 관심도가 최고조에 달했습니다.';
            WHEN 3 THEN
                v_headline := '[속보] ' || COALESCE(v_stock_name, '시장') || ', 대규모 공동구매 소식에 매수세 대거 유입';
                v_content := '학생들의 단체 구매 수요가 확인되며 ' || COALESCE(v_stock_name, '종목') || '에 대한 긍정적 전망이 확산되고 있습니다.';
            ELSE
                v_headline := '[투자분석] ' || COALESCE(v_stock_name, '시장') || ', 유저 만족도 압도적 1위 기록';
                v_content := '품질과 가성비 모두에서 높은 점수를 받으며 신뢰도가 대폭 상승했습니다.';
        END CASE;
    ELSE
        v_impact_rate := -ROUND((RANDOM() * 2.5 + 1.0)::NUMERIC, 1);
        v_idx := FLOOR(RANDOM() * 5);
        CASE v_idx
            WHEN 0 THEN
                v_headline := '[시황] ' || COALESCE(v_stock_name, '시장') || ', 일시적 재고 부족 및 공급 지연 우려';
                v_content := '유통 과정에서의 일시적 차질로 인해 ' || COALESCE(v_stock_name, '종목') || '의 수급 불균형 우려가 제기되고 있습니다.';
            WHEN 1 THEN
                v_headline := '[악재] ' || COALESCE(v_stock_name, '시장') || ', 경쟁 대체재 등장으로 점유율 분산';
                v_content := '유사 신제품들이 학급에 유입되면서 단기 선호도가 분산되고 있습니다.';
            WHEN 2 THEN
                v_headline := '[특징주] ' || COALESCE(v_stock_name, '시장') || ', 차익 실현성 매도 물량 출회로 관망세';
                v_content := '단기 급등 이후 학생들의 차익 실현 심리가 맞물리며 거래 회전율이 둔화되고 있습니다.';
            WHEN 3 THEN
                v_headline := '[시장경고] ' || COALESCE(v_stock_name, '시장') || ', 가격 인상 소식에 소비자 반응 엇갈려';
                v_content := '원가 상승에 따른 가격 조정 우려가 나오며 보수적인 접근이 늘고 있습니다.';
            ELSE
                v_headline := '[증시뉴스] ' || COALESCE(v_stock_name, '시장') || ', 계절적 비수기 진입으로 수요 일시 둔화';
                v_content := '학기 중 일정 변화로 인해 일일 소비량이 소폭 감소한 것으로 파악됩니다.';
        END CASE;
    END IF;

    INSERT INTO public.news (stock_id, headline, content, sentiment, impact_rate, created_at)
    VALUES (v_stock_id, v_headline, v_content, v_sentiment, v_impact_rate, NOW())
    RETURNING id INTO v_news_id;

    RETURN jsonb_build_object(
        'id', v_news_id,
        'stock_id', v_stock_id,
        'stock_name', v_stock_name,
        'headline', v_headline,
        'content', v_content,
        'sentiment', v_sentiment,
        'impact_rate', v_impact_rate,
        'created_at', NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
