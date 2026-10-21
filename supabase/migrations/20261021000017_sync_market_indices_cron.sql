-- ========================================================
-- Migration: Schedule Real-time Market Indices Sync (KOSPI & KOSDAQ)
-- Date: 2026-10-21
-- Description:
-- 1. Ensure pg_net and pg_cron extensions are enabled.
-- 2. Schedule 'sync-market-indices-job' via pg_cron.
--    - Target: Supabase Edge Function 'sync-market-indices'
--    - Schedule: '*/10 0-6 * * 1-5' (Every 10 min during 00:00~06:59 UTC, Monday to Friday)
--    - KST equivalent: 09:00 ~ 15:59 KST (Korean Stock Market Trading Hours)
-- ========================================================

CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
DECLARE
    v_job_id INT;
BEGIN
    -- 기존에 동일한 이름의 job이 등록되어 있다면 삭제 후 재등록
    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'sync-market-indices-job';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

    -- 평일 09:00~15:50 (KST) 10분 주기 스케줄 등록
    PERFORM cron.schedule(
        'sync-market-indices-job',
        '*/10 0-6 * * 1-5',
        $CRON$
        SELECT net.http_post(
            url := 'https://ulgbshgzwmnytejfutsb.supabase.co/functions/v1/sync-market-indices',
            headers := jsonb_build_object('Content-Type', 'application/json'),
            body := '{"source": "pg_cron"}'::jsonb
        );
        $CRON$
    );
END $$;
