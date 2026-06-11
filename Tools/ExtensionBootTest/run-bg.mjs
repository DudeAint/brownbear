// /tmp/bbtest/run-bg.mjs
// Drive boot-bg.mjs across every unpacked extension under /tmp/crx, one isolated child process each
// (clean global per ext), with a hard timeout. Aggregate into a per-extension verdict table plus a
// root-cause rollup (missing chrome.* APIs and error phases across the whole set).
//
// Usage:  node run-bg.mjs [crxRoot]

import { readdirSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const CRX_ROOT = process.argv[2] || '/tmp/crx';
const BOOT = path.join(path.dirname(new URL(import.meta.url).pathname), 'boot-bg.mjs');
const TIMEOUT_MS = 25000;

function listExts() {
    const out = [];
    for (const id of readdirSync(CRX_ROOT)) {
        const dir = path.join(CRX_ROOT, id, 'unpacked');
        if (existsSync(dir) && existsSync(path.join(dir, 'manifest.json'))) { out.push({ id, dir }); }
        else { out.push({ id, dir, noManifest: true }); }
    }
    return out;
}

function bootOne({ id, dir, noManifest }) {
    return new Promise((resolve) => {
        if (noManifest) { resolve({ id, ok: false, kind: 'no-manifest', fatal: 'no unpacked/manifest.json' }); return; }
        const child = spawn(process.execPath, [BOOT, dir, id], { stdio: ['ignore', 'pipe', 'ignore'] });
        let out = '';
        const killer = setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, TIMEOUT_MS);
        child.stdout.on('data', (d) => { out += d.toString(); });
        child.on('close', (code, signal) => {
            clearTimeout(killer);
            const vline = out.split('\n').filter((l) => l.startsWith('BBVERDICT:')).pop();
            let v;
            try { v = JSON.parse(vline.slice('BBVERDICT:'.length)); } catch { v = null; }
            if (!v) { resolve({ id, ok: false, kind: signal === 'SIGKILL' ? 'timeout/hang' : 'no-verdict', fatal: `child exited code=${code} signal=${signal}; no JSON verdict` }); return; }
            resolve(v);
        });
    });
}

const exts = listExts();
process.stderr.write(`[run-bg] booting ${exts.length} extensions (timeout ${TIMEOUT_MS}ms each)\n`);

// Bounded concurrency so we don't fork 26 node processes at once on a tight machine.
const CONC = 4;
const results = [];
let idx = 0;
async function worker() {
    while (idx < exts.length) {
        const e = exts[idx++];
        process.stderr.write(`  · ${e.id} ...\n`);
        results.push(await bootOne(e));
    }
}
await Promise.all(Array.from({ length: CONC }, () => worker()));

// ---------------------------------------------------------------- report
results.sort((a, b) => (a.name || a.id).localeCompare(b.name || b.id));
const okCount = results.filter((r) => r.ok).length;
const broken = results.filter((r) => !r.ok);

console.log('\n================ BACKGROUND / SERVICE-WORKER BOOT REPORT ================\n');
for (const r of results) {
    const flag = r.ok ? '✅' : '❌';
    const head = `${flag}  ${(r.name || r.id).slice(0, 34).padEnd(34)} ${(r.kind || '?').padEnd(16)} mv${r.mv || '?'} ${r.vendor || ''}`;
    console.log(head);
    if (!r.ok) {
        if (r.fatal) { console.log(`        FATAL: ${r.fatal}`); }
        for (const e of (r.errors || [])) { console.log(`        ✗ [${e.phase}] ${e.message}`); }
        for (const u of (r.unhandled || [])) { console.log(`        ⚠ unhandledRejection: ${u}`); }
    }
    if (r.missing && r.missing.length) { console.log(`        ↪ touched-but-missing: ${r.missing.join(', ')}`); }
}

// Root-cause rollups.
const missingTally = new Map();
for (const r of results) { for (const m of (r.missing || [])) { missingTally.set(m, (missingTally.get(m) || 0) + 1); } }
const phaseTally = new Map();
for (const r of broken) { for (const e of (r.errors || [])) { const k = e.message.replace(/[0-9]+/g, 'N').slice(0, 60); phaseTally.set(k, (phaseTally.get(k) || 0) + 1); } }

console.log('\n---------------- ROOT-CAUSE ROLLUP ----------------');
console.log(`\nMissing chrome.* surface (touched by an ext, undefined in shim) — ${missingTally.size} distinct:`);
for (const [k, n] of [...missingTally.entries()].sort((a, b) => b[1] - a[1])) { console.log(`  ${String(n).padStart(2)}×  ${k}`); }
console.log(`\nBoot error signatures — ${phaseTally.size} distinct:`);
for (const [k, n] of [...phaseTally.entries()].sort((a, b) => b[1] - a[1])) { console.log(`  ${String(n).padStart(2)}×  ${k}`); }

console.log(`\n================ ${okCount}/${results.length} booted clean · ${broken.length} broken ================`);
