export const meta = {
  name: 'autonomous-build-loop',
  description:
    'Closed-loop autonomous build: refine -> plan -> verify-plan -> orchestrator build on an isolated ' +
    'iteration branch -> best-effort in-loop acceptance checks -> iterate until they are green or the ' +
    'budget is spent. The loop DRAFTS and converges a candidate on the integration branch; it does not ' +
    'self-certify. The AUTHORITATIVE external gate is a real exec OUTSIDE the loop: a human/CI re-running ' +
    'tools/acceptance-gate.sh on the integration branch and reading the real exit code before merging to ' +
    'main. Fails closed; does not push; does not modify main.',
  whenToUse:
    'A non-trivial build task you want drafted and iterated to a candidate under acceptance checks, with ' +
    'per-iteration branch isolation, for a human/CI to certify and merge.',
  phases: [
    { title: 'Refine', detail: 'compile the verifiable acceptance contract' },
    { title: 'Setup', detail: 'create the integration branch off an explicit base ref' },
    { title: 'Branch', detail: 'create + checkout the iteration branch off integration' },
    { title: 'Plan', detail: 'decompose against the contract' },
    { title: 'Verify-plan', detail: 'zetetic-check the plan before any code is written' },
    { title: 'Build', detail: 'orchestrator commits subtasks onto the checked-out iteration branch' },
    { title: 'Accept', detail: 'deterministic gate runners + independent reviews + independent compare' },
    { title: 'Converge', detail: 'merge-on-green (reported), or preserve/discard branch and iterate' },
  ],
}

// ---------------------------------------------------------------------------
// EXTERNALITY — read this; it is the design's load-bearing limit.
// A Workflow script CANNOT exec a subprocess or read a file — only agents run
// Bash. So everything the loop "checks" in-loop (the gate verdict, the changed
// files, the merge result) is ultimately reported BY AN AGENT. The JS hardens
// this as far as possible — it parses the tool's raw stdout rather than a model
// boolean, runs two gate runners, checks internal consistency, and derives
// reviewer lenses from the reported diff — but two copies of the same model are
// NOT independent oracles (arXiv:2310.01798), so the in-loop signals are
// BEST-EFFORT / ADVISORY, not a guarantee. This loop's job is to DRAFT and
// converge a candidate, not to certify it.
//
// The AUTHORITATIVE external gate lives OUTSIDE this loop and really execs:
//   tools/acceptance-gate.sh --config memory/acceptance-gates.loop.yaml \
//     --diff-base <baseRef> --diff-head <integrationBranch>
// run by a human or CI, reading the real exit code, before merging to main.
// The loop returns the integration branch for exactly that certification.
// ---------------------------------------------------------------------------

