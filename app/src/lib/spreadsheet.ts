import ExcelJS from 'exceljs';
export type SpreadsheetRow = Record<string,string>;
export type SpreadsheetWorksheet = {name:string;headers:string[];rows:SpreadsheetRow[]};
export type SpreadsheetData = {worksheets:SpreadsheetWorksheet[]};
function parseCsv(text:string):SpreadsheetWorksheet[]{
 const rows:string[][]=[];let row:string[]=[],cell='',quoted=false;
 for(let i=0;i<text.length;i++){const ch=text[i],next=text[i+1];if(ch==='"'){if(quoted&&next==='"'){cell+='"';i++}else quoted=!quoted}else if(ch===','&&!quoted){row.push(cell);cell=''}else if((ch==='\n'||ch==='\r')&&!quoted){if(ch==='\r'&&next==='\n')i++;row.push(cell);cell='';if(row.some(v=>v.trim()))rows.push(row);row=[]}else cell+=ch}
 if(cell||row.length){row.push(cell);if(row.some(v=>v.trim()))rows.push(row)}
 if(!rows.length)return [];
 const headers=rows[0].map((h,i)=>h.trim()||`Column ${i+1}`);
 return [{name:'CSV',headers,rows:rows.slice(1).filter(r=>r.some(v=>v.trim())).map(values=>Object.fromEntries(headers.map((h,i)=>[h,(values[i]??'').trim()]))) }];
}
function cellText(value:ExcelJS.CellValue):string{
 if(value===null||value===undefined)return '';
 if(value instanceof Date)return value.toISOString().slice(0,10);
 if(typeof value==='object'){
  if('text' in value && typeof value.text==='string')return value.text;
  if('result' in value)return cellText(value.result as ExcelJS.CellValue);
  if('richText' in value && Array.isArray(value.richText))return value.richText.map(x=>x.text).join('');
  if('hyperlink' in value && typeof value.hyperlink==='string')return value.text??value.hyperlink;
  return String(value);
 }
 return String(value).trim();
}
export async function readSpreadsheet(file:File):Promise<SpreadsheetData>{
 if(file.name.toLowerCase().endsWith('.csv'))return {worksheets:parseCsv(await file.text())};
 if(!file.name.toLowerCase().endsWith('.xlsx'))throw new Error('Please choose an .xlsx or .csv file.');
 const workbook=new ExcelJS.Workbook();
 await workbook.xlsx.load(await file.arrayBuffer());
 const worksheets:SpreadsheetWorksheet[]=[];
 workbook.eachSheet(ws=>{
  const headerRow=ws.getRow(1);
  const lastColumn=Math.max(headerRow.cellCount,ws.actualColumnCount);
  const headers=Array.from({length:lastColumn},(_,i)=>cellText(headerRow.getCell(i+1).value)||`Column ${i+1}`);
  const rows:SpreadsheetRow[]=[];
  ws.eachRow((row,rowNumber)=>{
   if(rowNumber===1)return;
   const record:SpreadsheetRow={};
   headers.forEach((h,i)=>record[h]=cellText(row.getCell(i+1).value));
   if(Object.values(record).some(v=>v.trim()))rows.push(record);
  });
  if(headers.some(h=>!/^Column \d+$/.test(h))||rows.length)worksheets.push({name:ws.name,headers,rows});
 });
 return {worksheets};
}
