import { useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import './reports.css';

const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });
const localDate = (d: Date) => d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
const today = () => localDate(new Date());
const monthStart = () => { const d = new Date(); d.setDate(1); return localDate(d); };
const fyStart = () => { const d = new Date(); const y = d.getFullYear(); return (d.getMonth() + 1 >= 4 ? y : y - 1) + '-04-01'; };
const rupees = (v: unknown) => money.format(Number(v || 0) / 100);
const quantity = (v: unknown) => Number(v || 0).toLocaleString('en-IN', { maximumFractionDigits: 3 });

type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };
type Contract = { contract_id: string; client_company_name: string; contract_number: string; title: string; revised_value_paise: number; total_billed_paise: number; total_received_paise: number; pending_receivable_paise: number; unbilled_contract_value_paise: number };
type Bill = { bill_id: string; bill_number: string; bill_date: string; amount_claimed_paise: number; received_paise: number; deducted_paise: number; retention_paise: number; pending_receivable_paise: number; status: string };
type WorkOrder = { work_order_id: string; contractor_name: string; po_number: string; payment_basis: string; agreed_percentage: number | null; agreed_work_amount_paise: number; total_advances_paise: number; settlement_paid_paise: number; settlement_pending_paise: number | null; status: string };
type Purchase = { id: string; purchase_number: string | null; vendor_invoice_number: string | null; purchase_date: string; total_amount_paise: number; payment_status: string; vendors?: { name: string } | null };
type Material = { id: string; name: string; current_quantity: number; purchase_price_paise: number };
type Issue = { id: string; issue_number: string | null; issue_date: string; work_order_id: string; material_issue_items: { description_snapshot: string; quantity_issued: number; contractor_unit_rate_paise: number }[] };
type MaterialReturn = { id: string; return_number: string | null; return_date: string; material_return_items: { quantity_returned: number; condition: string }[] };
type Settlement = { id: string; work_order_id: string; settlement_number: string; settlement_date: string; recovery_due_paise: number; status: string };

