import { useEffect, useMemo, useRef, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { readSpreadsheet, type SpreadsheetRow } from '../lib/spreadsheet';

type ImportType = 'customers' | 'materials' | 'stock' | 'invoices' | 'payments';
type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };

const labels: Record<ImportType, string> = { customers: 'Customers', materials: 'Materials', stock: 'Stock Ledger', invoices: 'Historical Invoices', payments: 'Historical Payments' };
const aliases: Record<ImportType, Record<string, string[]>> = {
  customers: { name: ['customer','customer name','name','client'], gstin: ['gstin','gst no','gst number'], pan: ['pan'], phone: ['phone','mobile','mobile number','contact'], email: ['email','email address'], billing_address_line1: ['address','billing address','address line 1'], billing_city: ['city','billing city'], billing_state: ['state','billing state'], billing_state_code: ['state code','billing state code'], billing_postal_code: ['pin','pincode','postal code','zip'], shipping_address_line1: ['shipping address','shipping address line 1'], shipping_city: ['shipping city'], shipping_state: ['shipping state'], shipping_state_code: ['shipping state code'], shipping_postal_code: ['shipping pin','shipping pincode','shipping postal code'] },
  materials: { name: ['material','material name','name','item'], unit: ['unit','uom','unit name'], category: ['category','material category'], hsn_sac_code: ['hsn','hsn/sac','hsn sac','sac'], gst_rate: ['gst','gst %','gst rate','tax'], selling_price: ['price','selling price','rate','unit price'], quantity: ['quantity','qty','opening stock','stock'] },
  stock: { material: ['material','material name','item'], movement_type: ['type','movement type','transaction type'], quantity: ['quantity','qty'], movement_date: ['date','movement date','transaction date'], notes: ['notes','remarks','description'] },
  invoices: { invoice_number: ['invoice number','invoice no','invoice #','bill no','bill number'], invoice_date: ['invoice date','date'], customer: ['customer','customer name','client'], material: ['material','material name','item'], quantity: ['quantity','qty'], unit_price: ['unit price','price','rate'], gst_rate: ['gst','gst %','gst rate','tax'] },
  payments: { invoice_number: ['invoice number','invoice no','invoice #','bill no'], amount: ['amount','payment','paid amount'], payment_date: ['payment date','date'], payment_method: ['payment method','method','mode'], reference_number: ['reference','reference number','transaction id','utr'], notes: ['notes','remarks'] },
};

function normalize(s: string) { return s.trim().toLowerCase().replace(/[^a-z0-9]+/g, ' '); }
function valueFor(row: SpreadsheetRow, names: string[]) { const entries = Object.entries(row); const wanted = names.map(normalize); const hit = entries.find(([k]) => wanted.includes(normalize(k))); return hit?.[1]?.trim() ?? ''; }
function buildRows(type: ImportType, source: SpreadsheetRow[]) {
  const map = aliases[type];
  return source.map(row => Object.fromEntries(Object.entries(map).map(([field, names]) => [field, valueFor(row, names)])));
}
function requiredFields(type: ImportType) { return type === 'customers' ? ['name'] : type === 'materials' ? ['name'] : type === 'stock' ? ['material','movement_type','quantity'] : type === 'invoices' ? ['invoice_number','customer','material','quantity'] : ['invoice_number','amount']; }

