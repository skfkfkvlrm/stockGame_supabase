-- ========================================================
-- Migration: 20261020000016_clean_zero_share_holdings.sql
-- Description: Zero-Share Holding Pruning & Proportional Invested Amount Integrity Trigger
-- Target: PostgreSQL 15+ (Supabase BaaS)
-- Projects: stockGame_supabase (Remote ID: ulgbshgzwmnytejfutsb)
-- ========================================================

-- 1. 기존 잔여 보유 수량이 0인 모든 고스트 레코드 즉시 삭제 청산
DELETE FROM public.user_holdings
WHERE amount <= 0 AND locked_amount <= 0;

-- 2. user_holdings 변경 전 무결성 방어 트리거 함수 (BEFORE UPDATE OR INSERT)
-- - 수량이 0 이하가 되면 잔류 투자원금(total_invested_amount)과 평단가를 0으로 초기화
-- - 부분 매도 등으로 수량이 남아있을 경우 투자원금을 잔여수량 비례(잔여수량 * 평단가)로 재산출
CREATE OR REPLACE FUNCTION public.trg_fn_clean_zero_user_holdings()
RETURNS TRIGGER AS $$
BEGIN
    -- 사용자의 보유 수량과 락 수량이 모두 0 이하인 경우 고스트 데이터 리셋
    IF NEW.amount <= 0 AND NEW.locked_amount <= 0 THEN
        NEW.amount := 0;
        NEW.locked_amount := 0;
        NEW.total_invested_amount := 0;
        NEW.average_price := 0;
    -- 부분 매도 등으로 잔여 주식이 남아있는 경우: 투자원금을 잔여 주식 기준(잔여주식 * 평단가)으로 비례 정합화
    ELSIF (NEW.amount + NEW.locked_amount) > 0 AND NEW.average_price > 0 THEN
        NEW.total_invested_amount := (NEW.amount + NEW.locked_amount)::BIGINT * NEW.average_price::BIGINT;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_clean_zero_user_holdings ON public.user_holdings;
CREATE TRIGGER trg_clean_zero_user_holdings
BEFORE UPDATE OR INSERT ON public.user_holdings
FOR EACH ROW
EXECUTE FUNCTION public.trg_fn_clean_zero_user_holdings();

-- 3. 전량 매도 완료된 0주 레코드 자동 정리 트리거 (AFTER UPDATE)
-- 수량이 0이 된 보유 주식 행을 테이블에서 즉시 DELETE하여 불필요한 테이블 비대화 및 0주 노출 원천 차단
CREATE OR REPLACE FUNCTION public.trg_fn_delete_zero_user_holdings()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.amount <= 0 AND NEW.locked_amount <= 0 THEN
        DELETE FROM public.user_holdings WHERE id = NEW.id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_delete_zero_user_holdings ON public.user_holdings;
CREATE TRIGGER trg_delete_zero_user_holdings
AFTER UPDATE ON public.user_holdings
FOR EACH ROW
WHEN (NEW.amount <= 0 AND NEW.locked_amount <= 0)
EXECUTE FUNCTION public.trg_fn_delete_zero_user_holdings();

-- 4. 관리자 일괄 정리용 유지보수 RPC 함수 신설 (admin_clean_zero_holdings)
CREATE OR REPLACE FUNCTION public.admin_clean_zero_holdings()
RETURNS JSONB AS $$
DECLARE
    v_deleted_count INT := 0;
BEGIN
    IF NOT public.is_admin() AND current_user NOT IN ('postgres', 'supabase_admin') AND auth.role() != 'service_role' THEN
        RAISE EXCEPTION '관리자 권한이 필요합니다.';
    END IF;

    WITH deleted_rows AS (
        DELETE FROM public.user_holdings
        WHERE amount <= 0 AND locked_amount <= 0
        RETURNING id
    )
    SELECT COUNT(*) INTO v_deleted_count FROM deleted_rows;

    RETURN jsonb_build_object(
        'success', true,
        'deletedZeroHoldingsCount', v_deleted_count,
        'cleanedAt', NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
