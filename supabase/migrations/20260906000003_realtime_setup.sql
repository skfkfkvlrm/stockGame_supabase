-- ========================================================
-- Migration: 20260906000003_realtime_setup.sql
-- Description: Supabase Realtime Publication Configuration
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- 실시간 브로드캐스트가 필요한 테이블을 supabase_realtime 발행 목록에 등록
ALTER PUBLICATION supabase_realtime ADD TABLE public.stocks;
ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
ALTER PUBLICATION supabase_realtime ADD TABLE public.order_trades;
ALTER PUBLICATION supabase_realtime ADD TABLE public.news;
ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_holdings;
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_coupons;