export default function ReportsPage({ supabase, organizationId, onBack }: Props) {
  const [from, setFrom] = useState(monthStart());
  const [to, setTo] = useState(today());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [bills, setBills] = useState<Bill[]>([]);
  const [workOrders, setWorkOrders] = useState<WorkOrder[]>([]);
  const [purchases, setPurchases] = useState<Purchase[]>([]);
  const [materials, setMaterials] = useState<Material[]>([]);
  const [issues, setIssues] = useState<Issue[]>([]);
  const [returns, setReturns] = useState<MaterialReturn[]>([]);
  const [settlements, setSettlements] = useState<Settlement[]>([]);

  async function load() {
    setLoading(true); setError('');
    const results = await Promise.all([
      supabase.from('contract_finance_summary').select('contract_id,client_company_name,contract_number,title,revised_value_paise,total_billed_paise,total_received_paise,pending_receivable_paise,unbilled_contract_value_paise').eq('organization_id', organizationId).order('contract_number'),
      supabase.from('client_bill_finance_summary').select('bill_id,bill_number,bill_date,amount_claimed_paise,received_paise,deducted_paise,retention_paise,pending_receivable_paise,status').eq('organization_id', organizationId).gte('bill_date', from).lte('bill_date', to).order('bill_date', { ascending: false }),
      supabase.from('contractor_work_order_summary').select('work_order_id,contractor_name,po_number,payment_basis,agreed_percentage,agreed_work_amount_paise,total_advances_paise,settlement_paid_paise,settlement_pending_paise,status').eq('organization_id', organizationId).order('po_number'),
      supabase.from('material_purchases').select('id,purchase_number,vendor_invoice_number,purchase_date,total_amount_paise,payment_status,vendors(name)').eq('organization_id', organizationId).gte('purchase_date', from).lte('purchase_date', to).order('purchase_date', { ascending: false }),
      supabase.from('materials').select('id,name,current_quantity,purchase_price_paise').eq('organization_id', organizationId).eq('is_active', true).order('name'),
      supabase.from('material_issues').select('id,issue_number,issue_date,work_order_id,material_issue_items(description_snapshot,quantity_issued,contractor_unit_rate_paise)').eq('organization_id', organizationId).gte('issue_date', from).lte('issue_date', to).neq('status','cancelled').order('issue_date',{ascending:false}),
      supabase.from('material_returns').select('id,return_number,return_date,material_return_items(quantity_returned,condition)').eq('organization_id', organizationId).gte('return_date', from).lte('return_date', to).order('return_date',{ascending:false}),
      supabase.from('contractor_settlements').select('id,work_order_id,settlement_number,settlement_date,recovery_due_paise,status').eq('organization_id', organizationId).neq('status','cancelled').order('settlement_date',{ascending:false})
    ]);
    const failure = results.find(r => r.error);
    if (failure?.error) { setError(failure.error.message); setLoading(false); return; }
    setContracts((results[0].data || []) as Contract[]);
    setBills((results[1].data || []) as Bill[]);
    setWorkOrders((results[2].data || []) as WorkOrder[]);
    setPurchases((results[3].data || []) as unknown as Purchase[]);
    setMaterials((results[4].data || []) as Material[]);
    setIssues((results[5].data || []) as unknown as Issue[]);
    setReturns((results[6].data || []) as unknown as MaterialReturn[]);
    setSettlements((results[7].data || []) as Settlement[]);
    setLoading(false);
  }
  useEffect(() => { void load(); }, [organizationId, from, to]);

  const contractTotals = useMemo(() => contracts.reduce((a, c) => ({
    value: a.value + Number(c.revised_value_paise), billed: a.billed + Number(c.total_billed_paise),
    received: a.received + Number(c.total_received_paise), pending: a.pending + Number(c.pending_receivable_paise),
    unbilled: a.unbilled + Number(c.unbilled_contract_value_paise)
  }), { value: 0, billed: 0, received: 0, pending: 0, unbilled: 0 }), [contracts]);
  const billTotals = bills.reduce((a, b) => ({
    claimed: a.claimed + Number(b.amount_claimed_paise), received: a.received + Number(b.received_paise),
    deductions: a.deductions + Number(b.deducted_paise), retention: a.retention + Number(b.retention_paise),
    pending: a.pending + Number(b.pending_receivable_paise)
  }), { claimed: 0, received: 0, deductions: 0, retention: 0, pending: 0 });
  const workTotals = workOrders.reduce((a, w) => ({
    agreed: a.agreed + Number(w.agreed_work_amount_paise), advances: a.advances + Number(w.total_advances_paise),
    paid: a.paid + Number(w.settlement_paid_paise), pending: a.pending + Number(w.settlement_pending_paise || 0)
  }), { agreed: 0, advances: 0, paid: 0, pending: 0 });
  const purchaseTotal = purchases.reduce((s, p) => s + Number(p.total_amount_paise), 0);
  const recoveryDue = settlements.reduce((s, item) => s + Number(item.recovery_due_paise), 0);
  const stockValue = materials.reduce((s, m) => s + Number(m.current_quantity) * Number(m.purchase_price_paise || 0), 0);
  const issueQuantity = issues.reduce((s, issue) => s + issue.material_issue_items.reduce((n, line) => n + Number(line.quantity_issued), 0), 0);
  const issueValue = issues.reduce((s, issue) => s + issue.material_issue_items.reduce((n, line) => n + Number(line.quantity_issued) * Number(line.contractor_unit_rate_paise), 0), 0);
  const returnedQuantity = returns.reduce((s, item) => s + item.material_return_items.reduce((n, line) => n + Number(line.quantity_returned), 0), 0);

  return <main className="main-content reports-page">
    <button className="back-link" onClick={onBack}>← Back to dashboard</button>
    <header className="topbar"><div><p className="eyebrow">Reports & analytics</p><h1>Construction business reports</h1><p className="page-subtitle">Contract finance, client receivables, procurement, contractor advances and settlements.</p></div></header>
    <section className="report-toolbar">
      <div><span>From</span><input type="date" value={from} max={to} onChange={e => setFrom(e.target.value)} /></div>
      <div><span>To</span><input type="date" value={to} min={from} max={today()} onChange={e => setTo(e.target.value)} /></div>
      <div className="report-presets"><button onClick={() => { setFrom(today()); setTo(today()); }}>Today</button><button onClick={() => { setFrom(monthStart()); setTo(today()); }}>This month</button><button onClick={() => { setFrom(fyStart()); setTo(today()); }}>Current FY</button><button onClick={() => { setFrom('2000-01-01'); setTo(today()); }}>All history</button></div>
      <span className="report-status">{loading ? 'Refreshing…' : 'Live database figures'}</span>
    </section>
    {error && <div className="alert error page-alert">{error}</div>}
    <section className="report-metrics">
      <div className="metric"><span>Revised contract value</span><strong>{rupees(contractTotals.value)}</strong><small>{contracts.length} contracts · all history</small></div>
      <div className="metric"><span>Client receivables</span><strong>{rupees(contractTotals.pending)}</strong><small>Across all contracts</small></div>
      <div className="metric"><span>Vendor purchases</span><strong>{rupees(purchaseTotal)}</strong><small>{purchases.length} purchases in period</small></div>
      <div className="metric"><span>Settlement pending</span><strong>{rupees(workTotals.pending)}</strong><small>{workOrders.length} work orders</small></div>
      <div className="metric"><span>Stock at purchase value</span><strong>{rupees(stockValue)}</strong><small>{materials.length} active materials</small></div>
      <div className="metric"><span>Contractor recovery due</span><strong>{rupees(recoveryDue)}</strong><small>{settlements.filter(s => Number(s.recovery_due_paise) > 0).length} settlements with recovery</small></div>
    </section>
    <section className="reports-grid">
      <div className="report-card"><div className="section-head"><div><p className="eyebrow">Project finance · all history</p><h3>Contract portfolio</h3></div></div><div className="report-lines">
        <span><b>Revised contract value</b><strong>{rupees(contractTotals.value)}</strong></span><span><b>Billed</b><strong>{rupees(contractTotals.billed)}</strong></span><span><b>Receipts</b><strong>{rupees(contractTotals.received)}</strong></span><span><b>Pending receivables</b><strong>{rupees(contractTotals.pending)}</strong></span><span className="report-grand"><b>Unbilled contract value</b><strong>{rupees(contractTotals.unbilled)}</strong></span>
      </div></div>
      <div className="report-card"><div className="section-head"><div><p className="eyebrow">Client billing · selected period</p><h3>Bill & receipt summary</h3></div></div><div className="report-lines">
        <span><b>Amount claimed</b><strong>{rupees(billTotals.claimed)}</strong></span><span><b>Receipts</b><strong>{rupees(billTotals.received)}</strong></span><span><b>Non-retention deductions</b><strong>{rupees(billTotals.deductions - billTotals.retention)}</strong></span><span><b>Retention held</b><strong>{rupees(billTotals.retention)}</strong></span><span className="report-grand"><b>Bill balance</b><strong>{rupees(billTotals.pending)}</strong></span>
      </div></div>
      <div className="report-card"><div className="section-head"><div><p className="eyebrow">Procurement · selected period</p><h3>Vendor purchases</h3></div></div><div className="report-lines">
        <span><b>Purchase value</b><strong>{rupees(purchaseTotal)}</strong></span><span><b>Purchase records</b><strong>{purchases.length}</strong></span><span><b>Unpaid records</b><strong>{purchases.filter(p => p.payment_status === 'unpaid').length}</strong></span><span><b>Partially paid</b><strong>{purchases.filter(p => p.payment_status === 'partially_paid').length}</strong></span><span className="report-grand"><b>Material issue charge value</b><strong>{rupees(issueValue)}</strong></span>
      </div></div>
      <div className="report-card"><div className="section-head"><div><p className="eyebrow">Contractor finance · all history</p><h3>Work order & settlement</h3></div></div><div className="report-lines">
        <span><b>Agreed work value</b><strong>{rupees(workTotals.agreed)}</strong></span><span><b>Advances issued</b><strong>{rupees(workTotals.advances)}</strong></span><span><b>Settlement payments</b><strong>{rupees(workTotals.paid)}</strong></span><span><b>Recovery due</b><strong>{rupees(recoveryDue)}</strong></span><span><b>Material quantity issued</b><strong>{quantity(issueQuantity)}</strong></span><span><b>Material quantity returned</b><strong>{quantity(returnedQuantity)}</strong></span><span className="report-grand"><b>Settlement balance</b><strong>{rupees(workTotals.pending)}</strong></span>
      </div></div>
    </section>
    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Project finance</p><h3>Contract performance</h3></div><span>Portfolio totals are all-time</span></div><table><thead><tr><th>Contract / client</th><th>Revised value</th><th>Billed</th><th>Received</th><th>Pending</th><th>Unbilled</th></tr></thead><tbody>{contracts.length === 0 ? <tr><td colSpan={6}><div className="table-empty">No contracts found.</div></td></tr> : contracts.map(c => <tr key={c.contract_id}><td><strong>{c.contract_number}</strong><small className="report-subline">{c.title} · {c.client_company_name}</small></td><td>{rupees(c.revised_value_paise)}</td><td>{rupees(c.total_billed_paise)}</td><td>{rupees(c.total_received_paise)}</td><td><strong>{rupees(c.pending_receivable_paise)}</strong></td><td>{rupees(c.unbilled_contract_value_paise)}</td></tr>)}</tbody></table></section>
    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Client receivables</p><h3>Bill register</h3></div><span>{bills.length} bills in selected period</span></div><table><thead><tr><th>Bill</th><th>Date</th><th>Claimed</th><th>Received</th><th>Deductions</th><th>Retention</th><th>Pending</th><th>Status</th></tr></thead><tbody>{bills.length === 0 ? <tr><td colSpan={8}><div className="table-empty">No client bills in this period.</div></td></tr> : bills.map(b => <tr key={b.bill_id}><td><strong>{b.bill_number}</strong></td><td>{new Date(b.bill_date).toLocaleDateString('en-IN')}</td><td>{rupees(b.amount_claimed_paise)}</td><td>{rupees(b.received_paise)}</td><td>{rupees(b.deducted_paise)}</td><td>{rupees(b.retention_paise)}</td><td><strong>{rupees(b.pending_receivable_paise)}</strong></td><td><span className="pill">{b.status}</span></td></tr>)}</tbody></table></section>
    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Procurement</p><h3>Purchase register</h3></div><span>{purchases.length} purchases in selected period</span></div><table><thead><tr><th>Purchase</th><th>Vendor invoice</th><th>Vendor</th><th>Date</th><th>Amount</th><th>Payment status</th></tr></thead><tbody>{purchases.length === 0 ? <tr><td colSpan={6}><div className="table-empty">No purchases in this period.</div></td></tr> : purchases.map(p => <tr key={p.id}><td><strong>{p.purchase_number || '—'}</strong></td><td>{p.vendor_invoice_number || '—'}</td><td>{p.vendors?.name || '—'}</td><td>{new Date(p.purchase_date).toLocaleDateString('en-IN')}</td><td>{rupees(p.total_amount_paise)}</td><td>{p.payment_status}</td></tr>)}</tbody></table></section>
    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Contractor management</p><h3>Work order settlement register</h3></div><span>{workOrders.length} work orders</span></div><table><thead><tr><th>PO number</th><th>Contractor</th><th>Basis</th><th>Agreed work</th><th>Advances</th><th>Paid</th><th>Pending</th><th>Status</th></tr></thead><tbody>{workOrders.length === 0 ? <tr><td colSpan={8}><div className="table-empty">No work orders found.</div></td></tr> : workOrders.map(w => <tr key={w.work_order_id}><td><strong>{w.po_number}</strong></td><td>{w.contractor_name}</td><td>{w.payment_basis === 'percentage' ? String(w.agreed_percentage) + '%' : 'Fixed'}</td><td>{rupees(w.agreed_work_amount_paise)}</td><td>{rupees(w.total_advances_paise)}</td><td>{rupees(w.settlement_paid_paise)}</td><td>{rupees(w.settlement_pending_paise)}</td><td>{w.status}</td></tr>)}</tbody></table></section>
    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Materials</p><h3>Current material stock</h3></div><span>{materials.length} active materials · purchase-cost estimate</span></div><table><thead><tr><th>Material</th><th>Current quantity</th><th>Last purchase cost / unit</th><th>Stock value</th></tr></thead><tbody>{materials.length === 0 ? <tr><td colSpan={4}><div className="table-empty">No active materials found.</div></td></tr> : materials.map(m => <tr key={m.id}><td><strong>{m.name}</strong></td><td>{quantity(m.current_quantity)}</td><td>{rupees(m.purchase_price_paise)}</td><td>{rupees(Number(m.current_quantity) * Number(m.purchase_price_paise || 0))}</td></tr>)}</tbody></table></section>
    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Contractor material control</p><h3>Material issue register</h3></div><span>{issues.length} issues in selected period</span></div><table><thead><tr><th>Issue</th><th>Date</th><th>PO / work order</th><th>Item lines</th><th>Quantity issued</th><th>Contractor-rate value</th></tr></thead><tbody>{issues.length === 0 ? <tr><td colSpan={6}><div className="table-empty">No material issues in this period.</div></td></tr> : issues.map(issue => <tr key={issue.id}><td><strong>{issue.issue_number || issue.id.slice(0,8)}</strong></td><td>{new Date(issue.issue_date).toLocaleDateString('en-IN')}</td><td>{workOrders.find(w => w.work_order_id === issue.work_order_id)?.po_number || '—'}</td><td>{issue.material_issue_items.length}</td><td>{quantity(issue.material_issue_items.reduce((n,line)=>n+Number(line.quantity_issued),0))}</td><td>{rupees(issue.material_issue_items.reduce((n,line)=>n+Number(line.quantity_issued)*Number(line.contractor_unit_rate_paise),0))}</td></tr>)}</tbody></table></section>
    <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Contractor material control</p><h3>Material return register</h3></div><span>{returns.length} returns in selected period</span></div><table><thead><tr><th>Return</th><th>Date</th><th>Item lines</th><th>Quantity returned</th><th>Usable</th><th>Damaged / scrap</th></tr></thead><tbody>{returns.length === 0 ? <tr><td colSpan={6}><div className="table-empty">No material returns in this period.</div></td></tr> : returns.map(item => <tr key={item.id}><td><strong>{item.return_number || item.id.slice(0,8)}</strong></td><td>{new Date(item.return_date).toLocaleDateString('en-IN')}</td><td>{item.material_return_items.length}</td><td>{quantity(item.material_return_items.reduce((n,line)=>n+Number(line.quantity_returned),0))}</td><td>{quantity(item.material_return_items.filter(line=>line.condition==='usable').reduce((n,line)=>n+Number(line.quantity_returned),0))}</td><td>{quantity(item.material_return_items.filter(line=>line.condition!=='usable').reduce((n,line)=>n+Number(line.quantity_returned),0))}</td></tr>)}</tbody></table></section>
  </main>;
}
