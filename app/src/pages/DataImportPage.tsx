import { useEffect, useMemo, useRef, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { readSpreadsheet, type SpreadsheetRow } from '../lib/spreadsheet';

type ImportType = 'customers'|'materials'|'stock'|'invoices'|'payments'|'client_companies'|'contracts'|'projects'|'vendors'|'contractors'|'work_orders'|'advances'|'client_bills'|'client_receipts'|'client_deductions'|'material_purchases'|'material_issues'|'material_returns';
type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };
type FieldMap = Record<string, string[]>;
const labels: Record<ImportType,string> = {
  customers:'Legacy customers',materials:'Material catalogue',stock:'Legacy stock ledger',invoices:'Historical sales invoices',payments:'Historical sales payments',
  client_companies:'Client companies',contracts:'Client contracts',projects:'Projects / sites',vendors:'Vendors',contractors:'Contractors',
  work_orders:'Contractor work orders',advances:'Contractor advances',client_bills:'Client bills / claims',client_receipts:'Client receipts',client_deductions:'Client deductions',material_purchases:'Material purchases',material_issues:'Contractor material issues',material_returns:'Contractor material returns'
};
const aliases: Record<ImportType,FieldMap> = {
  customers:{name:['customer','customer name','name','client'],gstin:['gstin','gst no','gst number'],pan:['pan'],phone:['phone','mobile','mobile number','contact'],email:['email','email address'],billing_address_line1:['address','billing address','address line 1'],billing_city:['city','billing city'],billing_state:['state','billing state'],billing_state_code:['state code','billing state code'],billing_postal_code:['pin','pincode','postal code','zip'],shipping_address_line1:['shipping address','shipping address line 1'],shipping_city:['shipping city'],shipping_state:['shipping state'],shipping_state_code:['shipping state code'],shipping_postal_code:['shipping pin','shipping pincode','shipping postal code']},
  materials:{name:['material','material name','name','item'],unit:['unit','uom','unit name'],category:['category','material category'],hsn_sac_code:['hsn','hsn/sac','hsn sac','sac'],gst_rate:['gst','gst %','gst rate','tax'],selling_price:['price','selling price','rate','unit price'],quantity:['quantity','qty','opening stock','stock']},
  stock:{material:['material','material name','item'],movement_type:['type','movement type','transaction type'],quantity:['quantity','qty'],movement_date:['date','movement date','transaction date'],notes:['notes','remarks','description']},
  invoices:{invoice_number:['invoice number','invoice no','invoice #','bill no','bill number'],invoice_date:['invoice date','date'],customer:['customer','customer name','client'],material:['material','material name','item'],quantity:['quantity','qty'],unit_price:['unit price','price','rate'],gst_rate:['gst','gst %','gst rate','tax']},
  payments:{invoice_number:['invoice number','invoice no','invoice #','bill no'],amount:['amount','payment','paid amount'],payment_date:['payment date','date'],payment_method:['payment method','method','mode'],reference_number:['reference','reference number','transaction id','utr'],notes:['notes','remarks']},
  client_companies:{name:['client company','company name','name','client'],gstin:['gstin','gst no'],pan:['pan'],contact_person:['contact person','contact'],phone:['phone','mobile'],email:['email'],billing_address:['billing address','address'],city:['city'],state:['state'],state_code:['state code'],postal_code:['postal code','pincode','pin']},
  contracts:{contract_number:['contract number','contract no','tender number','agreement number'],client_company:['client company','company name','client'],title:['title','contract title','work name'],contract_type:['contract type','type'],contract_date:['contract date','date'],original_value:['original value','contract value','value'],revised_value:['revised value','revised contract value'],start_date:['start date'],expected_end_date:['expected end date','end date'],scope_of_work:['scope','scope of work'],notes:['notes','remarks']},
  projects:{contract_number:['contract number','contract no'],project_code:['project code','site code','code'],name:['project name','site name','name'],site_address:['site address','address'],site_contact:['site contact','contact person'],site_phone:['site phone','phone'],start_date:['start date'],expected_end_date:['expected end date','end date'],notes:['notes','remarks']},
  vendors:{name:['vendor','vendor name','name','supplier'],gstin:['gstin','gst no'],pan:['pan'],contact_person:['contact person','contact'],phone:['phone','mobile'],email:['email'],address:['address'],city:['city'],state:['state'],state_code:['state code'],postal_code:['postal code','pincode','pin']},
  contractors:{name:['contractor','contractor name','name','subcontractor'],contractor_type:['contractor type','type'],gstin:['gstin','gst no'],pan:['pan'],contact_person:['contact person','contact'],phone:['phone','mobile'],email:['email'],address:['address'],city:['city'],state:['state'],state_code:['state code'],postal_code:['postal code','pincode','pin'],notes:['notes','remarks']},
  work_orders:{po_number:['po number','work order number','work order no'],project_code:['project code','site code'],project_name:['project name','site name'],contractor:['contractor','contractor name'],payment_basis:['payment basis','basis'],fixed_amount:['fixed amount','work amount','amount'],agreed_percentage:['agreed percentage','percentage','po percentage'],po_date:['po date','date'],materials_chargeable:['materials chargeable','material chargeable'],start_date:['start date'],expected_end_date:['expected end date','end date'],scope_of_work:['scope','scope of work'],terms_and_conditions:['terms','terms and conditions'],notes:['notes','remarks']},
  advances:{po_number:['po number','work order number','work order no'],amount:['amount','advance amount'],advance_date:['advance date','date'],payment_method:['payment method','method','mode'],reference_number:['reference','reference number','utr','transaction id'],notes:['notes','remarks']},
  client_bills:{contract_number:['contract number','contract no'],bill_number:['bill number','bill no','ra bill number','claim number'],bill_date:['bill date','date'],period_from:['period from','from date'],period_to:['period to','to date'],amount_claimed:['amount claimed','claimed amount','bill amount','amount'],status:['status'],notes:['notes','remarks']},
  client_receipts:{contract_number:['contract number','contract no'],bill_number:['bill number','bill no','ra bill number'],amount:['amount','receipt amount','received amount'],receipt_date:['receipt date','date'],payment_method:['payment method','method','mode'],reference_number:['reference','reference number','utr','transaction id'],notes:['notes','remarks']},
  client_deductions:{contract_number:['contract number','contract no'],bill_number:['bill number','bill no','ra bill number'],deduction_type:['deduction type','type'],amount:['amount','deduction amount'],deduction_date:['deduction date','date'],is_recoverable:['recoverable','is recoverable'],reference_number:['reference','reference number'],notes:['notes','remarks']},
  material_purchases:{purchase_number:['purchase number','purchase no','internal purchase number'],vendor_name:['vendor','vendor name','supplier'],vendor_invoice_number:['vendor invoice number','invoice number','invoice no'],purchase_date:['purchase date','date'],material:['material','material name','item'],quantity:['quantity','qty'],unit_cost:['unit cost','purchase rate','rate','cost'],gst_rate:['gst rate','gst %','gst'],other_charges:['other charges','transport','freight'],notes:['notes','remarks']},
  material_issues:{issue_number:['issue number','issue no','material issue number'],po_number:['po number','work order number','work order no'],issue_date:['issue date','date'],material:['material','material name','item'],quantity:['quantity','qty'],contractor_unit_rate:['contractor rate','charge rate','rate'],notes:['notes','remarks']},
  material_returns:{return_number:['return number','return no','material return number'],issue_number:['issue number','issue no','material issue number'],return_date:['return date','date'],material:['material','material name','item'],quantity_returned:['quantity returned','returned quantity','quantity','qty'],condition:['condition','material condition'],line_notes:['line notes','item notes'],notes:['notes','remarks']}
};
const normalize = (s:string) => s.trim().toLowerCase().replace(/[^a-z0-9]+/g,' ');
const valueFor = (row:SpreadsheetRow,names:string[]) => { const wanted=names.map(normalize); return Object.entries(row).find(([k])=>wanted.includes(normalize(k)))?.[1]?.trim() ?? ''; };
const buildRows = (type:ImportType,source:SpreadsheetRow[]) => source.map(row=>Object.fromEntries(Object.entries(aliases[type]).map(([field,names])=>[field,valueFor(row,names)])));
const required: Record<ImportType,string[]> = {
  customers:['name'],materials:['name'],stock:['material','movement_type','quantity'],invoices:['invoice_number','customer','material','quantity'],payments:['invoice_number','amount'],
  client_companies:['name'],contracts:['contract_number','client_company','title','original_value'],projects:['contract_number','name'],vendors:['name'],contractors:['name'],
  work_orders:['po_number','contractor','payment_basis'],advances:['po_number','amount'],client_bills:['contract_number','bill_number','amount_claimed'],client_receipts:['contract_number','amount'],client_deductions:['contract_number','deduction_type','amount'],
  material_purchases:['purchase_number','vendor_name','material','quantity','unit_cost'],material_issues:['issue_number','po_number','material','quantity'],material_returns:['return_number','issue_number','material','quantity_returned']
};
const constructionTypes: ImportType[] = ['client_companies','contracts','projects','vendors','contractors','work_orders','advances','client_bills','client_receipts','client_deductions','material_purchases','material_issues','material_returns'];

