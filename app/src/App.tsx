import { useEffect, useMemo, useState } from 'react';
import type { Session, SupabaseClient } from '@supabase/supabase-js';
import { clearSupabaseConfig, loadSupabaseConfig, normalizeSupabaseUrl, saveSupabaseConfig, type SupabaseConfig } from './lib/config';
import { getSupabaseClient, resetSupabaseClient } from './lib/supabase';

type Screen = 'config' | 'login' | 'organization' | 'dashboard';

type AppStatus = {
  ok: boolean;
  authenticated: boolean;
  schema_version?: number;
  currency_code?: string;
  locale?: string;
};

function App() {
  const [config, setConfig] = useState<SupabaseConfig | null>(() => loadSupabaseConfig());
  const [session, setSession] = useState<Session | null>(null);
  const [screen, setScreen] = useState<Screen>(config ? 'login' : 'config');
  const [statusMessage, setStatusMessage] = useState('');
  const [error, setError] = useState('');

  const supabase = useMemo<SupabaseClient | null>(() => {
    return config ? getSupabaseClient(config) : null;
  }, [config]);

  useEffect(() => {
    if (!supabase) return;

    let mounted = true;
    supabase.auth.getSession().then(({ data, error: sessionError }) => {
      if (!mounted) return;
      if (sessionError) {
        setError(sessionError.message);
        setSession(null);
        setScreen('login');
        return;
      }
      setSession(data.session);
      setScreen(data.session ? 'dashboard' : 'login');
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      if (!nextSession) setScreen('login');
    });

    return () => {
      mounted = false;
      listener.subscription.unsubscribe();
    };
  }, [supabase]);

  async function testAndSaveConfig(urlValue: string, keyValue: string) {
    setError('');
    setStatusMessage('Checking Supabase connection…');

    const url = normalizeSupabaseUrl(urlValue);
    const publishableKey = keyValue.trim();

    if (!/^https:\/\/[^/]+\.supabase\.co$/i.test(url)) {
      setStatusMessage('');
      setError('Enter the Supabase Project URL, for example https://your-project.supabase.co.');
      return;
    }
    if (!publishableKey) {
      setStatusMessage('');
      setError('Enter the Supabase publishable/anon key.');
      return;
    }

    const nextConfig = { url, publishableKey };
    try {
      const testClient = getSupabaseClient(nextConfig);
      const { error: authError } = await testClient.auth.getSession();
      if (authError) throw authError;
      saveSupabaseConfig(nextConfig);
      setConfig(nextConfig);
      setScreen('login');
      setStatusMessage('Connection settings saved.');
    } catch (err) {
      setStatusMessage('');
      setError(err instanceof Error ? err.message : 'Could not connect to Supabase.');
    }
  }

  async function signOut() {
    if (supabase) await supabase.auth.signOut();
    setSession(null);
    setScreen('login');
  }

  function changeConnection() {
    resetSupabaseClient();
    clearSupabaseConfig();
    setConfig(null);
    setSession(null);
    setStatusMessage('');
    setError('');
    setScreen('config');
  }

  if (screen === 'config') {
    return <ConfigPage onSave={testAndSaveConfig} error={error} status={statusMessage} />;
  }

  if (!supabase || !config) {
    return <ConfigPage onSave={testAndSaveConfig} error={error} status={statusMessage} />;
  }

  if (screen === 'login' || !session) {
    return <LoginPage supabase={supabase} onLoggedIn={() => setScreen('dashboard')} error={error} setError={setError} />;
  }

  if (screen === 'organization') {
    return <OrganizationSetupPage supabase={supabase} onComplete={() => setScreen('dashboard')} error={error} setError={setError} />;
  }

  return <DashboardPage config={config} session={session} supabase={supabase} onSignOut={signOut} onChangeConnection={changeConnection} onOrganizationSetup={() => setScreen('organization')} />;
}

function ConfigPage({ onSave, error, status }: { onSave: (url: string, key: string) => Promise<void>; error: string; status: string }) {
  const existing = loadSupabaseConfig();
  const [url, setUrl] = useState(existing?.url ?? '');
  const [key, setKey] = useState(existing?.publishableKey ?? '');
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    await onSave(url, key);
    setBusy(false);
  }

  return (
    <AuthLayout eyebrow="First-run setup" title="Connect your database" subtitle="Each business connects this desktop app to its own Supabase project.">
      <form className="stack" onSubmit={submit}>
        <label>Supabase Project URL<input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://your-project.supabase.co" autoComplete="off" /></label>
        <label>Publishable / anon key<input value={key} onChange={(e) => setKey(e.target.value)} placeholder="sb_publishable_… or legacy anon key" autoComplete="off" /></label>
        <p className="hint">Only the public client key belongs here. Never put a service-role key or database password in the desktop application.</p>
        {error && <div className="alert error">{error}</div>}
        {status && <div className="alert success">{status}</div>}
        <button className="primary" disabled={busy}>{busy ? 'Testing…' : 'Save and continue'}</button>
      </form>
    </AuthLayout>
  );
}

