import { useEffect, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import setupSql from '../generated/customerDatabaseSetup.json';
import constructionUpgradeSql from '../generated/constructionWorkflowUpgrade.json';
import contractorSettlementUpgradeSql from '../generated/contractorSettlementUpgrade.json';
import constructionImportUpgradeSql from '../generated/constructionDataImportUpgrade.json';

type Props = {
  supabase: SupabaseClient;
  error?: string;
  onReady: () => void;
};

type SetupStatusResponse = {
  initialized?: boolean;
  admin_exists?: boolean;
  schema_version?: number | null;
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

    // Database verification runs before an administrator signs in. Use the
    // deliberately public, read-only setup RPC rather than get_app_status(),
    // which requires an authenticated session.
    const { data, error: rpcError } = await supabase.rpc('get_setup_status');
    if (rpcError) {
      console.error('Database verification RPC failed:', {
        code: rpcError.code,
        message: rpcError.message,
        details: rpcError.details,
        hint: rpcError.hint,
      });
      setMessage('Database verification RPC failed.');
      if (rpcError.code === 'PGRST202' || rpcError.code === 'PGRST205') {
        setError('The database setup check is not installed in this Supabase project. Copy the database setup SQL below, run it in the Supabase SQL Editor, then verify again.');
      } else {
        setError(`Database verification failed: ${rpcError.message}${rpcError.code ? ` (code ${rpcError.code})` : ''}`);
      }
      setBusy(false);
      return;
    }

    console.info('Database verification RPC response:', data);

    const setupStatus = data as SetupStatusResponse | null;
    if (!setupStatus || typeof setupStatus !== 'object' || !Number.isFinite(Number(setupStatus.schema_version))) {
      setSchemaVersion(null);
      setMessage('Database setup status could not be interpreted.');
      setError('The setup-status function returned an unexpected response. Check the installed SQL version and try again.');
      setBusy(false);
      return;
    }

    const version = Number(setupStatus.schema_version);
    setSchemaVersion(version);
    const responseSummary = `Setup check succeeded • administrator_exists=${String(setupStatus.admin_exists ?? false)} • schema_version=${version}`;

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

    if (version < 16) {
      setMessage(`${responseSummary}. Contractor settlement schema update required.`);
      setError('This database is at schema v15. Copy the Contractor Settlement Upgrade SQL and run migration 0016 only in this business Supabase project. Do not rerun migrations 0013, 0014 or 0015, or the original setup SQL.');
      setBusy(false);
      return;
    }

    if (version < 17) {
      setMessage(`${responseSummary}. Construction data import update required.`);
      setError('This database is at schema v16. Copy the Construction Data Import Upgrade SQL and run migration 0017 only in this business Supabase project. Do not rerun earlier migrations or the original setup SQL.');
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

  async function copySettlementUpgradeSql() {
    setError('');
    try {
      await navigator.clipboard.writeText(contractorSettlementUpgradeSql);
      setCopied(true);
      setMessage('Contractor Settlement Upgrade SQL copied. Run migration 0016 only in Supabase.');
      window.setTimeout(() => setCopied(false), 2500);
    } catch (e) {
      setError(e instanceof Error ? `Could not copy the settlement upgrade SQL: ${e.message}` : 'Could not copy the settlement upgrade SQL.');
    }
  }

  async function copyConstructionImportUpgradeSql() {
    setError('');
    try {
      await navigator.clipboard.writeText(constructionImportUpgradeSql);
      setCopied(true);
      setMessage('Construction Data Import Upgrade SQL copied. Run migration 0017 only.');
      window.setTimeout(() => setCopied(false), 2500);
    } catch (e) {
      setError(e instanceof Error ? `Could not copy the construction import upgrade SQL: ${e.message}` : 'Could not copy the construction import upgrade SQL.');
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
          <span className="brand-mark">BS</span>
          <div><strong>BuildSphere</strong><small>Construction Management</small></div>
        </div>

        <div className="auth-copy">
          <p className="eyebrow">Database setup</p>
          <h1>Prepare your business database</h1>
          <p>
            Your Supabase project is connected, but the BuildSphere database schema has not been installed yet.
            This is a one-time setup for this business.
          </p>
        </div>

        <div className="stack" style={{ gap: 12 }}>
          <div className="setup-card" style={{ display: 'block', marginBottom: 0 }}>
            <h3>{schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 17 ? 'Update the existing database' : 'Install the database schema'}</h3>
            <p>
              {schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15
                ? 'Your existing business database is already installed. Apply the construction workflow migrations in order; do not rerun the original setup script.'
                : schemaVersion === 15
                  ? 'Your database is at schema version 15. Apply only migration 0016 to enable replacement settlements after cancellation. Do not rerun earlier migrations.'
                  : schemaVersion === 16
                    ? 'Your database is at schema version 16. Apply only migration 0017 to enable construction data imports. Do not rerun earlier migrations.'
                  : 'The complete production database setup SQL is bundled inside this desktop application. You do not need access to our GitHub repository.'}
            </p>
            <ol style={{ margin: '14px 0 0', paddingLeft: 22, lineHeight: 1.8 }}>
              <li>Click <strong>{schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15
                  ? 'Copy construction workflow upgrade SQL'
                  : schemaVersion === 15
                    ? 'Copy contractor settlement upgrade SQL'
                    : schemaVersion === 16
                      ? 'Copy construction data import upgrade SQL'
                    : 'Copy database setup SQL'}</strong>.</li>
              <li>Open the Supabase SQL Editor for this business.</li>
              <li>Paste the SQL and click <strong>Run</strong>.</li>
              <li>Return here and click <strong>Verify database setup</strong>.</li>
            </ol>
          </div>

          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {(schemaVersion === null || schemaVersion < 8) && (
              <button className="secondary" type="button" onClick={() => void copySetupSql()}>
                {copied ? 'SQL copied' : 'Copy database setup SQL'}
              </button>
            )}
            {schemaVersion !== null && schemaVersion >= 12 && schemaVersion < 15 && (
              <button className="secondary" type="button" onClick={() => void copyUpgradeSql()}>
                {copied ? 'SQL copied' : 'Copy construction workflow upgrade SQL'}
              </button>
            )}
            {schemaVersion === 16 && (
              <button className="secondary" type="button" onClick={() => void copyConstructionImportUpgradeSql()}>
                {copied ? 'SQL copied' : 'Copy construction data import upgrade SQL'}
              </button>
            )}
            {schemaVersion === 15 && (
              <button className="secondary" type="button" onClick={() => void copySettlementUpgradeSql()}>
                {copied ? 'SQL copied' : 'Copy contractor settlement upgrade SQL'}
              </button>
            )}
            <a
              href="https://supabase.com/dashboard"
              target="_blank"
              rel="noreferrer"
              style={{ display: 'inline-block', border: '1px solid #d6dce5', borderRadius: 9, padding: '10px 14px', color: '#344054', textDecoration: 'none', fontSize: 12 }}
            >Open Supabase</a>
          </div>
        </div>

        {schemaVersion !== null && schemaVersion >= 8 && schemaVersion < 12 && <div className="alert info">This database is on an older intermediate schema. Apply its missing numbered migrations in sequence before the construction workflow upgrade. The full setup script is intentionally not offered here to protect existing business data.</div>}
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
