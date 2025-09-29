# file: bin/seed_demo.sh
#!/usr/bin/env bash
set -euo pipefail
# Why: Seed de démo idempotent pour débloquer l'UI Factures et tester PDF.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! docker compose ps >/dev/null 2>&1; then
  echo "Docker compose not ready. Run from repo root." >&2
  exit 1
fi

echo "[STEP] Seeding demo data into API DB…"
docker compose exec -T api python - <<'PY'
import asyncio, random, time
from datetime import datetime, timedelta, date
from sqlalchemy import select, and_
from app.db import database
from app import models

async def seed():
    await database.connect()
    try:
        utbl = models.User.__table__
        u = await database.fetch_one(select(utbl).limit(1))
        if not u:
            print("No user found. Create admin via UI first."); return
        company_id = int(u["company_id"])

        ctbl = models.Client.__table__
        itbl = models.Invoice.__table__
        ltbl = models.InvoiceLine.__table__

        clients = [
            ("Acme SARL",   "facturation+acme@example.com",   "0102030405"),
            ("Globex SA",   "billing+globex@example.com",     "0102030406"),
            ("Initech SAS", "accounting+initech@example.com", "0102030407"),
        ]

        client_ids = {}
        for name,email,phone in clients:
            row = await database.fetch_one(
                select(ctbl.c.id).where(and_(ctbl.c.company_id==company_id, ctbl.c.name==name))
            )
            if row:
                cid = int(row[0])
            else:
                cid = await database.execute(ctbl.insert().values(
                    name=name, email=email, phone=phone, company_id=company_id
                ))
            client_ids[name] = cid

        # 6 derniers mois
        today = datetime.utcnow().date()
        statuses = ["draft", "sent", "paid", "overdue"]
        random.seed(42)

        def month_offset(d: date, months_back: int) -> date:
            # approx: 30 jours pour simplifier les démos
            return d - timedelta(days=30*months_back)

        created = 0
        for idx, (name, _, _) in enumerate(clients, start=1):
            for m in range(6):
                issued = month_offset(today, m)
                number = f"DEMO-{issued.strftime('%Y%m')}-{idx:02d}"
                exists = await database.fetch_one(
                    select(itbl.c.id).where(and_(itbl.c.company_id==company_id, itbl.c.number==number))
                )
                if exists:
                    continue

                status = random.choice(statuses)
                iid = await database.execute(itbl.insert().values(
                    number=number,
                    title=f"Prestation {name}",
                    status=status,
                    currency="EUR",
                    total_cents=0,
                    issued_date=issued,
                    due_date=issued + timedelta(days=30),
                    client_id=client_ids[name],
                    company_id=company_id,
                ))

                total = 0
                # 1 à 3 lignes
                for li in range(1, random.randint(1,3)+1):
                    qty = random.randint(1,4)
                    unit = random.choice([2500, 4990, 9990, 12000, 19900])  # en cents
                    line_total = qty * unit
                    total += line_total
                    await database.execute(ltbl.insert().values(
                        invoice_id=iid,
                        description=f"Service {li}",
                        qty=qty,
                        unit_price_cents=unit,
                        total_cents=line_total,
                    ))

                await database.execute(itbl.update().where(itbl.c.id==iid).values(total_cents=total))
                created += 1

        print(f"Seed done. Invoices created: {created}")
    finally:
        await database.disconnect()

asyncio.run(seed())
PY

echo "[STEP] Done. Open UI: http://localhost:3000 (onglet Factures)"
echo "       API list:     http://localhost:8000/docs -> GET /invoices/_list"
