import { useEffect, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import setupSql from '../generated/customerDatabaseSetup.json';
import constructionUpgradeSql from '../generated/constructionWorkflowUpgrade.json';

type Props = {
  supabase: SupabaseClient;
  error?: string;
  onReady: () => void;
};

type AppStatusResponse = {
  ok?: boolean;
  authenticated?: boolean;
  schema_version?: number | null;
  currency_code?: string;
  locale?: string;
};

export default function DatabaseSetupPage({ supabase, error: initialError, onReady }: Props) {
  const [error, setError] = useState(initialError ?? '');
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const [message, setMessage] = useState('Checking database schema…');
  const [schemaVersion, setSchemaVersion] = useState<number | null>(null);

  async function verify() {
    setBusy(true);
    setError('');
    setMessage('Checking database schema…');

    const { data, error: rpcError } = await supabase.rpc('get_app_status');
    if (rpcError) {
      console.error('Database verification RPC failed:', {
        code: rpcError.code,
        message: rpcError.message,
        details: rpcError.details,
        hint: rpcError.hint,
      });
      setMessage('Database verification RPC failed.');
      if (rpcError.code === 'PGRST202' || rpcError.code === 'PGRST205') {
        setError('Install the database setup SQL below in this Supabase project, then click Verify database setup.');
      } else {
        setError(`Database verification failed: ${rpcError.message}${rpcError.code ? ` (code ${rpcError.code})` : ''}`);
      }
      setBusy(false);
      return;
    }

    console.info('Database verification RPC response:', data);

    const appStatus = data as AppStatusResponse | null;
    const version = Number(appStatus?.schema_version ?? 0);
    setSchemaVersion(version);
    const responseSummary = appStatus
      ? `RPC succeeded • authenticated=${String(appStatus.authenticated ?? 'unknown')} • schema_version=${String(appStatus.schema_version ?? 'null')}`
      : 'RPC succeeded, but returned no status object.';

    if (version < 8) {
      setMessage(`${responseSummary}.`);
      setError('The database schema exists but the app did not receive schema version 8 from get_app_status(). This is a verification/permissions issue, not proof that the migrations are missing.');
      setBusy(false);
      return;
    }

    if (version < 15) {
      setMessage(`${responseSummary}. Construction workflow schema update required.`);
      setError(version >= 12
        ? 'This database needs migrations 0013, 0014 and 0015. Copy the Construction Workflow Upgrade SQL below and run it in Supabase. Do not rerun the original database setup SQL.'
        : `This database is at schema v${version}. Apply the missing numbered migrations through v12 first, then run the Construction Workflow Upgrade SQL. Do not rerun migrations 0001–0012.`);
      setBusy(false);
      return;
    }

    setMessage(`${responseSummary}. Database schema v${version} is ready.`);
    setBusy(false);
    onReady();
  }

  async function copyUpgradeSql() {
    setError('');
    try {
      await navigator.clipboard.writeText(constructionUpgradeSql);
      setCopied(true);
      setMessage('Construction Workflow Upgrade SQL copied. Run migrations 0013, 0014 and 0015 in Supabase.');
      window.setTimeout(() => setCopied(false), 2500);
    } catch (e) {
      setError(e instanceof Error ? `Could not copy the upgrade SQL: ${e.message}` : 'Could not copy the upgrade SQL.');
    }
  }

  async function copySetupSql() {
    setError('');
    try {
      await navigator.clipboard.writeText(setupSql);
      setCopied(true);
      setMessage('Database setup SQL copied to the clipboard.');
      window.setTimeout(() => setCopied(false), 2500);
    } catch (e) {
      setError(e instanceof Error ? `Could not copy the setup SQL: ${e.message}` : 'Could not copy the setup SQL.');
    }
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
            Your Supabase project is connected, but the Material Management System database schema has not been installed yet.
            This is a one-time setup for this business.
          </p>
        </div>

        <div className="stack" style={{ gap: 12 }}>
          <div className="setup-card" style={{ display: 'block', marginBottom: 0 }}>
            <h3>{schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15 ? 'Update the existing database' : 'Install the database schema'}</h3>
            <p>
              {schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15
                ? 'Your existing business database is already installed. Apply only the new construction workflow migrations; do not rerun the original setup script.'
                : 'The complete production database setup SQL is bundled inside this desktop application. You do not need access to our GitHub repository.'}
            </p>
            <ol style={{ margin: '14px 0 0', paddingLeft: 22, lineHeight: 1.8 }}>
              <li>Click <strong>{schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15 ? 'Copy construction workflow upgrade SQL' : 'Copy database setup SQL'}</strong>.</li>
              <li>Open the Supabase SQL Editor for this business.</li>
              <li>Paste the SQL and click <strong>Run</strong>.</li>
              <li>Return here and click <strong>Verify database setup</strong>.</li>
            </ol>
          </div>

          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <button className="secondary" type="button" onClick={() => void (schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15 ? copyUpgradeSql() : copySetupSql())}>
              {copied ? 'SQL copied' : schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15 ? 'Copy construction workflow upgrade SQL' : 'Copy database setup SQL'}
            </button>
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
          The setup uses your own Supabase project. The desktop application never needs your database password or service-role key.
          Your business data remains in your Supabase project.
        </p>

        <footer>Customer-owned Supabase • Product database schema is bundled with the installer</footer>
      </div>
    </div>
  );
}
