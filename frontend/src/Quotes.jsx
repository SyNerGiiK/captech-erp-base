import React, { useEffect, useState } from "react";
import { api } from "./api";

export default function Quotes() {
    const [clients, setClients] = useState([]);
    const [list, setList] = useState([]);
    const [form, setForm] = useState({ title: "", amount_cents: 0, status: "draft", client_id: 0 });
    const [msg, setMsg] = useState("");

    const load = async () => {
        const cs = await api.listClients({ limit: 200 });
        setClients(cs);
        const qs = await api.listQuotes({});
        setList(qs);
    };

    useEffect(() => {
        load();
    }, []);

    const create = async () => {
        setMsg("");
        try {
            if (!form.title.trim()) throw new Error("Titre requis");
            if (!form.client_id) throw new Error("Client requis");
            await api.createQuote({ ...form, amount_cents: Number(form.amount_cents || 0) });
            setForm({ title: "", amount_cents: 0, status: "draft", client_id: 0 });
            await load();
            setMsg("Devis créé");
        } catch (e) {
            setMsg(String(e.message));
        }
    };

    const del = async (id) => {
        setMsg("");
        try {
            await api.deleteQuote(id);
            await load();
            setMsg("Devis supprimé");
        } catch (e) {
            setMsg(String(e.message));
        }
    };

    return (
        <div>
            <h2>Devis</h2>
            <div style={{ display: "grid", gap: 8, maxWidth: 520, marginBottom: 16 }}>
                <input placeholder="Titre *" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} />
                <input type="number" placeholder="Montant (centimes) *" value={form.amount_cents}
                    onChange={(e) => setForm({ ...form, amount_cents: e.target.value })} />
                <select value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
                    <option value="draft">draft</option>
                    <option value="sent">sent</option>
                    <option value="accepted">accepted</option>
                    <option value="rejected">rejected</option>
                </select>
                <select value={form.client_id} onChange={(e) => setForm({ ...form, client_id: Number(e.target.value) })}>
                    <option value={0}>-- Client --</option>
                    {clients.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
                <button onClick={create}>Créer</button>
            </div>
            {msg && <div style={{ marginBottom: 8 }}>{msg}</div>}
            <table border="1" cellPadding="6" style={{ borderCollapse: "collapse", width: "100%" }}>
                <thead><tr><th>ID</th><th>N°</th><th>Titre</th><th>Montant (cts)</th><th>Statut</th><th>Client</th><th></th></tr></thead>
                <tbody>
                    {list.map(q => (
                        <tr key={q.id}>
                            <td>{q.id}</td>
                            <td>{q.number}</td>
                            <td>{q.title}</td>
                            <td>{q.amount_cents}</td>
                            <td>{q.status}</td>
                            <td>{q.client_id}</td>
                            <td><button onClick={() => del(q.id)}>Supprimer</button></td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
}