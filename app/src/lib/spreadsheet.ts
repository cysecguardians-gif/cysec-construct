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
function bestHeaderRow(ws:ExcelJS.Worksheet):number{
 let best=1,bestScore=-1;
 const limit=Math.min(Math.max(ws.actualRowCount,1),25);
 for(let n=1;n<=limit;n++){
  const row=ws.getRow(n);let nonEmpty=0,textLike=0;
  row.eachCell({includeEmpty:false},cell=>{const value=cell.value;if(value!==null&&value!==undefined&&plain(value)!==''){nonEmpty++;if(typeof value==='string'||typeof value==='number')textLike++;}});
  const score=nonEmpty*3+textLike;
  if(score>bestScore){best=n;bestScore=score;}
 }
 return best;
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
  const headers=Array.from({length:lastColumn},(_,i)=>plain(header.getCell(i+1).value)||`Column ${i+1}`);
  const rows:SpreadsheetRow[]=[];
  ws.eachRow((row,rowNumber)=>{if(rowNumber<=headerRow)return;const record:SpreadsheetRow={};headers.forEach((h,i)=>record[h]=formulaValue(row.getCell(i+1),ws));if(Object.values(record).some(v=>v.trim()))rows.push(record)});
  if(rows.length)worksheets.push({name:ws.name,headers,rows,headerRow});
 });
 return {worksheets};
}
