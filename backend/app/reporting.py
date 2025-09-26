from app.db import database

CREATE_MATVIEWS_SQL = """
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_matviews WHERE schemaname='public' AND matviewname='mv_quotes_by_status'
  ) THEN
    CREATE MATERIALIZED VIEW public.mv_quotes_by_status AS
    SELECT
      company_id,
      status,
      COUNT(*)::bigint AS count,
      COALESCE(SUM(amount_cents),0)::bigint AS amount_cents
    FROM quotes
    GROUP BY company_id, status;
    CREATE UNIQUE INDEX IF NOT EXISTS mv_quotes_by_status_uidx
      ON public.mv_quotes_by_status(company_id, status);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_matviews WHERE schemaname='public' AND matviewname='mv_monthly_revenue'
  ) THEN
    CREATE MATERIALIZED VIEW public.mv_monthly_revenue AS
    SELECT
      company_id,
      date_trunc('month', created_at)::date AS month,
      COALESCE(SUM(amount_cents),0)::bigint AS amount_cents
    FROM quotes
    WHERE status = 'accepted'
    GROUP BY company_id, date_trunc('month', created_at)::date;
    CREATE UNIQUE INDEX IF NOT EXISTS mv_monthly_revenue_uidx
      ON public.mv_monthly_revenue(company_id, month);
  END IF;
END $$ LANGUAGE plpgsql;
"""

REFRESH_STATUS_SQL = "REFRESH MATERIALIZED VIEW public.mv_quotes_by_status;"
REFRESH_MONTHLY_SQL = "REFRESH MATERIALIZED VIEW public.mv_monthly_revenue;"

async def ensure_matviews():
    await database.execute(CREATE_MATVIEWS_SQL)

async def refresh_matviews():
    await database.execute(REFRESH_STATUS_SQL)
    await database.execute(REFRESH_MONTHLY_SQL)