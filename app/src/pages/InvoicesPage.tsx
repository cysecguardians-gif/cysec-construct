import { useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

type Customer = { id: string; name: string; gstin: string | null; billing_state: string | null; billing_state_code: string | null; is_active: boolean };
type Material = { id: string; name: string; hsn_sac_code: string | null; gst_rate: number; selling_price_paise: number; current_quantity: number; is_active: boolean; units?: { name: string; short_code: string } | null };
type InvoiceSummary = { invoice_id: string; customer_id: string; invoice_number: string; invoice_date: string; invoice_status: string; grand_total_paise: number; paid_amount_paise: number; pending_amount_paise: number; payment_status: string; customers?: { name: string } | null };
type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };

type Line = { materialId: string; quantity: string; unitPrice: string };
const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });

export default function InvoicesPage({ supabase, organizationId, onBack }: Props) {
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [materials, setMaterials] = useState<Material[]>([]);
  const [invoices, setInvoices] = useState<InvoiceSummary[]>([]);
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState('');
  const [showCreate, setShowCreate] = useState(false);

  async function load() {
    setBusy(true); setError('');
    const [c, m, i] = await Promise.all([
      supabase.from('customers').select('id,name,gstin,billing_state,billing_state_code,is_active').eq('organization_id', organizationId).order('name'),
      supabase.from('materials').select('id,name,hsn_sac_code,gst_rate,selling_price_paise,current_quantity,is_active,units(name,short_code)').eq('organization_id', organizationId).order('name'),
      supabase.from('invoice_payment_summary').select('invoice_id,customer_id,invoice_number,invoice_date,invoice_status,grand_total_paise,paid_amount_paise,pending_amount_paise,payment_status,customers(name)').eq('organization_id', organizationId).order('invoice_date', { ascending: false }),
    ]);
    setBusy(false);
    if (c.error || m.error || i.error) { setError(c.error?.message || m.error?.message || i.error?.message || 'Could not load invoice data.'); return; }
    setCustomers((c.data ?? []) as Customer[]); setMaterials((m.data ?? []) as unknown as Material[]); setInvoices((i.data ?? []) as unknown as InvoiceSummary[]);
  }
  useEffect(() => { void load(); }, [organizationId]);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase(); if (!term) return invoices;
    return invoices.filter((i) => `${i.invoice_number} ${i.customers?.name ?? ''} ${i.payment_status}`.toLowerCase().includes(term));
  }, [invoices, search]);

  async function createInvoice(values: { customerId: string; lines: Line[]; discountEnabled: boolean; discountType: string; discountValue: string; gstEnabled: boolean; placeState: string; placeStateCode: string; notes: string }) {
    const items = values.lines.map((line) => {
      const material = materials.find((m) => m.id === line.materialId);
      if (!material) throw new Error('Select a valid material.');
      const quantity = Number(line.quantity); const price = Math.round(Number(line.unitPrice) * 100);
      if (!Number.isFinite(quantity) || quantity <= 0) throw new Error(`Enter a valid quantity for ${material.name}.`);
      if (quantity > Number(material.current_quantity)) throw new Error(`Insufficient stock for ${material.name}. Available: ${material.current_quantity}.`);
      if (!Number.isFinite(price) || price < 0) throw new Error(`Enter a valid price for ${material.name}.`);
      return { material_id: material.id, quantity, unit_price_paise: price, discount_amount_paise: 0 };
    });
    if (!items.length) throw new Error('Add at least one material.');
    const discountValue = values.discountEnabled ? Number(values.discountValue || 0) : 0;
    if (!Number.isFinite(discountValue) || discountValue < 0) throw new Error('Enter a valid discount.');
    const { error: rpcError } = await supabase.rpc('issue_invoice', {
      p_organization_id: organizationId,
      p_customer_id: values.customerId,
      p_invoice_date: new Date().toISOString().slice(0, 10),
      p_items: items,
      p_discount_enabled: values.discountEnabled,
      p_discount_type: values.discountEnabled ? values.discountType : null,
      p_discount_value: values.discountEnabled ? discountValue : null,
      p_gst_enabled: values.gstEnabled,
      p_place_of_supply_state: values.gstEnabled ? values.placeState.trim() || null : null,
      p_place_of_supply_state_code: values.gstEnabled ? values.placeStateCode.trim() || null : null,
      p_notes: values.notes.trim() || null,
    });
    if (rpcError) throw rpcError;
    setShowCreate(false); await load();
  }

  return <main className="main-content">
    <header className="topbar"><div><button className="back-link" onClick={onBack}>← Overview</button><p className="eyebrow">Sales</p><h1>Invoices</h1></div><button className="primary compact" onClick={() => setShowCreate(true)}>Create invoice</button></header>
    <section className="page-toolbar"><input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search invoice number, customer or payment status…"/><span>{filtered.length} invoice{filtered.length === 1 ? '' : 's'}</span></section>
    {error && <div className="alert error page-alert">{error}</div>}
    <section className="table-card">{busy ? <div className="table-empty">Loading invoices…</div> : filtered.length === 0 ? <div className="table-empty"><strong>No invoices yet</strong><span>Create an invoice to record a sale and deduct stock.</span></div> : <table><thead><tr><th>Invoice</th><th>Customer</th><th>Date</th><th>Total</th><th>Paid</th><th>Pending</th><th>Status</th></tr></thead><tbody>{filtered.map((invoice) => <tr key={invoice.invoice_id}><td><strong>{invoice.invoice_number}</strong></td><td>{invoice.customers?.name || '—'}</td><td>{new Date(invoice.invoice_date).toLocaleDateString('en-IN')}</td><td>{money.format(Number(invoice.grand_total_paise) / 100)}</td><td>{money.format(Number(invoice.paid_amount_paise) / 100)}</td><td>{money.format(Number(invoice.pending_amount_paise) / 100)}</td><td><span className={`pill ${invoice.payment_status === 'paid' ? 'active' : ''}`}>{invoice.payment_status === 'partially_paid' ? 'Partially Paid' : invoice.payment_status.charAt(0).toUpperCase() + invoice.payment_status.slice(1)}</span></td></tr>)}</tbody></table>}</section>
    {showCreate && <InvoiceForm customers={customers.filter((c) => c.is_active)} materials={materials.filter((m) => m.is_active)} onCancel={() => setShowCreate(false)} onSave={createInvoice}/>} 
  </main>;
}

