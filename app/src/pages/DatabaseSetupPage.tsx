import { useEffect, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

type Props = {
  supabase: SupabaseClient;
  error?: string;
  onReady: () => void;
};

const migrations = [
  '0001_initial_schema.sql',
  '0002_transactional_operations.sql',
  '0003_bootstrap_and_connection.sql',
  '0004_customer_operations.sql',
  '0005_invoice_security_and_helpers.sql',
  '0006_material_stock_threshold.sql',
  '0007_access_control_and_audit.sql',
  '0008_login_session_tracking.sql',
];

export default function DatabaseSetupPage({ supabase, error: initialError, onReady }: Props) {
  const [error, setError] = useState(initialError ?? '');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('Checking database schema…');

  async function verify() {
    setBusy(true);
    setError('');
    setMessage('Checking database schema…');

    const { data, error: rpcError } = await supabase.rpc('get_app_status');
    if (rpcError) {
      setMessage('Database setup is still required.');
      setError(rpcError.message);
      setBusy(false);
      return;
    }

    const version = Number((data as { schema_version?: number } | null)?.schema_version ?? 0);
    if (version < 8) {
      setMessage(`Database schema version ${version || 'not detected'} is incomplete.`);
      setError('Run all migrations through 0008_login_session_tracking.sql, then verify again.');
      setBusy(false);
      return;
    }

    setMessage(`Database schema v${version} is ready.`);
    setBusy(false);
    onReady();
  }

  useEffect(() => {
    void verify();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="auth-page">
      <div className="auth-card" style={{ width: 'min(700px, 100%)' }}>
        <div className="brand auth-brand">
          <span className="brand-mark">M</span>
          <div><strong>Material Management</strong><small>Business Edition</small></div>
        </div>

        <div className="auth-copy">
          <p className="eyebrow">Database setup</p>
          <h1>Prepare your business database</h1>
          <p>
            The Supabase project is connected, but the application schema has not been installed yet.
            The desktop app cannot create the tables itself because each customer owns their Supabase project.
          </p>
        </div>

        <div className="stack" style={{ gap: 12 }}>
          <div className="setup-card" style={{ display: 'block', marginBottom: 0 }}>
            <h3>Run the SQL migrations in Supabase</h3>
            <p>
              Open the Supabase SQL Editor and run these files in order. The SQL is already stored in this product's
              GitHub repository under <strong>supabase/migrations/</strong>.
            </p>
            <ol style={{ margin: '14px 0 0', paddingLeft: 22, lineHeight: 1.8 }}>
              {migrations.map((migration) => <li key={migration}><code>{migration}</code></li>)}
            </ol>
          </div>

          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <a
              href="https://github.com/cysecguardians-gif/material-management-system/blob/main/docs/SUPABASE_SETUP.md"
              target="_blank"
              rel="noreferrer"
              style={{ display: 'inline-block', border: '1px solid #d6dce5', borderRadius: 9, padding: '10px 14px', color: '#344054', textDecoration: 'none', fontSize: 12 }}
            >Open setup guide</a>
            <a
              href="https://supabase.com/dashboard"
              target="_blank"
              rel="noreferrer"
              style={{ display: 'inline-block', border: '1px solid #d6dce5', borderRadius: 9, padding: '10px 14px', color: '#344054', textDecoration: 'none', fontSize: 12 }}
            >Open Supabase</a>
          </div>
        </div>

        {message && <div className="alert info">{message}</div>}
        {error && <div className="alert error">{error}</div>}

        <button className="primary" onClick={() => void verify()} disabled={busy}>
          {busy ? 'Verifying…' : 'Verify database setup'}
        </button>

        <p className="hint">
          Nothing in this screen requires a service-role key or database password. After the schema is ready,
          the application will continue to organization setup automatically.
        </p>

        <footer>Customer-owned Supabase • SQL migrations are version controlled</footer>
      </div>
    </div>
  );
}