export default function DataImportPage({ supabase, organizationId, onBack }: Props) {
  const [type, setType] = useState<ImportType>('customers');
  const [sourceRows, setSourceRows] = useState<SpreadsheetRow[]>([]);
  const [mappedRows, setMappedRows] = useState<Record<string,string>[]>([]);
  const [fileName, setFileName] = useState('');
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => { let active = true; (async () => {
    const { data, error: e } = await supabase.from('organization_members').select('role,is_active').eq('organization_id', organizationId).eq('user_id', (await supabase.auth.getUser()).data.user?.id ?? '').maybeSingle();
    if (!active) return;
    if (e) setError(e.message); else setIsAdmin(data?.is_active === true && data?.role === 'admin');
  })(); return () => { active = false; }; }, [supabase, organizationId]);

  const validation = useMemo(() => {
    const required = requiredFields(type);
    const errors: string[] = [];
    mappedRows.forEach((row, i) => required.forEach(field => { if (!row[field]?.trim()) errors.push(`Row ${i + 2}: ${field.replaceAll('_',' ')} is required.`); }));
    const checkNumber = (value: string, field: string, row: number, options: { min?: number; max?: number; exclusiveMin?: boolean } = {}) => {
      if (!value.trim()) return;
      const n = Number(value);
      if (!Number.isFinite(n) || (options.exclusiveMin ? n <= (options.min ?? 0) : n < (options.min ?? 0)) || (options.max !== undefined && n > options.max)) {
        const range = options.max === undefined ? (options.exclusiveMin ? 'greater than' : 'at least') + ` ${options.min ?? 0}` : `between ${options.min ?? 0} and ${options.max}`;
        errors.push(`Row ${row}: ${field.replaceAll('_', ' ')} must be a valid number ${range}.`);
      }
    };
    mappedRows.forEach((r, i) => {
      const row = i + 2;
      if (type === 'stock') checkNumber(r.quantity, 'quantity', row, { min: 0, exclusiveMin: true });
      if (type === 'materials') {
        checkNumber(r.gst_rate, 'gst_rate', row, { min: 0, max: 100 });
        checkNumber(r.selling_price, 'selling_price', row, { min: 0 });
        checkNumber(r.quantity, 'quantity', row, { min: 0 });
      }
      if (type === 'invoices') {
        checkNumber(r.quantity, 'quantity', row, { min: 0, exclusiveMin: true });
        checkNumber(r.unit_price, 'unit_price', row, { min: 0 });
        checkNumber(r.gst_rate, 'gst_rate', row, { min: 0, max: 100 });
      }
      if (type === 'payments') checkNumber(r.amount, 'amount', row, { min: 0, exclusiveMin: true });
    });
    return [...new Set(errors)];
  }, [mappedRows, type]);

  async function handleFile(file?: File) {
    if (!file) return;
    setBusy(true); setError(''); setMessage('Reading spreadsheet locally…');
    try { const rows = await readSpreadsheet(file); if (!rows.length) throw new Error('The spreadsheet contains no data rows.'); setSourceRows(rows); setMappedRows(buildRows(type, rows) as Record<string,string>[]); setFileName(file.name); setMessage(`${rows.length} data rows loaded. Review the preview before importing.`); }
    catch (e) { setSourceRows([]); setMappedRows([]); setFileName(''); setError(e instanceof Error ? e.message : 'Could not read the spreadsheet.'); setMessage(''); }
    finally { setBusy(false); }
  }

  function changeType(next: ImportType) { setType(next); if (sourceRows.length) setMappedRows(buildRows(next, sourceRows) as Record<string,string>[]); setError(''); setMessage(''); }

  async function importRows() {
    if (!mappedRows.length || validation.length) return;
    setBusy(true); setError(''); setMessage('Importing…');
    const rpc = type === 'customers' ? 'import_customers' : type === 'materials' ? 'import_materials' : type === 'stock' ? 'import_stock_movements' : type === 'invoices' ? 'import_historical_invoices' : 'import_historical_payments';
    const { data, error: e } = await supabase.rpc(rpc, { p_organization_id: organizationId, p_rows: mappedRows });
    if (e) setError(e.message); else setMessage(`Import complete: ${JSON.stringify(data)}. The import was written atomically.`);
    setBusy(false);
  }

  if (isAdmin === false) return <main className="main-content"><header className="topbar"><div><p className="eyebrow">Data Import</p><h1>Admin access required</h1></div></header><section className="setup-card"><div><h3>Historical data import is restricted</h3><p>Only an Admin can import customer, material, stock, invoice or payment history.</p></div><button className="secondary" onClick={onBack}>Back</button></section></main>;
  if (isAdmin === null) return <main className="main-content"><div className="mini-empty">Checking access…</div></main>;

  const previewColumns = Object.keys(aliases[type]);
  return <main className="main-content">
    <header className="topbar"><div><p className="eyebrow">Migration</p><h1>Import business data</h1><p className="page-subtitle">Bring existing Excel or CSV records into this business workspace.</p></div><button className="secondary" onClick={onBack}>Back</button></header>
    <section className="setup-card"><div><h3>Choose data to import</h3><p>Files are read locally by the desktop application. Nothing is uploaded until you confirm the import.</p></div><select value={type} onChange={e => changeType(e.target.value as ImportType)}>{Object.entries(labels).map(([k,v]) => <option key={k} value={k}>{v}</option>)}</select></section>
    <section className="quick-card">
      <div className="section-head"><div><p className="eyebrow">Step 1</p><h3>Upload Excel or CSV</h3></div><button className="primary compact" disabled={busy} onClick={() => inputRef.current?.click()}>Choose file</button><input ref={inputRef} hidden type="file" accept=".xlsx,.csv" onChange={e => void handleFile(e.target.files?.[0])}/></div>
      {fileName && <p className="hint">{fileName} • {sourceRows.length} rows</p>}
      {error && <div className="alert error">{error}</div>}{message && <div className="alert info">{message}</div>}
    </section>
    {mappedRows.length > 0 && <section className="recent-card"><div className="section-head"><div><p className="eyebrow">Step 2</p><h3>Review and validate</h3></div><span className={validation.length ? 'status-badge danger' : 'status-badge'}>{validation.length ? `${validation.length} validation issue${validation.length===1?'':'s'}` : `${mappedRows.length} rows ready`}</span></div>
      {validation.length > 0 && <div className="alert error">{validation.slice(0,8).map((v,i)=><div key={i}>{v}</div>)}{validation.length > 8 && <div>…and {validation.length-8} more.</div>}</div>}
      <div className="table-wrap"><table><thead><tr><th>Row</th>{previewColumns.map(c => <th key={c}>{c.replaceAll('_',' ')}</th>)}</tr></thead><tbody>{mappedRows.slice(0,10).map((r,i)=><tr key={i}><td>{i+2}</td>{previewColumns.map(c=><td key={c}>{r[c] || '—'}</td>)}</tr>)}</tbody></table></div>
      <div className="section-head import-footer"><p className="hint">Showing the first 10 rows. Imports are all-or-nothing.</p><button className="primary" disabled={busy || validation.length > 0} onClick={() => void importRows()}>{busy ? 'Importing…' : `Import ${mappedRows.length} rows`}</button></div>
    </section>}
  </main>;
}
