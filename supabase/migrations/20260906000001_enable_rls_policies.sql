-- ========================================================
-- Migration: 20260906000001_enable_rls_policies.sql
-- Description: Row Level Security (RLS) Policies & Access Control
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- ========================================================

-- RLS 활성화
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_holdings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_trades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.point_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.news ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_price_history ENABLE ROW LEVEL SECURITY;

-- 관리자 여부 판별 헬퍼 함수
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('ROLE_ADMIN', 'ROLE_TEACHER')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 1. profiles RLS
CREATE POLICY "본인 프로필 조회 허용" ON public.profiles
  FOR SELECT USING (auth.uid() = id OR public.is_admin());

CREATE POLICY "랭킹용 프로필 요약 조회 허용" ON public.profiles
  FOR SELECT USING (true);

CREATE POLICY "관리자 전용 프로필 수정 허용" ON public.profiles
  FOR UPDATE USING (public.is_admin());

-- 2. stocks RLS
CREATE POLICY "종목 정보 누구나 조회 허용" ON public.stocks
  FOR SELECT USING (true);

CREATE POLICY "관리자만 종목 CUD 허용" ON public.stocks
  FOR ALL USING (public.is_admin());

-- 3. user_holdings RLS
CREATE POLICY "본인 보유 주식만 조회 허용" ON public.user_holdings
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

-- 4. orders RLS
CREATE POLICY "본인 주문만 조회 허용" ON public.orders
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

-- 5. order_trades RLS
CREATE POLICY "체결 내역 전체 조회 허용" ON public.order_trades
  FOR SELECT USING (true);

-- 6. point_transactions RLS
CREATE POLICY "본인 포인트 이력만 조회 허용" ON public.point_transactions
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

-- 7. coupons RLS
CREATE POLICY "판매 쿠폰 누구나 조회 허용" ON public.coupons
  FOR SELECT USING (true);

CREATE POLICY "관리자만 쿠폰 CUD 허용" ON public.coupons
  FOR ALL USING (public.is_admin());

-- 8. user_coupons RLS
CREATE POLICY "본인 보유 쿠폰만 조회 허용" ON public.user_coupons
  FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "본인 쿠폰 사용 처리 허용" ON public.user_coupons
  FOR UPDATE USING (auth.uid() = user_id AND status = 'UNUSED')
  WITH CHECK (status = 'USED');

-- 9. news RLS
CREATE POLICY "뉴스 전체 조회 허용" ON public.news
  FOR SELECT USING (true);

CREATE POLICY "관리자만 뉴스 관리 허용" ON public.news
  FOR ALL USING (public.is_admin());

-- 10. stock_price_history RLS
CREATE POLICY "시세 차트 히스토리 누구나 조회 허용" ON public.stock_price_history
  FOR SELECT USING (true);
