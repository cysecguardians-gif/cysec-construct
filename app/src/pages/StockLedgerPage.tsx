import { useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

type Movement = { id: string; material_id: string; movement_type: string; quantity: number; notes: string | null; created_at: string; reference_type: string | null; reference_id: string | null; material_name:string; selling_price_paise:number; unit_short_code:string|null; counterparty_name:string|null; project_name:string|null; contract_number:string|null; po_number:string|null; vendor_invoice_number:string|null };
type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };
const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });
const labels: Record<string, string> = { opening: 'Opening', purchase: 'Purchase', sale: 'Sale', adjustment_in: 'Adjustment in', adjustment_out: 'Adjustment out', return_in: 'Return in', return_out: 'Return out' };
const incoming = new Set(['opening', 'purchase', 'adjustment_in', 'return_in']);
const outgoing = new Set(['sale', 'adjustment_out', 'return_out']);
const localDate = (d: Date) => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
const today = () => localDate(new Date());
const monthStart = () => { const d = new Date(); d.setDate(1); return localDate(d); };

export default function StockLedgerPage({ supabase, organizationId, onBack }: Props) {
  const [movements, setMovements] = useState<Movement[]>([]); const [search, setSearch] = useState(''); const [from, setFrom] = useState(monthStart()); const [to, setTo] = useState(today()); const [type, setType] = useState('all'); const [loading, setLoading] = useState(true); const [error, setError] = useState('');
  async function load() {
    setLoading(true);
    setError('');
    const pageSize = 500;
    const rows: Movement[] = [];
    try {
      for (let offset = 0; ; offset += pageSize) {
        const { data, error: queryError } = await supabase
          .from('construction_stock_ledger')
          .select('id,material_id,movement_type,quantity,notes,created_at,reference_type,reference_id,material_name,selling_price_paise,unit_short_code,counterparty_name,project_name,contract_number,po_number,vendor_invoice_number')
          .eq('organization_id', organizationId)
          .gte('created_at', `${from}T00:00:00`)
          .lte('created_at', `${to}T23:59:59.999`)
          .order('created_at', { ascending: false })
          .order('id', { ascending: false })
          .range(offset, offset + pageSize - 1);
        if (queryError) throw queryError;
        const page = (data ?? []) as unknown as Movement[];
        rows.push(...page);
        if (page.length < pageSize) break;
      }
      setMovements(rows);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load the stock ledger.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { void load(); }, [organizationId, from, to]);
  const filtered = useMemo(() => movements.filter(m => (type === 'all' || m.movement_type === type) && (`${m.material_name} ${m.counterparty_name??''} ${m.project_name??''} ${m.contract_number??''} ${m.po_number??''} ${m.notes ?? ''} ${m.reference_id ?? ''}`).toLowerCase().includes(search.trim().toLowerCase())), [movements, type, search]);
  const stockInCount = filtered.filter(m => incoming.has(m.movement_type)).length; const stockOutCount = filtered.filter(m => outgoing.has(m.movement_type)).length;
  return <main className="main-content"><button className="back-link" onClick={onBack}>← Back to materials</button><header className="topbar"><div><p className="eyebrow">Inventory</p><h1>Stock ledger</h1></div></header>
    <section className="report-toolbar"><div><span>From</span><input type="date" value={from} max={to} onChange={e => setFrom(e.target.value)} /></div><div><span>To</span><input type="date" value={to} min={from} max={today()} onChange={e => setTo(e.target.value)} /></div><div><span>Movement</span><select value={type} onChange={e => setType(e.target.value)}><option value="all">All movements</option>{Object.entries(labels).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div></section>
    {error && <div className="alert error page-alert">{error}</div>}
    <section className="report-metrics"><div className="metric"><span>Inbound movements</span><strong>{stockInCount.toLocaleString('en-IN')}</strong><small>Selected period</small></div><div className="metric"><span>Outbound movements</span><strong>{stockOutCount.toLocaleString('en-IN')}</strong><small>Selected period</small></div><div className="metric"><span>Movement records</span><strong>{filtered.length.toLocaleString('en-IN')}</strong><small>Across selected materials</small></div><div className="metric"><span>Materials represented</span><strong>{new Set(filtered.map(m => m.material_id)).size}</strong><small>In filtered movements</small></div></section>
    <section className="page-toolbar"><input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search material, notes or reference…" /><span>{filtered.length} movement{filtered.length === 1 ? '' : 's'}</span></section>
    <section className="table-card">{loading ? <div className="table-empty">Loading stock ledger…</div> : filtered.length === 0 ? <div className="table-empty"><strong>No stock movements</strong><span>There are no movements matching this filter.</span></div> : <table><thead><tr><th>Date</th><th>Material</th><th>Type</th><th>Quantity</th><th>Value at selling price</th><th>Contractor / Vendor</th><th>Project / PO</th><th>Reference</th><th>Notes</th></tr></thead><tbody>{filtered.map(m => <tr key={m.id}><td>{new Date(m.created_at).toLocaleString('en-IN')}</td><td><strong>{m.material_name ?? 'Unknown material'}</strong>{m.unit_short_code && <small>{m.unit_short_code}</small>}</td><td><span className={`pill ${incoming.has(m.movement_type) ? 'active' : ''}`}>{m.reference_type==='material_issue'?'Issued to contractor':m.reference_type==='material_return'?'Contractor return':m.reference_type==='material_purchase'?'Vendor purchase':labels[m.movement_type] ?? m.movement_type}</span></td><td>{Number(m.quantity).toLocaleString('en-IN')}</td><td>{money.format(Number(m.quantity) * Number(m.selling_price_paise) / 100)}</td><td>{m.counterparty_name??'—'}</td><td>{[m.project_name,m.po_number??m.contract_number].filter(Boolean).join(' · ')||'—'}</td><td>{m.reference_type ? `${m.reference_type}${m.reference_id ? ` • ${m.reference_id.slice(0, 8)}` : ''}` : '—'}</td><td>{m.notes || '—'}</td></tr>)}</tbody></table>}</section>
  </main>;
}
