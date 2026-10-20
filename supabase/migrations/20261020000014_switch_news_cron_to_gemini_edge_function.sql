-- ========================================================
-- Migration: Switch News Cron to Gemini 2.5 Flash Lite Edge Function
-- Date: 2026-10-20
-- Description:
-- 1. Enable pg_net extension for asynchronous HTTP requests.
-- 2. Switch pg_cron 'auto-generate-news-job' from static SQL template RPC
--    to invoking the 'generate-news' Edge Function powered by Google Gemini API.
-- ========================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

-- Re-schedule news cron job to call Edge Function every 5 minutes
DO $$
DECLARE
    v_job_id INT;
BEGIN
    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'auto-generate-news-job';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
        'auto-generate-news-job',
        '*/5 * * * *',
        $CRON$
        SELECT net.http_post(
            url := 'https://ulgbshgzwmnytejfutsb.supabase.co/functions/v1/generate-news',
            headers := jsonb_build_object('Content-Type', 'application/json'),
            body := '{}'::jsonb
        );
        $CRON$
    );
END $$;
