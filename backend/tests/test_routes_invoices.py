from fastapi.testclient import TestClient
from starlette.routing import Route
from app.main import app

client = TestClient(app)

def _routes():
    return [r for r in app.routes if isinstance(r, Route)]

def _find_exact(path: str, method: str):
    for r in _routes():
        if r.path == path and method.upper() in (r.methods or set()):
            return r
    return None

def _has_byid_prefix():
    # Starlette peut exposer '/invoices/by-id/{invoice_id}' OU '/invoices/by-id/{invoice_id:int}'
    return any(r.path.startswith("/invoices/by-id/{invoice_id") for r in _routes())

def test_has_static_list_route():
    assert _find_exact("/invoices/_list", "GET") is not None

def test_no_legacy_dynamic_root():
    assert all(not r.path.startswith("/invoices/{") for r in _routes())

def test_has_by_id_routes():
    assert _has_byid_prefix()

def test_static_list_not_captured_by_dynamic_returns_not_422():
    resp = client.get("/invoices/_list")
    assert resp.status_code != 422  # peut être 200/401/403 selon l'auth

def test_by_id_path_requires_int():
    # Avec convertisseur ':int', Starlette retourne 404 si non convertible.
    # Sans convertisseur, FastAPI match puis valide et peut retourner 422.
    resp = client.get("/invoices/by-id/abc")
    assert resp.status_code in (404, 422)
