import ExcelJS from 'exceljs';
export type SpreadsheetRow = Record<string,string>;
export type SpreadsheetWorksheet = {name:string;headers:string[];rows:SpreadsheetRow[];headerRow:number};
export type SpreadsheetData = {worksheets:SpreadsheetWorksheet[]};
function parseCsv(text:string):SpreadsheetWorksheet[]{
 const rows:string[][]=[];let row:string[]=[],cell='',quoted=false;
 for(let i=0;i<text.length;i++){const ch=text[i],next=text[i+1];if(ch==='"'){if(quoted&&next==='"'){cell+='"';i++}else quoted=!quoted}else if(ch===','&&!quoted){row.push(cell);cell=''}else if((ch==='\n'||ch==='\r')&&!quoted){if(ch==='\r'&&next==='\n')i++;row.push(cell);cell='';if(row.some(v=>v.trim()))rows.push(row);row=[]}else cell+=ch}
 if(cell||row.length){row.push(cell);if(row.some(v=>v.trim()))rows.push(row)}
 if(!rows.length)return [];
 const headers=rows[0].map((h,i)=>h.trim()||`Column ${i+1}`);
 return [{name:'CSV',headers,headerRow:1,rows:rows.slice(1).filter(r=>r.some(v=>v.trim())).map(values=>Object.fromEntries(headers.map((h,i)=>[h,(values[i]??'').trim()]))) }];
}
function plain(value:unknown):string{
 if(value===null||value===undefined)return '';
 if(value instanceof Date)return value.toISOString().slice(0,10);
 if(typeof value==='object'){
  const v=value as Record<string,unknown>;
  if(typeof v.text==='string')return v.text;
  if(v.result!==undefined)return plain(v.result);
  if(Array.isArray(v.richText))return v.richText.map(x=>(x as {text?:string}).text??'').join('');
  if(typeof v.hyperlink==='string')return typeof v.text==='string'?v.text:v.hyperlink;
  return '';
 }
 return String(value).trim();
}
function normalizeHeader(value:string):string{return value.toLowerCase().replace(/[^a-z0-9]+/g,' ').trim();}
function bestHeaderRow(ws:ExcelJS.Worksheet):number{
 const limit=Math.min(Math.max(ws.actualRowCount,1),40);
 let best=1,bestScore=-1;
 for(let n=1;n<=limit;n++){
  const values:string[]=[];
  ws.getRow(n).eachCell({includeEmpty:false},cell=>{const v=plain(cell.value);if(v)values.push(normalizeHeader(v));});
  const joined=values.join(' | ');
  const hasItem=values.some(v=>v.includes('item of discription')||v.includes('item of description')||v==='item description'||v==='material name');
  const hasUnit=values.some(v=>v==='unit'||v==='uom'||v==='type');
  const hasSerial=values.some(v=>v==='sl no'||v==='sl number'||v==='serial no'||v==='s no');
  const hasTotal=values.some(v=>v==='total qty'||v==='total quantity');
  const score=(hasItem?100:0)+(hasUnit?35:0)+(hasSerial?25:0)+(hasTotal?20:0)+Math.min(values.length,15);
  if(score>bestScore){best=n;bestScore=score;}
  if(hasItem&&hasUnit&&(hasSerial||hasTotal))return n;
 }
 return best;
}
function uniqueHeaders(raw:string[]):string[]{
 const seen=new Map<string,number>();
 return raw.map((header,i)=>{const base=header.trim()||`Column ${i+1}`;const count=(seen.get(base)??0)+1;seen.set(base,count);return count===1?base:`${base} (${count})`;});
}
function formulaValue(cell:ExcelJS.Cell,ws:ExcelJS.Worksheet):string{
 const value=cell.value;
 if(value&&typeof value==='object'&&'formula' in value){
  const result=(value as {result?:unknown}).result;
  if(result!==undefined)return plain(result);
  const formula=String((value as {formula:string}).formula);
  const sum=formula.match(/^\s*SUM\(\$?([A-Z]+)\$?(\d+):\$?([A-Z]+)\$?(\d+)\)\s*$/i);
  if(sum){const col=(s:string)=>{let n=0;for(const ch of s.toUpperCase())n=n*26+ch.charCodeAt(0)-64;return n};const c1=col(sum[1]),c2=col(sum[3]),r1=Number(sum[2]),r2=Number(sum[4]);let total=0;for(let r=r1;r<=r2;r++)for(let c=c1;c<=c2;c++){const v=Number(plain(ws.getRow(r).getCell(c).value));if(Number.isFinite(v))total+=v;}return String(total);}
  return '';
 }
 return plain(value);
}
export async function readSpreadsheet(file:File):Promise<SpreadsheetData>{
 if(file.name.toLowerCase().endsWith('.csv'))return {worksheets:parseCsv(await file.text())};
 if(!file.name.toLowerCase().endsWith('.xlsx'))throw new Error('Please choose an .xlsx or .csv file.');
 const workbook=new ExcelJS.Workbook();
 await workbook.xlsx.load(await file.arrayBuffer());
 const worksheets:SpreadsheetWorksheet[]=[];
 workbook.eachSheet(ws=>{
  const headerRow=bestHeaderRow(ws),header=ws.getRow(headerRow);
  const lastColumn=Math.max(header.cellCount,ws.actualColumnCount);
  const headers=uniqueHeaders(Array.from({length:lastColumn},(_,i)=>plain(header.getCell(i+1).value)||`Column ${i+1}`));
  const rows:SpreadsheetRow[]=[];
  ws.eachRow((row,rowNumber)=>{if(rowNumber<=headerRow)return;const record:SpreadsheetRow={};headers.forEach((h,i)=>record[h]=formulaValue(row.getCell(i+1),ws));if(Object.values(record).some(v=>v.trim()))rows.push(record)});
  if(rows.length)worksheets.push({name:ws.name,headers,rows,headerRow});
 });
 return {worksheets};
}
