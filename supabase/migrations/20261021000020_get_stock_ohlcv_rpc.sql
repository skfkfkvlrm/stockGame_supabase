-- ========================================================================
-- Migration: 20261021000020_get_stock_ohlcv_rpc.sql
-- Description:
-- 1. Create high-performance real-time OHLCV aggregation RPC: public.get_stock_ohlcv
-- 2. Supports dynamic timeframes: 10M, 1H, 1D, 1W, 1MO, 3MO, ALL
-- 3. Seamlessly unifies historical seed data with live execution logs from order_trades.
-- ========================================================================

CREATE OR REPLACE FUNCTION public.get_stock_ohlcv(
    p_stock_id BIGINT,
    p_timeframe VARCHAR DEFAULT 'ALL'
)
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
    v_cur_price INT;
    v_pub_price INT;
    v_today_date DATE;
BEGIN
    SELECT current_price, publication_price INTO v_cur_price, v_pub_price
    FROM public.stocks WHERE id = p_stock_id;

    IF v_cur_price IS NULL THEN
        RETURN '[]'::JSONB;
    END IF;

    v_today_date := (NOW() AT TIME ZONE 'Asia/Seoul')::DATE;

    IF p_timeframe IN ('10M', '3M', '1M') THEN
        WITH bucketed AS (
            SELECT 
                to_char(
                    date_trunc('hour', created_at AT TIME ZONE 'Asia/Seoul') + 
                    (((EXTRACT(minute FROM created_at AT TIME ZONE 'Asia/Seoul')::INT / 10) * 10) || ' minutes')::INTERVAL, 
                    'YYYY-MM-DD HH24:MI'
                ) AS candle_time,
                (ARRAY_AGG(price ORDER BY created_at ASC))[1] AS o,
                MAX(price) AS h,
                MIN(price) AS l,
                (ARRAY_AGG(price ORDER BY created_at DESC))[1] AS c,
                SUM(amount)::BIGINT AS v
            FROM public.order_trades
            WHERE stock_id = p_stock_id
            GROUP BY 1
            ORDER BY 1 DESC
            LIMIT 30
        )
        SELECT jsonb_agg(
            jsonb_build_object(
                'date', candle_time,
                'baseDate', candle_time,
                'openPrice', o,
                'highPrice', h,
                'lowPrice', l,
                'closePrice', c,
                'price', c,
                'volume', v
            ) ORDER BY candle_time ASC
        ) INTO v_result
        FROM bucketed;

    ELSIF p_timeframe IN ('1H', '3H', '6H', '12H') THEN
        WITH bucketed AS (
            SELECT 
                to_char(date_trunc('hour', created_at AT TIME ZONE 'Asia/Seoul'), 'YYYY-MM-DD HH24:MI') AS candle_time,
                (ARRAY_AGG(price ORDER BY created_at ASC))[1] AS o,
                MAX(price) AS h,
                MIN(price) AS l,
                (ARRAY_AGG(price ORDER BY created_at DESC))[1] AS c,
                SUM(amount)::BIGINT AS v
            FROM public.order_trades
            WHERE stock_id = p_stock_id
            GROUP BY 1
            ORDER BY 1 DESC
            LIMIT 40
        )
        SELECT jsonb_agg(
            jsonb_build_object(
                'date', candle_time,
                'baseDate', candle_time,
                'openPrice', o,
                'highPrice', h,
                'lowPrice', l,
                'closePrice', c,
                'price', c,
                'volume', v
            ) ORDER BY candle_time ASC
        ) INTO v_result
        FROM bucketed;

    ELSIF p_timeframe = '1D' THEN
        WITH today_trades AS (
            SELECT 
                to_char(date_trunc('hour', created_at AT TIME ZONE 'Asia/Seoul'), 'YYYY-MM-DD HH24:MI') AS candle_time,
                (ARRAY_AGG(price ORDER BY created_at ASC))[1] AS o,
                MAX(price) AS h,
                MIN(price) AS l,
                (ARRAY_AGG(price ORDER BY created_at DESC))[1] AS c,
                SUM(amount)::BIGINT AS v
            FROM public.order_trades
            WHERE stock_id = p_stock_id
              AND (created_at AT TIME ZONE 'Asia/Seoul')::DATE = v_today_date
            GROUP BY 1
            ORDER BY 1 ASC
        ),
        fallback_recent AS (
            SELECT 
                to_char(date_trunc('hour', created_at AT TIME ZONE 'Asia/Seoul'), 'YYYY-MM-DD HH24:MI') AS candle_time,
                (ARRAY_AGG(price ORDER BY created_at ASC))[1] AS o,
                MAX(price) AS h,
                MIN(price) AS l,
                (ARRAY_AGG(price ORDER BY created_at DESC))[1] AS c,
                SUM(amount)::BIGINT AS v
            FROM public.order_trades
            WHERE stock_id = p_stock_id
            GROUP BY 1
            ORDER BY 1 DESC
            LIMIT 10
        )
        SELECT 
            CASE 
                WHEN (SELECT COUNT(*) FROM today_trades) > 0 THEN 
                    (SELECT jsonb_agg(jsonb_build_object(
                        'date', candle_time, 'baseDate', candle_time,
                        'openPrice', o, 'highPrice', h, 'lowPrice', l, 'closePrice', c, 'price', c, 'volume', v
                    ) ORDER BY candle_time ASC) FROM today_trades)
                WHEN (SELECT COUNT(*) FROM fallback_recent) > 0 THEN
                    (SELECT jsonb_agg(jsonb_build_object(
                        'date', candle_time, 'baseDate', candle_time,
                        'openPrice', o, 'highPrice', h, 'lowPrice', l, 'closePrice', c, 'price', c, 'volume', v
                    ) ORDER BY candle_time ASC) FROM fallback_recent)
                ELSE
                    jsonb_build_array(jsonb_build_object(
                        'date', to_char(NOW() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD 09:00'),
                        'baseDate', to_char(NOW() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD 09:00'),
                        'openPrice', v_cur_price, 'highPrice', v_cur_price, 'lowPrice', v_cur_price, 'closePrice', v_cur_price, 'price', v_cur_price, 'volume', 0
                    ))
            END INTO v_result;

    ELSE
        WITH limited_days AS (
            SELECT 
                base_date::TEXT AS b_date,
                open_price AS o,
                high_price AS h,
                low_price AS l,
                close_price AS c,
                volume AS v
            FROM public.stock_price_history
            WHERE stock_id = p_stock_id
            ORDER BY base_date DESC
            LIMIT CASE 
                    WHEN p_timeframe = '1W' THEN 7
                    WHEN p_timeframe = '1MO' THEN 30
                    WHEN p_timeframe = '3MO' THEN 90
                    ELSE 99999
                  END
        )
        SELECT jsonb_agg(
            jsonb_build_object(
                'date', b_date,
                'baseDate', b_date,
                'openPrice', o,
                'highPrice', h,
                'lowPrice', l,
                'closePrice', c,
                'price', c,
                'volume', v
            ) ORDER BY b_date ASC
        ) INTO v_result
        FROM limited_days;
    END IF;

    IF v_result IS NULL OR jsonb_array_length(v_result) = 0 THEN
        v_result := jsonb_build_array(jsonb_build_object(
            'date', to_char(NOW() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD'),
            'baseDate', to_char(NOW() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD'),
            'openPrice', v_cur_price,
            'highPrice', v_cur_price,
            'lowPrice', v_cur_price,
            'closePrice', v_cur_price,
            'price', v_cur_price,
            'volume', 0
        ));
    END IF;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
