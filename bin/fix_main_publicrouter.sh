#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MAIN="backend/app/main.py"
BACKUP="${MAIN}.bak_$(date +%Y%m%d_%H%M%S)"

echo "[BACKUP] $MAIN -> $BACKUP"
cp "$MAIN" "$BACKUP"

echo "[PATCH] remove 'public_router' import/use"
# 1) supprime la ligne d'import du public_router si présente
sed -i -E 's/^from app\.routers\.invoices import public_router.*$//g' "$MAIN"
# 2) supprime l’inclusion éventuelle du public_router
sed -i -E 's/^\s*app\.include_router\(\s*public_router\s*\)\s*$//g' "$MAIN"

echo "[RESTART] docker compose restart api"
docker compose restart api

echo "[TEST] tests public pdf"
docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py
