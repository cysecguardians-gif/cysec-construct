import { useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };
type ContractFinance = { contract_id:string; client_company_name:string; contract_number:string; title:string; original_value_paise:number; revised_value_paise:number; total_billed_paise:number; total_received_paise:number; total_deductions_paise:number; retention_paise:number; pending_receivable_paise:number; unbilled_contract_value_paise:number };
type Bill = { bill_id:string; contract_id:string; bill_number:string; bill_date:string; amount_claimed_paise:number; received_paise:number; deducted_paise:number; retention_paise:number; pending_receivable_paise:number; status:string };
type Purchase = { id:string; purchase_number:string|null; purchase_date:string; total_amount_paise:number; vendors?:{name:string}|null };
type Advance = { id:string; advance_date:string; amount_paise:number; contractors?:{name:string}|null; contractor_work_orders?:{po_number:string}|null };
type WorkOrder = { work_order_id:string; contractor_name:string; po_number:string; agreed_work_amount_paise:number; total_advances_paise:number; settlement_final_payable_paise:number; settlement_paid_paise:number; settlement_pending_paise:number|null; status:string };
type Material = { id:string; name:string; current_quantity:number; purchase_price_paise:number; units?:{short_code:string}|null };
type Settlement = { id:string; settlement_number:string; settlement_date:string; final_payable_paise:number; recovery_due_paise:number; status:string };

const money = new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR',maximumFractionDigits:2});
const today = () => new Date().toISOString().slice(0,10);
const monthStart = () => { const d=new Date(); d.setDate(1); return d.toISOString().slice(0,10); };
const fyStart = () => { const d=new Date(); const y=d.getFullYear(); return `${d.getMonth()+1>=4?y:y-1}-04-01`; };
const inr = (v:number) => money.format(Number(v||0)/100);

