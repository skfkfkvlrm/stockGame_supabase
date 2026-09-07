-- ========================================================
-- StockGame: 21개 주식 종목 클린 리셋 및 쿠폰 시스템 완비 SQL
-- Execution Target: Supabase Cloud SQL Editor (ulgbshgzwmnytejfutsb)
-- ========================================================

-- [Step 1] 더티 테스트 데이터 및 주문/체결 내역 초기화
TRUNCATE TABLE public.order_trades CASCADE;
TRUNCATE TABLE public.orders CASCADE;
TRUNCATE TABLE public.user_holdings CASCADE;
TRUNCATE TABLE public.stock_price_history CASCADE;

-- 테스트 종목 (쿰척쿰척 등) 제거
DELETE FROM public.stocks WHERE name = '쿰척쿰척' OR id > 21;

-- [Step 2] 21개 정식 주식 종목 시드 데이터 클린 복원/업데이트
INSERT INTO public.stocks (id, name, content, publication_balance, publication_price, current_price, prev_price, high_limit_price, low_limit_price, market_status, status)
VALUES
(1, '새콤달콤', '화가나고 피곤할 땐 새콤달콤', 100, 800, 800, 800, 1040, 560, 'CONTINUOUS', 'LISTED'),
(2, '포켓몬빵', '띠부띠부씰이 들어있는 포켓몬빵', 100, 1500, 1500, 1500, 1950, 1050, 'CONTINUOUS', 'LISTED'),
(3, '바나나우유', '달콤하고 부드러운 항아리 바나나우유', 100, 1400, 1400, 1400, 1820, 980, 'CONTINUOUS', 'LISTED'),
(4, '쿠키런테크', '전 세계를 달리는 데브시스터즈 쿠키런 개발사', 50, 3000, 3000, 3000, 3900, 2100, 'CONTINUOUS', 'LISTED'),
(5, '크래프톤', '배틀그라운드 글로벌 IP 보유 게임 개발사', 30, 5000, 5000, 5000, 6500, 3500, 'CONTINUOUS', 'LISTED'),
(6, '넥슨게임즈', '메이플스토리, 던파 등 글로벌 메가히트 게임 명가', 50, 2500, 2500, 2500, 3250, 1750, 'CONTINUOUS', 'LISTED'),
(7, '넷마블', '모바일 RPG 및 캐주얼 게임 선도 기업', 100, 2000, 2000, 2000, 2600, 1400, 'CONTINUOUS', 'LISTED'),
(8, '닌텐도', '스위치 신작 게임 스토어 이용권', 20, 10000, 10000, 10000, 13000, 7000, 'CONTINUOUS', 'LISTED'),
(9, '로블록스', '로블록스 게임 로벅스 충전권', 80, 4000, 4000, 4000, 5200, 2800, 'CONTINUOUS', 'LISTED'),
(10, 'SM엔터', '에스파/NCT 등 글로벌 K-POP 테마', 100, 4000, 4000, 4000, 5200, 2800, 'CONTINUOUS', 'LISTED'),
(11, '하이브', '방탄소년단/뉴진스 아티스트 테마', 50, 8000, 8000, 8000, 10400, 5600, 'CONTINUOUS', 'LISTED'),
(12, '치지직/숲', '라이브 스트리밍 및 후원 아이템', 80, 3500, 3500, 3500, 4550, 2450, 'CONTINUOUS', 'LISTED'),
(13, '지우개똥청소기', '책상 위 지우개 가루 자동 청소기', 100, 1200, 1200, 1200, 1560, 840, 'CONTINUOUS', 'LISTED'),
(14, '샤프심연구소', '부러지지 않는 0.5mm 아인 샤프심', 100, 1000, 1000, 1000, 1300, 700, 'CONTINUOUS', 'LISTED'),
(15, '캐릭터필통', '인기 캐릭터 자수 고급 2단 필통', 80, 2200, 2200, 2200, 2860, 1540, 'CONTINUOUS', 'LISTED'),
(16, '축구공테크', '점심시간 피구/축구 최고급 공', 60, 3500, 3500, 3500, 4550, 2450, 'CONTINUOUS', 'LISTED'),
(17, '배드민턴클럽', '요넥스 고급 배드민턴 라켓셋', 50, 4500, 4500, 4500, 5850, 3150, 'CONTINUOUS', 'LISTED'),
(18, '포켓몬카드', '희귀 홀로그램 갓팩 컬렉션', 40, 6000, 6000, 6000, 7800, 4200, 'CONTINUOUS', 'LISTED'),
(19, 'AI로봇선생님', '24시간 질문받는 챗봇 로봇', 20, 12000, 12000, 12000, 15600, 8400, 'CONTINUOUS', 'LISTED'),
(20, '드론배달소', '교실 창문으로 받아보는 드론 딜리버리', 30, 9000, 9000, 9000, 11700, 6300, 'CONTINUOUS', 'LISTED'),
(21, '스마트책상', '높낮이 조절 및 온열 쿨링 기능 책상', 15, 15000, 15000, 15000, 19500, 10500, 'CONTINUOUS', 'LISTED')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    content = EXCLUDED.content,
    publication_balance = EXCLUDED.publication_balance,
    publication_price = EXCLUDED.publication_price,
    current_price = EXCLUDED.publication_price,
    prev_price = EXCLUDED.publication_price,
    high_limit_price = EXCLUDED.high_limit_price,
    low_limit_price = EXCLUDED.low_limit_price,
    market_status = 'CONTINUOUS',
    status = 'LISTED';

SELECT setval('public.stocks_id_seq', 21);

-- [Step 3] 상점 쿠폰 5종 초기 데이터 점검 및 복원
INSERT INTO public.coupons (id, coupon_code, name, price, status)
VALUES
(1, 'CPN-2026-0001', '자리 변경 쿠폰이당', 50000, 'ON_SALE'),
(2, 'CPN-2026-0002', '청소당번 면제', 3000, 'ON_SALE'),
(3, 'CPN-2026-0003', '자리 뺏기', 100000, 'ON_SALE'),
(4, 'CPN-2026-0004', '쌤 삥뜯기', 500000, 'ON_SALE'),
(5, 'CPN-2026-0005', '자율 동아리 간식권', 25000, 'ON_SALE')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    price = EXCLUDED.price,
    status = EXCLUDED.status;

SELECT setval('public.coupons_id_seq', (SELECT GREATEST(5, COALESCE(MAX(id), 0)) FROM public.coupons));

-- [Step 4] 쿠폰 구매 원자적 트랜잭션 함수 생성 (buy_coupon)
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

-- [Step 5] 쿠폰 사용 처리 함수 생성 (use_coupon)
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

-- [Step 6] 권한 부여 및 Row Level Security (RLS) 정책 설정
ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_coupons ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read coupons" ON public.coupons;
CREATE POLICY "Anyone can read coupons" ON public.coupons FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can read own coupons" ON public.user_coupons;
CREATE POLICY "Users can read own coupons" ON public.user_coupons FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own coupons" ON public.user_coupons;
CREATE POLICY "Users can insert own coupons" ON public.user_coupons FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own coupons" ON public.user_coupons;
CREATE POLICY "Users can update own coupons" ON public.user_coupons FOR UPDATE USING (auth.uid() = user_id);

GRANT EXECUTE ON FUNCTION public.buy_coupon(BIGINT) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.use_coupon(BIGINT) TO authenticated, anon;
GRANT SELECT ON public.coupons TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_coupons TO authenticated, anon;