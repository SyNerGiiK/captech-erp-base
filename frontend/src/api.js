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