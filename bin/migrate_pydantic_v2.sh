#!/usr/bin/env bash
set -euo pipefail

echo "[STEP] Sauvegarde (branche) et migration Pydantic v2"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git add -A >/dev/null 2>&1 || true
  git commit -m "wip: avant migration pydantic v2" >/dev/null 2>&1 || true
  git branch -f backup-pre-pyd-v2 >/dev/null 2>&1 || true
fi

python3 bin/_pyd_v2_refactor.py

echo "[STEP] Reconstruit/Redémarre l'API"
docker compose restart api

echo "[STEP] Lancement tests (routes + public URL + public PDF)"
docker compose exec -T api pytest -q \
  /app/tests/test_routes_invoices.py \
  /app/tests/test_public_url.py \
  /app/tests/test_invoice_public_pdf.py
