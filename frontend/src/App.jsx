import React, { useEffect, useState } from "react";
import Auth from "./Auth";
import Clients from "./Clients";
import Quotes from "./Quotes";
import Invoices from "./Invoices";
import Reports from "./Reports";
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
      <h1>CapTech ERP â€” MVP Frontend</h1>

      <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
        <Tab id="auth">Auth</Tab>
        <Tab id="clients">Clients</Tab>
        <Tab id="quotes">Devis</Tab>
        <Tab id="invoices">Factures</Tab>
        <Tab id="reports">Reports</Tab>
        <div style={{ marginLeft: "auto" }}>
          {session ? (
            <span style={{ padding: "4px 8px", border: "1px solid #10b981", borderRadius: 8, background: "#d1fae5", color: "#065f46" }}>
              {session.email} (company #{session.company_id}) <button onClick={() => setToken(null)} style={{ marginLeft: 8 }}>Logout</button>
            </span>
          ) : (
            <span style={{ padding: "4px 8px", border: "1px solid #ef4444", borderRadius: 8, background: "#fee2e2", color: "#7f1d1d" }}>
              non connectÃ©
            </span>
          )}
        </div>
      </div>

      {tab === "auth" && <Auth />}
      {tab === "clients" && (session ? <Clients /> : <p>Connecte-toi d'abord dans l'onglet <b>Auth</b>.</p>)}
      {tab === "quotes"  && (session ? <Quotes  /> : <p>Connecte-toi d'abord dans l'onglet <b>Auth</b>.</p>)}
      {tab === "invoices"&& (session ? <Invoices/> : <p>Connecte-toi d'abord dans l'onglet <b>Auth</b>.</p>)}
      {tab === "reports" && (session ? <Reports /> : <p>Connecte-toi d\'abord dans l\'onglet <b>Auth</b>.</p>)}
    </div>
  );
}