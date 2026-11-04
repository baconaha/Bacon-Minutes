// Bundles main, preload and renderer with esbuild into dist/.
import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');
const watch = process.argv.includes('--dev');

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });

const common = { bundle: true, sourcemap: watch ? 'inline' : false, logLevel: 'warning', legalComments: 'none' };

await Promise.all([
  build({
    ...common,
    entryPoints: [join(root, 'src/main/main.js')],
    outfile: join(dist, 'main.cjs'),
    platform: 'node',
    format: 'cjs',
    target: 'node22',
    external: ['electron'],
  }),
  build({
    ...common,
    entryPoints: [join(root, 'src/preload/preload.js')],
    outfile: join(dist, 'preload.cjs'),
    platform: 'node',
    format: 'cjs',
    target: 'node22',
    external: ['electron'],
  }),
  build({
    ...common,
    entryPoints: [join(root, 'src/renderer/main.jsx')],
    outfile: join(dist, 'renderer.js'),
    platform: 'browser',
    format: 'esm',
    target: 'chrome130',
    jsx: 'automatic',
    jsxImportSource: 'preact',
    minify: !watch,
  }),
]);

cpSync(join(root, 'src/renderer/index.html'), join(dist, 'index.html'));
cpSync(join(root, 'src/renderer/styles'), join(dist, 'styles'), { recursive: true });
cpSync(join(root, 'build/icon.png'), join(dist, 'icon.png'));
console.log('built to', dist);
