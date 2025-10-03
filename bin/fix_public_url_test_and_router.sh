set -euo pipefail

# 1) Corrige l'import dans le test
f="backend/tests/test_public_url.py"
if [ -f "$f" ] && grep -q "from app.auth_utils import get_current_user" "$f"; then
  sed -i 's/from app\.auth_utils import get_current_user/from app.deps import get_current_user/' "$f"
fi

# 2) Ne garder qu'une seule inclusion du public_router dans main.py
m="backend/app/main.py"
if [ -f "$m" ]; then
  count=$(grep -c 'app.include_router(invoices.public_router)' "$m" || true)
  if [ "$count" -gt 1 ]; then
    awk '
    /app\.include_router\(invoices\.public_router\)/{
       if(seen++) next
    }
    {print}
    ' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  fi
fi

# 3) Forcer un operation_id unique pour l’endpoint public (au cas où)
inv="backend/app/routers/invoices.py"
if [ -f "$inv" ]; then
  perl -0777 -pe 's/@public_router\.get\(\s*"\/public\/\{invoice_id:int\}\/download\.pdf"\s*\)/@public_router.get("\/public\/{invoice_id:int}\/download.pdf", operation_id="public_download_invoice_pdf_v1")/s' -i "$inv"
fi