export default function DataImportPage({supabase,organizationId,onBack}:Props) {
  const [type,setType]=useState<ImportType>('client_companies');
  const [sourceRows,setSourceRows]=useState<SpreadsheetRow[]>([]);
  const [mappedRows,setMappedRows]=useState<Record<string,string>[]>([]);
  const [fileName,setFileName]=useState('');
  const [error,setError]=useState('');
  const [message,setMessage]=useState('');
  const [busy,setBusy]=useState(false);
  const [isAdmin,setIsAdmin]=useState<boolean|null>(null);
  const inputRef=useRef<HTMLInputElement>(null);

  useEffect(()=>{let active=true;(async()=>{
    const user=await supabase.auth.getUser();
    const {data,error:e}=await supabase.from('organization_members').select('role,is_active').eq('organization_id',organizationId).eq('user_id',user.data.user?.id??'').maybeSingle();
    if(!active)return;
    if(e)setError(e.message);else setIsAdmin(data?.is_active===true&&data?.role==='admin');
  })();return()=>{active=false}},[supabase,organizationId]);

  const validation=useMemo(()=>{
    const errors:string[]=[];
    mappedRows.forEach((row,i)=>{
      required[type].forEach(field=>{if(!row[field]?.trim())errors.push('Row '+(i+2)+': '+field.replaceAll('_',' ')+' is required.');});
      const numericFields=type==='contracts'?['original_value','revised_value']:type==='work_orders'?['fixed_amount','agreed_percentage']:type==='client_bills'?['amount_claimed']:type==='material_purchases'?['quantity','unit_cost','gst_rate','other_charges']:type==='material_issues'?['quantity','contractor_unit_rate']:type==='material_returns'?['quantity_returned']:['amount'];
      numericFields.forEach(field=>{if(row[field]&&(!Number.isFinite(Number(row[field]))||Number(row[field])<0))errors.push('Row '+(i+2)+': '+field.replaceAll('_',' ')+' must be a valid non-negative number.');});
      if(['stock','invoices','payments','advances','client_bills','client_receipts','client_deductions','material_issues','material_returns','material_purchases'].includes(type)){
        const f=type==='stock'||type==='invoices'||type==='material_issues'?'quantity':type==='material_purchases'?'quantity':type==='material_returns'?'quantity_returned':type==='payments'||type==='advances'||type==='client_receipts'||type==='client_deductions'?'amount':'amount_claimed';
        if(row[f]&&Number(row[f])<=0)errors.push('Row '+(i+2)+': '+f.replaceAll('_',' ')+' must be greater than zero.');
      }
      if(type==='contracts'&&row.revised_value&&Number(row.revised_value)<Number(row.original_value))errors.push('Row '+(i+2)+': revised value cannot be below original value.');
      if(type==='work_orders'&&row.payment_basis&& !['fixed','percentage'].includes(row.payment_basis.toLowerCase()))errors.push('Row '+(i+2)+': payment basis must be fixed or percentage.');
      if(type==='work_orders'&&row.payment_basis?.toLowerCase()==='fixed'&&!row.fixed_amount)errors.push('Row '+(i+2)+': fixed amount is required for fixed work orders.');
      if(type==='work_orders'&&row.payment_basis?.toLowerCase()==='percentage'&&(!row.agreed_percentage||Number(row.agreed_percentage)<=0||Number(row.agreed_percentage)>100))errors.push('Row '+(i+2)+': percentage must be greater than 0 and at most 100.');
      if(type==='client_bills'&&row.status&&!['draft','submitted','approved'].includes(row.status.toLowerCase()))errors.push('Row '+(i+2)+': bill status must be draft, submitted or approved.');
      if(type==='projects'&&!row.contract_number)errors.push('Row '+(i+2)+': contract number is required.');
      if(type==='work_orders'&&!row.project_code&&!row.project_name)errors.push('Row '+(i+2)+': provide a project code or project name.');
    });
    return [...new Set(errors)];
  },[mappedRows,type]);

  async function handleFile(file?:File){
    if(!file)return;
    setBusy(true);setError('');setMessage('Reading spreadsheet locally…');
    try{const rows=await readSpreadsheet(file);if(!rows.length)throw new Error('The spreadsheet contains no data rows.');setSourceRows(rows);setMappedRows(buildRows(type,rows));setFileName(file.name);setMessage(rows.length+' rows loaded. Review the preview before importing.');}
    catch(e){setSourceRows([]);setMappedRows([]);setFileName('');setError(e instanceof Error?e.message:'Could not read the spreadsheet.');setMessage('');}
    finally{setBusy(false);}
  }
  function changeType(next:ImportType){setType(next);if(sourceRows.length)setMappedRows(buildRows(next,sourceRows));setError('');setMessage('');}
  async function importRows(){
    if(!mappedRows.length||validation.length)return;
    setBusy(true);setError('');setMessage('Importing records in one database transaction…');
    const isConstruction=constructionTypes.includes(type);
    const rpc=isConstruction?'import_construction_records':type==='customers'?'import_customers':type==='materials'?'import_materials':type==='stock'?'import_stock_movements':type==='invoices'?'import_historical_invoices':'import_historical_payments';
    const args=isConstruction?{p_organization_id:organizationId,p_import_type:type,p_rows:mappedRows}:{p_organization_id:organizationId,p_rows:mappedRows};
    const {data,error:e}=await supabase.rpc(rpc,args);
    if(e)setError(e.message);else setMessage('Import completed: '+JSON.stringify(data)+'.');
    setBusy(false);
  }

  if(isAdmin===false)return <main className="main-content"><header className="topbar"><div><p className="eyebrow">Data Import</p><h1>Admin access required</h1></div></header><section className="setup-card"><div><h3>Historical data import is restricted</h3><p>Only an Admin can import business and financial history.</p></div><button className="secondary" onClick={onBack}>Back</button></section></main>;
  if(isAdmin===null)return <main className="main-content"><div className="mini-empty">Checking access…</div></main>;
  const columns=Object.keys(aliases[type]);
  return <main className="main-content">
    <header className="topbar"><div><p className="eyebrow">Migration & onboarding</p><h1>Import business data</h1><p className="page-subtitle">Bring existing Excel or CSV records into this business workspace.</p></div><button className="secondary" onClick={onBack}>Back</button></header>
    <section className="setup-card"><div><h3>Choose data to import</h3><p>Files are read locally. Data is sent to Supabase only when you confirm the import.</p></div><select value={type} onChange={e=>changeType(e.target.value as ImportType)}><optgroup label="Construction management">{constructionTypes.map(k=><option key={k} value={k}>{labels[k]}</option>)}</optgroup><optgroup label="Legacy material / sales">{(['customers','materials','stock','invoices','payments'] as ImportType[]).map(k=><option key={k} value={k}>{labels[k]}</option>)}</optgroup></select></section>
    {constructionTypes.includes(type)&&<section className="quick-card import-guidance"><div className="section-head"><div><p className="eyebrow">Important</p><h3>Import in dependency order</h3></div></div><p>Import client companies before contracts, contracts before projects, and projects plus contractors before work orders. Import bills before receipts and deductions. Work order advances are imported after work orders. Material purchase rows are grouped by purchase number; issue rows by issue number; return rows by return number. Keep each transaction number consistent across its item rows.</p><p>Amounts in spreadsheets are entered in rupees and converted to paise. Material purchase/issue/return imports call the same transactional stock functions as normal app operations. Existing records are not overwritten; duplicate keys or missing parent records stop the entire batch.</p><p>Contractor settlements are intentionally not imported as raw rows: their material, advance and payable snapshots must be generated by the settlement workflow after source transactions are verified.</p></section>}
    <section className="quick-card import-columns"><div><p className="eyebrow">Spreadsheet format</p><h3>Expected columns for {labels[type]}</h3><p className="hint">Required fields are marked with an asterisk. Header aliases are accepted where available.</p><p className="import-column-list">{columns.map((column,i)=><span key={column}>{column.replaceAll('_',' ')}{required[type].includes(column)?' *':''}{i<columns.length-1?' · ':''}</span>)}</p></div></section>
    <section className="quick-card">
      <div className="section-head"><div><p className="eyebrow">Step 1</p><h3>Upload Excel or CSV</h3></div><button className="primary compact" disabled={busy} onClick={()=>inputRef.current?.click()}>Choose file</button><input ref={inputRef} hidden type="file" accept=".xlsx,.csv" onChange={e=>void handleFile(e.target.files?.[0])}/></div>
      {fileName&&<p className="hint">{fileName} • {sourceRows.length} rows</p>}
      {error&&<div className="alert error">{error}</div>}{message&&<div className="alert info">{message}</div>}
    </section>
    {mappedRows.length>0&&<section className="recent-card"><div className="section-head"><div><p className="eyebrow">Step 2</p><h3>Review and validate</h3></div><span className={validation.length?'status-badge danger':'status-badge'}>{validation.length?validation.length+' validation issue(s)':mappedRows.length+' rows ready'}</span></div>
      {validation.length>0&&<div className="alert error">{validation.slice(0,8).map((v,i)=><div key={i}>{v}</div>)}{validation.length>8&&<div>…and {validation.length-8} more.</div>}</div>}
      <div className="table-wrap"><table><thead><tr><th>Row</th>{columns.map(c=><th key={c}>{c.replaceAll('_',' ')}</th>)}</tr></thead><tbody>{mappedRows.slice(0,10).map((r,i)=><tr key={i}><td>{i+2}</td>{columns.map(c=><td key={c}>{r[c]||'—'}</td>)}</tr>)}</tbody></table></div>
      <div className="section-head import-footer"><p className="hint">Showing the first 10 rows. Each import batch is all-or-nothing.</p><button className="primary" disabled={busy||validation.length>0} onClick={()=>void importRows()}>{busy?'Importing…':'Import '+mappedRows.length+' rows'}</button></div>
    </section>}
  </main>;
}
