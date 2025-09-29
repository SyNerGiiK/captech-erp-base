# 0) VA DANS TON PROJET (adapte le chemin si besoin)
cd ~/captech-erp-base 2>/dev/null || cd /mnt/g/captech-erp-base

# 1) VERIF: on doit voir "backend" et "frontend"
ls backend frontend >/dev/null || { echo "✖ Place-toi dans le dossier captech-erp-base"; exit 1; }

# 2) ECRIS LE Makefile (WSL/Linux)
cat > Makefile <<'EOF'
SHELL := /bin/bash
.PHONY: up down build logs seed test restart-api restart-web

up:            ## start stack
	docker compose up -d

down:          ## stop stack
	docker compose down

build:         ## rebuild API (no-cache)
	docker compose build --no-cache api

logs:          ## API logs
	docker compose logs -f api

seed:          ## demo seed if available
	- docker compose exec -T api python /app/seed_demo.py

test:          ## run PDF public tests
	docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py

restart-api:
	docker compose restart api

restart-web:
	docker compose restart web
EOF

# 3) ECRIS LE SCRIPT DE PATCH
mkdir -p bin
cat > bin/apply_resume_patch.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

req() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
req docker; req awk; req sed

# FRONT env (API directe, pas de proxy)
mkdir -p "$root/frontend"
cat > "$root/frontend/.env.local" <<EOT
VITE_USE_PROXY=0
VITE_API_URL=http://localhost:8000
EOT
echo "[OK] frontend/.env.local written"

# BACKEND: ajouter /invoices/{id}/public_url si absent
ipy="$root/backend/app/routers/invoices.py"
[[ -f "$ipy" ]] || { echo "[ERR] not found: $ipy"; exit 1; }

if ! grep -q "def get_invoice_public_url" "$ipy"; then
  # Imports (idempotent)
  grep -q "from fastapi import Depends" "$ipy" || sed -i '1i from fastapi import Depends, HTTPException' "$ipy"
  grep -q "from sqlalchemy import select, and_" "$ipy" || sed -i '1i from sqlalchemy import select, and_' "$ipy"
  grep -q "from app.auth_utils import get_current_user" "$ipy" || sed -i '1i from app.auth_utils import get_current_user' "$ipy"
  grep -q "from app.link_utils import create_signed_token" "$ipy" || sed -i '1i from app.link_utils import create_signed_token' "$ipy"

  cat >> "$ipy" <<'PYEOF'

@router.get("/invoices/{invoice_id}/public_url")
async def get_invoice_public_url(invoice_id: int, user=Depends(get_current_user)):
    inv_tbl = models.Invoice.__table__
    inv = await database.fetch_one(
        select(inv_tbl).where(and_(inv_tbl.c.id==invoice_id, inv_tbl.c.company_id==user["company_id"]))
    )
    if not inv:
        raise HTTPException(status_code=404, detail="Invoice not found")
    token = create_signed_token(
        kind="invoice_pdf",
        data={"invoice_id": int(invoice_id), "company_id": int(user["company_id"])},
        ttl_seconds=300
    )
    return {"path": f"/invoices/public/{int(invoice_id)}/download.pdf", "token": token}
PYEOF
  echo "[OK] backend endpoint public_url added"
else
  echo "[SKIP] backend endpoint already present"
fi

# FRONT: Invoices.jsx propre
mkdir -p "$root/frontend/src"
cat > "$root/frontend/src/Invoices.jsx" <<'JSX'
import React, { useEffect, useState } from "react";

const apiBase = (import.meta.env.VITE_USE_PROXY === "1")
  ? "/api"
  : (import.meta.env.VITE_API_URL ?? "http://localhost:8000");

export default function Invoices() {
  const [items, setItems] = useState([]);
  const [sel, setSel] = useState(null);
  const [loading, setLoading] = useState(false);
  const [vat, setVat] = useState(20);

  const session = (() => {
    try { return JSON.parse(localStorage.getItem("session") || "null"); }
    catch { return null; }
  })();
  const token = session?.token ?? "";

  async function refresh() {
    setLoading(true);
    try {
      const res = await fetch(`${apiBase}/invoices/?limit=50&offset=0`, {
        headers: { "Authorization": `Bearer ${token}` }
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const rows = Array.isArray(data) ? data : (data.items ?? []);
      setItems(rows);
      if (rows.length && !sel) setSel(rows[0]);
    } catch (e) {
      console.error("refresh invoices failed", e);
      alert("Impossible de charger les factures (voir console).");
    } finally {
      setLoading(false);
    }
  }

  async function downloadPdf() {
    if (!sel?.id) { alert("Sélectionne une facture."); return; }
    try {
      const res = await fetch(`${apiBase}/invoices/${sel.id}/public_url`, {
        headers: { "Authorization": `Bearer ${token}` }
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json(); // { path, token }
      const url = `${apiBase}${data.path}?token=${encodeURIComponent(data.token)}&vat_percent=${encodeURIComponent(vat)}`;
      window.open(url, "_blank", "noopener");
    } catch (e) {
      console.error("download pdf failed", e);
      alert("Téléchargement PDF impossible.");
    }
  }

  useEffect(() => { refresh(); /* eslint-disable-next-line */ }, []);

  return (
    <div style={{ padding: 16 }}>
      <h2>Factures</h2>
      <div style={{ marginBottom: 12, display: "flex", gap: 8, alignItems: "center" }}>
        <button onClick={refresh} disabled={loading}>Rafraîchir</button>
        <label>TVA %:&nbsp;
          <input type="number" min="0" max="25" value={vat} onChange={e => setVat(e.target.value)} style={{ width: 64 }} />
        </label>
        <button onClick={downloadPdf} disabled={!sel}>Télécharger (PDF)</button>
      </div>

      {loading && <p>Chargement…</p>}

      {!loading && items.length === 0 && (
        <p>Aucune facture. Crée une facture depuis l’API (/docs) ou via le seed.</p>
      )}

      {!loading && items.length > 0 && (
        <table border="1" cellPadding="6" style={{ borderCollapse: "collapse", width: "100%" }}>
          <thead>
            <tr>
              <th>ID</th>
              <th>Numéro</th>
              <th>Titre</th>
              <th>Statut</th>
              <th>Total</th>
            </tr>
          </thead>
          <tbody>
            {items.map(it => (
              <tr key={it.id}
                  onClick={() => setSel(it)}
                  style={{ background: sel?.id === it.id ? "#eef" : "transparent", cursor: "pointer" }}>
                <td>{it.id}</td>
                <td>{it.number}</td>
                <td>{it.title}</td>
                <td>{it.status}</td>
                <td>{(it.total_cents ?? 0) / 100} €</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
JSX
echo "[OK] frontend/src/Invoices.jsx written"

# RESTART containers
echo "[STEP] docker compose restart api web"
docker compose restart api web

echo
echo "✅ Done."
echo "Front: http://localhost:3000  (onglet Factures)"
echo "API  : http://localhost:8000/docs"
EOF

# 4) RENDRE EXE ET LANCER
chmod +x bin/apply_resume_patch.sh
./bin/apply_resume_patch.sh
