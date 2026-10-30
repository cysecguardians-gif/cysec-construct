import { useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

type Invoice = { invoice_id: string; customer_id: string; invoice_number: string; invoice_date: string; invoice_status: string; grand_total_paise: number; paid_amount_paise: number; pending_amount_paise: number; payment_status: string; customers?: { name: string } | null };
type Payment = { id: string; amount_paise: number; payment_date: string; payment_method: string; reference_number: string | null; notes: string | null };
type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };
const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });

export default function PaymentsPage({ supabase, organizationId, onBack }: Props) {
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [selected, setSelected] = useState<Invoice | null>(null);

  async function load() {
    setBusy(true); setError('');
    const { data, error: e } = await supabase.from('invoice_payment_summary').select('invoice_id,customer_id,invoice_number,invoice_date,invoice_status,grand_total_paise,paid_amount_paise,pending_amount_paise,payment_status,customers(name)').eq('organization_id', organizationId).order('invoice_date', { ascending: false });
    setBusy(false);
    if (e) { setError(e.message); return; }
    setInvoices((data ?? []) as unknown as Invoice[]);
  }
  useEffect(() => { void load(); }, [organizationId]);

  const filtered = useMemo(() => { const t = search.trim().toLowerCase(); return t ? invoices.filter(i => `${i.invoice_number} ${i.customers?.name ?? ''} ${i.payment_status}`.toLowerCase().includes(t)) : invoices; }, [invoices, search]);
  const pendingTotal = invoices.filter(i => i.invoice_status !== 'cancelled').reduce((s, i) => s + Number(i.pending_amount_paise), 0);

  return <main className="main-content">
    <header className="topbar"><div><button className="back-link" onClick={onBack}>← Overview</button><p className="eyebrow">Collections</p><h1>Payments</h1></div></header>
    <section className="metric-grid"><div className="metric"><span>Invoices</span><strong>{invoices.length}</strong></div><div className="metric"><span>Pending balance</span><strong>{money.format(pendingTotal / 100)}</strong></div><div className="metric"><span>Partially paid</span><strong>{invoices.filter(i => i.payment_status === 'partially_paid').length}</strong></div><div className="metric"><span>Fully paid</span><strong>{invoices.filter(i => i.payment_status === 'paid').length}</strong></div></section>
    <section className="page-toolbar"><input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search invoice, customer or status…"/><span>{filtered.length} invoice{filtered.length === 1 ? '' : 's'}</span></section>
    {error && <div className="alert error page-alert">{error}</div>}
    <section className="table-card">{busy ? <div className="table-empty">Loading payments…</div> : filtered.length === 0 ? <div className="table-empty"><strong>No invoices found</strong><span>Payments become available after an invoice is issued.</span></div> : <table><thead><tr><th>Invoice</th><th>Customer</th><th>Total</th><th>Paid</th><th>Pending</th><th>Status</th><th></th></tr></thead><tbody>{filtered.map(i => <tr key={i.invoice_id}><td><strong>{i.invoice_number}</strong><small>{new Date(i.invoice_date).toLocaleDateString('en-IN')}</small></td><td>{i.customers?.name || '—'}</td><td>{money.format(Number(i.grand_total_paise) / 100)}</td><td>{money.format(Number(i.paid_amount_paise) / 100)}</td><td>{money.format(Number(i.pending_amount_paise) / 100)}</td><td><span className={`pill ${i.payment_status === 'paid' ? 'active' : ''}`}>{label(i.payment_status)}</span></td><td className="row-actions">{i.payment_status !== 'paid' && i.invoice_status !== 'cancelled' && <button onClick={() => setSelected(i)}>Record payment</button>}<button onClick={() => setSelected(i)}>History</button></td></tr>)}</tbody></table>}</section>
    {selected && <PaymentModal supabase={supabase} organizationId={organizationId} invoice={selected} onClose={() => setSelected(null)} onSaved={async () => { setSelected(null); await load(); }} />}
  </main>;
}

