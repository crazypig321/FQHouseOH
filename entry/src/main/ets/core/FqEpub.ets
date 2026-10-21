import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';

interface FqZipEntry {
  name: string;
  data: Uint8Array;
}

let fqCrcTable: number[] = [];

function fqCrc32(data: Uint8Array): number {
  if (fqCrcTable.length === 0) {
    const table: number[] = [];
    for (let i = 0; i < 256; i++) {
      let c: number = i;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) !== 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table.push(c);
    }
    fqCrcTable = table;
  }
  let crc: number = 0xFFFFFFFF;
  for (let i = 0; i < data.length; i++) {
    crc = (crc >>> 8) ^ fqCrcTable[(crc ^ data[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

function fqPushU16(out: number[], value: number): void {
  out.push(value & 0xFF, (value >>> 8) & 0xFF);
}

function fqPushU32(out: number[], value: number): void {
  out.push(value & 0xFF, (value >>> 8) & 0xFF, (value >>> 16) & 0xFF, (value >>> 24) & 0xFF);
}

function fqZipStored(entries: FqZipEntry[]): Uint8Array {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const out: number[] = [];
  const central: number[] = [];
  const count: number = entries.length;
  for (const entry of entries) {
    const nameBytes: Uint8Array = encoder.encodeInto(entry.name);
    const offset: number = out.length;
    const crc: number = fqCrc32(entry.data);
    fqPushU32(out, 0x04034b50);
    fqPushU16(out, 20);
    fqPushU16(out, 0);
    fqPushU16(out, 0);
    fqPushU16(out, 0);
    fqPushU16(out, 0x21);
    fqPushU32(out, crc);
    fqPushU32(out, entry.data.length);
    fqPushU32(out, entry.data.length);
    fqPushU16(out, nameBytes.length);
    fqPushU16(out, 0);
    for (const b of nameBytes) {
      out.push(b);
    }
    for (const b of entry.data) {
      out.push(b);
    }
    fqPushU32(central, 0x02014b50);
    fqPushU16(central, 20);
    fqPushU16(central, 20);
    fqPushU16(central, 0);
    fqPushU16(central, 0);
    fqPushU16(central, 0);
    fqPushU16(central, 0x21);
    fqPushU32(central, crc);
    fqPushU32(central, entry.data.length);
    fqPushU32(central, entry.data.length);
    fqPushU16(central, nameBytes.length);
    fqPushU16(central, 0);
    fqPushU16(central, 0);
    fqPushU16(central, 0);
    fqPushU16(central, 0);
    fqPushU32(central, 0);
    fqPushU32(central, offset);
    for (const b of nameBytes) {
      central.push(b);
    }
  }
  const centralOffset: number = out.length;
  for (const b of central) {
    out.push(b);
  }
  fqPushU32(out, 0x06054b50);
  fqPushU16(out, 0);
  fqPushU16(out, 0);
  fqPushU16(out, count);
  fqPushU16(out, count);
  fqPushU32(out, central.length);
  fqPushU32(out, centralOffset);
  fqPushU16(out, 0);
  return new Uint8Array(out);
}

export function fqXmlEscape(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function fqSeedHex(seed: string): string {
  let h: number = 0;
  for (let i = 0; i < seed.length; i++) {
    h = ((h << 5) - h + seed.charCodeAt(i)) | 0;
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

export function fqWriteChapterEpub(path: string, title: string, paragraphs: string[]): void {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const uid: string = `fq-${fqSeedHex(title)}-${fqSeedHex(paragraphs.length > 1 ? paragraphs[1] : title)}`;
  const escTitle: string = fqXmlEscape(title);
  let bodyXml: string = '';
  for (const para of paragraphs) {
    const p: string = para.trim();
    if (p.length === 0) {
      continue;
    }
    bodyXml += `<p>${fqXmlEscape(p)}</p>\n`;
  }
  const xhtml: string = `<?xml version="1.0" encoding="utf-8"?>\n` +
    `<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n` +
    `<html xmlns="http://www.w3.org/1999/xhtml">\n` +
    `<head><title>${escTitle}</title></head>\n` +
    `<body>\n${bodyXml}</body>\n</html>\n`;
  const opf: string = `<?xml version="1.0" encoding="utf-8"?>\n` +
    `<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">\n` +
    `  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n` +
    `    <dc:title>${escTitle}</dc:title>\n` +
    `    <dc:language>zh</dc:language>\n` +
    `    <dc:identifier id="bookid">${uid}</dc:identifier>\n` +
    `    <dc:creator>FQHouse</dc:creator>\n` +
    `  </metadata>\n` +
    `  <manifest>\n` +
    `    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n` +
    `    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>\n` +
    `  </manifest>\n` +
    `  <spine toc="ncx">\n` +
    `    <itemref idref="chapter1"/>\n` +
    `  </spine>\n` +
    `</package>\n`;
  const ncx: string = `<?xml version="1.0" encoding="utf-8"?>\n` +
    `<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n` +
    `  <head>\n` +
    `    <meta name="dtb:uid" content="${uid}"/>\n` +
    `    <meta name="dtb:depth" content="1"/>\n` +
    `    <meta name="dtb:totalPageCount" content="0"/>\n` +
    `    <meta name="dtb:maxPageNumber" content="0"/>\n` +
    `  </head>\n` +
    `  <docTitle><text>${escTitle}</text></docTitle>\n` +
    `  <navMap>\n` +
    `    <navPoint id="nav1" playOrder="1">\n` +
    `      <navLabel><text>${escTitle}</text></navLabel>\n` +
    `      <content src="chapter1.xhtml"/>\n` +
    `    </navPoint>\n` +
    `  </navMap>\n` +
    `</ncx>\n`;
  const container: string = `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n` +
    `  <rootfiles>\n` +
    `    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n` +
    `  </rootfiles>\n` +
    `</container>\n`;
  const entries: FqZipEntry[] = [];
  entries.push({ name: 'mimetype', data: encoder.encodeInto('application/epub+zip') });
  entries.push({ name: 'META-INF/container.xml', data: encoder.encodeInto(container) });
  entries.push({ name: 'OEBPS/content.opf', data: encoder.encodeInto(opf) });
  entries.push({ name: 'OEBPS/toc.ncx', data: encoder.encodeInto(ncx) });
  entries.push({ name: 'OEBPS/chapter1.xhtml', data: encoder.encodeInto(xhtml) });
  const zip: Uint8Array = fqZipStored(entries);
  const file: fileIo.File = fileIo.openSync(
    path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(file.fd, zip.buffer);
  fileIo.closeSync(file);
}
