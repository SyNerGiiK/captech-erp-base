# bin/run_route_tests.sh
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
testfile="$root/backend/tests/test_routes_invoices.py"

mkdir -p "$root/backend/tests"

# Écrit le test si absent
if [[ ! -f "$testfile" ]]; then
  cat > "$testfile" <<'PYEOF'
import pytest
from starlette.routing import Route
from app.main import app

def _routes():
    return [r for r in app.routes if isinstance(r, Route)]

def _find(path: str, method: str):
    for r in _routes():
        if r.path == path and method.upper() in (r.methods or set()):
            return r
    return None

def test_has_static_list_route():
    assert _find("/invoices/_list", "GET") is not None

def test_no_legacy_dynamic_root():
    assert all(not r.path.startswith("/invoices/{") for r in _routes())

def test_has_by_id_routes():
    assert any(r.path.startswith("/invoices/by-id/{invoice_id}") for r in _routes())

@pytest.mark.anyio
async def test_static_list_not_captured_by_dynamic_returns_not_422():
    import httpx
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get("/invoices/_list")
    assert resp.status_code != 422

@pytest.mark.anyio
async def test_by_id_path_requires_int():
    import httpx
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
        resp = await ac.get("/invoices/by-id/abc")
    assert resp.status_code == 422
PYEOF
  echo "[OK] test_routes_invoices.py créé"
else
  echo "[SKIP] test_routes_invoices.py déjà présent"
fi

echo "[STEP] docker compose exec -T api pytest -q /app/tests/test_routes_invoices.py"
docker compose exec -T api pytest -q /app/tests/test_routes_invoices.py
