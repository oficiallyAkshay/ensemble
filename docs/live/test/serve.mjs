// A tiny static server for docs/ that sends the headers GitHub Pages sends (Cache-Control: max-age=600, no compression of .gz,
// .wasm.gz and .task.gz served as opaque bytes) and counts requests per path, so the tests can prove the demo reuses the cache.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('../../', import.meta.url)));
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.json': 'application/json', '.gz': 'application/gzip', '.svg': 'image/svg+xml' };

export async function serve(port = 0) {
  const hits = new Map();
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    let path = normalize(decodeURIComponent(url.pathname));
    if (path.endsWith('/')) path += 'index.html';
    const file = join(ROOT, path);
    if (!file.startsWith(ROOT)) { res.writeHead(403).end(); return; }
    try {
      const st = await stat(file);
      hits.set(path, (hits.get(path) || 0) + 1);
      const body = await readFile(file);
      res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream', 'Content-Length': st.size, 'Cache-Control': 'max-age=600', 'Last-Modified': st.mtime.toUTCString() });
      res.end(body);
    } catch { hits.set(path, (hits.get(path) || 0) + 1); res.writeHead(404).end('not found'); }
  });
  await new Promise((r) => server.listen(port, '127.0.0.1', r));
  return { port: server.address().port, hits, close: () => new Promise((r) => server.close(r)) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) { const s = await serve(Number(process.argv[2]) || 8791); console.log(`serving docs/ on http://127.0.0.1:${s.port}/`); }
