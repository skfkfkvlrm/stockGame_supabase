-- ========================================================
-- Migration: 20260906000004_seed_initial_data.sql
-- Description: Seed Initial Stocks & Coupons Data from Production MariaDB
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 1. 기초 주식 종목 시드 데이터
INSERT INTO public.stocks (id, name, content, publication_balance, publication_price, current_price, prev_price, high_limit_price, low_limit_price, market_status, status)
VALUES
(1, '새콤달콤', '화가나고 피곤할 땐 새콤달콤', 74, 800, 861, 861, 1119, 603, 'CONTINUOUS', 'LISTED'),
(2, '포켓몬빵', '띠부띠부씰이 들어있는 포켓몬빵', 100, 1500, 1950, 1950, 2535, 1365, 'CONTINUOUS', 'LISTED'),
(3, '바나나우유', '달콤하고 부드러운 항아리 바나나우유', 100, 1400, 1450, 1450, 1885, 1015, 'CONTINUOUS', 'LISTED'),
(4, '쿠키런테크', '전 세계를 달리는 데브시스터즈 쿠키런 개발사', 50, 3000, 3800, 3800, 4940, 2660, 'CONTINUOUS', 'LISTED'),
(5, '크래프톤', '배틀그라운드 글로벌 IP 보유 게임 개발사', 30, 5000, 6100, 6100, 7930, 4270, 'CONTINUOUS', 'LISTED'),
(6, '넥슨게임즈', '메이플스토리, 던파 등 글로벌 메가히트 게임 명가', 50, 2500, 2500, 2500, 3250, 1750, 'CONTINUOUS', 'LISTED'),
(7, '넷마블', '모바일 RPG 및 캐주얼 게임 선도 기업', 100, 2000, 2000, 2000, 2600, 1400, 'CONTINUOUS', 'LISTED'),
(8, '닌텐도', '스위치 신작 게임 스토어 이용권', 20, 10000, 11600, 11600, 15080, 8120, 'CONTINUOUS', 'LISTED'),
(9, '로블록스', '로블록스 게임 로벅스 충전권', 80, 4000, 4000, 4000, 5200, 2800, 'CONTINUOUS', 'LISTED'),
(10, 'SM엔터', '에스파/NCT 등 글로벌 K-POP 테마', 100, 4000, 4000, 4000, 5200, 2800, 'CONTINUOUS', 'LISTED'),
(11, '하이브', '방탄소년단/뉴진스 아티스트 테마', 50, 8000, 9200, 9200, 11960, 6440, 'CONTINUOUS', 'LISTED'),
(12, '치지직/숲', '라이브 스트리밍 및 후원 아이템', 80, 3500, 3500, 3500, 4550, 2450, 'CONTINUOUS', 'LISTED'),
(13, '지우개똥청소기', '책상 위 지우개 가루 자동 청소기', 100, 1200, 1200, 1200, 1560, 840, 'CONTINUOUS', 'LISTED'),
(14, '샤프심연구소', '부러지지 않는 0.5mm 아인 샤프심', 100, 1000, 1000, 1000, 1300, 700, 'CONTINUOUS', 'LISTED'),
(16, '축구공테크', '점심시간 피구/축구 최고급 공', 60, 3500, 3500, 3500, 4550, 2450, 'CONTINUOUS', 'LISTED'),
(17, '배드민턴클럽', '요넥스 고급 배드민턴 라켓셋', 50, 4500, 4500, 4500, 5850, 3150, 'CONTINUOUS', 'LISTED'),
(18, '포켓몬카드', '희귀 홀로그램 갓팩 컬렉션', 40, 6000, 6000, 6000, 7800, 4200, 'CONTINUOUS', 'LISTED'),
(19, 'AI로봇선생님', '24시간 질문받는 챗봇 로봇', 20, 12000, 12000, 12000, 15600, 8400, 'CONTINUOUS', 'LISTED'),
(20, '드론배달소', '교실 창문으로 받아보는 드론 딜리버리', 30, 9000, 9000, 9000, 11700, 6300, 'CONTINUOUS', 'LISTED'),
(21, '스마트책상', '높낮이 조절 및 온열 쿨링 기능 책상', 20, 15000, 15000, 15000, 19500, 10500, 'CONTINUOUS', 'LISTED'),
(22, '쿰척쿰척', '식품 제조', 7000, 500, 500, 500, 650, 350, 'CONTINUOUS', 'LISTED')
ON CONFLICT (id) DO UPDATE
SET current_price = EXCLUDED.current_price,
    prev_price = EXCLUDED.prev_price,
    high_limit_price = EXCLUDED.high_limit_price,
    low_limit_price = EXCLUDED.low_limit_price;

SELECT setval('public.stocks_id_seq', (SELECT MAX(id) FROM public.stocks));

-- 2. 기초 보상 쿠폰 시드 데이터
INSERT INTO public.coupons (id, coupon_code, name, price, status)
VALUES
(1, 'CPN-2026-0001', '자리 변경 쿠폰이당', 50000, 'ON_SALE'),
(2, 'CPN-2026-0002', '청소당번 면제', 3000, 'ON_SALE'),
(3, 'CPN-2026-0003', '자리 뺏기', 100000, 'ON_SALE'),
(30, 'CPN-2026-0004', '쌤 삥뜯기', 500000, 'ON_SALE'),
(31, 'CPN-2026-0005', '자율 동아리 간식권', 25000, 'ON_SALE')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    price = EXCLUDED.price,
    status = EXCLUDED.status;

SELECT setval('public.coupons_id_seq', (SELECT MAX(id) FROM public.coupons));
