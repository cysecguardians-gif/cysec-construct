import { useEffect, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import setupSql from '../generated/customerDatabaseSetup.json';
import upgradeSql from '../generated/customerDatabaseUpgrade.json';

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

    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError) {
      setMessage('Could not check the current administrator session.');
      setError(`Authentication check failed: ${sessionError.message}`);
      setBusy(false);
      return;
    }
    if (!sessionData.session) {
      setMessage('Database schema installed. Administrator setup is the next step.');
      setBusy(false);
      onReady();
      return;
    }

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

    if (version < 26) {
      setMessage(`${responseSummary}.`);
      setError('Schema version 25 detected. Apply the targeted migration 0026 using the upgrade SQL below, then verify again.');
      setBusy(false);
      return;
    }

    if (appStatus?.authenticated === false) {
      setMessage(`${responseSummary}. Sign in as the administrator to complete verification.`);
      setError('The database status function did not receive the authenticated administrator session. Sign in, then verify again.');
      setBusy(false);
      return;
    }

    setMessage(`${responseSummary}. Database schema v${version} is ready.`);
    setBusy(false);
    onReady();
  }

  async function copySetupSql() {
    setError('');
    try {
      const sqlToCopy = schemaVersion !== null && schemaVersion >= 25 ? upgradeSql : setupSql;
      await navigator.clipboard.writeText(sqlToCopy);
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
          <span className="brand-mark">CC</span>
          <div><strong>CySec Construct</strong><small>Construction Management</small></div>
        </div>

        <div className="auth-copy">
          <p className="eyebrow">Database setup</p>
          <h1>{schemaVersion !== null && schemaVersion >= 25 ? 'Update your business database' : 'Prepare your business database'}</h1>
          <p>
            {schemaVersion !== null && schemaVersion >= 25
              ? `Your existing database is at schema version ${schemaVersion}. Apply the targeted compatibility migration to upgrade it to version 26.`
              : 'Your Supabase project is connected, but the CySec Construct database schema has not been installed yet. This is a one-time setup for this business.'}
          </p>
        </div>

        <div className="stack" style={{ gap: 12 }}>
          <div className="setup-card" style={{ display: 'block', marginBottom: 0 }}>
            {schemaVersion !== null && schemaVersion >= 25 ? <>
              <h3>Apply the v25 → v26 compatibility update</h3>
              <p>Only migration 0026 is required for this existing database. Do not rerun the complete initial setup script.</p>
              <ol style={{ margin: '14px 0 0', paddingLeft: 22, lineHeight: 1.8 }}>
                <li>Click <strong>Copy database upgrade SQL</strong>.</li>
                <li>Open the Supabase SQL Editor for this business.</li>
                <li>Paste the migration and click <strong>Run</strong>.</li>
                <li>Return here and click <strong>Verify database setup</strong>.</li>
              </ol>
            </> : <>
              <h3>Install the database schema</h3>
              <p>The complete production database setup SQL is bundled inside this desktop application. You do not need access to our GitHub repository.</p>
              <ol style={{ margin: '14px 0 0', paddingLeft: 22, lineHeight: 1.8 }}>
                <li>Click <strong>Copy database setup SQL</strong>.</li>
                <li>Open the Supabase SQL Editor for this business.</li>
                <li>Paste the SQL and click <strong>Run</strong>.</li>
                <li>Return here and click <strong>Verify database setup</strong>. The app will then prompt you to create the first administrator before authenticated verification.</li>
              </ol>
            </>}
          </div>

          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <button className="secondary" type="button" onClick={() => void copySetupSql()}>
              {copied ? 'SQL copied' : schemaVersion !== null && schemaVersion >= 25 ? 'Copy database upgrade SQL' : 'Copy database setup SQL'}
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
