import { useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import './reports.css';

const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });

type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };
type Invoice = { id: string; invoice_number: string | null; invoice_date: string; status: string; discount_amount_paise: number; subtotal_paise: number; taxable_value_paise: number; total_gst_paise: number; grand_total_paise: number };
type Payment = { id: string; invoice_id: string; amount_paise: number; payment_date: string; payment_method: string };
type Movement = { id: string; material_id: string; movement_type: string; quantity: number; created_at: string; materials?: { name: string }[] | null };
type CustomerBalance = { customer_id: string; name: string; total_invoiced_paise: number; total_paid_paise: number; total_pending_paise: number };

const localDate = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
const today = () => localDate(new Date());
const monthStart = () => { const d = new Date(); d.setDate(1); return localDate(d); };
const fyStart = () => { const d = new Date(); const year = d.getFullYear(); const month = d.getMonth() + 1; return `${month >= 4 ? year : year - 1}-04-01`; };

export default function ReportsPage({ supabase, organizationId, onBack }: Props) {
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(today());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [movements, setMovements] = useState<Movement[]>([]);
  const [balances, setBalances] = useState<CustomerBalance[]>([]);

  async function load() {
    setLoading(true); setError('');
    const [invoiceResult, paymentResult, movementResult, balanceResult] = await Promise.all([
      supabase.from('invoices').select('id,invoice_number,invoice_date,status,discount_amount_paise,subtotal_paise,taxable_value_paise,total_gst_paise,grand_total_paise').eq('organization_id', organizationId).gte('invoice_date', from).lte('invoice_date', to).order('invoice_date', { ascending: false }),
      supabase.from('payments').select('id,invoice_id,amount_paise,payment_date,payment_method').eq('organization_id', organizationId).gte('payment_date', from).lte('payment_date', to).order('payment_date', { ascending: false }),
      supabase.from('stock_movements').select('id,material_id,movement_type,quantity,created_at,materials(name)').eq('organization_id', organizationId).gte('created_at', `${from}T00:00:00`).lte('created_at', `${to}T23:59:59.999`).order('created_at', { ascending: false }),
      supabase.from('customer_balance_summary').select('customer_id,name,total_invoiced_paise,total_paid_paise,total_pending_paise').eq('organization_id', organizationId).order('total_pending_paise', { ascending: false }).limit(20),
    ]);
    if (invoiceResult.error || paymentResult.error || movementResult.error || balanceResult.error) {
      setError(invoiceResult.error?.message || paymentResult.error?.message || movementResult.error?.message || balanceResult.error?.message || 'Could not load reports.');
      setLoading(false); return;
    }
    setInvoices((invoiceResult.data ?? []) as Invoice[]);
    setPayments((paymentResult.data ?? []) as Payment[]);
    setMovements((movementResult.data ?? []) as Movement[]);
    setBalances((balanceResult.data ?? []) as CustomerBalance[]);
    setLoading(false);
  }

  useEffect(() => { void load(); }, [organizationId, from, to]);

  const issued = useMemo(() => invoices.filter(i => i.status === 'issued'), [invoices]);
  const cancelled = useMemo(() => invoices.filter(i => i.status === 'cancelled'), [invoices]);
  const sales = useMemo(() => ({
    invoices: issued.length,
    subtotal: issued.reduce((s, i) => s + Number(i.subtotal_paise), 0),
    discounts: issued.reduce((s, i) => s + Number(i.discount_amount_paise), 0),
    taxable: issued.reduce((s, i) => s + Number(i.taxable_value_paise), 0),
    gst: issued.reduce((s, i) => s + Number(i.total_gst_paise), 0),
    total: issued.reduce((s, i) => s + Number(i.grand_total_paise), 0),
  }), [issued]);
  const collected = payments.reduce((s, p) => s + Number(p.amount_paise), 0);
  const outstanding = balances.reduce((s, b) => s + Number(b.total_pending_paise), 0);
  const stockInCount = movements.filter(m => ['opening', 'purchase', 'adjustment_in', 'return_in'].includes(m.movement_type)).length;
  const stockOutCount = movements.filter(m => ['sale', 'adjustment_out', 'return_out'].includes(m.movement_type)).length;

  return <main className="main-content reports-page">
    <button className="back-link" onClick={onBack}>← Back to dashboard</button>
    <header className="topbar"><div><p className="eyebrow">Reports</p><h1>Business reports</h1></div></header>
    <section className="report-toolbar">
      <div><span>From</span><input type="date" value={from} max={to} onChange={e => setFrom(e.target.value)} /></div>
      <div><span>To</span><input type="date" value={to} min={from} max={today()} onChange={e => setTo(e.target.value)} /></div>
      <div className="report-presets"><button onClick={() => { setFrom(today()); setTo(today()); }}>Today</button><button onClick={() => { setFrom(monthStart()); setTo(today()); }}>This month</button><button onClick={() => { setFrom(fyStart()); setTo(today()); }}>Current FY</button></div>
      <span className="report-status">{loading ? 'Refreshing…' : `${issued.length} issued invoices`}</span>
    </section>
    {error && <div className="alert error page-alert">{error}</div>}

    <section className="report-metrics">
      <div className="metric"><span>Sales</span><strong>{money.format(sales.total / 100)}</strong><small>{sales.invoices} issued invoices</small></div>
      <div className="metric"><span>Payments collected</span><strong>{money.format(collected / 100)}</strong><small>{payments.length} payments in period</small></div>
      <div className="metric"><span>Top 20 receivables</span><strong>{money.format(outstanding / 100)}</strong><small>Sum of the 20 largest customer balances, not company total</small></div>
      <div className="metric"><span>GST</span><strong>{money.format(sales.gst / 100)}</strong><small>On issued invoices</small></div>
    </section>

    <section className="reports-grid">
      <div className="report-card"><div className="section-head"><div><p className="eyebrow">Sales</p><h3>Sales summary</h3></div></div><div className="report-lines">
        <span><b>Subtotal</b><strong>{money.format(sales.subtotal / 100)}</strong></span>
        <span><b>Discounts</b><strong>{money.format(sales.discounts / 100)}</strong></span>
        <span><b>Taxable value</b><strong>{money.format(sales.taxable / 100)}</strong></span>
        <span><b>GST</b><strong>{money.format(sales.gst / 100)}</strong></span>
        <span className="report-grand"><b>Grand total</b><strong>{money.format(sales.total / 100)}</strong></span>
      </div></div>
      <div className="report-card"><div className="section-head"><div><p className="eyebrow">Stock</p><h3>Movement summary</h3></div></div><div className="report-lines">
        <span><b>Inbound movements</b><strong>{stockInCount.toLocaleString('en-IN')}</strong></span>
        <span><b>Outbound movements</b><strong>{stockOutCount.toLocaleString('en-IN')}</strong></span>
        <span><b>Movement records</b><strong>{movements.length}</strong></span>
        <span className="report-note">Movement counts only. Quantities from different materials and units cannot be combined.</span>
      </div></div>
    </section>

    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Receivables</p><h3>Customer balances</h3></div><span>Top 20 by outstanding amount</span></div><table><thead><tr><th>Customer</th><th>Invoiced</th><th>Paid</th><th>Outstanding</th></tr></thead><tbody>{balances.length === 0 ? <tr><td colSpan={4}><div className="table-empty">No customer balances found.</div></td></tr> : balances.map(b => <tr key={b.customer_id}><td><strong>{b.name}</strong></td><td>{money.format(Number(b.total_invoiced_paise) / 100)}</td><td>{money.format(Number(b.total_paid_paise) / 100)}</td><td><strong>{money.format(Number(b.total_pending_paise) / 100)}</strong></td></tr>)}</tbody></table></section>

    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Invoices</p><h3>Period activity</h3></div><span>{cancelled.length} cancelled</span></div><table><thead><tr><th>Invoice</th><th>Date</th><th>Status</th><th>Amount</th></tr></thead><tbody>{invoices.length === 0 ? <tr><td colSpan={4}><div className="table-empty">No invoices in this period.</div></td></tr> : invoices.slice(0, 50).map(i => <tr key={i.id}><td><strong>{i.invoice_number || 'Draft'}</strong></td><td>{new Date(i.invoice_date).toLocaleDateString('en-IN')}</td><td><span className={`pill ${i.status === 'issued' ? 'active' : ''}`}>{i.status.charAt(0).toUpperCase() + i.status.slice(1)}</span></td><td>{money.format(Number(i.grand_total_paise) / 100)}</td></tr>)}</tbody></table></section>
  </main>;
}