export default function ReportsPage({supabase,organizationId,onBack}:Props){
 const [from,setFrom]=useState(monthStart()),[to,setTo]=useState(today()),[loading,setLoading]=useState(false),[error,setError]=useState('');
 const [contracts,setContracts]=useState<ContractFinance[]>([]),[bills,setBills]=useState<Bill[]>([]),[purchases,setPurchases]=useState<Purchase[]>([]),[advances,setAdvances]=useState<Advance[]>([]),[workOrders,setWorkOrders]=useState<WorkOrder[]>([]),[materials,setMaterials]=useState<Material[]>([]),[settlements,setSettlements]=useState<Settlement[]>([]);
 async function load(){
  setLoading(true);setError('');
  const [c,b,p,a,w,m,s]=await Promise.all([
   supabase.from('contract_finance_summary').select('*').eq('organization_id',organizationId).order('contract_number'),
   supabase.from('client_bill_finance_summary').select('*').eq('organization_id',organizationId).gte('bill_date',from).lte('bill_date',to).order('bill_date',{ascending:false}),
   supabase.from('material_purchases').select('id,purchase_number,purchase_date,total_amount_paise,vendors(name)').eq('organization_id',organizationId).gte('purchase_date',from).lte('purchase_date',to).order('purchase_date',{ascending:false}),
   supabase.from('contractor_advances').select('id,advance_date,amount_paise,contractors(name),contractor_work_orders(po_number)').eq('organization_id',organizationId).gte('advance_date',from).lte('advance_date',to).order('advance_date',{ascending:false}),
   supabase.from('contractor_work_order_summary').select('*').eq('organization_id',organizationId).order('po_number'),
   supabase.from('materials').select('id,name,current_quantity,purchase_price_paise,units(short_code)').eq('organization_id',organizationId).eq('is_active',true).order('name'),
   supabase.from('contractor_settlements').select('id,settlement_number,settlement_date,final_payable_paise,recovery_due_paise,status').eq('organization_id',organizationId).gte('settlement_date',from).lte('settlement_date',to).order('settlement_date',{ascending:false})
  ]);
  const failure=c.error||b.error||p.error||a.error||w.error||m.error||s.error;
  if(failure){setError(failure.message);setLoading(false);return;}
  setContracts((c.data??[]) as ContractFinance[]);setBills((b.data??[]) as Bill[]);setPurchases((p.data??[]) as unknown as Purchase[]);setAdvances((a.data??[]) as unknown as Advance[]);setWorkOrders((w.data??[]) as WorkOrder[]);setMaterials((m.data??[]) as unknown as Material[]);setSettlements((s.data??[]) as Settlement[]);setLoading(false);
 }
 useEffect(()=>{void load();},[supabase,organizationId,from,to]);
 const totals=useMemo(()=>({
  contractValue:contracts.reduce((n,x)=>n+Number(x.revised_value_paise),0),
  received:contracts.reduce((n,x)=>n+Number(x.total_received_paise),0),
  receivable:contracts.reduce((n,x)=>n+Number(x.pending_receivable_paise),0),
  billed:bills.reduce((n,x)=>n+Number(x.amount_claimed_paise),0),
  billPending:bills.reduce((n,x)=>n+Number(x.pending_receivable_paise),0),
  purchase:purchases.reduce((n,x)=>n+Number(x.total_amount_paise),0),
  advances:advances.reduce((n,x)=>n+Number(x.amount_paise),0),
  stock:materials.reduce((n,x)=>n+Number(x.current_quantity)*Number(x.purchase_price_paise),0),
  settlementPayable:settlements.reduce((n,x)=>n+Number(x.final_payable_paise),0),
  recovery:settlements.reduce((n,x)=>n+Number(x.recovery_due_paise),0)
 }),[contracts,bills,purchases,advances,materials,settlements]);
 const activeOrders=workOrders.filter(x=>['active','on_hold','settlement_pending'].includes(x.status));
 return <main className="main-content reports-page">
  <button className="back-link" onClick={onBack}>← Overview</button>
  <header className="topbar"><div><p className="eyebrow">Management reporting</p><h1>Construction reports</h1><p className="page-subtitle">Project finance, procurement, inventory and contractor performance.</p></div></header>
  <section className="report-toolbar"><div><span>From</span><input type="date" value={from} max={to} onChange={e=>setFrom(e.target.value)}/></div><div><span>To</span><input type="date" value={to} min={from} max={today()} onChange={e=>setTo(e.target.value)}/></div><div className="report-presets"><button onClick={()=>{setFrom(today());setTo(today());}}>Today</button><button onClick={()=>{setFrom(monthStart());setTo(today());}}>This month</button><button onClick={()=>{setFrom(fyStart());setTo(today());}}>Current FY</button></div><span className="report-status">{loading?'Refreshing…':`Updated for ${from} to ${to}`}</span></section>
  {error&&<div className="alert error page-alert">{error}</div>}
  <p className="eyebrow">Contract portfolio · all active and historical contracts</p>
  <section className="report-metrics"><div className="metric"><span>Revised contract value</span><strong>{inr(totals.contractValue)}</strong><small>{contracts.length} contracts</small></div><div className="metric"><span>Client receipts</span><strong>{inr(totals.received)}</strong><small>All recorded receipts</small></div><div className="metric"><span>Pending receivables</span><strong>{inr(totals.receivable)}</strong><small>Across contracts</small></div><div className="metric"><span>Stock at purchase cost</span><strong>{inr(totals.stock)}</strong><small>{materials.length} active materials</small></div></section>
  <section className="reports-grid">
   <div className="report-card"><div className="section-head"><div><p className="eyebrow">Client billing · selected period</p><h3>Client bills & receivables</h3></div></div><div className="report-lines"><span><b>Claims raised</b><strong>{inr(totals.billed)}</strong></span><span><b>Pending on period bills</b><strong>{inr(totals.billPending)}</strong></span><span><b>Bill records</b><strong>{bills.length}</strong></span><span><b>Retention held</b><strong>{inr(bills.reduce((n,x)=>n+Number(x.retention_paise),0))}</strong></span></div></div>
   <div className="report-card"><div className="section-head"><div><p className="eyebrow">Procurement · selected period</p><h3>Vendor purchases</h3></div></div><div className="report-lines"><span><b>Purchase value</b><strong>{inr(totals.purchase)}</strong></span><span><b>Purchase records</b><strong>{purchases.length}</strong></span><span><b>Contractor advances</b><strong>{inr(totals.advances)}</strong></span><span><b>Advance transactions</b><strong>{advances.length}</strong></span></div></div>
   <div className="report-card"><div className="section-head"><div><p className="eyebrow">Contractor performance</p><h3>Work orders & settlements</h3></div></div><div className="report-lines"><span><b>Active / on-hold work orders</b><strong>{activeOrders.length}</strong></span><span><b>Settlement payable</b><strong>{inr(totals.settlementPayable)}</strong></span><span><b>Recovery due</b><strong>{inr(totals.recovery)}</strong></span><span><b>Settlements in period</b><strong>{settlements.length}</strong></span></div></div>
  </section>
  <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Project management</p><h3>Contract finance by client</h3></div><span>{contracts.length} contracts · all time</span></div><table><thead><tr><th>Contract</th><th>Client</th><th>Revised value</th><th>Billed</th><th>Received</th><th>Retention</th><th>Pending</th><th>Unbilled</th></tr></thead><tbody>{contracts.length===0?<tr><td colSpan={8}><div className="table-empty">No contract finance records yet.</div></td></tr>:contracts.map(x=><tr key={x.contract_id}><td><strong>{x.contract_number}</strong><small>{x.title}</small></td><td>{x.client_company_name}</td><td>{inr(x.revised_value_paise)}</td><td>{inr(x.total_billed_paise)}</td><td>{inr(x.total_received_paise)}</td><td>{inr(x.retention_paise)}</td><td><strong>{inr(x.pending_receivable_paise)}</strong></td><td>{inr(x.unbilled_contract_value_paise)}</td></tr>)}</tbody></table></section>
  <section className="reports-grid">
   <div className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Contractor control</p><h3>Work order position</h3></div></div><table><thead><tr><th>PO / Contractor</th><th>Agreed amount</th><th>Advances</th><th>Settlement pending</th><th>Status</th></tr></thead><tbody>{workOrders.length===0?<tr><td colSpan={5}>No work orders recorded.</td></tr>:workOrders.slice(0,30).map(x=><tr key={x.work_order_id}><td><strong>{x.po_number}</strong><small>{x.contractor_name}</small></td><td>{inr(x.agreed_work_amount_paise)}</td><td>{inr(x.total_advances_paise)}</td><td>{x.settlement_pending_paise==null?'—':inr(x.settlement_pending_paise)}</td><td>{x.status}</td></tr>)}</tbody></table></div>
   <div className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Inventory</p><h3>Material stock valuation</h3></div></div><table><thead><tr><th>Material</th><th>Available</th><th>Unit</th><th>Purchase cost value</th></tr></thead><tbody>{materials.length===0?<tr><td colSpan={4}>No active materials.</td></tr>:materials.slice(0,30).map(x=><tr key={x.id}><td><strong>{x.name}</strong></td><td>{Number(x.current_quantity).toLocaleString('en-IN',{maximumFractionDigits:3})}</td><td>{x.units?.short_code||'—'}</td><td>{inr(Number(x.current_quantity)*Number(x.purchase_price_paise))}</td></tr>)}</tbody></table></div>
  </section>
  <section className="table-card report-table-card"><div className="report-table-head"><div><p className="eyebrow">Period activity</p><h3>Vendor purchases & contractor advances</h3></div><span>{purchases.length+advances.length} transactions</span></div><table><thead><tr><th>Date</th><th>Type</th><th>Reference / party</th><th>Amount</th></tr></thead><tbody>{[...purchases.map(x=>({id:x.id,date:x.purchase_date,type:'Vendor purchase',reference:x.purchase_number||x.vendors?.name||'Purchase',amount:Number(x.total_amount_paise)})),...advances.map(x=>({id:x.id,date:x.advance_date,type:'Contractor advance',reference:x.contractor_work_orders?.po_number||x.contractors?.name||'Advance',amount:Number(x.amount_paise)}))].sort((x,y)=>y.date.localeCompare(x.date)).slice(0,50).map(x=><tr key={x.id}><td>{new Date(x.date).toLocaleDateString('en-IN')}</td><td>{x.type}</td><td>{x.reference}</td><td>{inr(x.amount)}</td></tr>)}</tbody></table></section>
 </main>;
}
