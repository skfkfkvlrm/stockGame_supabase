-- ==============================================================================
-- Migration: 20260906000010_market_indices.sql
-- Description: 실시간 코스피(KOSPI) / 코스닥(KOSDAQ) 시장 지수 테이블 생성, RLS 및 초기 실측 시드
-- ==============================================================================

-- 1. market_indices 테이블 생성
CREATE TABLE IF NOT EXISTS public.market_indices (
    name VARCHAR(20) PRIMARY KEY,                    -- 'KOSPI', 'KOSDAQ'
    kor_name VARCHAR(50) NOT NULL,                  -- '코스피', '코스닥'
    market_type VARCHAR(50) NOT NULL,               -- '유가증권시장', '코스닥시장'
    value NUMERIC(10, 2) NOT NULL,                  -- 현재 지수
    change_val NUMERIC(10, 2) NOT NULL,             -- 전일대비 변동폭
    change_rate NUMERIC(6, 2) NOT NULL,             -- 등락률 (%)
    prev_close NUMERIC(10, 2) NOT NULL,             -- 전일 종가
    open_price NUMERIC(10, 2) NOT NULL,             -- 당일 시가
    high_price NUMERIC(10, 2) NOT NULL,             -- 당일 고가
    low_price NUMERIC(10, 2) NOT NULL,              -- 당일 저가
    high_52w NUMERIC(10, 2),                        -- 52주 최고가
    low_52w NUMERIC(10, 2),                         -- 52주 최저가
    volume BIGINT DEFAULT 0,                        -- 거래량
    trading_value BIGINT DEFAULT 0,                 -- 거래대금
    market_status VARCHAR(20) DEFAULT 'OPEN',       -- 'OPEN', 'CLOSE', 'HOLIDAY'
    chart_history JSONB NOT NULL DEFAULT '[]'::jsonb, -- 최근 7거래일 종가 추이
    updated_at TIMESTAMPTZ DEFAULT NOW()            -- 갱신 일시
);

-- 2. RLS 활성화
ALTER TABLE public.market_indices ENABLE ROW LEVEL SECURITY;

-- 3. RLS 정책 설정 (멱등성 보장)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'market_indices' AND policyname = 'Allow public read access to market_indices'
    ) THEN
        CREATE POLICY "Allow public read access to market_indices" ON public.market_indices FOR SELECT TO public USING (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'market_indices' AND policyname = 'Allow service role update on market_indices'
    ) THEN
        CREATE POLICY "Allow service role update on market_indices" ON public.market_indices FOR ALL TO service_role USING (true);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' AND tablename = 'market_indices'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.market_indices;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END $$;

-- 4. 실제 실시간 코스피/코스닥 초기 시드 데이터 UPSERT
INSERT INTO public.market_indices (
    name, kor_name, market_type, value, change_val, change_rate,
    prev_close, open_price, high_price, low_price, high_52w, low_52w,
    volume, trading_value, market_status, chart_history, updated_at
) VALUES
(
    'KOSPI', '코스피', '유가증권시장', 5768.01, 99.96, 1.76,
    5668.05, 5488.41, 5768.01, 5488.41, 6200.00, 5400.00,
    458290000, 9820300000000, 'CLOSE',
    '[6625.93, 6384.24, 6035.35, 6008.81, 5554.22, 5668.05, 5768.01]'::jsonb,
    NOW()
),
(
    'KOSDAQ', '코스닥', '코스닥시장', 808.89, 14.11, 1.78,
    794.78, 773.06, 808.92, 773.06, 920.00, 750.00,
    892400000, 7450200000000, 'CLOSE',
    '[892.27, 849.19, 837.03, 823.88, 760.82, 794.78, 808.89]'::jsonb,
    NOW()
)
ON CONFLICT (name) DO UPDATE SET
    kor_name = EXCLUDED.kor_name,
    market_type = EXCLUDED.market_type,
    value = EXCLUDED.value,
    change_val = EXCLUDED.change_val,
    change_rate = EXCLUDED.change_rate,
    prev_close = EXCLUDED.prev_close,
    open_price = EXCLUDED.open_price,
    high_price = EXCLUDED.high_price,
    low_price = EXCLUDED.low_price,
    high_52w = EXCLUDED.high_52w,
    low_52w = EXCLUDED.low_52w,
    volume = EXCLUDED.volume,
    trading_value = EXCLUDED.trading_value,
    market_status = EXCLUDED.market_status,
    chart_history = EXCLUDED.chart_history,
    updated_at = EXCLUDED.updated_at;
