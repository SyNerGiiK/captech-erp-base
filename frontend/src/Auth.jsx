import React, { useState } from "react";
import { api, getToken, setToken } from "./api";

export default function Auth() {
    const [email, setEmail] = useState("demo@captech.local");
    const [password, setPassword] = useState("pass");
    const [company, setCompany] = useState("CapTech");
    const [me, setMe] = useState(null);
    const [loading, setLoading] = useState(false);
    const [msg, setMsg] = useState("");

    const doRegister = async () => {
        setLoading(true);
        setMsg("");
        try {
            await api.register({ email, password, company_name: company });
            const m = await api.me();
            setMe(m);
            setMsg("Inscription OK");
        } catch (e) {
            setMsg(String(e.message));
        } finally {
            setLoading(false);
        }
    };

    const doLogin = async () => {
        setLoading(true);
        setMsg("");
        try {
            await api.login({ email, password });
            const m = await api.me();
            setMe(m);
            setMsg("Connexion OK");
        } catch (e) {
            setMsg(String(e.message));
        } finally {
            setLoading(false);
        }
    };

    const doMe = async () => {
        setLoading(true);
        try {
            const m = await api.me();
            setMe(m);
            setMsg("Token valide");
        } catch (e) {
            setMsg(String(e.message));
        } finally {
            setLoading(false);
        }
    };

    const doLogout = () => {
        setToken(null); // why: invalide la session locale
        setMe(null);
        setMsg("Déconnecté");
    };

    const token = getToken();

    return (
        <div>
            <h2>Authentification</h2>
            <div style={{ display: "grid", gap: 8, maxWidth: 480 }}>
                <label>
                    Email
                    <input value={email} onChange={(e) => setEmail(e.target.value)} style={{ width: "100%" }} />
                </label>
                <label>
                    Mot de passe
                    <input value={password} onChange={(e) => setPassword(e.target.value)} type="password" style={{ width: "100%" }} />
                </label>
                <label>
                    Société (pour Register)
                    <input value={company} onChange={(e) => setCompany(e.target.value)} style={{ width: "100%" }} />
                </label>
                <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                    <button onClick={doRegister} disabled={loading}>Register</button>
                    <button onClick={doLogin} disabled={loading}>Login</button>
                    <button onClick={doMe} disabled={loading || !token}>/auth/me</button>
                    <button onClick={doLogout} disabled={!token}>Logout</button>
                </div>
                <div style={{ fontSize: 12, color: token ? "#065f46" : "#7f1d1d" }}>
                    Token: {token ? "présent" : "absent"}
                </div>
                {msg && <div style={{ whiteSpace: "pre-wrap" }}>{msg}</div>}
                {me && (
                    <pre style={{ background: "#f3f4f6", padding: 12, borderRadius: 8 }}>
                        {JSON.stringify(me, null, 2)}
                    </pre>
                )}
            </div>
        </div>
    );
}