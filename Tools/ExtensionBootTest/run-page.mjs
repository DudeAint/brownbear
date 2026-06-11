// /tmp/bbtest/run-page.mjs
// Drive boot-page.mjs across every unpacked extension under /tmp/crx, one isolated child each, with
// a hard timeout. Aggregate a per-extension / per-page table and a rollup of missing page-shim
// chrome.* surface and page error signatures.
//
// Usage:  node run-page.mjs [crxRoot]

import { readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const CRX_ROOT = process.argv[2] || '/tmp/crx';
const BOOT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'boot-page.mjs');
const TIMEOUT_MS = 25000;

function listExts() {
    const out = [];
    for (const id of readdirSync(CRX_ROOT)) {
        const dir = path.join(CRX_ROOT, id, 'unpacked');
        if (existsSync(path.join(dir, 'manifest.json'))) { out.push({ id, dir }); }
        else { out.push({ id, dir, noManifest: true }); }
    }
    return out;
}

function bootOne({ id, dir, noManifest }) {
    return new Promise((resolve) => {
        if (noManifest) { resolve({ id, ok: false, kind: 'no-manifest' }); return; }
        const child = spawn(process.execPath, [BOOT, dir, id], { stdio: ['ignore', 'pipe', 'ignore'] });
        let out = '';
        const killer = setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, TIMEOUT_MS);
        child.stdout.on('data', (d) => { out += d.toString(); });
        child.on('close', (code, signal) => {
            clearTimeout(killer);
            const vline = out.split('\n').filter((l) => l.startsWith('BBVERDICT:')).pop();
            let v; try { v = JSON.parse(vline.slice('BBVERDICT:'.length)); } catch { v = null; }
            if (!v) { resolve({ id, ok: false, kind: signal === 'SIGKILL' ? 'timeout/hang' : 'no-verdict' }); return; }
            resolve(v);
        });
    });
}

const exts = listExts();
process.stderr.write(`[run-page] ${exts.length} extensions\n`);
const CONC = 4; const results = []; let idx = 0;
async function worker() { while (idx < exts.length) { const e = exts[idx++]; process.stderr.write(`  · ${e.id}\n`); results.push(await bootOne(e)); } }
await Promise.all(Array.from({ length: CONC }, () => worker()));

results.sort((a, b) => (a.name || a.id).localeCompare(b.name || b.id));
const withPages = results.filter((r) => r.pageCount > 0 || r.pages);
const okCount = results.filter((r) => r.ok).length;

console.log('\n================ POPUP / OPTIONS / PAGE BOOT REPORT ================\n');
for (const r of results) {
    if (r.kind === 'no-manifest') { console.log(`⏭  ${r.id.slice(0, 34)}  (no manifest — not unpacked)`); continue; }
    const flag = r.ok ? '✅' : '❌';
    console.log(`${flag}  ${(r.name || r.id).slice(0, 34).padEnd(34)} ${r.pageCount || 0} page(s) mv${r.mv || '?'} ${r.vendor || ''}`);
    for (const e of (r.loadErrors || [])) { console.log(`        ✗ [${e.phase}] ${e.message}`); }
    for (const p of (r.pages || [])) {
        if (!p.ok) { for (const er of p.errors) { console.log(`        ✗ ${p.kind} (${p.htmlRel}): ${er}`); } }
    }
    if (r.missing && r.missing.length) { console.log(`        ↪ page-shim missing: ${r.missing.join(', ')}`); }
}

const missingTally = new Map();
for (const r of results) { for (const m of (r.missing || [])) { missingTally.set(m, (missingTally.get(m) || 0) + 1); } }
const sigTally = new Map();
for (const r of results) { for (const p of (r.pages || [])) { for (const e of (p.errors || [])) { const k = e.replace(/[0-9]+/g, 'N').slice(0, 70); sigTally.set(k, (sigTally.get(k) || 0) + 1); } } }

console.log('\n---------------- ROOT-CAUSE ROLLUP ----------------');
console.log(`\nMissing page-shim chrome.* surface — ${missingTally.size} distinct:`);
for (const [k, n] of [...missingTally.entries()].sort((a, b) => b[1] - a[1])) { console.log(`  ${String(n).padStart(2)}×  ${k}`); }
console.log(`\nPage error signatures — ${sigTally.size} distinct:`);
for (const [k, n] of [...sigTally.entries()].sort((a, b) => b[1] - a[1])) { console.log(`  ${String(n).padStart(2)}×  ${k}`); }

const broken = results.filter((r) => !r.ok && r.kind !== 'no-manifest');
console.log(`\n================ ${okCount} clean · ${broken.length} with page errors · ${results.filter((r) => r.kind === 'no-manifest').length} not unpacked ================`);