function PaymentModal({ supabase, organizationId, invoice, onClose, onSaved }: { supabase: SupabaseClient; organizationId: string; invoice: Invoice; onClose: () => void; onSaved: () => Promise<void> }) {
  const [payments, setPayments] = useState<Payment[]>([]);
  const [amount, setAmount] = useState((Number(invoice.pending_amount_paise) / 100).toFixed(2));
  const [method, setMethod] = useState('upi'); const [reference, setReference] = useState(''); const [notes, setNotes] = useState('');
  const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  useEffect(() => { void (async () => { const { data, error: e } = await supabase.from('payments').select('id,amount_paise,payment_date,payment_method,reference_number,notes').eq('organization_id', organizationId).eq('invoice_id', invoice.invoice_id).order('payment_date', { ascending: false }); if (!e) setPayments((data ?? []) as Payment[]); })(); }, [invoice.invoice_id]);
  async function save(e: React.FormEvent) { e.preventDefault(); const paise = Math.round(Number(amount) * 100); if (!Number.isFinite(paise) || paise <= 0) { setError('Enter a valid payment amount.'); return; } if (paise > Number(invoice.pending_amount_paise)) { setError('Payment cannot exceed the pending balance.'); return; } setBusy(true); setError(''); const { error: e2 } = await supabase.rpc('record_payment', { p_organization_id: organizationId, p_invoice_id: invoice.invoice_id, p_amount_paise: paise, p_payment_date: new Date().toISOString().slice(0, 10), p_payment_method: method, p_reference_number: reference.trim() || null, p_notes: notes.trim() || null }); setBusy(false); if (e2) { setError(e2.message); return; } await onSaved(); }
  return <div className="modal-backdrop"><div className="modal"><div className="modal-header"><div><h2>{invoice.invoice_number}</h2><small>{invoice.customers?.name || 'Customer'} • Pending {money.format(Number(invoice.pending_amount_paise) / 100)}</small></div><button onClick={onClose}>×</button></div><div className="payment-history">{payments.length ? payments.map(p => <div className="payment-row" key={p.id}><div><strong>{money.format(Number(p.amount_paise) / 100)}</strong><small>{new Date(p.payment_date).toLocaleDateString('en-IN')} • {label(p.payment_method)}{p.reference_number ? ` • ${p.reference_number}` : ''}</small></div></div>) : <div className="table-empty">No payments recorded yet.</div>}</div>{invoice.invoice_status !== 'cancelled' && invoice.payment_status !== 'paid' && <form className="stack" onSubmit={save}><div className="two-col"><label>Amount (₹)<input type="number" min="0.01" max={Number(invoice.pending_amount_paise) / 100} step="0.01" value={amount} onChange={e => setAmount(e.target.value)} required/></label><label>Payment method<select value={method} onChange={e => setMethod(e.target.value)}><option value="cash">Cash</option><option value="upi">UPI</option><option value="bank_transfer">Bank Transfer</option><option value="cheque">Cheque</option><option value="card">Card</option><option value="other">Other</option></select></label></div><label>Reference number <span className="muted">optional</span><input value={reference} onChange={e => setReference(e.target.value)} placeholder="UTR / cheque number / receipt number"/></label><label>Notes <span className="muted">optional</span><input value={notes} onChange={e => setNotes(e.target.value)}/></label>{error && <div className="alert error">{error}</div>}<div className="modal-actions"><button type="button" onClick={onClose}>Close</button><button className="primary compact" disabled={busy}>{busy ? 'Saving…' : 'Record payment'}</button></div></form>}{invoice.payment_status === 'paid' && <div className="alert success">This invoice is fully paid.</div>}</div></div>;
}
function label(value: string) { return value === 'partially_paid' ? 'Partially Paid' : value === 'paid' ? 'Paid' : value === 'cancelled' ? 'Cancelled' : value === 'pending' ? 'Pending' : value.replaceAll('_', ' ').replace(/\b\w/g, c => c.toUpperCase()); }
