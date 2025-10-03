#!/usr/bin/env bash
set -euo pipefail

echo "[STEP] Cherche les derniers 'class Config:'…"
HITS=$(grep -RIn "^[[:space:]]*class[[:space:]]\+Config[[:space:]]*:" backend/app || true)
if [ -z "$HITS" ]; then
  echo "[OK] Aucun bloc 'class Config:' trouvé — le warning peut provenir d'un import indirect."
else
  echo "$HITS" | sed 's/^/  - /'
fi

python3 - << 'PY'
import re
from pathlib import Path

ROOT = Path("backend/app")

CONFIG_RE = re.compile(
    r'(?m)^(?P<indent>\s*)class\s+Config\s*:\s*\n(?P<body>(?:\s{4,}.*\n)+)'
)

def ensure_configdict_import(text: str) -> str:
    import_re = re.compile(r'(?m)^from\s+pydantic\s+import\s+([^\n]+)$')
    m = import_re.search(text)
    if not m:
        return text
    line = m.group(0)
    items = [x.strip() for x in m.group(1).split(",")]
    if "ConfigDict" not in items:
        items.append("ConfigDict")
        newline = f"from pydantic import {', '.join(sorted(set(items)))}"
        text = text.replace(line, newline)
    return text

def refactor(text: str) -> str:
    def _replace(m: re.Match) -> str:
        indent = m.group("indent")
        body = m.group("body")
        # on conserve les anciennes lignes en TODO pour vérification
        todos = "\n".join(f"{indent}# TODO(pydantic v2): vérifier -> {l.strip()}"
                          for l in body.splitlines() if l.strip())
        return f"{indent}model_config = ConfigDict(from_attributes=True)\n{todos}\n"
    return CONFIG_RE.sub(_replace, text)

changed = []
for p in ROOT.rglob("*.py"):
    txt = p.read_text(encoding="utf-8")
    if "class Config" in txt:
        new = refactor(txt)
        if new != txt:
            new = ensure_configdict_import(new)
            p.write_text(new, encoding="utf-8")
            changed.append(str(p))

if changed:
    print("[OK] Fichiers mis à jour :")
    for c in changed:
        print("  -", c)
else:
    print("[OK] Aucun fichier modifié (déjà migré ?)")
PY

echo "[STEP] Redémarre l'API"
docker compose restart api

echo "[STEP] Relance les tests"
docker compose exec -T api pytest -q \
  /app/tests/test_routes_invoices.py \
  /app/tests/test_public_url.py \
  /app/tests/test_invoice_public_pdf.py
