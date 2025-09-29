import re
import time
import pytest
import httpx
from datetime import date
from sqlalchemy import select, and_

from app.main import app
from app.db import database
from app import models
from app.auth_utils import get_current_user
from httpx import ASGITransport


async def _first_ok(ac: httpx.AsyncClient, paths: list[str]) -> httpx.Response | None:
    for p in paths:
        r = await ac.get(p)
        if r.status_code < 400:
            return r
    return None


@pytest.mark.anyio
@pytest.mark.parametrize("anyio_backend", ["asyncio"])
async def test_public_url_happy_path(anyio_backend):
    """Doit renvoyer 200 + une URL .../public/{invoice_id}/download.pdf?token=..."""
    await database.connect()
    try:
        # 1) user -> company_id
        utbl = models.User.__table__
        u = await database.fetch_one(select(utbl).limit(1))
        if not u:
            pytest.skip("Aucun utilisateur. Crée l'admin via l'UI, puis relance le test.")
        company_id = int(u["company_id"])

        # 2) client + facture + ligne
        ctbl = models.Client.__table__
        itbl = models.Invoice.__table__
        ltbl = models.InvoiceLine.__table__

        suffix = int(time.time())
        cid = await database.execute(
            ctbl.insert().values(
                name=f"TestClient-{suffix}",
                email=f"test.client.{suffix}@example.com",
                phone="0600000000",
                company_id=company_id,
            )
        )
        iid = await database.execute(
            itbl.insert().values(
                number=f"T-{suffix}",
                title="Test PDF",
                status="sent",
                currency="EUR",
                total_cents=0,
                issued_date=date.today(),   # ✅ date, pas str
                due_date=None,
                client_id=cid,
                company_id=company_id,
            )
        )
        await database.execute(
            ltbl.insert().values(
                invoice_id=iid,
                description="Ligne test",
                qty=1,
                unit_price_cents=12345,
                total_cents=12345,
            )
        )
        await database.execute(
            itbl.update()
            .where(and_(itbl.c.id == iid, itbl.c.company_id == company_id))
            .values(total_cents=12345)
        )

        # 3) override auth
        async def _fake_user():
            return {"company_id": company_id}
        app.dependency_overrides[get_current_user] = _fake_user

        # 4) call endpoint (chemins tolérants selon l'état du routeur)
        transport = ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
            candidates = [
                f"/invoices/by-id/{int(iid)}/public_url",
                f"/invoices/{int(iid)}/public_url",
                f"/invoices/{int(iid)}/public-url",
            ]
            resp = await _first_ok(ac, candidates)

        assert resp is not None, "Aucun des chemins public_url n'existe"
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert "url" in data and isinstance(data["url"], str)
        assert re.search(rf"/public/{int(iid)}/download\.pdf\?token=", data["url"])

    finally:
        app.dependency_overrides.pop(get_current_user, None)
        await database.disconnect()


@pytest.mark.anyio
@pytest.mark.parametrize("anyio_backend", ["asyncio"])
async def test_public_url_404_other_company(anyio_backend):
    """Doit renvoyer 404 si la facture appartient à une autre société."""
    await database.connect()
    try:
        utbl = models.User.__table__
        u = await database.fetch_one(select(utbl).limit(1))
        if not u:
            pytest.skip("Aucun utilisateur. Crée l'admin via l'UI, puis relance le test.")
        user_company_id = int(u["company_id"])

        ctbl = models.Client.__table__
        itbl = models.Invoice.__table__
        ltbl = models.InvoiceLine.__table__
        company_tbl = models.Company.__table__

        suffix = int(time.time())

        # On prend une société ≠ de l'user si elle existe, sinon on en crée une (name seul)
        other = await database.fetch_one(
            select(company_tbl.c.id).where(company_tbl.c.id != user_company_id).limit(1)
        )
        if other:
            other_company_id = int(other["id"])
        else:
            other_company_id = await database.execute(
                company_tbl.insert().values(name=f"OtherCo-{suffix}")
            )

        cid2 = await database.execute(
            ctbl.insert().values(
                name=f"ClientOther-{suffix}",
                email=f"client.other.{suffix}@example.com",
                phone="0600000001",
                company_id=other_company_id,
            )
        )
        iid2 = await database.execute(
            itbl.insert().values(
                number=f"T-OTHER-{suffix}",
                title="Other Co",
                status="draft",
                currency="EUR",
                total_cents=1000,
                issued_date=date.today(),
                due_date=None,
                client_id=cid2,
                company_id=other_company_id,
            )
        )
        await database.execute(
            ltbl.insert().values(
                invoice_id=iid2,
                description="Other line",
                qty=1,
                unit_price_cents=1000,
                total_cents=1000,
            )
        )

        async def _fake_user():
            return {"company_id": user_company_id}
        app.dependency_overrides[get_current_user] = _fake_user

        transport = ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
            candidates = [
                f"/invoices/by-id/{int(iid2)}/public_url",
                f"/invoices/{int(iid2)}/public_url",
                f"/invoices/{int(iid2)}/public-url",
            ]
            # On veut 404 sur tous les chemins candidats
            results = [await ac.get(p) for p in candidates]

        assert all(r.status_code == 404 for r in results), \
            "L'endpoint ne renvoie pas 404 pour une facture d'une autre société"

    finally:
        app.dependency_overrides.pop(get_current_user, None)
        await database.disconnect()
