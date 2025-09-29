# bin/route_by_id_refactor.sh  (version corrigée)
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ipy="$root/backend/app/routers/invoices.py"
fx="$root/frontend/src/Invoices.jsx"

[[ -f "$ipy" ]] || { echo "[ERR] Introuvable: $ipy"; exit 1; }
[[ -f "$fx"  ]] || { echo "[ERR] Introuvable: $fx";  exit 1; }

ts="$(date +%Y%m%d_%H%M%S)"
cp -a "$ipy" "$ipy.bak_$ts"
cp -a "$fx"  "$fx.bak_$ts"

echo '[1/3] Backend: rename /invoices/{invoice_id} -> /invoices/by-id/{invoice_id}'
# verbs: get|put|patch|delete|post (au cas où)
perl -0777 -pe 's#(@router\.(?:get|put|patch|delete|post)\(\s*")/invoices/\{invoice_id\}#${1}/invoices/by-id/{invoice_id}#g' -i "$ipy"
# cas avec suffixes (ex: /download.pdf, autres sous-routes)
perl -0777 -pe 's#(@router\.(?:get|put|patch|delete|post)\(\s*")/invoices/\{invoice_id\}/#${1}/invoices/by-id/{invoice_id}/#g' -i "$ipy"

echo '[2/3] Frontend: update template strings vers /invoices/by-id/${id}'
# d'abord le cas spécifique download.pdf
perl -0777 -pe 's#/invoices/\$\{([^}]+)\}/download\.pdf#/invoices/by-id/\$\{\1\}/download.pdf#g' -i "$fx"
# puis le cas générique (éviter _list et les requêtes liste)
perl -0777 -pe 's#/invoices/\$\{([^}]+)\}(?!/_list|\?limit)#/invoices/by-id/\$\{\1\}#g' -i "$fx"

echo '[3/3] Restart containers'
docker compose restart api web

echo
echo '✅ Refactor terminé.'
echo 'Test API:   http://localhost:8000/docs'
echo 'Test Front: http://localhost:3000 (Factures → Rafraîchir)'
echo
echo 'Astuce curl (facultatif):'
echo '  TOKEN=...; curl -i "http://localhost:8000/invoices/_list?limit=5" -H "Authorization: Bearer $TOKEN"'
