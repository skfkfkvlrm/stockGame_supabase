-- ========================================================================
-- Migration: 20261021000018_sync_market_indices_closing_cron.sql
-- Description:
-- 1. Extend market indices collection schedule with 16:00 KST closing job.
--    - Target: Supabase Edge Function 'sync-market-indices'
--    - Schedule: '0 7 * * 1-5' (16:00 KST / 07:00 UTC, Monday to Friday)
--    - Purpose: Fetch 100% confirmed KRX closing index & final 7-day history.
-- ========================================================================

CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    -- Check if existing closing job already registered
    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'sync-market-indices-closing-job';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

    -- Schedule closing job at 16:00 KST (07:00 UTC) every weekday (Mon-Fri)
    PERFORM cron.schedule(
        'sync-market-indices-closing-job',
        '0 7 * * 1-5',
        $CRON$
        SELECT net.http_post(
            url := 'https://ulgbshgzwmnytejfutsb.supabase.co/functions/v1/sync-market-indices',
            headers := jsonb_build_object('Content-Type', 'application/json'),
            body := '{"source": "pg_cron_closing"}'::jsonb
        );
        $CRON$
    );
END $$;
