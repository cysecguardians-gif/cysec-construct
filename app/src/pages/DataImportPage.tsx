import { useEffect, useMemo, useRef, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { readSpreadsheet, type SpreadsheetData, type SpreadsheetRow } from '../lib/spreadsheet';

type ImportType = 'contractors' | 'materials' | 'stock' | 'customers' | 'invoices' | 'payments';
type Props = { supabase: SupabaseClient; organizationId: string; onBack: () => void };
type Field = { key: string; label: string; required?: boolean };
const labels: Record<ImportType,string> = { contractors:'Contractors', materials:'Materials', stock:'Stock Ledger', customers:'Customers', invoices:'Historical Invoices', payments:'Historical Payments' };
const fields: Record<ImportType,Field[]> = {
 contractors:[{key:'name',label:'Contractor name',required:true},{key:'contractor_type',label:'Contractor type'},{key:'gstin',label:'GSTIN'},{key:'pan',label:'PAN'},{key:'contact_person',label:'Contact person'},{key:'phone',label:'Phone'},{key:'email',label:'Email'},{key:'address',label:'Address'},{key:'state',label:'State'},{key:'state_code',label:'State code'},{key:'notes',label:'Notes'}],
 materials:[{key:'name',label:'Material name',required:true},{key:'unit',label:'Unit'},{key:'category',label:'Category'},{key:'hsn_sac_code',label:'HSN/SAC'},{key:'gst_rate',label:'GST rate (%)'},{key:'selling_price',label:'Selling price (₹)'}],
 stock:[{key:'material',label:'Material name',required:true},{key:'movement_type',label:'Movement type',required:true},{key:'quantity',label:'Quantity',required:true},{key:'movement_date',label:'Movement date'},{key:'notes',label:'Notes'}],
 customers:[{key:'name',label:'Customer name',required:true},{key:'gstin',label:'GSTIN'},{key:'pan',label:'PAN'},{key:'phone',label:'Phone'},{key:'email',label:'Email'},{key:'billing_address_line1',label:'Billing address'},{key:'billing_city',label:'City'},{key:'billing_state',label:'State'},{key:'billing_state_code',label:'State code'},{key:'billing_postal_code',label:'PIN'}],
 invoices:[{key:'invoice_number',label:'Invoice number',required:true},{key:'invoice_date',label:'Invoice date'},{key:'customer',label:'Customer',required:true},{key:'material',label:'Material',required:true},{key:'quantity',label:'Quantity',required:true},{key:'unit_price',label:'Unit price (₹)'},{key:'gst_rate',label:'GST rate (%)'}],
 payments:[{key:'invoice_number',label:'Invoice number',required:true},{key:'amount',label:'Amount (₹)',required:true},{key:'payment_date',label:'Payment date'},{key:'payment_method',label:'Payment method'},{key:'reference_number',label:'Reference number'},{key:'notes',label:'Notes'}]
};
const aliases: Record<string,string[]> = {
 name:['name','contractor','contractor name','material','material name','item','item description','description of item','item of discription','item of description','description of item','customer','customer name','supplier','party name'],
 contractor_type:['type','contractor type'], gstin:['gstin','gst no','gst number'], pan:['pan'], contact_person:['contact person','contact'], phone:['phone','mobile','mobile number'], email:['email','email address'], address:['address','address line 1'], state:['state'], state_code:['state code'], notes:['notes','remarks','comments'],
 unit:['unit','uom','unit name','type'], category:['category','material category'], hsn_sac_code:['hsn','hsn/sac','hsn sac','sac'], gst_rate:['gst','gst %','gst rate','tax'], selling_price:['price','selling price','rate','unit price'], quantity:['quantity','qty','total qty','total quantity','opening stock','stock'], material:['material','material name','item','item description','description of item'], movement_type:['type','movement type','transaction type'], movement_date:['date','movement date','transaction date','challan date'], invoice_number:['invoice number','invoice no','invoice #','bill no','bill number'], invoice_date:['invoice date','date'], customer:['customer','customer name','client'], unit_price:['unit price','price','rate'], amount:['amount','payment','paid amount'], payment_date:['payment date','date'], payment_method:['payment method','method','mode'], reference_number:['reference','reference number','transaction id','utr'], billing_address_line1:['address','billing address','address line 1'], billing_city:['city','billing city'], billing_state:['state','billing state'], billing_state_code:['state code','billing state code'], billing_postal_code:['pin','pincode','postal code','zip']
};
const normalize=(s:string)=>s.trim().toLowerCase().replace(/[^a-z0-9]+/g,' ');
function guess(header:string,type:ImportType){const h=normalize(header);return fields[type].find(f=>[f.key,...(aliases[f.key]??[])].some(a=>normalize(a)===h))?.key??'';}
function mappedRows(rows:SpreadsheetRow[],mapping:Record<string,string>){return rows.map(row=>{const out:Record<string,string>={};for(const [header,value] of Object.entries(row)){const key=mapping[header];if(key)out[key]=value??'';}return out;});}
export default function DataImportPage({supabase,organizationId,onBack}:Props){
 const [type,setType]=useState<ImportType>('contractors');
 const [useSheetName,setUseSheetName]=useState(true);
 const [book,setBook]=useState<SpreadsheetData|null>(null),[sheet,setSheet]=useState('');
 const [mapping,setMapping]=useState<Record<string,string>>({});
 const [fileName,setFileName]=useState(''),[error,setError]=useState(''),[message,setMessage]=useState(''),[busy,setBusy]=useState(false),[isAdmin,setIsAdmin]=useState<boolean|null>(null);
 const inputRef=useRef<HTMLInputElement>(null);
 const sourceRows=book?.worksheets.find(x=>x.name===sheet)?.rows??[];
 const mappedPreview=type==='contractors'&&useSheetName&&sheet?[{...mappedRows(sourceRows,mapping)[0],name:sheet}]:mappedRows(sourceRows,mapping);
 const preview=type==='materials'?mappedPreview.filter(row=>Boolean(row.name?.trim())):mappedPreview;
 const skippedBlankMaterialRows=type==='materials'?mappedPreview.length-preview.length:0;
 useEffect(()=>{let active=true;(async()=>{const user=await supabase.auth.getUser();const {data,error:e}=await supabase.from('organization_members').select('role,is_active').eq('organization_id',organizationId).eq('user_id',user.data.user?.id??'').maybeSingle();if(!active)return;if(e)setError(e.message);else setIsAdmin(data?.is_active===true&&data?.role==='admin')})();return()=>{active=false}},[supabase,organizationId]);
 async function handleFile(file?:File){if(!file)return;setBusy(true);setError('');setMessage('Reading workbook…');try{const data=await readSpreadsheet(file);if(!data.worksheets.length)throw new Error('No worksheets found in this workbook.');setBook(data);setSheet(data.worksheets[0].name);setFileName(file.name);const next:Record<string,string>={};for(const h of data.worksheets[0].headers)next[h]=guess(h,type);setMapping(next);setMessage(`${data.worksheets.length} worksheet(s) found. Select a worksheet and map its columns.`)}catch(e){setBook(null);setSheet('');setFileName('');setError(e instanceof Error?e.message:'Could not read the workbook.');setMessage('')}finally{setBusy(false)}}
 function changeType(next:ImportType){setType(next);if(next==='contractors')setUseSheetName(true);const headers=book?.worksheets.find(x=>x.name===sheet)?.headers??[];const nextMap:Record<string,string>={};headers.forEach(h=>nextMap[h]=guess(h,next));setMapping(nextMap);setError('');setMessage('')}
 function changeSheet(next:string){setSheet(next);const headers=book?.worksheets.find(x=>x.name===next)?.headers??[];const nextMap:Record<string,string>={};headers.forEach(h=>nextMap[h]=guess(h,type));setMapping(nextMap);setError('');setMessage('')}
 const validation=useMemo(()=>{
  const issues:string[]=[];
  const required=fields[type].filter(field=>field.required).map(field=>field.key);
  if(!preview.length)return issues;
  if(type==='contractors'&&useSheetName)return issues;
  required.forEach(key=>{
   if(!Object.values(mapping).includes(key))issues.push(`Map an Excel column to ${fields[type].find(field=>field.key===key)?.label??key}.`);
  });
  preview.forEach((row,index)=>{
   required.forEach(key=>{
    if(!row[key]?.trim())issues.push(`Row ${index+2}: ${fields[type].find(field=>field.key===key)?.label??key} is required.`);
   });
   for(const key of ['quantity','gst_rate','selling_price','unit_price','amount']){
    if(row[key]?.trim()&&!Number.isFinite(Number(row[key])))issues.push(`Row ${index+2}: ${key.replaceAll('_',' ')} must be numeric.`);
   }
  });
  return [...new Set(issues)];
 },[preview,type,mapping,useSheetName]);
 async function importRows(){if(!preview.length||validation.length||busy||isAdmin!==true)return;setBusy(true);setError('');setMessage('Importing…');try{
  if(type==='contractors'){
   const rows=preview.filter(r=>r.name?.trim()).map(r=>({organization_id:organizationId,name:r.name.trim(),contractor_type:['contractor','subcontractor','individual'].includes((r.contractor_type||'').toLowerCase())?(r.contractor_type||'').toLowerCase():'contractor',gstin:r.gstin||null,pan:r.pan||null,contact_person:r.contact_person||null,phone:r.phone||null,email:r.email||null,address:r.address||null,state:r.state||null,state_code:r.state_code||null,notes:r.notes||null,is_active:true}));
   const {error:e}=await supabase.from('contractors').upsert(rows,{onConflict:'organization_id,name',ignoreDuplicates:true});if(e)throw e;setMessage(`Import complete: ${rows.length} contractor row(s) processed. Existing names were not duplicated.`);
  }else{
   const rpc=type==='materials'?'import_materials':type==='stock'?'import_stock_movements':type==='customers'?'import_customers':type==='invoices'?'import_historical_invoices':'import_historical_payments';
   const payload=preview.map(r=>{const out={...r};if(type==='materials'&&out.selling_price)out.selling_price=String(Number(out.selling_price));return out});
   const {data,error:e}=await supabase.rpc(rpc,{p_organization_id:organizationId,p_rows:payload});if(e)throw e;setMessage(`Import complete: ${JSON.stringify(data)}`);
  }
  setBook(null);setSheet('');setFileName('');if(inputRef.current)inputRef.current.value='';
 }catch(e){setError(e instanceof Error?e.message:'The import could not be completed.');setMessage('Import failed. Your workbook and mapping are preserved so you can correct and retry.')}finally{setBusy(false)}}
 if(isAdmin===false)return <main className="main-content"><header className="topbar"><div><p className="eyebrow">Data Import</p><h1>Admin access required</h1></div></header><section className="setup-card"><div><h3>Historical data import is restricted</h3><p>Only an Admin can import business records.</p></div><button className="secondary" onClick={onBack}>Back</button></section></main>;
 if(isAdmin===null)return <main className="main-content"><div className="mini-empty">Checking access…</div></main>;
 return <main className="main-content"><header className="topbar"><div><p className="eyebrow">Data migration</p><h1>Import business data</h1><p className="page-subtitle">Choose worksheets, map your own Excel headings and preview records before importing.</p></div><button className="secondary" onClick={onBack}>Back</button></header>
 <section className="setup-card"><div><h3>1. Choose what you are importing</h3><p>Import contractors and materials from workbooks with different column names.</p></div><select value={type} onChange={e=>changeType(e.target.value as ImportType)}>{Object.entries(labels).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select></section>
 <section className="quick-card"><div className="section-head"><div><p className="eyebrow">Step 2</p><h3>Choose an Excel workbook</h3></div><button className="primary compact" disabled={busy} onClick={()=>inputRef.current?.click()}>{busy?'Reading…':'Choose file'}</button><input ref={inputRef} hidden type="file" accept=".xlsx,.csv" onChange={e=>void handleFile(e.target.files?.[0])}/></div>{fileName&&<p className="hint">{fileName} · {book?.worksheets.length??0} worksheets</p>}{error&&<div className="alert error">{error}</div>}{message&&<div className="alert info">{message}</div>}</section>
 {book&&<><section className="setup-card"><div><h3>3. Select worksheet</h3><p>Each worksheet can have its own column layout. Select one to map and import.</p></div><select value={sheet} onChange={e=>changeSheet(e.target.value)}>{book.worksheets.map(x=><option key={x.name} value={x.name}>{x.name} ({x.rows.length} rows)</option>)}</select></section>
 {!(type==='contractors'&&useSheetName)&&<section className="recent-card"><div className="section-head"><div><p className="eyebrow">Step 4</p><h3>Map Excel columns to CySec Construct fields</h3><p className="hint">Choose “Do not import” for columns you don't need. Matching suggestions are automatic and editable.</p></div><span className="status-badge">{sourceRows.length} rows</span></div>
 <div className="table-wrap"><table><thead><tr><th>Excel column</th><th>Sample value</th><th>Import as</th></tr></thead><tbody>{(book.worksheets.find(x=>x.name===sheet)?.headers??[]).map(h=><tr key={h}><td><strong>{h}</strong></td><td>{sourceRows.find(r=>r[h]?.trim())?.[h]??'—'}</td><td><select value={mapping[h]??''} onChange={e=>setMapping(m=>({...m,[h]:e.target.value}))}><option value="">Do not import</option>{fields[type].map(f=><option key={f.key} value={f.key}>{f.label}{f.required?' *':''}</option>)}</select></td></tr>)}</tbody></table></div></section>}
 {type==='contractors'&&<section className="setup-card"><label className="inline-check"><input type="checkbox" checked={useSheetName} onChange={e=>setUseSheetName(e.target.checked)}/> Use worksheet name as contractor name (for example, PRAVAT or TARUN)</label><p className="hint">When selected, this worksheet imports one contractor record using its tab name. Turn it off to map contractor names from rows instead.</p></section>}
 <section className="recent-card"><div className="section-head"><div><p className="eyebrow">Step 5</p><h3>Preview and validate</h3></div><span className={validation.length?'status-badge danger':'status-badge'}>{validation.length?`${validation.length} issue(s)`:`${preview.length} rows ready`}</span></div>{type==='materials'&&skippedBlankMaterialRows>0&&<div className="alert info">{skippedBlankMaterialRows} blank material row(s) skipped. Only rows with a material name will be imported. Opening stock quantities are not part of the material master import; use Stock Ledger for stock balances.</div>}{validation.length>0&&<div className="alert error">{validation.slice(0,10).map((v,i)=><div key={i}>{v}</div>)}{validation.length>10&&<div>…and {validation.length-10} more.</div>}</div>}<div className="table-wrap"><table><thead><tr><th>Row</th>{fields[type].filter(f=>Object.values(mapping).includes(f.key)).map(f=><th key={f.key}>{f.label}</th>)}</tr></thead><tbody>{preview.slice(0,10).map((r,i)=><tr key={i}><td>{i+2}</td>{fields[type].filter(f=>Object.values(mapping).includes(f.key)).map(f=><td key={f.key}>{r[f.key]||'—'}</td>)}</tr>)}</tbody></table></div><div className="section-head import-footer"><p className="hint">Showing first 10 rows. Contractor imports do not create work orders or material challans.</p><button className="primary" disabled={busy||validation.length>0||!preview.length} onClick={()=>void importRows()}>{busy?'Importing…':`Import ${preview.length} rows`}</button></div></section></>}
 </main>;
}
