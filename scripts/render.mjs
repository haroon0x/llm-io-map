#!/usr/bin/env node
/**
 * render.mjs — embed a manifest into the self-contained viewer.
 *
 * Usage:
 *   node render.mjs [manifest] [out.html] [--template viewer.template.html]
 *
 * Defaults:
 *   manifest = <cwd>/.llmmap/manifest.json   (run from the repo root)
 *   template = viewer.template.html next to this script
 *   out      = <cwd>/.llmmap/report.html
 *
 * The template must contain exactly one marker line:
 *   const MANIFEST = /*__LLMMAP_MANIFEST__*\/null;
 * It is replaced with the manifest JSON, safely escaped for inline <script>.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MARKER = '/*__LLMMAP_MANIFEST__*/null';
const GRADES = new Set(['recorded', 'serialized', 'reconstructed', 'representative', 'unresolved']);
const REQUIRED = ['schema_version', 'repo', 'call_sites'];

function die(msg) {
  console.error(`render: ${msg}`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = { manifest: null, out: null, template: null };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--template') out.template = argv[++i];
    else if (a.startsWith('--template=')) out.template = a.slice('--template='.length);
    else if (a === '--out') out.out = argv[++i];
    else if (a.startsWith('--out=')) out.out = a.slice('--out='.length);
    else if (a === '--manifest') out.manifest = argv[++i];
    else if (a.startsWith('--manifest=')) out.manifest = a.slice('--manifest='.length);
    else if (a === '-h' || a === '--help') {
      console.log('usage: node render.mjs [manifest.json] [report.html] [--template viewer.template.html]');
      process.exit(0);
    } else positional.push(a);
  }
  if (!out.manifest) out.manifest = positional[0] ?? path.join(process.cwd(), '.llmmap', 'manifest.json');
  if (!out.out) out.out = positional[1] ?? path.join(process.cwd(), '.llmmap', 'report.html');
  if (!out.template) out.template = path.resolve(__dirname, 'viewer.template.html');
  return out;
}

const args = parseArgs(process.argv.slice(2));

if (!fs.existsSync(args.manifest)) die(`manifest not found: ${args.manifest}`);
if (!fs.existsSync(args.template)) {
  die(
    `template not found: ${args.template}\n` +
      'copy the skill\'s assets/viewer.html next to this script as viewer.template.html, or pass --template.',
  );
}

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(args.manifest, 'utf8'));
} catch (err) {
  die(`manifest is not valid JSON: ${err.message}`);
}

for (const key of REQUIRED) {
  if (!(key in manifest)) die(`manifest missing required key: ${key}`);
}
if (!Array.isArray(manifest.call_sites)) die('manifest.call_sites must be an array');

// Structural validation — warnings only, so a draft can still be previewed.
const warnings = [];
const ids = new Set();
// Conventional semantics: `grade` / request_grade describe the REQUEST payload.
// `response_grade` describes the RESPONSE; a null response defaults to unresolved.
const counts = { recorded: 0, serialized: 0, reconstructed: 0, representative: 0, unresolved: 0 };
const resCounts = { recorded: 0, serialized: 0, reconstructed: 0, representative: 0, unresolved: 0 };
for (const cs of manifest.call_sites) {
  if (!cs.id) warnings.push(`call site without id: ${JSON.stringify(cs.name ?? '?')}`);
  else if (ids.has(cs.id)) warnings.push(`duplicate call-site id: ${cs.id}`);
  else ids.add(cs.id);
  if (!Array.isArray(cs.requests)) {
    warnings.push(`${cs.id ?? '?'}: no requests[] array`);
    continue;
  }
  for (const r of cs.requests) {
    const reqGrade = r.request_grade ?? r.grade;
    if (!reqGrade) warnings.push(`${cs.id}/${r.id ?? '?'}: missing request grade`);
    else if (!GRADES.has(reqGrade)) warnings.push(`${cs.id}/${r.id ?? '?'}: unknown request grade "${reqGrade}"`);
    else counts[reqGrade]++;

    let resGrade = r.response_grade;
    if (!resGrade) {
      if (r.response == null) resGrade = 'unresolved';
      else {
        resGrade = reqGrade;
        warnings.push(`${cs.id}/${r.id ?? '?'}: response present without response_grade (assuming "${resGrade}")`);
      }
    }
    if (!GRADES.has(resGrade)) warnings.push(`${cs.id}/${r.id ?? '?'}: unknown response grade "${resGrade}"`);
    else resCounts[resGrade]++;

    if (reqGrade && reqGrade !== 'unresolved' && !r.provenance) warnings.push(`${cs.id}/${r.id ?? '?'}: missing provenance`);
    if ((reqGrade !== 'unresolved' || resGrade !== 'unresolved') && r.request == null && r.response == null) {
      warnings.push(`${cs.id}/${r.id ?? '?'}: no request or response payload`);
    }
  }
}

function checkScriptSyntax(html, label) {
  const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  if (!scripts.length) die(`${label} contains no <script> block — wrong template?`);
  for (const src of scripts) {
    try {
      new Function(src); // compile only; never executes
    } catch (err) {
      die(`${label} has a JavaScript syntax error: ${err.message}\nThe report would render a blank page. Fix the template before shipping.`);
    }
  }
}

let template;
try {
  template = fs.readFileSync(args.template, 'utf8');
} catch (err) {
  die(`cannot read template: ${err.message}`);
}
checkScriptSyntax(template, args.template);

const occurrences = template.split(MARKER).length - 1;
if (occurrences !== 1) die(`template must contain the marker exactly once, found ${occurrences}`);

const safeJson = JSON.stringify(manifest)
  .replace(/</g, '\\u003c')
  .replace(/\u2028/g, '\\u2028')
  .replace(/\u2029/g, '\\u2029');

const html = template.replace(MARKER, `/*__LLMMAP_MANIFEST__*/${safeJson}`);
checkScriptSyntax(html, args.template + ' (with manifest embedded)');

fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true });
fs.writeFileSync(args.out, html);

const total = Object.values(counts).reduce((a, b) => a + b, 0);
console.log(`render: wrote ${args.out}`);
console.log(`        ${manifest.call_sites.length} call site(s), ${total} payload(s)`);
console.log(`        requests:  ${fmtCounts(counts)}`);
console.log(`        responses: ${fmtCounts(resCounts)}`);
function fmtCounts(c) {
  return Object.keys(c).map((k) => `${c[k]} ${k}`).join(' · ');
}
if (manifest.summary?.evidence) {
  const declared = manifest.summary.evidence;
  for (const k of Object.keys(counts)) {
    if (typeof declared[k] === 'number' && declared[k] !== counts[k]) {
      warnings.push(`summary.evidence.${k} is ${declared[k]} but the request payloads count ${counts[k]}`);
    }
  }
}
if (manifest.summary?.response_evidence) {
  const declared = manifest.summary.response_evidence;
  for (const k of Object.keys(resCounts)) {
    if (typeof declared[k] === 'number' && declared[k] !== resCounts[k]) {
      warnings.push(`summary.response_evidence.${k} is ${declared[k]} but the responses count ${resCounts[k]}`);
    }
  }
}
if (warnings.length) {
  console.log(`\nrender: ${warnings.length} warning(s):`);
  for (const w of warnings.slice(0, 25)) console.log(`  - ${w}`);
  if (warnings.length > 25) console.log(`  … ${warnings.length - 25} more`);
}
console.log('open it: file://' + path.resolve(args.out));
