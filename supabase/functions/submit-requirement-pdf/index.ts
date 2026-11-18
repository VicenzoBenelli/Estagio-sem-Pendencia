// ESP-13 / ESP-14 / ESP-15: Edge Function para submissão segura de PDF privado com validação binária,
// envio para bucket privado sem overwrite, finalização atômica anti-TOCTOU e compensação segura de órfãos.

const BUCKET_NAME = 'internship-documents';
const DEFAULT_MAX_PDF_BYTES = 5 * 1024 * 1024; // 5 MiB (alinhado ao bucket)
const MIN_PDF_BYTES = 64;
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-idempotency-key',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface JsonErrorBody {
  ok: false;
  error: {
    code: string;
    message: string;
  };
}

interface PrepareReadyResult {
  outcome: 'ready_to_upload' | 'ready_to_finalize';
  intent_id: string;
  lease_token: string;
  process_id: string;
  process_requirement_id: string;
  target_version: number;
  storage_bucket: string;
  storage_path: string;
}

interface PrepareAlreadyCommittedResult {
  outcome: 'already_committed';
  submission: Record<string, unknown>;
  requirement: Record<string, unknown>;
}

type PrepareResult = PrepareReadyResult | PrepareAlreadyCommittedResult;

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}

function errorResponse(status: number, code: string, message: string): Response {
  const payload: JsonErrorBody = {
    ok: false,
    error: { code, message },
  };
  return jsonResponse(status, payload as unknown as Record<string, unknown>);
}

function getMaxPdfBytes(): number {
  const raw = Deno.env.get('PDF_MAX_SIZE_BYTES');
  if (!raw) return DEFAULT_MAX_PDF_BYTES;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return DEFAULT_MAX_PDF_BYTES;
  }
  return parsed;
}

