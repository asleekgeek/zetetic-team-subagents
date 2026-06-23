// extract-core.mjs — load the DETERMINISTIC core (LENSES + synthesizeVerdict) out of
// the adversarial-verify workflow WITHOUT executing its runtime body (top-level await /
// agent() calls). The workflow is not an importable module (runtime-injected globals,
// top-level return), so we slice the pure-declaration prefix — everything before the
// `// --- run ---` marker — strip the ESM export, and eval it to recover the exact
// functions the workflow uses. Testing the real code, not a copy, so there is no drift.
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const here = path.dirname(fileURLToPath(import.meta.url))
const wfPath = path.resolve(here, '../../../.claude/workflows/adversarial-verify.js')
const full = fs.readFileSync(wfPath, 'utf8')

const marker = '// --- run ---'
const idx = full.indexOf(marker)
if (idx < 0) throw new Error('extract-core: `// --- run ---` marker not found in workflow')
let prefix = full.slice(0, idx).replace(/^export const meta/m, 'const meta')

// eslint-disable-next-line no-new-func
const load = new Function(prefix + '\nreturn { LENSES, synthesizeVerdict };')
export const { LENSES, synthesizeVerdict } = load()
