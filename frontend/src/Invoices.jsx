import React, { useEffect, useState } from "react";

export default function Invoices() {
  const [items, setItems] = useState([]);
  const [sel, setSel] = useState(null);
  const [loading, setLoading] = useState(false);
  const base = (import.meta.env.VITE_USE_PROXY==="1"?"/api":(import.meta.env.VITE_API_URL??"http://localhost:8000"));

  async function load() {
    setLoading(true);
    try {
      const token = localStorage.getItem("token") || "";
      const res = await fetch(base + "/invoices", { headers: { "Authorization": "Bearer " + token }});
      if (!res.ok) throw new Error("load invoices: " + res.status);
      const data = await res.json();
      setItems(data);
      if (data.length) setSel(data[0]);
    } catch (e) { alert(e.message); }
    finally { setLoading(false); }
  }
  useEffect(() => { load(); }, []);

  return (
    <div style={{ padding: 16 }}>
      <h2>Factures</h2>
      <div style={{ display:"flex", gap:8, alignItems:"center", marginBottom:12 }}>
        <button onClick={load} disabled={loading}>{loading ? "Chargement..." : "Rafraichir"}</button>
        <select value={sel?.id ?? ""} onChange={e=>{
          const id = Number(e.target.value);
          setSel(items.find(x=>x.id===id) || null);
        }}>
          <option value="">-- choisir une facture --</option>
          {items.map(inv => (
            <option key={inv.id} value={inv.id}>{inv.number} - {inv.title}</option>
          ))}
        </select>
        <button onClick={async ()=>{
          if (!sel?.id) { alert("Selectionne une facture"); return; }
          try {
            const token = localStorage.getItem("token") || "";
            const resp = await fetch(base + "/invoices/" + sel.id + "/signed_link", {
              method: "POST",
              headers: { "Authorization": "Bearer " + token }
            });
            if (!resp.ok) throw new Error("link failed " + resp.status);
            const data = await resp.json();
            const url = base + data.path; // /invoices/public/{id}/download.pdf?token=...
            window.open(url, "_blank");
          } catch(e) { alert("PDF link error: " + e.message); }
        }}>Telecharger (PDF)</button>
      </div>
      <ul>
        {items.map(inv => (
          <li key={inv.id}>{inv.number} - {inv.title} [{inv.status}] total: {Math.round((inv.total_cents||0)/100)} EUR</li>
        ))}
      </ul>
    </div>
  );
}