function extractBearerToken(req: Request): string | null {
  const authHeader = req.headers.get('authorization') ?? req.headers.get('Authorization');
  if (!authHeader) return null;
  const match = /^Bearer\s+(.+)$/i.exec(authHeader.trim());
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

function sanitizeBasename(rawFilename: string): string | null {
  const normalized = rawFilename.replace(/[\x00-\x1f\x7f]/g, '').trim();
  if (!normalized || normalized.includes('..')) {
    return null;
  }
  const parts = normalized.split(/[\\/]/);
  const basename = (parts[parts.length - 1] ?? '').trim();
  if (!basename || basename.length > 180) {
    return null;
  }
  if (!/^[^\\/]+\.pdf$/i.test(basename) || basename.startsWith('.')) {
    return null;
  }
  return basename;
}

function isPdfWhitespace(b: number): boolean {
  return b === 0x00 || b === 0x09 || b === 0x0a || b === 0x0c || b === 0x0d || b === 0x20;
}

function isPdfDelimiter(b: number): boolean {
  return (
    b === 0x28 || // (
    b === 0x29 || // )
    b === 0x3c || // <
    b === 0x3e || // >
    b === 0x5b || // [
    b === 0x5d || // ]
    b === 0x7b || // {
    b === 0x7d || // }
    b === 0x2f || // /
    b === 0x25 // %
  );
}

function isPdfRegular(b: number): boolean {
  return !isPdfWhitespace(b) && !isPdfDelimiter(b);
}

function isAsciiDigit(b: number): boolean {
  return b >= 0x30 && b <= 0x39;
}

function isTokenBoundary(bytes: Uint8Array, pos: number, limit: number): boolean {
  return pos >= limit || isPdfWhitespace(bytes[pos]) || isPdfDelimiter(bytes[pos]);
}

function matchAsciiAt(bytes: Uint8Array, pos: number, limit: number, token: string): boolean {
  if (pos < 0 || pos + token.length > limit) {
    return false;
  }
  for (let i = 0; i < token.length; i++) {
    if (bytes[pos + i] !== token.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

function asciiSubstring(bytes: Uint8Array, start: number, end: number): string {
  let out = '';
  for (let i = start; i < end; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

function isDigitsOnlySlice(bytes: Uint8Array, start: number, end: number): boolean {
  if (start >= end) return false;
  for (let i = start; i < end; i++) {
    if (!isAsciiDigit(bytes[i])) return false;
  }
  return true;
}

function skipPdfWs(bytes: Uint8Array, pos: number, limit: number): number {
  let cursor = pos;
  while (cursor < limit && isPdfWhitespace(bytes[cursor])) {
    cursor++;
  }
  return cursor;
}

function skipPdfWsAndComments(bytes: Uint8Array, pos: number, limit: number): number {
  let cursor = pos;
  while (cursor < limit) {
    while (cursor < limit && isPdfWhitespace(bytes[cursor])) {
      cursor++;
    }
    if (cursor < limit && bytes[cursor] === 0x25) {
      cursor++;
      while (cursor < limit && bytes[cursor] !== 0x0a && bytes[cursor] !== 0x0d) {
        cursor++;
      }
      continue;
    }
    break;
  }
  return cursor;
}

function hasIndirectObjectAndEndobj(bytes: Uint8Array): boolean {
  let foundObj = false;
  let foundEndobj = false;
  const len = bytes.byteLength;

  for (let i = 8; i < len && (!foundObj || !foundEndobj); i++) {
    if (!foundObj && bytes[i] === 0x6f && matchAsciiAt(bytes, i, len, 'obj')) {
      if (isTokenBoundary(bytes, i + 3, len) && i >= 4 && isPdfWhitespace(bytes[i - 1])) {
        let p = i - 1;
        while (p > 8 && isPdfWhitespace(bytes[p - 1])) p--;
        const genEnd = p;
        while (p > 8 && isAsciiDigit(bytes[p - 1])) p--;
        const genStart = p;
        if (genStart < genEnd && p > 8 && isPdfWhitespace(bytes[p - 1])) {
          while (p > 8 && isPdfWhitespace(bytes[p - 1])) p--;
          const objEnd = p;
          while (p > 8 && isAsciiDigit(bytes[p - 1])) p--;
          const objStart = p;
          if (objStart < objEnd && (objStart === 8 || isPdfWhitespace(bytes[objStart - 1]) || isPdfDelimiter(bytes[objStart - 1]))) {
            foundObj = true;
          }
        }
      }
    }
    if (!foundEndobj && bytes[i] === 0x65 && matchAsciiAt(bytes, i, len, 'endobj')) {
      const leftOk = i === 8 || isPdfWhitespace(bytes[i - 1]) || isPdfDelimiter(bytes[i - 1]);
      if (leftOk && isTokenBoundary(bytes, i + 6, len)) {
        foundEndobj = true;
      }
    }
  }

  return foundObj && foundEndobj;
}

function findLastStartxref(
  bytes: Uint8Array,
): { status: 'ok'; startxrefAbsolutePos: number; xrefOffset: number } | { status: 'invalid_offset' } | null {
  const tailStart = Math.max(0, bytes.byteLength - 2048);
  let p = bytes.byteLength;
  while (p > tailStart && bytes[p - 1] <= 0x20) {
    p--;
  }

  const eofPos = p - 5;
  if (eofPos < tailStart || !matchAsciiAt(bytes, eofPos, p, '%%EOF')) {
    return null;
  }

  let wsBeforeEof = eofPos;
  while (wsBeforeEof > tailStart && isPdfWhitespace(bytes[wsBeforeEof - 1])) {
    wsBeforeEof--;
  }
  if (wsBeforeEof === eofPos) {
    return null;
  }

  const digitsEnd = wsBeforeEof;
  let digitsStart = digitsEnd;
  while (digitsStart > tailStart && isAsciiDigit(bytes[digitsStart - 1])) {
    digitsStart--;
  }
  if (digitsStart === digitsEnd) {
    return null;
  }
  if (digitsEnd - digitsStart > 15) {
    return { status: 'invalid_offset' };
  }

  let wsBeforeDigits = digitsStart;
  while (wsBeforeDigits > tailStart && isPdfWhitespace(bytes[wsBeforeDigits - 1])) {
    wsBeforeDigits--;
  }
  if (wsBeforeDigits === digitsStart) {
    return null;
  }

  const sxPos = wsBeforeDigits - 9;
  if (sxPos < tailStart || !matchAsciiAt(bytes, sxPos, wsBeforeDigits, 'startxref')) {
    return null;
  }
  if (sxPos > 0 && !isPdfWhitespace(bytes[sxPos - 1]) && !isPdfDelimiter(bytes[sxPos - 1])) {
    return null;
  }

  const xrefOffset = Number.parseInt(asciiSubstring(bytes, digitsStart, digitsEnd), 10);
  return {
    status: 'ok',
    startxrefAbsolutePos: sxPos,
    xrefOffset,
  };
}

function skipLiteralString(bytes: Uint8Array, start: number, limit: number): number {
  let depth = 1;
  let i = start + 1;
  while (i < limit && depth > 0) {
    const b = bytes[i];
    if (b === 0x5c) {
      i += 2;
      continue;
    }
    if (b === 0x28) {
      depth++;
    } else if (b === 0x29) {
      depth--;
    }
    i++;
  }
  return depth === 0 ? i : -1;
}

function skipHexString(bytes: Uint8Array, start: number, limit: number): number {
  let i = start + 1;
  while (i < limit) {
    if (bytes[i] === 0x3e) {
      return i + 1;
    }
    i++;
  }
  return -1;
}

function findMatchingDictEnd(bytes: Uint8Array, dictStart: number, limit: number): number {
  if (dictStart + 2 > limit || bytes[dictStart] !== 0x3c || bytes[dictStart + 1] !== 0x3c) {
    return -1;
  }
  let depth = 1;
  let i = dictStart + 2;
  while (i < limit) {
    const b = bytes[i];
    if (b === 0x25) {
      i++;
      while (i < limit && bytes[i] !== 0x0a && bytes[i] !== 0x0d) i++;
      continue;
    }
    if (b === 0x28) {
      i = skipLiteralString(bytes, i, limit);
      if (i < 0) return -1;
      continue;
    }
    if (b === 0x3c) {
      if (i + 1 < limit && bytes[i + 1] === 0x3c) {
        depth++;
        i += 2;
        continue;
      }
      i = skipHexString(bytes, i, limit);
      if (i < 0) return -1;
      continue;
    }
    if (b === 0x3e && i + 1 < limit && bytes[i + 1] === 0x3e) {
      depth--;
      i += 2;
      if (depth === 0) {
        return i;
      }
      continue;
    }
    i++;
  }
  return -1;
}

function skipArray(bytes: Uint8Array, start: number, limit: number): number {
  let depth = 1;
  let i = start + 1;
  while (i < limit && depth > 0) {
    const b = bytes[i];
    if (b === 0x25) {
      i++;
      while (i < limit && bytes[i] !== 0x0a && bytes[i] !== 0x0d) i++;
      continue;
    }
    if (b === 0x28) {
      i = skipLiteralString(bytes, i, limit);
      if (i < 0) return -1;
      continue;
    }
    if (b === 0x3c) {
      if (i + 1 < limit && bytes[i + 1] === 0x3c) {
        i = findMatchingDictEnd(bytes, i, limit);
        if (i < 0) return -1;
        continue;
      }
      i = skipHexString(bytes, i, limit);
      if (i < 0) return -1;
      continue;
    }
    if (b === 0x5b) {
      depth++;
    } else if (b === 0x5d) {
      depth--;
    }
    i++;
  }
  return depth === 0 ? i : -1;
}

function readRegularTokenBounds(
  bytes: Uint8Array,
  pos: number,
  limit: number,
): { start: number; end: number } | null {
  const start = skipPdfWsAndComments(bytes, pos, limit);
  if (start >= limit || !isPdfRegular(bytes[start])) {
    return null;
  }
  let end = start;
  while (end < limit && isPdfRegular(bytes[end])) {
    end++;
  }
  return { start, end };
}

interface ParsedTrailerDict {
  typeName: string | null;
  size: number | null;
  hasRootRef: boolean;
  lengthKind: 'missing' | 'direct' | 'indirect' | 'invalid' | 'duplicate';
  lengthValue: number | null;
}

function parseTrailerDictionary(bytes: Uint8Array, dictStart: number, dictEnd: number): ParsedTrailerDict | null {
  const bodyEnd = dictEnd - 2;
  let cursor = dictStart + 2;
  let typeName: string | null = null;
  let size: number | null = null;
  let hasRootRef = false;
  let lengthKind: ParsedTrailerDict['lengthKind'] = 'missing';
  let lengthValue: number | null = null;

  while (true) {
    cursor = skipPdfWsAndComments(bytes, cursor, bodyEnd);
    if (cursor >= bodyEnd) break;

    if (bytes[cursor] !== 0x2f) {
      return null;
    }
    const keyStart = cursor + 1;
    let keyEnd = keyStart;
    while (keyEnd < bodyEnd && isPdfRegular(bytes[keyEnd])) {
      keyEnd++;
    }
    if (keyEnd === keyStart) {
      return null;
    }
    const key = asciiSubstring(bytes, keyStart, keyEnd);
    cursor = skipPdfWsAndComments(bytes, keyEnd, bodyEnd);
    if (cursor >= bodyEnd) {
      return null;
    }

    const valStartByte = bytes[cursor];
    if (valStartByte === 0x3c) {
      if (cursor + 1 < bodyEnd && bytes[cursor + 1] === 0x3c) {
        const nestedEnd = findMatchingDictEnd(bytes, cursor, bodyEnd);
        if (nestedEnd < 0) return null;
        cursor = nestedEnd;
      } else {
        const hexEnd = skipHexString(bytes, cursor, bodyEnd);
        if (hexEnd < 0) return null;
        cursor = hexEnd;
      }
      if (key === 'Length') {
        lengthKind = lengthKind === 'missing' ? 'invalid' : 'duplicate';
      }
      continue;
    }

    if (valStartByte === 0x5b) {
      const arrEnd = skipArray(bytes, cursor, bodyEnd);
      if (arrEnd < 0) return null;
      cursor = arrEnd;
      if (key === 'Length') {
        lengthKind = lengthKind === 'missing' ? 'invalid' : 'duplicate';
      }
      continue;
    }

    if (valStartByte === 0x28) {
      const strEnd = skipLiteralString(bytes, cursor, bodyEnd);
      if (strEnd < 0) return null;
      cursor = strEnd;
      if (key === 'Length') {
        lengthKind = lengthKind === 'missing' ? 'invalid' : 'duplicate';
      }
      continue;
    }

    if (valStartByte === 0x2f) {
      const nameStart = cursor + 1;
      let nameEnd = nameStart;
      while (nameEnd < bodyEnd && isPdfRegular(bytes[nameEnd])) {
        nameEnd++;
      }
      if (nameEnd === nameStart) return null;
      const valName = asciiSubstring(bytes, nameStart, nameEnd);
      if (key === 'Type') {
        typeName = valName;
      } else if (key === 'Length') {
        lengthKind = lengthKind === 'missing' ? 'invalid' : 'duplicate';
      }
      cursor = nameEnd;
      continue;
    }

    if (!isPdfRegular(valStartByte)) {
      return null;
    }

    let tok1End = cursor;
    while (tok1End < bodyEnd && isPdfRegular(bytes[tok1End])) {
      tok1End++;
    }
    const tok1IsDigits = isDigitsOnlySlice(bytes, cursor, tok1End);
    let isIndirectRef = false;
    let nextCursor = tok1End;

    if (tok1IsDigits) {
      const tok2 = readRegularTokenBounds(bytes, tok1End, bodyEnd);
      if (tok2 && isDigitsOnlySlice(bytes, tok2.start, tok2.end)) {
        const tok3 = readRegularTokenBounds(bytes, tok2.end, bodyEnd);
        if (tok3 && tok3.end - tok3.start === 1 && bytes[tok3.start] === 0x52) {
          isIndirectRef = true;
          nextCursor = tok3.end;
        }
      }
    }

    if (key === 'Root' && isIndirectRef) {
      hasRootRef = true;
    } else if (key === 'Size' && !isIndirectRef && tok1IsDigits && tok1End - cursor <= 12) {
      const parsedSize = Number.parseInt(asciiSubstring(bytes, cursor, tok1End), 10);
      if (Number.isSafeInteger(parsedSize) && parsedSize >= 1) {
        size = parsedSize;
      }
    } else if (key === 'Length') {
      if (lengthKind !== 'missing') {
        lengthKind = 'duplicate';
      } else if (isIndirectRef) {
        lengthKind = 'indirect';
      } else if (tok1IsDigits && tok1End - cursor <= 12) {
        const parsedLength = Number.parseInt(asciiSubstring(bytes, cursor, tok1End), 10);
        if (Number.isSafeInteger(parsedLength)) {
          lengthKind = 'direct';
          lengthValue = parsedLength;
        } else {
          lengthKind = 'invalid';
        }
      } else {
        lengthKind = 'invalid';
      }
    }

    cursor = nextCursor;
  }

  return {
    typeName,
    size,
    hasRootRef,
    lengthKind,
    lengthValue,
  };
}

function validateClassicXrefTable(
  bytes: Uint8Array,
  xrefOffset: number,
  startxrefAbsolutePos: number,
): boolean {
  const start = skipPdfWs(bytes, xrefOffset, startxrefAbsolutePos);
  if (!matchAsciiAt(bytes, start, startxrefAbsolutePos, 'xref')) {
    return false;
  }
  if (start + 4 >= startxrefAbsolutePos || !isPdfWhitespace(bytes[start + 4])) {
    return false;
  }

  let cursor = skipPdfWsAndComments(bytes, start + 4, startxrefAbsolutePos);
  let trailerPos = -1;
  while (cursor < startxrefAbsolutePos) {
    const b = bytes[cursor];
    if (b === 0x25) {
      cursor++;
      while (cursor < startxrefAbsolutePos && bytes[cursor] !== 0x0a && bytes[cursor] !== 0x0d) {
        cursor++;
      }
      continue;
    }
    if (
      b === 0x74 &&
      matchAsciiAt(bytes, cursor, startxrefAbsolutePos, 'trailer') &&
      (cursor === start + 4 || isPdfWhitespace(bytes[cursor - 1]) || isPdfDelimiter(bytes[cursor - 1])) &&
      isTokenBoundary(bytes, cursor + 7, startxrefAbsolutePos)
    ) {
      trailerPos = cursor;
      break;
    }
    cursor++;
  }
  if (trailerPos < 0) {
    return false;
  }

  const dictStart = skipPdfWsAndComments(bytes, trailerPos + 7, startxrefAbsolutePos);
  const dictEnd = findMatchingDictEnd(bytes, dictStart, startxrefAbsolutePos);
  if (dictEnd < 0) {
    return false;
  }

  const parsedDict = parseTrailerDictionary(bytes, dictStart, dictEnd);
  return parsedDict !== null && parsedDict.size !== null && parsedDict.hasRootRef;
}

function validateXrefStreamObject(
  bytes: Uint8Array,
  xrefOffset: number,
  startxrefAbsolutePos: number,
): { valid: true } | { valid: false; message: string } {
  // 1. Offset deve iniciar um objeto indireto PDF (<objNum> <genNum> obj)
  let cursor = skipPdfWs(bytes, xrefOffset, startxrefAbsolutePos);
  const objNumStart = cursor;
  while (cursor < startxrefAbsolutePos && isAsciiDigit(bytes[cursor])) {
    cursor++;
  }
  if (cursor === objNumStart || cursor - objNumStart > 12) {
    return {
      valid: false,
      message: 'A tabela ou stream de referências cruzadas indicada por startxref é inválida ou está truncada.',
    };
  }
  const objNum = Number.parseInt(asciiSubstring(bytes, objNumStart, cursor), 10);
  if (!Number.isSafeInteger(objNum) || objNum <= 0) {
    return {
      valid: false,
      message: 'O número do objeto de Cross-Reference Stream é inválido.',
    };
  }

  const afterObjNum = skipPdfWs(bytes, cursor, startxrefAbsolutePos);
  if (afterObjNum === cursor) {
    return {
      valid: false,
      message: 'Objeto de Cross-Reference Stream malformado.',
    };
  }

  cursor = afterObjNum;
  const genStart = cursor;
  while (cursor < startxrefAbsolutePos && isAsciiDigit(bytes[cursor])) {
    cursor++;
  }
  if (cursor === genStart || cursor - genStart > 6) {
    return {
      valid: false,
      message: 'Número de geração do objeto de Cross-Reference Stream inválido.',
    };
  }

  const afterGen = skipPdfWs(bytes, cursor, startxrefAbsolutePos);
  if (afterGen === cursor || !matchAsciiAt(bytes, afterGen, startxrefAbsolutePos, 'obj')) {
    return {
      valid: false,
      message: 'Cabeçalho obj do Cross-Reference Stream ausente.',
    };
  }
  if (!isTokenBoundary(bytes, afterGen + 3, startxrefAbsolutePos)) {
    return {
      valid: false,
      message: 'Delimitador ausente após obj do Cross-Reference Stream.',
    };
  }

  // 2. Dicionário obrigatório << ... >> com /Type /XRef, /Size, /Root e /Length inteiro direto
  const dictStart = skipPdfWsAndComments(bytes, afterGen + 3, startxrefAbsolutePos);
  const dictEnd = findMatchingDictEnd(bytes, dictStart, startxrefAbsolutePos);
  if (dictEnd < 0) {
    return {
      valid: false,
      message: 'Dicionário do Cross-Reference Stream inválido ou truncado.',
    };
  }

  const dict = parseTrailerDictionary(bytes, dictStart, dictEnd);
  if (!dict || dict.typeName !== 'XRef' || dict.size === null || !dict.hasRootRef) {
    return {
      valid: false,
      message: 'O objeto apontado por startxref não possui dicionário /Type /XRef válido.',
    };
  }

  // Limite documentado da validação mínima: comprimentos indiretos ou não inteiros não são suportados em XRef stream
  if (dict.lengthKind !== 'direct' || dict.lengthValue === null || dict.lengthValue <= 0) {
    return {
      valid: false,
      message:
        'O Cross-Reference Stream deve declarar /Length numérico direto positivo compatível com o arquivo.',
    };
  }

  // 3. Token 'stream' logo após o dicionário (antes de startxref)
  const streamTokenPos = skipPdfWsAndComments(bytes, dictEnd, startxrefAbsolutePos);
  if (
    !matchAsciiAt(bytes, streamTokenPos, startxrefAbsolutePos, 'stream') ||
    !isTokenBoundary(bytes, streamTokenPos + 6, startxrefAbsolutePos)
  ) {
    return {
      valid: false,
      message: 'O objeto /Type /XRef não contém o token stream correspondente.',
    };
  }

  // 4. Início real dos bytes do stream: exatamente CRLF (\r\n) ou LF (\n) após 'stream' (ISO 32000-1)
  const afterStreamKeyword = streamTokenPos + 6;
  let streamDataStart = -1;
  if (
    afterStreamKeyword + 1 < startxrefAbsolutePos &&
    bytes[afterStreamKeyword] === 0x0d &&
    bytes[afterStreamKeyword + 1] === 0x0a
  ) {
    streamDataStart = afterStreamKeyword + 2;
  } else if (afterStreamKeyword < startxrefAbsolutePos && bytes[afterStreamKeyword] === 0x0a) {
    streamDataStart = afterStreamKeyword + 1;
  }

  if (streamDataStart < 0 || streamDataStart >= startxrefAbsolutePos) {
    return {
      valid: false,
      message: 'Quebra de linha obrigatória ausente após o marcador stream do Cross-Reference Stream.',
    };
  }

  // 5 & 6. Os bytes declarados em /Length precisam caber estritamente no arquivo e antes de startxref
  const streamDataEnd = streamDataStart + dict.lengthValue;
  if (!Number.isSafeInteger(streamDataEnd) || streamDataEnd > startxrefAbsolutePos || streamDataEnd > bytes.byteLength) {
    return {
      valid: false,
      message: 'O stream do Cross-Reference Stream está incompleto ou excede os limites do arquivo.',
    };
  }

  // 7. Delimitador 'endstream' exatamente após streamDataStart + /Length (admitindo no máximo um marcador EOL antes dele)
  let endstreamPos = -1;
  for (const eolLen of [0, 2, 1]) {
    const candidate = streamDataEnd + eolLen;
    if (candidate + 9 > startxrefAbsolutePos) continue;
    if (eolLen === 2 && (bytes[streamDataEnd] !== 0x0d || bytes[streamDataEnd + 1] !== 0x0a)) continue;
    if (eolLen === 1 && bytes[streamDataEnd] !== 0x0a && bytes[streamDataEnd] !== 0x0d) continue;
    if (
      matchAsciiAt(bytes, candidate, startxrefAbsolutePos, 'endstream') &&
      isTokenBoundary(bytes, candidate + 9, startxrefAbsolutePos)
    ) {
      endstreamPos = candidate;
      break;
    }
  }

  if (endstreamPos < 0) {
    return {
      valid: false,
      message:
        'Delimitador endstream ausente ou em posição incompatível com /Length no Cross-Reference Stream.',
    };
  }

  // 8. Encerramento coerente do objeto ('endobj') sem tokens extras antes de startxref
  const endobjPos = skipPdfWsAndComments(bytes, endstreamPos + 9, startxrefAbsolutePos);
  if (
    !matchAsciiAt(bytes, endobjPos, startxrefAbsolutePos, 'endobj') ||
    !isTokenBoundary(bytes, endobjPos + 6, startxrefAbsolutePos)
  ) {
    return {
      valid: false,
      message: 'Encerramento endobj ausente no objeto de Cross-Reference Stream.',
    };
  }

  const trailingAfterEndobj = skipPdfWsAndComments(bytes, endobjPos + 6, startxrefAbsolutePos);
  if (trailingAfterEndobj !== startxrefAbsolutePos) {
    return {
      valid: false,
      message: 'Estrutura inválida entre endobj do Cross-Reference Stream e startxref.',
    };
  }

  return { valid: true };
}

function validatePdfBytes(bytes: Uint8Array, maxBytes: number): { code: string; message: string } | null {
  if (bytes.byteLength === 0) {
    return {
      code: 'empty_file',
      message: 'O arquivo PDF enviado está vazio.',
    };
  }
  if (bytes.byteLength > maxBytes) {
    return {
      code: 'file_too_large',
      message: `O arquivo PDF excede o limite máximo permitido (${maxBytes} bytes).`,
    };
  }
  if (bytes.byteLength < MIN_PDF_BYTES) {
    return {
      code: 'corrupted_or_truncated_pdf',
      message: 'O arquivo enviado não possui estrutura mínima válida de PDF.',
    };
  }

  // Assinatura %PDF-1.x ou %PDF-2.x exatamente no início do arquivo
  if (
    bytes[0] !== 0x25 || // %
    bytes[1] !== 0x50 || // P
    bytes[2] !== 0x44 || // D
    bytes[3] !== 0x46 || // F
    bytes[4] !== 0x2d || // -
    (bytes[5] !== 0x31 && bytes[5] !== 0x32) || // 1 ou 2
    bytes[6] !== 0x2e || // .
    bytes[7] < 0x30 ||
    bytes[7] > 0x39
  ) {
    return {
      code: 'invalid_pdf_signature',
      message: 'Os bytes do arquivo não correspondem a um documento PDF válido (%PDF-).',
    };
  }

  if (!hasIndirectObjectAndEndobj(bytes)) {
    return {
      code: 'invalid_pdf_structure',
      message: 'O arquivo enviado não contém objetos PDF válidos.',
    };
  }

  const tailStartxref = findLastStartxref(bytes);
  if (!tailStartxref) {
    return {
      code: 'truncated_or_corrupted_pdf',
      message: 'O arquivo PDF está truncado ou sem terminador startxref/%%EOF válido.',
    };
  }
  if (tailStartxref.status === 'invalid_offset') {
    return {
      code: 'truncated_or_corrupted_pdf',
      message: 'O offset startxref do PDF é inválido para o tamanho do arquivo.',
    };
  }

  const { xrefOffset, startxrefAbsolutePos } = tailStartxref;
  if (
    !Number.isSafeInteger(xrefOffset) ||
    xrefOffset < 8 ||
    xrefOffset >= startxrefAbsolutePos
  ) {
    return {
      code: 'truncated_or_corrupted_pdf',
      message: 'O offset startxref do PDF está fora dos limites do arquivo.',
    };
  }

  // Aceita tabela clássica (xref + trailer) ou Cross-Reference Stream PDF 1.5+ validado em offsets de bytes
  if (validateClassicXrefTable(bytes, xrefOffset, startxrefAbsolutePos)) {
    return null;
  }

  const xrefStreamCheck = validateXrefStreamObject(bytes, xrefOffset, startxrefAbsolutePos);
  if (xrefStreamCheck.valid) {
    return null;
  }

  return {
    code: 'truncated_or_corrupted_pdf',
    message: xrefStreamCheck.message,
  };
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource);
  const view = new Uint8Array(digest);
  let hex = '';
  for (let i = 0; i < view.length; i++) {
    hex += view[i].toString(16).padStart(2, '0');
  }
  return hex;
}

function parseRpcError(payload: unknown): { code: string; message: string } {
  const rawMessage =
    typeof payload === 'object' && payload !== null && 'message' in payload
      ? String((payload as { message?: unknown }).message ?? '')
      : '';

  const tagMatch = /^\[ERR:([a-z0-9_]+)\]\s*(.*)$/i.exec(rawMessage);
  if (tagMatch) {
    return {
      code: tagMatch[1],
      message: tagMatch[2] || 'Erro ao processar submissão documental.',
    };
  }

  const pgCode =
    typeof payload === 'object' && payload !== null && 'code' in payload
      ? String((payload as { code?: unknown }).code ?? '')
      : '';

  return {
    code: pgCode || 'submission_backend_error',
    message: rawMessage || 'Falha interna ao processar submissão documental.',
  };
}

function mapBackendCodeToHttpStatus(code: string): number {
  switch (code) {
    case 'invalid_input':
    case 'empty_file':
    case 'invalid_checksum':
    case 'invalid_filename':
    case 'storage_mime_mismatch':
    case 'storage_size_mismatch':
      return 400;
    case 'file_too_large':
      return 413;
    case 'forbidden_role':
    case 'forbidden_owner':
    case 'unauthorized_backend_caller':
    case 'process_cancelled':
      return 403;
    case 'requirement_not_found':
    case 'intent_not_found':
    case 'submission_not_found':
    case 'storage_object_missing':
      return 404;
    case 'requirement_status_conflict':
    case 'idempotency_mismatch':
    case 'submission_in_progress':
    case 'version_conflict':
    case 'intent_invalid_state':
    case 'lease_lost':
      return 409;
    default:
      return 500;
  }
}

async function verifyAuthenticatedUser(
  supabaseUrl: string,
  anonKey: string,
  bearerToken: string,
): Promise<{ ok: true; userId: string } | { ok: false; status: number; code: string; message: string }> {
  const res = await fetch(`${supabaseUrl}/auth/v1/user`, {
    method: 'GET',
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${bearerToken}`,
    },
  });

  if (!res.ok) {
    return {
      ok: false,
      status: 401,
      code: 'invalid_or_expired_session',
      message: 'Sessão ausente, inválida ou expirada.',
    };
  }

  const user = (await res.json()) as { id?: unknown };
  if (typeof user?.id !== 'string' || !UUID_REGEX.test(user.id)) {
    return {
      ok: false,
      status: 401,
      code: 'invalid_user_identity',
      message: 'Identidade autenticada inválida.',
    };
  }

  return { ok: true, userId: user.id };
}

async function callBackendRpc<T>(
  supabaseUrl: string,
  serviceRoleKey: string,
  rpcName: string,
  params: Record<string, unknown>,
): Promise<{ ok: true; data: T } | { ok: false; error: { code: string; message: string } }> {
  const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${rpcName}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify(params),
  });

  const text = await res.text();
  let parsed: unknown = null;
  if (text.length > 0) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = { message: text };
    }
  }

  if (!res.ok) {
    return {
      ok: false,
      error: parseRpcError(parsed),
    };
  }

  return {
    ok: true,
    data: parsed as T,
  };
}

function encodeStorageObjectPath(storagePath: string): string {
  return storagePath
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
}

async function uploadPdfToPrivateStorage(
  supabaseUrl: string,
  serviceRoleKey: string,
  bucket: string,
  storagePath: string,
  bytes: Uint8Array,
): Promise<{ ok: true } | { ok: false; message: string }> {
  const encodedPath = encodeStorageObjectPath(storagePath);
  const res = await fetch(`${supabaseUrl}/storage/v1/object/${encodeURIComponent(bucket)}/${encodedPath}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/pdf',
      'x-upsert': 'false',
      'cache-control': 'private, max-age=0, no-store',
    },
    body: bytes as unknown as BodyInit,
  });

  if (!res.ok) {
    const errText = await res.text().catch(() => '');
    return {
      ok: false,
      message: `Falha no envio ao bucket privado (HTTP ${res.status}): ${errText.slice(0, 180)}`,
    };
  }

  await res.body?.cancel();
  return { ok: true };
}

async function removeStorageObjectFromPrivateBucket(
  supabaseUrl: string,
  serviceRoleKey: string,
  bucket: string,
  storagePath: string,
): Promise<boolean> {
  const res = await fetch(`${supabaseUrl}/storage/v1/object/${encodeURIComponent(bucket)}`, {
    method: 'DELETE',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ prefixes: [storagePath] }),
  });

  await res.body?.cancel();
  return res.ok;
}

async function cleanupOrphanIfSafe(
  supabaseUrl: string,
  serviceRoleKey: string,
  intentId: string,
  errorCode: string,
  errorDetail: string,
): Promise<void> {
  const prep = await callBackendRpc<{
    safe_to_delete?: boolean;
    storage_bucket?: string;
    storage_path?: string;
  }>(supabaseUrl, serviceRoleKey, 'prepare_submission_orphan_cleanup', {
    p_intent_id: intentId,
    p_error_code: errorCode,
    p_error_detail: errorDetail.slice(0, 500),
  });

  if (!prep.ok || !prep.data?.safe_to_delete || !prep.data.storage_path || !prep.data.storage_bucket) {
    return;
  }

  const deleted = await removeStorageObjectFromPrivateBucket(
    supabaseUrl,
    serviceRoleKey,
    prep.data.storage_bucket,
    prep.data.storage_path,
  );

  if (deleted) {
    await callBackendRpc(supabaseUrl, serviceRoleKey, 'compensate_document_submission_intent', {
      p_intent_id: intentId,
      p_outcome_status: 'orphan_cleaned',
      p_error_code: errorCode,
      p_error_detail: errorDetail.slice(0, 500),
    });
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return errorResponse(405, 'method_not_allowed', 'Método HTTP não permitido.');
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return errorResponse(500, 'server_configuration_error', 'Configuração do servidor incompleta.');
  }

  // 1. Autenticação obrigatória via GoTrue (rejeita anônimos, JWT expirado/inválido ou sessão revogada)
  const bearerToken = extractBearerToken(req);
  if (!bearerToken) {
    return errorResponse(401, 'missing_authorization', 'Token de autenticação obrigatório.');
  }

  const authCheck = await verifyAuthenticatedUser(supabaseUrl, anonKey, bearerToken);
  if (!authCheck.ok) {
    return errorResponse(authCheck.status, authCheck.code, authCheck.message);
  }
  const actorId = authCheck.userId;

  // 2. Parse multipart/form-data
  const contentType = (req.headers.get('content-type') ?? '').toLowerCase();
  if (!contentType.includes('multipart/form-data')) {
    return errorResponse(
      415,
      'invalid_content_type',
      'Envie o documento utilizando multipart/form-data.',
    );
  }

  let formData: FormData;
  try {
    formData = await req.formData();
  } catch {
    return errorResponse(400, 'invalid_multipart_payload', 'Payload multipart inválido ou truncado.');
  }

  const rawRequirementId = formData.get('process_requirement_id');
  if (typeof rawRequirementId !== 'string' || !UUID_REGEX.test(rawRequirementId.trim())) {
    return errorResponse(
      400,
      'invalid_process_requirement_id',
      'Identificador process_requirement_id inválido ou ausente.',
    );
  }
  const processRequirementId = rawRequirementId.trim();

  const rawIdempotencyKey =
    formData.get('idempotency_key') ?? req.headers.get('x-idempotency-key');
  let idempotencyKey: string | null = null;
  if (rawIdempotencyKey !== null && rawIdempotencyKey !== '') {
    if (typeof rawIdempotencyKey !== 'string' || !UUID_REGEX.test(rawIdempotencyKey.trim())) {
      return errorResponse(
        400,
        'invalid_idempotency_key',
        'A chave de idempotência deve ser um UUID válido.',
      );
    }
    idempotencyKey = rawIdempotencyKey.trim();
  }

  const fileEntry = formData.get('file');
  if (!(fileEntry instanceof File)) {
    return errorResponse(400, 'missing_pdf_file', 'Arquivo PDF obrigatório no campo file.');
  }

  const sanitizedFilename = sanitizeBasename(fileEntry.name || '');
  if (!sanitizedFilename) {
    return errorResponse(
      400,
      'invalid_file_extension',
      'Nome de arquivo inválido; apenas documentos .pdf são aceitos.',
    );
  }

  const declaredMime = (fileEntry.type || '').split(';')[0].trim().toLowerCase();
  if (declaredMime !== 'application/pdf') {
    return errorResponse(
      415,
      'unsupported_media_type',
      'Apenas o tipo MIME application/pdf é aceito.',
    );
  }

  const maxPdfBytes = getMaxPdfBytes();
  if (fileEntry.size === 0) {
    return errorResponse(400, 'empty_file', 'O arquivo PDF enviado está vazio.');
  }
  if (fileEntry.size > maxPdfBytes) {
    return errorResponse(
      413,
      'file_too_large',
      `O arquivo PDF excede o limite máximo permitido (${maxPdfBytes} bytes).`,
    );
  }

  // 3. Leitura e validação binária estrita antes de qualquer gravação
  const fileBytes = new Uint8Array(await fileEntry.arrayBuffer());
  const validationError = validatePdfBytes(fileBytes, maxPdfBytes);
  if (validationError) {
    const status = validationError.code === 'file_too_large'
      ? 413
      : validationError.code === 'empty_file'
      ? 400
      : 422;
    return errorResponse(status, validationError.code, validationError.message);
  }

  const checksum = await sha256Hex(fileBytes);

  // 4. Preparação transacional + verificação de posse/estado/idempotência + geração de path opaco
  const prepareResult = await callBackendRpc<PrepareResult>(
    supabaseUrl,
    serviceRoleKey,
    'prepare_document_submission',
    {
      p_actor_id: actorId,
      p_process_requirement_id: processRequirementId,
      p_idempotency_key: idempotencyKey,
      p_original_filename: sanitizedFilename,
      p_size_bytes: fileBytes.byteLength,
      p_sha256_checksum: checksum,
      p_max_size_bytes: maxPdfBytes,
    },
  );

  if (!prepareResult.ok) {
    return errorResponse(
      mapBackendCodeToHttpStatus(prepareResult.error.code),
      prepareResult.error.code,
      prepareResult.error.message,
    );
  }

  if (prepareResult.data.outcome === 'already_committed') {
    return jsonResponse(200, {
      ok: true,
      idempotent_replay: true,
      submission: prepareResult.data.submission,
      requirement: prepareResult.data.requirement,
    });
  }

  const intent = prepareResult.data;
  let committed = false;

  const releaseAttempt = async (code: string, detail: string): Promise<void> => {
    try {
      await callBackendRpc(supabaseUrl, serviceRoleKey, 'release_document_submission_attempt', {
        p_intent_id: intent.intent_id,
        p_lease_token: intent.lease_token,
        p_error_code: code,
        p_error_detail: detail.slice(0, 500),
      });
    } catch {
      // Melhor esforço: se falhar liberação, o lease expira automaticamente no banco.
    }
  };

  const onClientAbort = () => {
    if (!committed) {
      void releaseAttempt('client_request_aborted', 'Conexão HTTP encerrada antes da confirmação.');
    }
  };
  req.signal?.addEventListener('abort', onClientAbort, { once: true });

  try {
    // 5. Upload para o bucket privado somente quando ainda não existe objeto íntegro da intenção retomada
    if (intent.outcome === 'ready_to_upload') {
      let uploadResult: { ok: true } | { ok: false; message: string };
      try {
        uploadResult = await uploadPdfToPrivateStorage(
          supabaseUrl,
          serviceRoleKey,
          intent.storage_bucket || BUCKET_NAME,
          intent.storage_path,
          fileBytes,
        );
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Exceção de transporte ao gravar PDF.';
        await releaseAttempt('storage_upload_transport_error', message);
        return errorResponse(
          502,
          'storage_upload_failed',
          'Falha de transporte ao enviar o PDF para o armazenamento privado.',
        );
      }

      if (!uploadResult.ok) {
        await releaseAttempt('storage_upload_failed', uploadResult.message);
        return errorResponse(
          502,
          'storage_upload_failed',
          'Não foi possível armazenar o PDF no bucket privado.',
        );
      }
    }

    // 6. Finalização atômica no PostgreSQL com verificação real de storage.objects, lease e anti-TOCTOU
    let finalizeResult:
      | {
          ok: true;
          data: {
            outcome: 'committed' | 'already_committed';
            submission: Record<string, unknown>;
            requirement: Record<string, unknown>;
          };
        }
      | { ok: false; error: { code: string; message: string } };

    try {
      finalizeResult = await callBackendRpc<{
        outcome: 'committed' | 'already_committed';
        submission: Record<string, unknown>;
        requirement: Record<string, unknown>;
      }>(supabaseUrl, serviceRoleKey, 'finalize_document_submission', {
        p_actor_id: actorId,
        p_intent_id: intent.intent_id,
        p_lease_token: intent.lease_token,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Exceção de transporte ao finalizar submissão.';
      await releaseAttempt('finalize_transport_error', message);
      return errorResponse(
        503,
        'finalize_transport_error',
        'Conexão interrompida ao confirmar a submissão no servidor. Tente novamente.',
      );
    }

    if (!finalizeResult.ok) {
      if (finalizeResult.error.code !== 'lease_lost') {
        await cleanupOrphanIfSafe(
          supabaseUrl,
          serviceRoleKey,
          intent.intent_id,
          finalizeResult.error.code,
          finalizeResult.error.message,
        );
      }

      return errorResponse(
        mapBackendCodeToHttpStatus(finalizeResult.error.code),
        finalizeResult.error.code,
        finalizeResult.error.message,
      );
    }

    committed = true;
    console.info(
      JSON.stringify({
        event: 'document_submission_committed',
        process_requirement_id: processRequirementId,
        intent_id: intent.intent_id,
        version: intent.target_version,
      }),
    );

    return jsonResponse(finalizeResult.data.outcome === 'already_committed' ? 200 : 201, {
      ok: true,
      idempotent_replay: finalizeResult.data.outcome === 'already_committed',
      submission: finalizeResult.data.submission,
      requirement: finalizeResult.data.requirement,
    });
  } finally {
    req.signal?.removeEventListener('abort', onClientAbort);
  }
});
