from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from app.db import database
from app.deps import get_current_user
from app.reporting import refresh_matviews

router = APIRouter(prefix="/reports", tags=["reports"])

@router.post("/refresh", status_code=202)
async def reports_refresh(user=Depends(get_current_user)):
    await refresh_matviews()
    return {"refreshed": True}

@router.get("/status")
async def reports_status(refresh: bool = False, user=Depends(get_current_user)):
    if refresh:
        await refresh_matviews()
    sql = text("""
        SELECT status, count, amount_cents
        FROM mv_quotes_by_status
        WHERE company_id = :cid
        ORDER BY status
    """).bindparams(cid=user["company_id"])
    rows = await database.fetch_all(sql)
    return [dict(r) for r in rows]

@router.get("/monthly")
async def reports_monthly(months: int = Query(12, ge=1, le=36), refresh: bool = False, user=Depends(get_current_user)):
    if refresh:
        await refresh_matviews()
    sql = text(f"""
        SELECT month, amount_cents
        FROM mv_monthly_revenue
        WHERE company_id = :cid
          AND month >= date_trunc('month', now()) - INTERVAL '{months-1} months'
        ORDER BY month ASC
    """).bindparams(cid=user["company_id"])
    rows = await database.fetch_all(sql)
    return [{"month": r["month"].strftime("%Y-%m"), "amount_cents": int(r["amount_cents"])} for r in rows]