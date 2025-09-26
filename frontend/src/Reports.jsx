import React, { useEffect, useState } from "react";
import {
  ResponsiveContainer,
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  LineChart, Line, Legend,
} from "recharts";

const API = "http://localhost:8000";

async function fetchReport(path) {
  const token = localStorage.getItem("token") || "";
  const res = await fetch(`${API}${path}`, { headers: { "Authorization": `Bearer ${token}` } });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

export default function Reports() {
  const [statusRows, setStatusRows] = useState([]);
  const [monthlyRows, setMonthlyRows] = useState([]);
  const [months, setMonths] = useState(12);
  const [loading, setLoading] = useState(false);
  const [msg, setMsg] = useState("");

  const load = async (doRefresh = false) => {
    setLoading(true);
    setMsg("");
    try {
      const [st, mo] = await Promise.all([
        fetchReport(`/reports/status${doRefresh ? "?refresh=true" : ""}`),
        fetchReport(`/reports/monthly?months=${months}${doRefresh ? "&refresh=true" : ""}`),
      ]);
      setStatusRows(st);
      setMonthlyRows(mo);
    } catch (e) {
      setMsg(String(e.message));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(false); }, []);
  useEffect(() => { load(false); }, [months]);

  const fmtEuro = (cts) => (cts/100).toLocaleString("fr-FR", { style:"currency", currency:"EUR" });

  return (
    <div>
      <h2>Reports</h2>
      <div style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 12 }}>
        <button onClick={() => load(false)} disabled={loading}>Recharger</button>
        <button onClick={() => load(true)} disabled={loading}>RafraÃ®chir + Recharger</button>
        <label style={{ marginLeft: 12 }}>
          Mois:{" "}
          <select value={months} onChange={e => setMonths(Number(e.target.value))}>
            {[3,6,12,18,24].map(m => <option key={m} value={m}>{m}</option>)}
          </select>
        </label>
      </div>
      {msg && <div style={{ marginBottom: 8, color: "#7f1d1d" }}>{msg}</div>}

      <div style={{ display: "grid", gap: 24 }}>
        <section style={{ height: 320, border: "1px solid #e5e7eb", borderRadius: 12, padding: 12 }}>
          <h3 style={{ margin: 0, marginBottom: 8 }}>Devis par statut</h3>
          <ResponsiveContainer width="100%" height="90%">
            <BarChart data={statusRows.map(r => ({ ...r, amount_eur: r.amount_cents/100 }))}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="status" />
              <YAxis yAxisId="left" />
              <YAxis yAxisId="right" orientation="right" />
              <Tooltip formatter={(v, n) => n.includes("amount") ? fmtEuro(v*100) : v} />
              <Legend />
              <Bar yAxisId="left" dataKey="count" name="Nombre" />
              <Bar yAxisId="right" dataKey="amount_eur" name="Montant (EUR)" />
            </BarChart>
          </ResponsiveContainer>
        </section>

        <section style={{ height: 320, border: "1px solid #e5e7eb", borderRadius: 12, padding: 12 }}>
          <h3 style={{ margin: 0, marginBottom: 8 }}>CA mensuel (acceptÃ©s)</h3>
          <ResponsiveContainer width="100%" height="90%">
            <LineChart data={monthlyRows.map(r => ({ ...r, amount_eur: r.amount_cents/100 }))}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="month" />
              <YAxis />
              <Tooltip formatter={(v) => fmtEuro((v||0)*100)} />
              <Legend />
              <Line type="monotone" dataKey="amount_eur" name="Montant (EUR)" dot />
            </LineChart>
          </ResponsiveContainer>
        </section>
      </div>
    </div>
  );
}