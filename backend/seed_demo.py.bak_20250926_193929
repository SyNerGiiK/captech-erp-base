import asyncio
from datetime import datetime
from sqlalchemy import select, func, and_
from app.db import database
from app import models
from app.link_utils import create_signed_token

async def main():
    await database.connect()
    # pick any existing user to get company_id
    utbl = models.User.__table__
    u = await database.fetch_one(select(utbl).limit(1))
    if not u:
        print("NO_USER")
        await database.disconnect()
        return
    company_id = int(u["company_id"])

    ctbl = models.Client.__table__
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    # ensure demo client
    client = await database.fetch_one(
        select(ctbl).where(and_(ctbl.c.company_id==company_id, ctbl.c.email=="demo.client@example.com"))
    )
    if client:
        cid = int(client["id"])
    else:
        cid = await database.execute(ctbl.insert().values(
            name="Client Demo",
            email="demo.client@example.com",
            phone="0600000000",
            company_id=company_id
        ))

    # create invoice
    count = await database.fetch_val(
        select(func.count()).select_from(itbl).where(itbl.c.company_id==company_id)
    ) or 0
    number = f"F-{datetime.utcnow().year}-{(int(count)+1):04d}"
    iid = await database.execute(itbl.insert().values(
        number=number,
        title="Facture Demo",
        status="draft",
        currency="EUR",
        total_cents=0,
        issued_date=None,
        due_date=None,
        client_id=cid,
        company_id=company_id
    ))

    # add lines
    lines = [("Prestation A", 2, 15000), ("Prestation B", 1, 9900)]
    total = 0
    for desc, qty, unit in lines:
        total += qty * unit
        await database.execute(ltbl.insert().values(
            invoice_id=iid,
            description=desc,
            qty=int(qty),
            unit_price_cents=int(unit),
            total_cents=int(qty*unit),
        ))
    await database.execute(
        itbl.update().where(and_(itbl.c.id==iid, itbl.c.company_id==company_id)).values(total_cents=int(total))
    )

    # mark sent to set dates (optional)
    await database.execute(itbl.update().where(itbl.c.id==iid).values(status="sent"))

    # make signed link (PDF)
    token = create_signed_token(
        kind="invoice_pdf",
        data={"invoice_id": int(iid), "company_id": company_id},
        ttl_seconds=900
    )
    path = f"/invoices/public/{iid}/download.pdf?token={token}"
    print("OK", cid, iid, number, path)

    await database.disconnect()

if __name__ == "__main__":
    asyncio.run(main())