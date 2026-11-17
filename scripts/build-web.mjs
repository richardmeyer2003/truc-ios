import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const destination = process.argv[2];
if (!destination) throw Error('Usage: node scripts/build-web.mjs <TURC Sites dist directory>');
const root = fileURLToPath(new URL('../', import.meta.url));
const dist = path.resolve(destination);
const assets = path.join(dist, 'mobile-assets');
const styles = ['style.css', 'glass.css', 'club.css', 'native.css', 'scanner.css'];
const scripts = ['roster-csv.js', 'progress.js', 'club.js'];
const sharedAssets = [
  'app-icon.png', 'club-config.js', 'vendor/supabase-2.119.0.js', 'vendor/jsqr-1.4.0.js',
  'vendor/qrcode-generator-1.4.4.js', 'vendor/pdf-lib-1.17.1.js'
];
await Promise.all(sharedAssets.map(async file => {
  try { await readFile(path.join(dist, file)); }
  catch { throw Error(`TURC Sites dist is missing ${file}`); }
}));
await mkdir(assets, { recursive: true });
await Promise.all([
  ...[...styles, ...scripts].map(file => cp(path.join(root, 'web', file), path.join(assets, file))),
  ...['appearance.css', 'appearance.js'].map(file => cp(path.join(root, 'web', file), path.join(dist, file))),
  cp(path.join(root, 'src', 'browser.css'), path.join(assets, 'browser.css')),
  build({
    entryPoints: [path.join(root, 'src', 'browser.mjs')], outfile: path.join(assets, 'browser.js'),
    bundle: true, format: 'iife', target: 'safari15', minify: true, legalComments: 'eof'
  })
]);
const browserAssets = await Promise.all(['browser.js', 'browser.css'].map(file => readFile(path.join(assets, file))));
const browserRevision = createHash('sha256').update(Buffer.concat(browserAssets)).digest('hex').slice(0, 12);
let html = await readFile(path.join(root, 'web', 'index.html'), 'utf8');
for (const file of [...styles, ...scripts]) html = html.replace(`"${file}"`, `"/mobile-assets/${file}"`);
for (const file of sharedAssets) html = html.replace(`"${file}"`, `"/${file}"`);
for (const file of ['appearance.css', 'appearance.js']) html = html.replace(`"${file}"`, `"/${file}"`);
html = html
  .replace('object-src', "media-src 'self' blob:; object-src")
  .replace('<title>Your club · TURC</title>', '<title>TURC Mobile</title>')
  .replace('<link rel="stylesheet" href="/appearance.css">', `<link rel="stylesheet" href="/mobile-assets/browser.css?v=${browserRevision}">\n  <link rel="stylesheet" href="/appearance.css">`)
  .replace('<script defer src="native.js"></script>', `<script defer src="/vendor/jsqr-1.4.0.js"></script>\n  <script defer src="/mobile-assets/browser.js?v=${browserRevision}"></script>`);
await writeFile(path.join(dist, 'mobile.html'), html);
console.log(`Built TURC Mobile → ${path.join(dist, 'mobile.html')}`);
