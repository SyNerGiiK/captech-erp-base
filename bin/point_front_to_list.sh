# bin/point_front_to_list.sh
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fx="$root/frontend/src/Invoices.jsx"

[[ -f "$fx" ]] || { echo "[ERR] introuvable: $fx"; exit 1; }

cp -a "$fx" "${fx}.bak_$(date +%Y%m%d_%H%M%S)"

# Remplace l'ancien endpoint par le nouveau
sed -i -E 's#/invoices/\?limit=50&offset=0#/invoices/list?limit=50\&offset=0#g' "$fx"

# Sanity: montre la ligne fetch
echo "---- Lignes fetch dans Invoices.jsx ----"
grep -n "fetch\(" "$fx" | sed -n '1,5p' || true
echo "----------------------------------------"

echo "[STEP] docker compose restart web"
docker compose restart web

echo "✅ OK. Ouvre http://localhost:3000 → Factures → clique « Rafraîchir »."
