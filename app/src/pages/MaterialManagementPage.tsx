import { useEffect, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import MaterialsPage from './MaterialsPage';
import StockLedgerPage from './StockLedgerPage';

type Vendor = { id: string; name: string; gstin: string | null; phone: string | null; is_active: boolean };
type Material = { id: string; name: string; purchase_price_paise: number; gst_rate: number; units?: { short_code: string } | null };
type Purchase = { id: string; purchase_number: string | null; vendor_invoice_number: string | null; purchase_date: string; total_amount_paise: number; vendors?: { name: string } | null; material_purchase_items?: { description_snapshot: string; quantity: number; unit_cost_paise: number }[] };
const money = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });
const paise = (v: string) => Math.round(Number(v || 0) * 100);

export default function MaterialManagementPage({ supabase, organizationId, section, onBack }: { supabase: SupabaseClient; organizationId: string; section: 'catalogue'|'purchases'|'ledger'; onBack: () => void }) {
  const tab = section;
  const [vendors, setVendors] = useState<Vendor[]>([]);
  const [materials, setMaterials] = useState<Material[]>([]);
  const [purchases, setPurchases] = useState<Purchase[]>([]);
  const [showVendor, setShowVendor] = useState(false);
  const [showPurchase, setShowPurchase] = useState(false);
  const [vendorForm, setVendorForm] = useState({ name:'', gstin:'', phone:'', email:'' });
  const [purchaseForm, setPurchaseForm] = useState({ vendor:'', date:new Date().toISOString().slice(0,10), number:'', invoice:'' });
  const [lines, setLines] = useState([{ material:'', quantity:'', cost:'', gst:'0' }]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const [v,m,p] = await Promise.all([
      supabase.from('vendors').select('id,name,gstin,phone,is_active').eq('organization_id',organizationId).order('name'),
      supabase.from('materials').select('id,name,purchase_price_paise,gst_rate,units(short_code)').eq('organization_id',organizationId).eq('is_active',true).order('name'),
      supabase.from('material_purchases').select('id,purchase_number,vendor_invoice_number,purchase_date,total_amount_paise,vendors(name),material_purchase_items(description_snapshot,quantity,unit_cost_paise)').eq('organization_id',organizationId).order('purchase_date',{ascending:false}).limit(300),
    ]);
    if(v.error||m.error||p.error){setError(v.error?.message||m.error?.message||p.error?.message||'Could not load material management data.');return;}
    setVendors((v.data??[]) as Vendor[]); setMaterials((m.data??[]) as unknown as Material[]); setPurchases((p.data??[]) as unknown as Purchase[]);
  }
  useEffect(()=>{void load()},[organizationId]);
  async function saveVendor(e:React.FormEvent){e.preventDefault();setBusy(true);setError('');const {error:e2}=await supabase.rpc('create_vendor',{p_organization_id:organizationId,p_name:vendorForm.name,p_gstin:vendorForm.gstin||null,p_phone:vendorForm.phone||null,p_email:vendorForm.email||null});if(e2)setError(e2.message);else{setShowVendor(false);setVendorForm({name:'',gstin:'',phone:'',email:''});await load()}setBusy(false)}
  async function savePurchase(e:React.FormEvent){e.preventDefault();setBusy(true);setError('');const items=lines.filter(x=>x.material&&x.quantity&&x.cost).map(x=>({material_id:x.material,quantity:Number(x.quantity),unit_cost_paise:paise(x.cost),gst_rate:Number(x.gst||0)}));if(!items.length){setError('Add at least one material line.');setBusy(false);return;}const {error:e2}=await supabase.rpc('record_material_purchase',{p_organization_id:organizationId,p_vendor_id:purchaseForm.vendor,p_items:items,p_purchase_date:purchaseForm.date,p_purchase_number:purchaseForm.number||null,p_vendor_invoice_number:purchaseForm.invoice||null});if(e2)setError(e2.message);else{setShowPurchase(false);setLines([{material:'',quantity:'',cost:'',gst:'0'}]);await load()}setBusy(false)}
  if(tab==='catalogue') return <MaterialsPage supabase={supabase} organizationId={organizationId} onBack={onBack}/>;
  if(tab==='ledger') return <StockLedgerPage supabase={supabase} organizationId={organizationId} onBack={onBack}/>;
  return <main className="main-content">
    <header className="topbar"><div><button className="back-link" onClick={onBack}>← Overview</button><p className="eyebrow">Material Management</p><h1>Vendor purchases</h1></div><div className="toolbar-actions"><button className="secondary" onClick={()=>setShowVendor(true)}>Add vendor</button><button className="primary compact" onClick={()=>setShowPurchase(true)} disabled={!vendors.length||!materials.length}>Record purchase</button></div></header>
    
    {error&&<div className="alert error page-alert">{error}</div>}
    <section className="metric-grid"><div className="metric"><span>Active vendors</span><strong>{vendors.filter(v=>v.is_active).length}</strong></div><div className="metric"><span>Purchase records</span><strong>{purchases.length}</strong></div><div className="metric"><span>Total purchases shown</span><strong>{money.format(purchases.reduce((s,p)=>s+Number(p.total_amount_paise),0)/100)}</strong></div></section>
    <section className="table-card"><table><thead><tr><th>Purchase date</th><th>Purchase reference</th><th>Vendor</th><th>Vendor invoice</th><th>Materials purchased</th><th>Total</th></tr></thead><tbody>{purchases.map(p=><tr key={p.id}><td>{new Date(p.purchase_date).toLocaleDateString('en-IN')}</td><td>{p.purchase_number||p.id.slice(0,8)}</td><td><strong>{p.vendors?.name||'—'}</strong></td><td>{p.vendor_invoice_number||'—'}</td><td>{(p.material_purchase_items??[]).map(i=>`${i.description_snapshot} · ${i.quantity} × ${money.format(Number(i.unit_cost_paise)/100)}`).join('; ')||'—'}</td><td>{money.format(Number(p.total_amount_paise)/100)}</td></tr>)}{!purchases.length&&<tr><td colSpan={6}>No vendor purchases recorded yet.</td></tr>}</tbody></table></section>
    {showVendor&&<div className="modal-backdrop"><div className="modal"><div className="modal-header"><h2>Add vendor</h2><button onClick={()=>setShowVendor(false)}>×</button></div><form className="stack" onSubmit={saveVendor}><label>Vendor name<input value={vendorForm.name} onChange={e=>setVendorForm({...vendorForm,name:e.target.value})} required/></label><div className="two-col wide"><label>GSTIN<input value={vendorForm.gstin} onChange={e=>setVendorForm({...vendorForm,gstin:e.target.value.toUpperCase()})}/></label><label>Phone<input value={vendorForm.phone} onChange={e=>setVendorForm({...vendorForm,phone:e.target.value})}/></label></div><label>Email<input type="email" value={vendorForm.email} onChange={e=>setVendorForm({...vendorForm,email:e.target.value})}/></label><div className="modal-actions"><button type="button" onClick={()=>setShowVendor(false)}>Cancel</button><button className="primary compact" disabled={busy}>Save vendor</button></div></form></div></div>}
    {showPurchase&&<div className="modal-backdrop"><div className="modal modal-wide"><div className="modal-header"><h2>Record material purchase</h2><button onClick={()=>setShowPurchase(false)}>×</button></div><form className="stack" onSubmit={savePurchase}><label>Vendor<select value={purchaseForm.vendor} onChange={e=>setPurchaseForm({...purchaseForm,vendor:e.target.value})} required><option value="">Select vendor</option>{vendors.filter(v=>v.is_active).map(v=><option key={v.id} value={v.id}>{v.name}</option>)}</select></label><div className="two-col wide"><label>Purchase date<input type="date" value={purchaseForm.date} onChange={e=>setPurchaseForm({...purchaseForm,date:e.target.value})}/></label><label>Internal purchase reference<input value={purchaseForm.number} onChange={e=>setPurchaseForm({...purchaseForm,number:e.target.value})}/></label></div><label>Vendor invoice number<input value={purchaseForm.invoice} onChange={e=>setPurchaseForm({...purchaseForm,invoice:e.target.value})}/></label><h3>Purchased materials</h3>{lines.map((line,i)=><div className="purchase-line" key={i}><label>Material<select value={line.material} onChange={e=>setLines(lines.map((x,j)=>j===i?{...x,material:e.target.value,cost:String((materials.find(m=>m.id===e.target.value)?.purchase_price_paise??0)/100)}:x))}><option value="">Select material</option>{materials.map(m=><option key={m.id} value={m.id}>{m.name}</option>)}</select></label><label>Quantity<input type="number" min="0.001" step="0.001" value={line.quantity} onChange={e=>setLines(lines.map((x,j)=>j===i?{...x,quantity:e.target.value}:x))} required/></label><label>Unit cost (₹)<input type="number" min="0" step="0.01" value={line.cost} onChange={e=>setLines(lines.map((x,j)=>j===i?{...x,cost:e.target.value}:x))} required/></label><label>GST %<input type="number" min="0" max="100" step="0.01" value={line.gst} onChange={e=>setLines(lines.map((x,j)=>j===i?{...x,gst:e.target.value}:x))}/></label><button type="button" className="icon-button" onClick={()=>setLines(lines.filter((_,j)=>j!==i))} disabled={lines.length===1}>Remove</button></div>)}<button type="button" className="secondary" onClick={()=>setLines([...lines,{material:'',quantity:'',cost:'',gst:'0'}])}>Add material line</button>{error&&<div className="alert error">{error}</div>}<div className="modal-actions"><button type="button" onClick={()=>setShowPurchase(false)}>Cancel</button><button className="primary compact" disabled={busy}>{busy?'Saving…':'Save purchase & update stock'}</button></div></form></div></div>}
  </main>;
}
