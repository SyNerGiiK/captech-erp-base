# bin/fix_invoices_403.sh  — à créer à la racine du repo (WSL)
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

ipy="$root/backend/app/routers/invoices.py"
fx="$root/frontend/src/Invoices.jsx"

[[ -f "$ipy" ]] || { echo "[ERR] introuvable: $ipy"; exit 1; }
[[ -f "$fx"  ]] || { echo "[ERR] introuvable: $fx";  exit 1; }

cp -a "$ipy" "${ipy}.bak_$(date +%Y%m%d_%H%M%S)"
cp -a "$fx"  "${fx}.bak_$(date +%Y%m%d_%H%M%S)"

# Assurer imports requis (idempotent)
grep -q "from fastapi import Depends" "$ipy" || sed -i '1i from fastapi import Depends, HTTPException' "$ipy"
grep -q "from sqlalchemy import select, and_" "$ipy" || sed -i '1i from sqlalchemy import select, and_' "$ipy"
grep -q "from app.auth_utils import get_current_user" "$ipy" || sed -i '1i from app.auth_utils import get_current_user' "$ipy"
grep -q "from app import models" "$ipy" || sed -i '1i from app import models' "$ipy"
grep -q "from app.db import database" "$ipy" || sed -i '1i from app.db import database' "$ipy"

# Ajouter un endpoint "safe" pour la liste des factures (ne touche pas l'existant)
if ! grep -q '@router.get("/invoices/list")' "$ipy"; then
  cat >> "$ipy" <<'PYEOF'

@router.get("/invoices/list")
async def list_invoices_safe(limit: int = 50, offset: int = 0, user=Depends(get_current_user)):
    inv = models.Invoice.__table__
    rows = await database.fetch_all(
        select(inv)
        .where(inv.c.company_id == user["company_id"])
        .order_by(inv.c.id.desc())
        .limit(limit).offset(offset)
    )
    return rows
PYEOF
  echo "[OK] /invoices/list ajouté"
else
  echo "[SKIP] /invoices/list déjà présent"
fi

# Pointer le front vers le nouvel endpoint
sed -i 's#/invoices/\?limit=50&offset=0#/invoices/list?limit=50\&offset=0#g' "$fx"

echo "[STEP] docker compose restart api web"
docker compose restart api web

echo "✅ Fini. Ouvre http://localhost:3000 → Factures → Rafraîchir."
