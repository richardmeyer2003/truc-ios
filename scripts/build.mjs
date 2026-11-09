import { cp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = path.join(root, 'www');
await mkdir(output, { recursive:true });
for (const entry of await readdir(path.join(root, 'web'))) {
  await cp(path.join(root, 'web', entry), path.join(output, entry), { recursive:true });
}
await build({ entryPoints:[path.join(root,'src/native.mjs')], outfile:path.join(output,'native.js'),
  bundle:true, format:'iife', target:'safari15', minify:true, legalComments:'eof' });
const config = await readFile(path.join(root,'web/club-config.js'),'utf8');
if (!config.includes('sb_publishable_') || /service_role|sb_secret_/.test(config)) {
  throw new Error('Only public Supabase configuration belongs in the app.');
}
const pkg = JSON.parse(await readFile(path.join(root,'package.json'),'utf8'));
await writeFile(path.join(output,'build-info.json'),JSON.stringify({ version:pkg.version,
  websiteBaseline:'b6b7c85ad1952e320a95080ec1c0fe48dcb4a202',
  commit:process.env.GITHUB_SHA || 'local' },null,2)+'\n');
console.log('Built TURC connected clubhouse → www');