const CONTRACT_SCHEMA = {
  type: 'object',
  required: ['goal', 'acceptance_criteria'],
  properties: {
    goal: { type: 'string', description: 'one-sentence measurable success criterion' },
    scope: { type: 'string' },
    out_of_scope: { type: 'array', items: { type: 'string' } },
    acceptance_criteria: {
      type: 'array',
      minItems: 1,
      items: {
        type: 'object',
        required: ['id', 'text', 'kind'],
        properties: {
          id: { type: 'string' },
          text: { type: 'string' },
          kind: { type: 'string', enum: ['deterministic', 'review', 'manual'] },
          checkable_cmd: { type: ['string', 'null'], description: 'shell line exiting 0 iff met; REQUIRED (non-null) when kind=deterministic, else use kind=review' },
        },
      },
    },
  },
}
const READY_BRANCH_SCHEMA = {
  type: 'object',
  required: ['ready', 'current_branch'],
  properties: {
    ready: { type: 'boolean' },
    current_branch: { type: 'string', description: 'git rev-parse --abbrev-ref HEAD after the step' },
    head: { type: 'string' },
  },
}
const PLAN_SCHEMA = {
  type: 'object',
  required: ['summary', 'ready'],
  properties: {
    summary: { type: 'string' },
    subtasks: { type: 'array', items: { type: 'string' } },
    critical_path: { type: 'string' },
    ready: { type: 'boolean', description: 'true only if complete enough to build now' },
  },
}
const SOUND_SCHEMA = { type: 'object', required: ['sound'], properties: { sound: { type: 'boolean' }, issues: { type: 'array', items: { type: 'string' } } } }
const BUILD_SCHEMA = {
  type: 'object',
  required: ['built_branch'],
  properties: {
    built_branch: { type: 'string', description: 'the branch the build actually committed to' },
    merged_subtasks: { type: 'array', items: { type: 'string' } },
    rejected_subtasks: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}
// The runner returns the tool's RAW output; the controller (not the model) decides from it.
const DET_RAW_SCHEMA = {
  type: 'object',
  required: ['raw_stdout', 'exit_code'],
  properties: {
    raw_stdout: { type: 'string', description: 'the EXACT JSON the tool printed to stdout, unaltered' },
    exit_code: { type: 'integer', description: 'the tool process exit code (0 accept / 3 reject / 2 usage)' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object',
  required: ['approved'],
  properties: {
    approved: { type: 'boolean', description: 'true iff you read the diff AND found no blocking issue' },
    dimension: { type: 'string' },
    blocking: { type: 'array', items: { type: 'string' } },
    evidence: { type: 'array', items: { type: 'string' }, description: 'file:line citations from the diff you reviewed' },
  },
}
const COMPARE_SCHEMA = {
  type: 'object',
  required: ['unmet'],
  properties: {
    unmet: { type: 'array', items: { type: 'string' }, description: 'contract criteria the build does not satisfy (id + why)' },
    met: { type: 'array', items: { type: 'string' } },
  },
}
const MERGE_SCHEMA = {
  type: 'object',
  required: ['merged', 'current_branch'],
  properties: {
    merged: { type: 'boolean', description: 'true iff the iteration branch actually merged into the integration branch' },
    current_branch: { type: 'string', description: 'git rev-parse --abbrev-ref HEAD when the merge ran (must be the integration branch)' },
    integration_head: { type: 'string' },
    conflicts: { type: 'array', items: { type: 'string' } },
  },
}

// Default iteration ceiling; on exhaustion the loop fails closed (does not ship a red build).
// source: Milestone 2 design fork decision (budget = 4 iterations, overridable via args.maxIterations).
const DEFAULT_MAX_ITERATIONS = 4
// A full iteration (plan+build+gates) is costly; do not start one below this many output tokens.
// source: operational default, mirrors the Workflow loop-until-budget pattern.
const TOKEN_FLOOR = 80000

// Parse one deterministic-runner result IN JS from the tool's raw output (not a model boolean). Any
// parse error, exit/accepted inconsistency, or leftover unmet fails closed. Best-effort: see EXTERNALITY.
function parseVerdict(d) {
  if (!d || typeof d.raw_stdout !== 'string') return { ok: false, accepted: false, unmet: ['gate runner returned no stdout — fail closed'], files: [] }
  let v
  try { v = JSON.parse(d.raw_stdout) } catch (e) { return { ok: false, accepted: false, unmet: ['gate stdout was not valid JSON — fail closed'], files: [] } }
  const accepted = v.accepted === true
  const exitOk = d.exit_code === 0
  const files = Array.isArray(v.changed_files) ? v.changed_files : []
  if (accepted !== exitOk) return { ok: false, accepted: false, unmet: ['gate accepted/exit_code disagree — fail closed'], files }
  if (accepted && (v.unmet || []).length > 0) return { ok: false, accepted: false, unmet: v.unmet, files }
  return { ok: true, accepted, unmet: v.unmet || [], files }
}

// Pick reviewer lenses from the reported changed files. Fail-safe toward MORE review: include security
// if any path looks sensitive, architecture if the change spans top-level dirs, and ALL lenses if the
// two runners' file lists disagree or are empty (an untrusted/empty list must not narrow review).
// source: coding-standards §10 stakes (sensitive = auth/crypto/billing/PII).
function reviewLenses(files1, files2) {
  const security = { agentType: 'zetetic-team-subagents:security-auditor', dimension: 'security (auth / crypto / billing / PII)' }
  const architecture = { agentType: 'zetetic-team-subagents:architect', dimension: 'architecture / layer boundaries' }
  const lenses = [{ agentType: 'zetetic-team-subagents:code-reviewer', dimension: 'clean-architecture / SOLID / size limits' }]
  const topDirs = (fs) => Array.from(new Set(fs.map((f) => f.split('/')[0]))).sort().join(',')
  const trusted = files1.length && files2.length && topDirs(files1) === topDirs(files2)
  if (!trusted) return lenses.concat(security, architecture)  // untrusted/empty -> widen, do not narrow
  const joined = files1.join('\n').toLowerCase()
  if (/auth|crypto|cipher|password|secret|token|billing|payment|\bpii\b|login|oauth|session/.test(joined)) lenses.push(security)
  if (new Set(files1.map((f) => f.split('/')[0])).size > 1) lenses.push(architecture)
  return lenses
}

// --- inputs ---------------------------------------------------------------
const rawTask = typeof args === 'string' ? args : (args && args.task)
if (!rawTask) {
  log('autonomous-build-loop: no task provided. Pass args.task (or a task string). Nothing to build.')
  return { accepted: false, error: 'missing args.task' }
}
const rawMax = args && args.maxIterations
const maxIterations = Number.isInteger(rawMax) ? rawMax : DEFAULT_MAX_ITERATIONS
if (maxIterations < 1) {
  log('maxIterations must be >= 1 (got ' + maxIterations + ')')
  return { accepted: false, error: 'maxIterations must be >= 1' }
}
const integrationBranch = (args && args.integrationBranch) || 'abl/integration'
const baseRef = (args && args.baseRef) || 'HEAD'

// --- Refine: the acceptance contract is the spec everything else is judged against ---
phase('Refine')
const contract = await agent(
  'Act as the refine layer (session-optimizer:refine). Turn the raw task below into a VERIFIABLE ' +
  'acceptance contract: a one-sentence measurable goal, explicit scope and out_of_scope, and at least ' +
  'one acceptance criterion. For each criterion choose kind: "deterministic" WITH a non-null ' +
  'checkable_cmd shell line that exits 0 iff the criterion is met (prefer these — they are ' +
  'machine-checkable); "review" when an independent reviewer must judge it; "manual" otherwise. If you ' +
  'cannot write a checkable_cmd, use kind=review. Resolve every vague reference to a concrete ' +
  'artifact.\n\nTASK:\n' + rawTask,
  { schema: CONTRACT_SCHEMA, phase: 'Refine' }
)
if (!contract) return { accepted: false, error: 'refine produced no contract' }
log('contract goal: ' + contract.goal)

// --- Setup: the integration branch must exist before the first iteration branches off it ---
phase('Setup')
const setup = await agent(
  'Prepare the loop integration branch. If ' + integrationBranch + ' does not already exist, create it ' +
  'at ' + baseRef + ' (git branch ' + integrationBranch + ' ' + baseRef + '). Do NOT check it out over ' +
  'uncommitted work, do NOT touch main, do NOT push. Report ready=true, the integration branch head SHA ' +
  'as head, and the current branch (git rev-parse --abbrev-ref HEAD) as current_branch.',
  { schema: READY_BRANCH_SCHEMA, phase: 'Setup' }
)
if (!setup || !setup.ready) return { accepted: false, error: 'could not prepare integration branch ' + integrationBranch }

let backlog = []
let residual = []
let accepted = false
let iter = 0

while (!accepted && iter < maxIterations) {
  if (budget.total && budget.remaining() < TOKEN_FLOOR) {
    log('stopping before a new iteration: token budget below floor (' + Math.round(budget.remaining() / 1000) + 'k left)')
    break
  }
  iter += 1
  const iterBranch = 'abl/iter-' + iter
  log('=== iteration ' + iter + '/' + maxIterations + ' (' + iterBranch + ') ===')

  // --- Branch: the LOOP creates + checks out the iteration branch, so branch creation is not
  //     delegated to the orchestrator (whose Moves do not describe a two-level integration->iter model). ---
  phase('Branch')
  const branch = await agent(
    'Create and CHECK OUT a fresh iteration branch ' + iterBranch + ' off ' + integrationBranch +
    ' (git checkout -B ' + iterBranch + ' ' + integrationBranch + '). Do NOT touch main, do NOT push. ' +
    'Report ready=true and the current branch (git rev-parse --abbrev-ref HEAD) as current_branch.',
    { schema: READY_BRANCH_SCHEMA, phase: 'Branch' }
  )
  if (!branch || !branch.ready || branch.current_branch !== iterBranch) {
    backlog = ['could not check out iteration branch ' + iterBranch + ' (on ' + ((branch && branch.current_branch) || '?') + ')']
    log('branch setup failed — fail closed this iteration: ' + backlog[0])
    continue
  }

  phase('Plan')
  const plan = await agent(
    'Plan the implementation that satisfies this acceptance contract. Decompose into subtasks with ' +
    'named artifacts and a critical path (orchestrator Move 1). Set ready=true only if the plan is ' +
    'complete enough to build now.\n\nCONTRACT:\n' + JSON.stringify(contract, null, 2) +
    (backlog.length ? '\n\nOUTSTANDING FROM LAST ITERATION (must be fixed):\n- ' + backlog.join('\n- ') : ''),
    { schema: PLAN_SCHEMA, phase: 'Plan' }
  )

  phase('Verify-plan')
  const planVerdict = await agent(
    'Zetetically verify this plan BEFORE any code is written. Does it actually satisfy every ' +
    'acceptance criterion, respect rules/coding-standards.md (layer dependencies, SOLID, size limits), ' +
    'and avoid dead/unwired code? Be a skeptic; set sound=false with specific issues if not.\n\n' +
    'CONTRACT:\n' + JSON.stringify(contract) + '\n\nPLAN:\n' + JSON.stringify(plan),
    { schema: SOUND_SCHEMA, phase: 'Verify-plan' }
  )
  if (planVerdict && planVerdict.sound === false) {
    backlog = planVerdict.issues && planVerdict.issues.length ? planVerdict.issues : ['plan unsound']
    log('plan rejected before build: ' + backlog.join(' | '))
    continue
  }

  phase('Build')
  const build = await agent(
    'You are the orchestrator, already on the checked-out iteration branch ' + iterBranch + '. Build ' +
    'exactly what this plan specifies to satisfy the contract: decompose, route to specialists in ' +
    'isolated worktrees branched OFF ' + iterBranch + ', and merge each subtask back into ' + iterBranch +
    ' as COMMITS only when its own gate is green (Move 5). Do NOT create or merge into ' + integrationBranch +
    ', do NOT touch main, do NOT push, and do NOT rely on the staging area — COMMIT your work to ' +
    iterBranch + ' so the acceptance gate can scope to the commit range ' + integrationBranch + '...' +
    iterBranch + '. Report the branch you committed to as built_branch and the subtasks you merged/' +
    'rejected.\n\nCONTRACT:\n' + JSON.stringify(contract) + '\n\nPLAN:\n' + JSON.stringify(plan) +
    (backlog.length ? '\n\nFIX THESE FROM LAST ITERATION:\n- ' + backlog.join('\n- ') : ''),
    { agentType: 'zetetic-team-subagents:orchestrator', schema: BUILD_SCHEMA, phase: 'Build' }
  )
  const builtBranch = (build && build.built_branch) || iterBranch
  if (builtBranch !== iterBranch) {
    backlog = ['build committed to ' + builtBranch + ' but the loop expected ' + iterBranch]
    log('branch mismatch — fail closed this iteration: ' + backlog[0])
    continue
  }

  phase('Accept')
  // (1) DETERMINISTIC gate — two runners; the JS parses each tool output (not a model boolean) and
  //     requires agreement + consistency. Best-effort (see EXTERNALITY): catches transcription drift,
  //     not adversarial collusion. The authoritative read is the human re-run on the integration branch.
  const detRun = (n) => () => agent(
    'Run the deterministic acceptance gate for this iteration and return its RAW output — do not judge, ' +
    'summarize, or alter it.\nSteps: (a) copy memory/acceptance-gates.loop.yaml to a temp file; (b) for ' +
    'each acceptance criterion with kind="deterministic" and a non-null checkable_cmd, append a gate ' +
    '{name:"contract:<id>", cmd:<checkable_cmd>, mandatory:true, origin:contract}; (c) run exactly: ' +
    'tools/acceptance-gate.sh --config <temp> --diff-base ' + integrationBranch + ' --diff-head ' +
    iterBranch + ' ; (d) return raw_stdout = the EXACT stdout the tool printed, and exit_code = the ' +
    'process exit code. Transcribe both precisely.\n\nCONTRACT:\n' + JSON.stringify(contract),
    { schema: DET_RAW_SCHEMA, label: 'gate:deterministic#' + n, phase: 'Accept' }
  )
  const [draw1, draw2] = await parallel([detRun(1), detRun(2)])
  const dv1 = parseVerdict(draw1)
  const dv2 = parseVerdict(draw2)
  const detOk = dv1.ok && dv2.ok && dv1.accepted === true && dv2.accepted === true

  // (2) INDEPENDENT reviewer agents (distinct agentTypes from the builder), lenses derived from the diff.
  const lenses = reviewLenses(dv1.files || [], dv2.files || [])
  const reviews = await parallel(lenses.map((l) => () =>
    agent(
      'You are reviewing code you did NOT write. Read the diff of the commit range ' + integrationBranch +
      '...' + iterBranch + ' (run: git diff ' + integrationBranch + '...' + iterBranch + ') and review it ' +
      'for: ' + l.dimension + '. Approve ONLY if you read the diff and found no blocking issue; cite ' +
      'file:line evidence for your verdict.\n\nCONTRACT GOAL: ' + contract.goal,
      { agentType: l.agentType, schema: REVIEW_SCHEMA, phase: 'Accept', label: 'review:' + l.dimension }
    )
  ))

  // (3) COMPARE-TO-CONTRACT — an INDEPENDENT reviewer-type agent (not the builder's default lineage)
  //     judges the review/manual criteria a command cannot check, against the actual diff, with evidence.
  const compare = await agent(
    'You are reviewing code you did NOT write. Read the diff of ' + integrationBranch + '...' + iterBranch +
    ' (git diff) and compare it to the acceptance contract. For every criterion with kind=review or ' +
    'manual, decide whether the implementation satisfies it and cite file:line evidence. Return the ' +
    'unmet criteria (id + why). Judge against the contract AS WRITTEN; do not invent requirements.\n\n' +
    'CONTRACT:\n' + JSON.stringify(contract),
    { agentType: 'zetetic-team-subagents:code-reviewer', schema: COMPARE_SCHEMA, phase: 'Accept', label: 'compare-to-contract' }
  )

  phase('Converge')
  const okReviews = reviews.filter(Boolean)
  const reviewsOk = okReviews.length === lenses.length && okReviews.every((r) => r.approved)
  const cmpOk = !!compare && (compare.unmet || []).length === 0
  const gatesGreen = detOk && reviewsOk && cmpOk

  residual = Array.from(new Set([].concat(
    detOk ? [] : [].concat(dv1.unmet || [], dv2.unmet || []),
    okReviews.filter((r) => !r.approved).flatMap((r) => r.blocking || [(r.dimension || 'review') + ' not approved']),
    okReviews.length === lenses.length ? [] : ['a reviewer did not return — fail closed'],
    (compare && compare.unmet) || [],
    compare ? [] : ['compare-to-contract did not return — fail closed']
  )))

  let greenButUnmerged = false
  if (gatesGreen) {
    // Gates green -> attempt the merge. The merge result is agent-reported (best-effort); the JS checks
    // the reported current_branch is the integration branch. The AUTHORITATIVE ancestry/exit check is the
    // human re-run on the integration branch (see EXTERNALITY + the return note).
    const merge = await agent(
      'Check out ' + integrationBranch + ' and merge the iteration branch ' + iterBranch + ' into it ' +
      '(git checkout ' + integrationBranch + ' && git merge --no-ff ' + iterBranch + '). Do NOT push and ' +
      'do NOT touch main. If the merge conflicts, abort it cleanly (git merge --abort) and report ' +
      'merged=false with the conflicting paths. Report merged, the current branch (git rev-parse ' +
      '--abbrev-ref HEAD) as current_branch, and the new integration head SHA as integration_head.',
      { schema: MERGE_SCHEMA, phase: 'Converge', label: 'integrate-on-green' }
    )
    if (merge && merge.merged === true && merge.current_branch === integrationBranch && merge.integration_head) {
      accepted = true
      log('iteration ' + iter + ' green and merged into ' + integrationBranch + ' (head ' + merge.integration_head + ', reported)')
    } else {
      greenButUnmerged = true  // keep the verified-green branch; do not throw the work away
      residual = residual.concat(['merge of ' + iterBranch + ' into ' + integrationBranch + ' did not land: ' +
        ((((merge && merge.conflicts) || []).join(', ')) || 'unknown') + ' — branch ' + iterBranch + ' preserved'])
      backlog = residual
      log('gates green but merge did not land — preserving ' + iterBranch + ' for re-merge; carried forward')
    }
  } else {
    backlog = residual
    log('iteration ' + iter + ' not accepted; residual: ' + residual.join(' | '))
  }

  if (!accepted && !greenButUnmerged) {
    // Rejected iteration: the controller owns the branch lifecycle — discard the branch, persist the backlog.
    await agent(
      'Housekeeping for a rejected iteration: check out ' + integrationBranch + ', then delete the ' +
      'iteration branch ' + iterBranch + ' and its worktree if present (it is discarded). Do NOT touch ' +
      'main. Then record these unmet acceptance items as gaps in the semantic layer (cross-session ' +
      'memory) keyed by the task "' + contract.goal + '", via tools/semantic-layer.sh.\nItems:\n- ' +
      residual.join('\n- '),
      { phase: 'Converge', label: 'cleanup+persist' }
    )
  }
}

if (!accepted) {
  log('NOT SHIPPED — ' + iter + ' iteration(s) exhausted without a merged green. Residual: ' + residual.join(' | '))
}
return {
  accepted,
  iterations: iter,
  integrationBranch,
  residual: accepted ? [] : residual,
  note: accepted
    ? 'in-loop checks green and abl/iter-' + iter + ' merged into ' + integrationBranch + ' (reported). ' +
      'AUTHORITATIVE step before shipping: run tools/acceptance-gate.sh --config ' +
      'memory/acceptance-gates.loop.yaml --diff-base ' + baseRef + ' --diff-head ' + integrationBranch +
      ' yourself (real exit code), review the diff, then merge ' + integrationBranch + ' to main.'
    : 'fail closed: budget/iterations exhausted without a merged green — integration NOT certified',
}
