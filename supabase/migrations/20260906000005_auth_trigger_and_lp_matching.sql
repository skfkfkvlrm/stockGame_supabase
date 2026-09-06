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
