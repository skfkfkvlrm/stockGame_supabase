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