function LoginPage({ supabase, onLoggedIn, error, setError }: { supabase: SupabaseClient; onLoggedIn: () => void; error: string; setError: (value: string) => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError('');
    const { error: signInError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (signInError) {
      setError(signInError.message);
      return;
    }
    onLoggedIn();
  }

  return (
    <AuthLayout eyebrow="Secure sign in" title="Welcome back" subtitle="Sign in to your business account.">
      <form className="stack" onSubmit={submit}>
        <label>Email<input type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="username" required /></label>
        <label>Password<input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" required /></label>
        {error && <div className="alert error">{error}</div>}
        <button className="primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
      </form>
    </AuthLayout>
  );
}

function OrganizationSetupPage({ supabase, onComplete, error, setError }: { supabase: SupabaseClient; onComplete: () => void; error: string; setError: (value: string) => void }) {
  const [legalName, setLegalName] = useState('');
  const [tradeName, setTradeName] = useState('');
  const [state, setState] = useState('');
  const [stateCode, setStateCode] = useState('');
  const [gstin, setGstin] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError('');
    const { error: rpcError } = await supabase.rpc('bootstrap_organization', {
      p_legal_name: legalName.trim(),
      p_trade_name: tradeName.trim() || null,
      p_gstin: gstin.trim() || null,
      p_state: state.trim(),
      p_state_code: stateCode.trim(),
    });
    setBusy(false);
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    onComplete();
  }

  return (
    <AuthLayout eyebrow="Business setup" title="Set up your organization" subtitle="This creates the first organization and makes your signed-in account its Admin.">
      <form className="stack" onSubmit={submit}>
        <label>Legal name<input value={legalName} onChange={(e) => setLegalName(e.target.value)} required /></label>
        <label>Trade name <span className="muted">optional</span><input value={tradeName} onChange={(e) => setTradeName(e.target.value)} /></label>
        <div className="two-col">
          <label>State<input value={state} onChange={(e) => setState(e.target.value)} placeholder="Odisha" required /></label>
          <label>State code<input value={stateCode} onChange={(e) => setStateCode(e.target.value)} placeholder="21" maxLength={2} required /></label>
        </div>
        <label>GSTIN <span className="muted">optional</span><input value={gstin} onChange={(e) => setGstin(e.target.value.toUpperCase())} maxLength={15} /></label>
        {error && <div className="alert error">{error}</div>}
        <button className="primary" disabled={busy}>{busy ? 'Creating…' : 'Create organization'}</button>
      </form>
    </AuthLayout>
  );
}

function DashboardPage({ config, session, supabase, onSignOut, onChangeConnection, onOrganizationSetup }: { config: SupabaseConfig; session: Session; supabase: SupabaseClient; onSignOut: () => Promise<void>; onChangeConnection: () => void; onOrganizationSetup: () => void }) {
  const [status, setStatus] = useState<AppStatus | null>(null);
  const [message, setMessage] = useState('Checking application status…');
  const [hasOrganization, setHasOrganization] = useState<boolean | null>(null);

  useEffect(() => {
    let active = true;
    async function load() {
      const { data, error } = await supabase.rpc('get_app_status');
      if (!active) return;
      if (error) {
        setMessage(error.message);
        return;
      }
      const nextStatus = data as AppStatus;
      setStatus(nextStatus);
      const { data: membership, error: membershipError } = await supabase
        .from('organization_members')
        .select('organization_id')
        .limit(1);
      if (membershipError) {
        setMessage(membershipError.message);
        return;
      }
      setHasOrganization((membership?.length ?? 0) > 0);
      setMessage('Ready');
    }
    load();
    return () => { active = false; };
  }, [supabase]);

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><span className="brand-mark">M</span><div><strong>Material Management</strong><small>Business Edition</small></div></div>
        <nav><button className="nav-active">Overview</button><button disabled>Materials</button><button disabled>Customers</button><button disabled>Invoices</button><button disabled>Payments</button><button disabled>Reports</button></nav>
        <div className="sidebar-bottom"><button onClick={onChangeConnection}>Change database</button><button onClick={onSignOut}>Sign out</button></div>
      </aside>
      <main className="main-content">
        <header className="topbar"><div><p className="eyebrow">Dashboard</p><h1>Business overview</h1></div><div className="user-chip">{session.user.email}</div></header>
        <section className="welcome-card"><div><span className="status-dot" /> <span>Connected</span><h2>Your workspace is ready.</h2><p>The core desktop shell is connected to this business's Supabase project.</p></div><div className="connection-box"><small>Database</small><strong>{new URL(config.url).hostname}</strong><small>Schema</small><strong>{status?.schema_version ? `v${status.schema_version}` : 'Checking…'}</strong></div></section>
        {hasOrganization === false && <section className="setup-card"><div><h3>Finish organization setup</h3><p>No organization is linked to this account yet. Create the first organization to start using materials, customers and invoices.</p></div><button className="primary compact" onClick={onOrganizationSetup}>Set up organization</button></section>}
        {message !== 'Ready' && <div className="alert info">{message}</div>}
        <section className="metric-grid"><Metric label="Materials" value="—" /><Metric label="Customers" value="—" /><Metric label="Pending invoices" value="—" /><Metric label="Stock value" value="—" /></section>
        <section className="empty-panel"><h3>Operations are coming next</h3><p>The foundation is in place. The next modules will add materials and stock ledger, customer management, invoice creation, payments and reports.</p></section>
      </main>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return <div className="metric"><span>{label}</span><strong>{value}</strong></div>;
}

function AuthLayout({ eyebrow, title, subtitle, children }: { eyebrow: string; title: string; subtitle: string; children: React.ReactNode }) {
  return <div className="auth-page"><div className="auth-card"><div className="brand auth-brand"><span className="brand-mark">M</span><div><strong>Material Management</strong><small>Business Edition</small></div></div><div className="auth-copy"><p className="eyebrow">{eyebrow}</p><h1>{title}</h1><p>{subtitle}</p></div>{children}<footer>India-first • INR • en-IN</footer></div></div>;
}

export default App;
