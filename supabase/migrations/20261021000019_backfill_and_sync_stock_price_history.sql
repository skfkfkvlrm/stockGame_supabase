-- ========================================================================
-- Migration: 20261021000019_backfill_and_sync_stock_price_history.sql
-- Description:
-- 1. Backfill historical trades from order_trades (since 2026-09-12) into stock_price_history.
-- 2. Create trigger on order_trades to automatically update/upsert stock_price_history
--    on every trade execution in real-time.
-- ========================================================================

-- 1. 2026-09-12 이후 order_trades에 누적된 실제 체결 일봉 백필 (Backfill)
INSERT INTO public.stock_price_history (stock_id, base_date, open_price, high_price, low_price, close_price, volume, created_at)
SELECT 
    t.stock_id,
    (t.created_at AT TIME ZONE 'Asia/Seoul')::DATE AS base_date,
    (ARRAY_AGG(t.price ORDER BY t.created_at ASC))[1] AS open_price,
    MAX(t.price) AS high_price,
    MIN(t.price) AS low_price,
    (ARRAY_AGG(t.price ORDER BY t.created_at DESC))[1] AS close_price,
    SUM(t.amount)::BIGINT AS volume,
    NOW() AS created_at
FROM public.order_trades t
WHERE (t.created_at AT TIME ZONE 'Asia/Seoul')::DATE >= '2026-09-12'
GROUP BY t.stock_id, (t.created_at AT TIME ZONE 'Asia/Seoul')::DATE
ON CONFLICT (stock_id, base_date) DO UPDATE
SET open_price = EXCLUDED.open_price,
    high_price = GREATEST(stock_price_history.high_price, EXCLUDED.high_price),
    low_price = LEAST(stock_price_history.low_price, EXCLUDED.low_price),
    close_price = EXCLUDED.close_price,
    volume = EXCLUDED.volume;

-- 2. 실시간 체결 시 stock_price_history 일봉 자동 갱신 트리거 함수
CREATE OR REPLACE FUNCTION public.trg_fn_update_stock_price_history()
RETURNS TRIGGER AS $$
DECLARE
    v_trade_date DATE;
BEGIN
    -- 한국 표준시(KST) 기준 당일 날짜 추출
    v_trade_date := (NEW.created_at AT TIME ZONE 'Asia/Seoul')::DATE;

    -- 당일 캔들 UPSERT (첫 거래 시 INSERT, 이후 거래 시 High/Low/Close/Volume 갱신)
    INSERT INTO public.stock_price_history (
        stock_id, 
        base_date, 
        open_price, 
        high_price, 
        low_price, 
        close_price, 
        volume, 
        created_at
    )
    VALUES (
        NEW.stock_id, 
        v_trade_date, 
        NEW.price, 
        NEW.price, 
        NEW.price, 
        NEW.price, 
        NEW.amount, 
        NOW()
    )
    ON CONFLICT (stock_id, base_date) DO UPDATE
    SET high_price = GREATEST(stock_price_history.high_price, EXCLUDED.close_price),
        low_price = LEAST(stock_price_history.low_price, EXCLUDED.close_price),
        close_price = EXCLUDED.close_price,
        volume = stock_price_history.volume + EXCLUDED.volume;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. order_trades에 트리거 부착 (기존 트리거 존재 시 삭제 후 재생성)
DROP TRIGGER IF EXISTS trg_sync_order_trades_to_history ON public.order_trades;

CREATE TRIGGER trg_sync_order_trades_to_history
AFTER INSERT ON public.order_trades
FOR EACH ROW
EXECUTE FUNCTION public.trg_fn_update_stock_price_history();
