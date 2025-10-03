#!/usr/bin/env bash
set -euo pipefail

echo "[STEP] Recherche des 'class Config:' restantes…"
grep -RIn --exclude-dir=.venv --exclude-dir=__pycache__ "^[[:space:]]*class[[:space:]]\+Config[[:space:]]*:" backend tests || true

python3 - << 'PY'
import re
from pathlib import Path

ROOTS = [Path("backend"), Path("tests")]

# Remplace un bloc "class Config:" (quelque soit l'indentation) par model_config = ConfigDict(...)
CONFIG_RE = re.compile(
    r'(?m)^(?P<indent>[ \t]*)class[ \t]+Config[ \t]*:[ \t]*\n(?P<body>(?:\s{4,}.*\n)+)'
)

def ensure_configdict_import(text: str) -> str:
    """
    Si on a déjà un import pydantic, injecte ConfigDict dedans.
    Sinon, ajoute un import propre au début du fichier.
    """
    import_lines = list(re.finditer(r'(?m)^from\s+pydantic\s+import\s+([^\n]+)$', text))
    if import_lines:
        m = import_lines[0]
        items = [x.strip() for x in m.group(1).split(",")]
        if "ConfigDict" not in items:
            items.append("ConfigDict")
            newline = f"from pydantic import {', '.join(sorted(set(items)))}"
            text = text[:m.start()] + newline + text[m.end():]
        return text
    # Pas d'import pydantic existant -> on en ajoute un propre juste après le 1er import
    first_import = re.search(r'(?m)^(import|from)\s+[^\n]+$', text)
    ins = "from pydantic import ConfigDict\n"
    if first_import:
        # insérer après le premier import
        pos = text.find("\n", first_import.end())
        if pos == -1:
            pos = first_import.end()
        text = text[:pos+1] + ins + text[pos+1:]
    else:
        # sinon tout en haut
        text = ins + text
    return text

def refactor_file(p: Path) -> bool:
    txt = p.read_text(encoding="utf-8")
    changed = False

    def _replace(m: re.Match) -> str:
        nonlocal changed
        changed = True
        indent = m.group("indent")
        body = m.group("body")
        # Conserve les anciennes lignes en TODO (pour vérification manuelle éventuelle)
        todos = "\n".join(f"{indent}# TODO(pydantic v2): vérifier -> {l.strip()}"
                          for l in body.splitlines() if l.strip())
        return f"{indent}model_config = ConfigDict(from_attributes=True)\n{todos}\n"

    new_txt = CONFIG_RE.sub(_replace, txt)
    if new_txt != txt:
        new_txt = ensure_configdict_import(new_txt)
        p.write_text(new_txt, encoding="utf-8")
        return True
    return False

touched = []
for root in ROOTS:
    if not root.exists():
        continue
    for p in root.rglob("*.py"):
        if ".venv" in p.parts or "__pycache__" in p.parts:
            continue
        if refactor_file(p):
            touched.append(str(p))

if touched:
    print("[OK] Fichiers modifiés :")
    for t in touched:
        print("  -", t)
else:
    print("[OK] Aucun fichier modifié (probablement déjà migré)")
PY

echo "[STEP] Redémarre l'API"
docker compose restart api

echo "[STEP] Relance les tests"
docker compose exec -T api pytest -q \
  /app/tests/test_routes_invoices.py \
  /app/tests/test_public_url.py \
  /app/tests/test_invoice_public_pdf.py
