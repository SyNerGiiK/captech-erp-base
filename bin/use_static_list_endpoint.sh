# bin/use_static_list_endpoint.sh
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ipy="$root/backend/app/routers/invoices.py"
fx="$root/frontend/src/Invoices.jsx"

[[ -f "$ipy" ]] || { echo "[ERR] introuvable: $ipy"; exit 1; }
[[ -f "$fx"  ]] || { echo "[ERR] introuvable: $fx";  exit 1; }

cp -a "$ipy" "${ipy}.bak_$(date +%Y%m%d_%H%M%S)"
cp -a "$fx"  "${fx}.bak_$(date +%Y%m%d_%H%M%S)"

# 1) Backend: renommer /invoices/list -> /invoices/_list si présent
if grep -q '@router.get("/invoices/list")' "$ipy"; then
  sed -i 's#@router.get("/invoices/list")#@router.get("/invoices/_list")#g' "$ipy"
  echo "[OK] renommé /invoices/list -> /invoices/_list"
fi

# 1bis) Si aucun des deux n'existe, on ajoute /invoices/_list
if ! grep -q '@router.get("/invoices/_list")' "$ipy"; then
  # Assurer imports
  grep -q "from fastapi import Depends" "$ipy" || sed -i '1i from fastapi import Depends' "$ipy"
  grep -q "from sqlalchemy import select, and_" "$ipy" || sed -i '1i from sqlalchemy import select, and_' "$ipy"
  grep -q "from app.auth_utils import get_current_user" "$ipy" || sed -i '1i from app.auth_utils import get_current_user' "$ipy"
  grep -q "from app import models" "$ipy" || sed -i '1i from app import models' "$ipy"
  grep -q "from app.db import database" "$ipy" || sed -i '1i from app.db import database' "$ipy"

  # Injecter la route en tête (avant tout @router.)
  tmp="$ipy.tmp.$$"
  {
    awk 'BEGIN{done=0}
      /^@router\./ && !done { 
        print "@router.get(\"/invoices/_list\")\nasync def list_invoices_static(limit: int = 50, offset: int = 0, user=Depends(get_current_user)):\n    inv = models.Invoice.__table__\n    rows = await database.fetch_all(\n        select(inv)\n        .where(inv.c.company_id == user[\"company_id\"]) \n        .order_by(inv.c.id.desc())\n        .limit(limit).offset(offset)\n    )\n    return rows\n";
        done=1
      }
      { print }
    ' "$ipy"
    # Si aucun @router. trouvé, append à la fin
    if ! grep -q '^@router\.' "$ipy"; then
      cat <<'PYEOF'
@router.get("/invoices/_list")
async def list_invoices_static(limit: int = 50, offset: int = 0, user=Depends(get_current_user)):
    inv = models.Invoice.__table__
    rows = await database.fetch_all(
        select(inv)
        .where(inv.c.company_id == user["company_id"])
        .order_by(inv.c.id.desc())
        .limit(limit).offset(offset)
    )
    return rows
PYEOF
    fi
  } > "$tmp"
  mv "$tmp" "$ipy"
  echo "[OK] ajouté /invoices/_list"
fi

# 2) Frontend: pointer vers /invoices/_list
sed -i -E 's#/invoices/(\\?limit=50&offset=0|list\\?limit=50&offset=0)#/invoices/_list?limit=50\&offset=0#g' "$fx"

echo "[STEP] docker compose restart api web"
docker compose restart api web

echo "✅ Teste maintenant: http://localhost:3000 (Factures → Rafraîchir)"
echo "   Si non connecté, onglet Auth puis reviens."