function InvoiceForm({ customers, materials, onCancel, onSave }: { customers: Customer[]; materials: Material[]; onCancel: () => void; onSave: (values: { customerId: string; lines: Line[]; discountEnabled: boolean; discountType: string; discountValue: string; gstEnabled: boolean; placeState: string; placeStateCode: string; notes: string }) => Promise<void> }) {
  const [customerId, setCustomerId] = useState(customers[0]?.id ?? '');
  const [lines, setLines] = useState<Line[]>([{ materialId: '', quantity: '1', unitPrice: '' }]);
  const [discountEnabled, setDiscountEnabled] = useState(false); const [discountType, setDiscountType] = useState('percentage'); const [discountValue, setDiscountValue] = useState('');
  const [gstEnabled, setGstEnabled] = useState(false); const [placeState, setPlaceState] = useState(''); const [placeStateCode, setPlaceStateCode] = useState(''); const [notes, setNotes] = useState('');
  const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  const customer = customers.find((c) => c.id === customerId);

  function chooseMaterial(index: number, materialId: string) { const material = materials.find((m) => m.id === materialId); setLines((x) => x.map((line, i) => i === index ? { ...line, materialId, unitPrice: material ? String(Number(material.selling_price_paise) / 100) : '' } : line)); }
  const subtotal = lines.reduce((sum, line) => { const q = Number(line.quantity) || 0; const p = Number(line.unitPrice) || 0; return sum + q * p; }, 0);
  const discount = discountEnabled ? (discountType === 'percentage' ? subtotal * (Number(discountValue) || 0) / 100 : Math.min(subtotal, Number(discountValue) || 0)) : 0;
  const taxable = Math.max(0, subtotal - discount);
  const gst = gstEnabled ? lines.reduce((sum, line) => { const m = materials.find((x) => x.id === line.materialId); const q = Number(line.quantity) || 0; const p = Number(line.unitPrice) || 0; const base = q * p; const share = subtotal > 0 ? base / subtotal : 0; const taxableLine = taxable * share; return sum + taxableLine * (Number(m?.gst_rate) || 0) / 100; }, 0) : 0;
  const total = taxable + gst;

  async function submit(e: React.FormEvent) { e.preventDefault(); setBusy(true); setError(''); try { await onSave({ customerId, lines, discountEnabled, discountType, discountValue, gstEnabled, placeState, placeStateCode, notes }); } catch (err) { setError(err instanceof Error ? err.message : 'Could not create invoice.'); } finally { setBusy(false); } }
  return <div className="modal-backdrop"><div className="modal invoice-modal"><div className="modal-header"><h2>Create invoice</h2><button onClick={onCancel}>×</button></div><form className="stack" onSubmit={submit}>
    <div className="two-col wide"><label>Customer<select value={customerId} onChange={(e) => setCustomerId(e.target.value)} required><option value="">Select customer</option>{customers.map((c) => <option key={c.id} value={c.id}>{c.name}{c.gstin ? ` • ${c.gstin}` : ''}</option>)}</select></label><div className="form-note customer-balance-note">{customer ? `Billing state: ${customer.billing_state || 'Not set'}${customer.billing_state_code ? ` (${customer.billing_state_code})` : ''}` : 'Select a customer.'}</div></div>
    <div className="invoice-lines"><div className="invoice-line-head"><span>Material</span><span>Quantity</span><span>Unit price (₹)</span><span>Line total</span><span></span></div>{lines.map((line, index) => { const material = materials.find((m) => m.id === line.materialId); const lineTotal = (Number(line.quantity) || 0) * (Number(line.unitPrice) || 0); return <div className="invoice-line" key={index}><select value={line.materialId} onChange={(e) => chooseMaterial(index, e.target.value)} required><option value="">Select material</option>{materials.map((m) => <option key={m.id} value={m.id}>{m.name} — stock {Number(m.current_quantity).toLocaleString('en-IN')}</option>)}</select><input type="number" min="0.001" step="0.001" value={line.quantity} onChange={(e) => setLines((x) => x.map((v, i) => i === index ? { ...v, quantity: e.target.value } : v))} required/><input type="number" min="0" step="0.01" value={line.unitPrice} onChange={(e) => setLines((x) => x.map((v, i) => i === index ? { ...v, unitPrice: e.target.value } : v))} required/><strong>{money.format(lineTotal)}</strong><button type="button" onClick={() => setLines((x) => x.length === 1 ? x : x.filter((_, i) => i !== index))}>×</button></div>})}<button type="button" className="secondary-action" onClick={() => setLines((x) => [...x, { materialId: '', quantity: '1', unitPrice: '' }])}>+ Add material</button></div>
    <div className="invoice-options"><label className="toggle-row"><input type="checkbox" checked={discountEnabled} onChange={(e) => setDiscountEnabled(e.target.checked)}/><span>Enable discount</span></label>{discountEnabled && <div className="two-col"><label>Type<select value={discountType} onChange={(e) => setDiscountType(e.target.value)}><option value="percentage">Percentage</option><option value="fixed">Fixed ₹</option></select></label><label>Discount value<input type="number" min="0" step="0.01" value={discountValue} onChange={(e) => setDiscountValue(e.target.value)}/></label></div>}<label className="toggle-row"><input type="checkbox" checked={gstEnabled} onChange={(e) => setGstEnabled(e.target.checked)}/><span>Enable GST</span></label>{gstEnabled && <div className="two-col"><label>Place of supply — state<input value={placeState} onChange={(e) => setPlaceState(e.target.value)} placeholder={customer?.billing_state || 'Odisha'} required/></label><label>State code<input value={placeStateCode} onChange={(e) => setPlaceStateCode(e.target.value)} maxLength={2} placeholder={customer?.billing_state_code || '21'} required/></label></div>}<label>Notes <span className="muted">optional</span><input value={notes} onChange={(e) => setNotes(e.target.value)}/></label></div>
    <div className="invoice-total"><span>Subtotal <strong>{money.format(subtotal)}</strong></span>{discountEnabled && <span>Discount <strong>− {money.format(discount)}</strong></span>}{gstEnabled && <span>GST <strong>{money.format(gst)}</strong></span>}<span className="grand">Grand total <strong>{money.format(total)}</strong></span></div>
    {error && <div className="alert error">{error}</div>}<div className="modal-actions"><button type="button" onClick={onCancel}>Cancel</button><button className="primary compact" disabled={busy || !customerId || materials.length === 0}>{busy ? 'Creating…' : 'Issue invoice'}</button></div>
  </form></div></div>;
}
