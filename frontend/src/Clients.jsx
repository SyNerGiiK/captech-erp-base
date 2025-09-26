import React, { useEffect, useState } from "react";
import { api } from "./api";

export default function Clients() {
    const [list, setList] = useState([]);
    const [q, setQ] = useState("");
    const [form, setForm] = useState({ name: "", email: "", phone: "" });
    const [msg, setMsg] = useState("");

    const load = async () => {
        try {
            const rows = await api.listClients({ q });
            setList(rows);
        } catch (e) {
            setMsg(String(e.message));
        }
    };

    useEffect(() => {
        load();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    const create = async () => {
        setMsg("");
        try {
            if (!form.name.trim()) throw new Error("Nom requis");
            await api.createClient(form);
            setForm({ name: "", email: "", phone: "" });
            await load();
            setMsg("Client créé");
        } catch (e) {
            setMsg(String(e.message));
        }
    };

    const del = async (id) => {
        setMsg("");
        try {
            await api.deleteClient(id);
            await load();
            setMsg("Client supprimé");
        } catch (e) {
            setMsg(String(e.message));
        }
    };

    return (
        <div>
            <h2>Clients</h2>
            <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
                <input placeholder="Recherche nom..." value={q} onChange={(e) => setQ(e.target.value)} />
                <button onClick={load}>Rechercher</button>
            </div>
            <div style={{ display: "grid", gap: 8, maxWidth: 480, marginBottom: 16 }}>
                <input placeholder="Nom *" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
                <input placeholder="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
                <input placeholder="Téléphone" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
                <button onClick={create}>Créer</button>
            </div>
            {msg && <div style={{ marginBottom: 8 }}>{msg}</div>}
            <table border="1" cellPadding="6" style={{ borderCollapse: "collapse", width: "100%" }}>
                <thead><tr><th>ID</th><th>Nom</th><th>Email</th><th>Téléphone</th><th></th></tr></thead>
                <tbody>
                    {list.map(c => (
                        <tr key={c.id}>
                            <td>{c.id}</td>
                            <td>{c.name}</td>
                            <td>{c.email || "-"}</td>
                            <td>{c.phone || "-"}</td>
                            <td><button onClick={() => del(c.id)}>Supprimer</button></td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    );
}