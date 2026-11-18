// The 3D files and the face tracker's vendor files exist once, in the app (Sources/Ensemble/Resources/web). The published site gets
// them at the paths below; this maps a published path to the app's file so the local servers can serve a docs/ without its own copy.
import { readFile } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = fileURLToPath(new URL('../../../Sources/Ensemble/Resources/web/', import.meta.url));

const LIBS = ['three.min.js', 'GLTFLoader.js', 'CCDIKSolver.js'];
const MAP = new Map([
  ...[...LIBS, 'hand.glb', 'scene3d.js'].map((f) => [`/assets/3d/${f}`, `tour/${f}`]),
  ...LIBS.map((f) => [`/live/capture3d/vendor/${f}`, `tour/${f}`]),
  ['/live/vendor/vision_bundle.js', 'vision_bundle.mjs'],
  ['/live/vendor/wasm/vision_wasm_internal.js', 'wasm/vision_wasm_internal.js'],
  ['/live/vendor/wasm/vision_wasm_internal.wasm.gz', 'wasm/vision_wasm_internal.wasm'],
]);

// The bytes for a published path, or null when the app has no such file. The wasm is gzipped here as the site's publish step does.
export async function appCopy(path) {
  const rel = MAP.get(path);
  if (!rel) return null;
  const body = await readFile(join(WEB, rel));
  return path.endsWith('.gz') ? gzipSync(body, { level: 9 }) : body;
}
