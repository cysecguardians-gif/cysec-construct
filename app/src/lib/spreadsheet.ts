export type SpreadsheetRow = Record<string, string>;

function decode(bytes: Uint8Array) {
  return new TextDecoder('utf-8').decode(bytes);
}

function parseCsv(text: string): SpreadsheetRow[] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (ch === '"') {
      if (quoted && next === '"') { cell += '"'; i += 1; }
      else quoted = !quoted;
    } else if (ch === ',' && !quoted) {
      row.push(cell); cell = '';
    } else if ((ch === '\n' || ch === '\r') && !quoted) {
      if (ch === '\r' && next === '\n') i += 1;
      row.push(cell); cell = '';
      if (row.some(v => v.trim() !== '')) rows.push(row);
      row = [];
    } else cell += ch;
  }
  if (cell || row.length) { row.push(cell); if (row.some(v => v.trim() !== '')) rows.push(row); }
  if (!rows.length) return [];
  const headers = rows[0].map((h, i) => h.trim() || `Column ${i + 1}`);
  return rows.slice(1).map(values => Object.fromEntries(headers.map((h, i) => [h, (values[i] ?? '').trim()])));
}

function findEndOfCentralDirectory(view: DataView) {
  for (let i = view.byteLength - 22; i >= Math.max(0, view.byteLength - 65557); i -= 1) {
    if (view.getUint32(i, true) === 0x06054b50) return i;
  }
  throw new Error('Invalid XLSX archive.');
}

async function unzipEntries(buffer: ArrayBuffer): Promise<Map<string, Uint8Array>> {
  const view = new DataView(buffer);
  const eocd = findEndOfCentralDirectory(view);
  const count = view.getUint16(eocd + 10, true);
  const directoryOffset = view.getUint32(eocd + 16, true);
  const entries = new Map<string, Uint8Array>();
  let p = directoryOffset;
  for (let n = 0; n < count; n += 1) {
    if (view.getUint32(p, true) !== 0x02014b50) throw new Error('Invalid XLSX central directory.');
    const method = view.getUint16(p + 10, true);
    const compressedSize = view.getUint32(p + 20, true);
    const nameLength = view.getUint16(p + 28, true);
    const extraLength = view.getUint16(p + 30, true);
    const commentLength = view.getUint16(p + 32, true);
    const localOffset = view.getUint32(p + 42, true);
    const name = new TextDecoder().decode(new Uint8Array(buffer, p + 46, nameLength));
    const local = new DataView(buffer, localOffset);
    if (local.getUint32(0, true) !== 0x04034b50) throw new Error('Invalid XLSX local entry.');
    const localNameLength = local.getUint16(26, true);
    const localExtraLength = local.getUint16(28, true);
    const compressed = new Uint8Array(buffer, localOffset + 30 + localNameLength + localExtraLength, compressedSize);
    let data: Uint8Array;
    if (method === 0) data = new Uint8Array(compressed);
    else if (method === 8) data = new Uint8Array(await new Response(new Blob([compressed]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
    else throw new Error(`Unsupported XLSX compression method: ${method}`);
    entries.set(name, data);
    p += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

function xmlText(xml: string, tag: string) {
  return [...xml.matchAll(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, 'g'))].map(m => m[1].replace(/<[^>]+>/g, '')).join('');
}

function columnIndex(ref: string) {
  const letters = ref.match(/^[A-Z]+/i)?.[0].toUpperCase() ?? 'A';
  let n = 0;
  for (const c of letters) n = n * 26 + c.charCodeAt(0) - 64;
  return n - 1;
}

async function parseXlsx(buffer: ArrayBuffer): Promise<SpreadsheetRow[]> {
  const entries = await unzipEntries(buffer);
  const sharedXml = entries.get('xl/sharedStrings.xml');
  const shared = sharedXml ? [...decode(sharedXml).matchAll(/<si>([\s\S]*?)<\/si>/g)].map(m => xmlText(m[1], 't')) : [];
  const sheetName = [...entries.keys()].find(k => /^xl\/worksheets\/sheet\d+\.xml$/.test(k));
  if (!sheetName) throw new Error('No worksheet found in XLSX file.');
  const xml = decode(entries.get(sheetName)!);
  const parsed: string[][] = [];
  for (const rowMatch of xml.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    const values: string[] = [];
    for (const cell of rowMatch[1].matchAll(/<c\s+([^>]*)>([\s\S]*?)<\/c>/g)) {
      const attrs = cell[1];
      const body = cell[2];
      const ref = attrs.match(/\br="([^"]+)"/)?.[1] ?? 'A1';
      const type = attrs.match(/\bt="([^"]+)"/)?.[1] ?? '';
      const raw = xmlText(body, 'v');
      const inline = type === 'inlineStr' ? xmlText(body, 't') : raw;
      const value = type === 's' ? (shared[Number(raw)] ?? '') : inline;
      values[columnIndex(ref)] = value;
    }
    parsed.push(values.map(v => v ?? ''));
  }
  if (!parsed.length) return [];
  const headers = parsed[0].map((h, i) => h.trim() || `Column ${i + 1}`);
  return parsed.slice(1).filter(r => r.some(v => v.trim() !== '')).map(r => Object.fromEntries(headers.map((h, i) => [h, (r[i] ?? '').trim()])));
}

export async function readSpreadsheet(file: File): Promise<SpreadsheetRow[]> {
  if (file.name.toLowerCase().endsWith('.csv')) return parseCsv(await file.text());
  if (file.name.toLowerCase().endsWith('.xlsx')) return parseXlsx(await file.arrayBuffer());
  throw new Error('Please choose an .xlsx or .csv file.');
}
