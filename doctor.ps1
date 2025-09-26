# file: doctor.ps1
# Usage: powershell -ExecutionPolicy Bypass -File .\doctor.ps1
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function Ensure-Dir($p){ if(-not(Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Utf8($Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false) # why: éviter BOM qui casse Python/YAML
  [IO.File]::WriteAllText($Path,$Content,$enc)
}
function Safe-Json($path){
  try{ Get-Content $path -Raw | ConvertFrom-Json } catch { $null }
}
function Has-LineLike($text,[string]$needle){ return [bool]($text -match [Regex]::Escape($needle)) }

# --- Vérifs rapides
if(-not (Get-Command docker -ErrorAction SilentlyContinue)){ throw "Docker Desktop requis." }
Ensure-Dir "$root/backend/app/routers"
Ensure-Dir "$root/frontend/src"

# =========================
# 1) BACKEND  (fix deps + auth + reports + CORS)
# =========================
# 1.1 requirements.txt
$reqPath = "$root/backend/requirements.txt"
if(-not(Test-Path $reqPath)){ throw "Manque: backend/requirements.txt" }
$lines = Get-Content $reqPath
$lines = $lines | Where-Object { $_ -notmatch '^\s*passlib(\[.*\])?' -and $_ -notmatch '^\s*bcrypt(\s*==.*)?\s*$' }
# garantir pydantic[email]
if(-not ($lines -match '^\s*pydantic(\[email\])?(\s*==.*)?\s*$')){
  $lines = $lines | Where-Object { $_ -notmatch '^\s*pydantic(\s*==.*)?\s*$' }
  $lines += 'pydantic[email]'
}
$lines += @('passlib[bcrypt]==1.7.4','bcrypt==4.0.1')
Write-Utf8 $reqPath (($lines | Where-Object { $_ -ne "" }) -join "`n")
Write-Host "[OK] requirements.txt épinglé (passlib/bcrypt + pydantic[email])"

# 1.2 auth_utils.py (bcrypt_sha256 + catch ValueError)
$authPath = "$root/backend/app/auth_utils.py"
$authPy = @'
import os
from datetime import datetime, timedelta
from jose import jwt
from passlib.context import CryptContext

SECRET_KEY = os.getenv("SECRET_KEY", "dev_change_me")
ALGO = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24 * 7

# why: bcrypt_sha256 évite la limite 72 octets; fallback bcrypt pour compat
_pwd = CryptContext(schemes=["bcrypt_sha256", "bcrypt"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return _pwd.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return _pwd.verify(plain, hashed)
    except ValueError:
        # why: éviter un 500 si mot de passe >72 octets
        return False

def create_access_token(sub: str, company_id: int) -> str:
    exp = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {"sub": sub, "company_id": company_id, "exp": exp}
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGO)
'@
Write-Utf8 $authPath $authPy
Write-Host "[OK] backend/app/auth_utils.py corrigé"

# 1.3 reports.py (corrige TextClause + params)
$reportsPath = "$root/backend/app/routers/reports.py"
$reportsPy = @'
from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from app.db import database
from app.deps import get_current_user
from app.reporting import refresh_matviews

router = APIRouter(prefix="/reports", tags=["reports"])

@router.post("/refresh", status_code=202)
async def reports_refresh(user=Depends(get_current_user)):
    await refresh_matviews()
    return {"refreshed": True}

@router.get("/status")
async def reports_status(refresh: bool = False, user=Depends(get_current_user)):
    if refresh:
        await refresh_matviews()
    sql = text("""
        SELECT status, count, amount_cents
        FROM mv_quotes_by_status
        WHERE company_id = :cid
        ORDER BY status
    """).bindparams(cid=user["company_id"])
    rows = await database.fetch_all(sql)
    return [dict(r) for r in rows]

@router.get("/monthly")
async def reports_monthly(months: int = Query(12, ge=1, le=36), refresh: bool = False, user=Depends(get_current_user)):
    if refresh:
        await refresh_matviews()
    sql = text(f"""
        SELECT month, amount_cents
        FROM mv_monthly_revenue
        WHERE company_id = :cid
          AND month >= date_trunc('month', now()) - INTERVAL '{months-1} months'
        ORDER BY month ASC
    """).bindparams(cid=user["company_id"])
    rows = await database.fetch_all(sql)
    return [{"month": r["month"].strftime("%Y-%m"), "amount_cents": int(r["amount_cents"])} for r in rows]
'@
Write-Utf8 $reportsPath $reportsPy
Write-Host "[OK] backend/app/routers/reports.py corrigé"

# 1.4 main.py (CORS + include routers si manquants)
$mainPath = "$root/backend/app/main.py"
if(-not(Test-Path $mainPath)){ throw "Manque: backend/app/main.py" }
$mainTxt = Get-Content $mainPath -Raw
# CORS origins
if($mainTxt -match 'allow_origins\s*='){
  $mainTxt = [regex]::Replace($mainTxt,'allow_origins\s*=\s*\[[^\]]*\]','allow_origins=["http://localhost:3000","http://127.0.0.1:3000"]','Singleline')
}else{
  $mainTxt = $mainTxt -replace 'app\.add_middleware\(\s*CORSMiddleware\s*,','app.add_middleware(CORSMiddleware,' + "`n    allow_origins=[`"http://localhost:3000`",`"http://127.0.0.1:3000`"],"
}
# include reports/invoices/payments si absents
if(-not ($mainTxt -match 'from app\.routers import invoices')){ $mainTxt = $mainTxt -replace '(from app\.routers import quotes.*)','from app.routers import quotes'+"`nfrom app.routers import invoices`nfrom app.routers import payments" }
if(-not ($mainTxt -match 'include_router\(invoices\.router\)')){ $mainTxt = $mainTxt -replace '(app\.include_router\(quotes\.router\).*)','$1'+"`napp.include_router(invoices.router)`napp.include_router(payments.router)" }
if(-not ($mainTxt -match 'from app\.routers import reports')){ $mainTxt = $mainTxt -replace '(from app\.routers import .*?)$',"$1`nfrom app.routers import reports" }
if(-not ($mainTxt -match 'include_router\(reports\.router\)')){ $mainTxt = $mainTxt -replace '(app\.include_router\(payments\.router\).*)','$1'+"`napp.include_router(reports.router)" }
Write-Utf8 $mainPath $mainTxt
Write-Host "[OK] backend/app/main.py patché (CORS + routers)"

# =========================
# 2) FRONTEND  (scaffold + proxy + App.jsx)
# =========================
$fe = "$root/frontend"; $src = "$fe/src"
Ensure-Dir $fe; Ensure-Dir $src

# 2.1 index.html & main.jsx si absents
if(-not(Test-Path "$fe/index.html")){
  Write-Utf8 "$fe/index.html" @'
<!doctype html>
<html lang="fr">
  <head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width, initial-scale=1.0"/><title>CapTech ERP — Frontend</title></head>
  <body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body>
</html>
'@
}
if(-not(Test-Path "$src/main.jsx")){
  Write-Utf8 "$src/main.jsx" @'
import React from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
createRoot(document.getElementById("root")).render(<App />);
'@
}

# 2.2 api.js (proxy-aware)
$apiJsPath = "$src/api.js"
$apiJs = @'
const API_FROM_ENV = import.meta.env.VITE_API_URL ?? "http://localhost:8000";
const USE_PROXY = (import.meta.env.VITE_USE_PROXY ?? "1") === "1";
const API_URL = USE_PROXY ? "/api" : API_FROM_ENV;

let _token = localStorage.getItem("token") || null;
export const setToken = (t) => { _token = t; if (t) localStorage.setItem("token", t); else localStorage.removeItem("token"); };
export const getToken = () => _token;

async function request(path, { method="GET", body, auth=false } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (auth && _token) headers["Authorization"] = `Bearer ${_token}`;
  const res = await fetch(`${API_URL}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  if (!res.ok) { const text = await res.text().catch(()=>""); throw new Error(`${res.status} ${res.statusText}: ${text}`); }
  const ct = res.headers.get("content-type") || "";
  return ct.includes("application/json") ? res.json() : null;
}

export const api = {
  register({ email, password, company_name }) { return request("/auth/register", { method:"POST", body:{ email, password, company_name } }); },
  login({ email, password }) { return request("/auth/login", { method:"POST", body:{ email, password } }); },
  me(){ return request("/auth/me", { auth:true }); },

  listClients({ q, limit=50, offset=0 } = {}) {
    const qs = new URLSearchParams(); if (q) qs.set("q",q); qs.set("limit",String(limit)); qs.set("offset",String(offset));
    return request(`/clients/?${qs.toString()}`, { auth:true });
  },
  createClient({ name, email, phone }) { return request("/clients/", { method:"POST", body:{ name, email, phone }, auth:true }); },
  deleteClient(id) { return request(`/clients/${id}`, { method:"DELETE", auth:true }); },

  listQuotes({ status, limit=50, offset=0 } = {}) {
    const qs = new URLSearchParams(); if (status) qs.set("status",status); qs.set("limit",String(limit)); qs.set("offset",String(offset));
    return request(`/quotes/?${qs.toString()}`, { auth:true });
  },
  createQuote({ title, amount_cents, status="draft", client_id }) { return request("/quotes/", { method:"POST", body:{ title, amount_cents, status, client_id }, auth:true }); },
  deleteQuote(id){ return request(`/quotes/${id}`, { method:"DELETE", auth:true }); },

  listInvoices({ status, q, limit=50, offset=0 } = {}) {
    const qs = new URLSearchParams(); if (status) qs.set("status",status); if (q) qs.set("q",q);
    qs.set("limit",String(limit)); qs.set("offset",String(offset));
    return request(`/invoices/?${qs.toString()}`, { auth:true });
  },
  createInvoice({ title, client_id, issued_date, due_date, currency="EUR" }) {
    return request("/invoices/", { method:"POST", body:{ title, client_id, issued_date, due_date, currency }, auth:true });
  },
  getInvoice(id){ return request(`/invoices/${id}`, { auth:true }); },
  updateInvoice(id, patch){ return request(`/invoices/${id}`, { method:"PATCH", body:patch, auth:true }); },
  createFromQuote(quote_id){ return request(`/invoices/from_quote/${quote_id}`, { method:"POST", auth:true }); },

  listLines(invoice_id){ return request(`/invoices/${invoice_id}/lines`, { auth:true }); },
  addLine(invoice_id, { description, qty, unit_price_cents }) {
    return request(`/invoices/${invoice_id}/lines`, { method:"POST", body:{ description, qty, unit_price_cents }, auth:true });
  },
  delLine(invoice_id, line_id){ return request(`/invoices/${invoice_id}/lines/${line_id}`, { method:"DELETE", auth:true }); },
  recalc(invoice_id){ return request(`/invoices/${invoice_id}/recalc`, { method:"POST", auth:true }); },

  listPayments(invoice_id){ return request(`/payments/${invoice_id}`, { auth:true }); },
  addPayment(invoice_id, { amount_cents, method, paid_at, note }){
    return request(`/payments/${invoice_id}`, { method:"POST", body:{ amount_cents, method, paid_at, note }, auth:true });
  },
};
'@
Write-Utf8 $apiJsPath $apiJs
Write-Host "[OK] frontend/src/api.js (proxy-aware)"

# 2.3 vite.config.js avec proxy
$viteCfgPath = "$root/frontend/vite.config.js"
$viteCfg = @'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    port: 3000,
    proxy: {
      "/api": {
        target: "http://api:8000",
        changeOrigin: true,
        rewrite: (p) => p.replace(/^\/api/, ""),
      },
    },
  },
});
'@
Write-Utf8 $viteCfgPath $viteCfg
Write-Host "[OK] vite.config.js (proxy /api -> http://api:8000)"

# 2.4 App.jsx propre (inclut Reports si présent)
$hasReports = Test-Path "$src/Reports.jsx"
$reportsImport = ""; $reportsTab = ""; $reportsBlock = ""
if($hasReports){
  $reportsImport = 'import Reports from "./Reports";'
  $reportsTab    = '        <Tab id="reports">Reports</Tab>'
  $reportsBlock  = '      {tab === "reports" && (session ? <Reports /> : <p>Connecte-toi d\''abord dans l\''onglet <b>Auth</b>.</p>)}'
}
$appTpl = @'
import React, { useEffect, useState } from "react";
import Auth from "./Auth";
import Clients from "./Clients";
import Quotes from "./Quotes";
import Invoices from "./Invoices";
__REPORTS_IMPORT__
import { getToken, setToken, api } from "./api";

export default function App() {
  const [tab, setTab] = useState("auth");
  const [session, setSession] = useState(null);
  const token = getToken();

  useEffect(() => {
    (async () => {
      if (token) { try { setSession(await api.me()); } catch { setSession(null); } }
      else setSession(null);
    })();
  }, [token]);

  const Tab = ({ id, children }) => (
    <button onClick={() => setTab(id)} disabled={tab===id}>{children}</button>
  );

  return (
    <div style={{ padding: 24, maxWidth: 1100, margin: "0 auto", fontFamily: "system-ui, sans-serif" }}>
      <h1>CapTech ERP — MVP Frontend</h1>

      <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
        <Tab id="auth">Auth</Tab>
        <Tab id="clients">Clients</Tab>
        <Tab id="quotes">Devis</Tab>
        <Tab id="invoices">Factures</Tab>
__REPORTS_TAB__
        <div style={{ marginLeft: "auto" }}>
          {session ? (
            <span style={{ padding: "4px 8px", border: "1px solid #10b981", borderRadius: 8, background: "#d1fae5", color: "#065f46" }}>
              {session.email} (company #{session.company_id}) <button onClick={() => setToken(null)} style={{ marginLeft: 8 }}>Logout</button>
            </span>
          ) : (
            <span style={{ padding: "4px 8px", border: "1px solid #ef4444", borderRadius: 8, background: "#fee2e2", color: "#7f1d1d" }}>
              non connecté
            </span>
          )}
        </div>
      </div>

      {tab === "auth" && <Auth />}
      {tab === "clients" && (session ? <Clients /> : <p>Connecte-toi d'abord dans l'onglet <b>Auth</b>.</p>)}
      {tab === "quotes"  && (session ? <Quotes  /> : <p>Connecte-toi d'abord dans l'onglet <b>Auth</b>.</p>)}
      {tab === "invoices"&& (session ? <Invoices/> : <p>Connecte-toi d'abord dans l'onglet <b>Auth</b>.</p>)}
__REPORTS_BLOCK__
    </div>
  );
}
'@
$app = $appTpl.Replace('__REPORTS_IMPORT__',$reportsImport).Replace('__REPORTS_TAB__',$reportsTab).Replace('__REPORTS_BLOCK__',$reportsBlock)
Write-Utf8 "$src/App.jsx" $app
Write-Host "[OK] frontend/src/App.jsx régénéré"

# 2.5 .env (active proxy)
Write-Utf8 "$root/frontend/.env" "VITE_USE_PROXY=1`n"
Write-Host "[OK] frontend/.env (VITE_USE_PROXY=1)"

# =========================
# 3) Compose override (healthchecks)
# =========================
$overridePath = "$root/docker-compose.override.yml"
$overrideYml = @'
services:
  db:
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d appdb"]
      interval: 10s
      timeout: 5s
      retries: 10
  api:
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz').read() else 1)\""]
      interval: 10s
      timeout: 5s
      retries: 20
'@
Write-Utf8 $overridePath $overrideYml
Write-Host "[OK] docker-compose.override.yml (healthchecks)"

# =========================
# 4) Rebuild & Restart
# =========================
Write-Host "`n[STEP] docker compose build --no-cache api"
docker compose build --no-cache api | Out-Host

Write-Host "`n[STEP] docker compose up -d"
docker compose up -d | Out-Host

Start-Sleep -Seconds 2
try{
  $h = Invoke-RestMethod http://localhost:8000/healthz -TimeoutSec 6
  Write-Host "Healthz => $($h | ConvertTo-Json -Compress)"
}catch{
  Write-Warning "Healthz KO (transitoire). Consulte: docker compose logs -f api"
}

Write-Host "`n✅ Doctor terminé."
Write-Host "UI:  http://localhost:3000"
Write-Host "API: http://localhost:8000/docs"
