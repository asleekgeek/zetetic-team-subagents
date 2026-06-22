---
name: web-to-semantic
description: >
  Wire the self-hosted web-ingest engine (A) to the query-indexed semantic layer (B) for the
  WEB source kind. Recall first; fetch only the gap; distill one sourced fact per page; verify the
  passage at its source; then GATE every fact through the fetch manifest so only pages we actually
  fetched can be persisted — closing the hole where a plausible-but-never-fetched URL would pass the
  schema's source-presence check. Specializes semantic-ingest-loop; does not fork it.
category: research
trigger: >
  When a topic must be answered from the open web and the result should become cheaply recallable;
  when "did we actually fetch the page this claim cites, or did we just believe it exists?" must be
  provable before a web fact is stored; whenever web-ingest and the semantic layer are used together.
agents:
  - shannon
  - ranganathan
  - peirce
  - feynman
  - popper
  - lavoisier
  - liskov
shapes: [define-the-measure-first, two-independent-methods, falsifiability-gate]
input: A topic or question to answer from the web. The agent's domain. Optional acquisition budget (pages/depth).
output: >
  A validated semantic-layer.yaml entry in which every fact's source is a URL this run fetched,
  Cortex memories for full content, sources[] auto-filled from the manifest, and gaps recording
  every claim that could not be grounded (blocked / TLS-failed / dropped).
zetetic_gate:
  logical: "The topic is normalized to a stable query_id before recall — same topic, same key (no forking)"
  critical: "Two gates in series: membership (this skill's manifest gate) THEN presence (semantic_layer §8). A fact must be FETCHED and carry a source — neither alone is enough"
  rational: "Ingest depth is proportional to the gap — a fresh recall HIT fetches nothing"
  essential: "On exit the entry records outcome + gaps; a web topic never closes without its learn signal"
composes: [semantic-ingest-loop, web-ingest, deep-research, lab-notebook]
aliases: [web-ingest-to-semantic, grounded-web-ingest, manifest-gated-ingest, a-to-b-bridge]
hand_off:
  recall_hit_fresh: "(stop ingest) — load facts + pointers and proceed with the actual task"
  large_unknown_topic: "/deep-research first — full investigation, then return here to ground + persist"
  source_unfetchable: "record a gap (status open); never store a fact whose page you could not fetch"
  every_fact_dropped: "the manifest gate left no survivors — the page(s) you fetched do not support any claim; widen acquisition (Step 2), do not weaken the gate"
---

## What this skill is

`semantic-ingest-loop` specialized for the **web** source kind, with one structural addition: a
**manifest-membership gate** inserted between *distill* and *persist*. It is the only place A
(`tools/web-ingest.sh`) and B (`tools/semantic-layer.sh`) are wired together — the tools import none
of each other (DIP / coding-standards §5). The wiring is two gates **in series**:

1. **membership** — `tools/manifest-gate.sh`: is the fact's source URL one we actually fetched?
2. **presence** — `semantic_layer.validate_entry` (unchanged): does the fact carry a source string at all?

A fact must pass **both**. Presence alone (B's existing check) cannot distinguish a real fetched URL
from a plausible one the model invented; membership can, because it has the fetch manifest.

## Invariants (state these before acting)

- **INV-1 — recall before ingest.** Query the semantic layer and Cortex *before* fetching a single
  page. A fresh recall HIT fetches nothing. (semantic-ingest-loop Phase 1; unchanged.)
- **INV-2 — source in manifest.** Every persisted fact's source URL MUST be a page this run fetched
  (present in the manifest). Stricter than §8's "has a source": the source must be one we *fetched and
  read*, not one we *believe exists*. The membership gate enforces it; ungrounded facts never reach
  `record`. **Fail closed** — what is not provably grounded is dropped, not stored.
- **INV-3 — no coupling.** `web_ingest`, `semantic_layer`, and `manifest_gate` import none of each
  other. This skill is the sole wiring point, so each tool stays independently testable and
  replaceable (swap the ingestion engine without touching the layer — OCP).
- **INV-4 — never close without the learn signal.** On exit the entry records `outcome` + `gaps`
  (firecrawl's `missingContent`). Blocked, TLS-failed, and gate-dropped facts all become gaps that
  seed the next visit's backlog. A topic never closes without it.

## Procedure (7 steps + a normalize pre-step)

> Steps 0, 1, 3, and 7 ARE `semantic-ingest-loop` Phases 0, 1, 3, and 5 — follow them there. This
> skill adds Step 2 (build the manifest), Step 4 (verify-at-source annotation), Step 5 (the gate),
> and specializes Step 6 (persist) to auto-fill `sources[]` from the manifest.

### Step 0 — Normalize the query (shannon + ranganathan)
Restate the topic as one natural-language question (the human key). Derive a stable kebab-case
`query_id` and 1–3 `aliases`. Same topic must always map to the same id, or recall misses and the
topic forks. *(= semantic-ingest-loop Phase 0.)*

### Step 1 — RECALL FIRST (INV-1)
`tools/semantic-layer.sh query "<topic>"` and `cortex recall` the same query.
- **HIT & `status: fresh`** → load `summary`, `facts`, `pointers.cortex_memories`; **jump to Step 6**
  (persist only if you learned something new — a clean HIT still owes Step 7).
- **HIT & `stale`/`superseded`**, or **MISS** → continue. Existing `gaps` from a prior visit are the
  priority acquisition backlog. *(= semantic-ingest-loop Phase 1.)*

### Step 2 — Acquire, and BUILD THE MANIFEST (peirce)
Fetch only the gap, with the self-hosted engine — run diverse framings (peirce), not one query:
```bash
tools/web-ingest.sh map   "<seed-url>" --search "<term>"        # discover candidate URLs
tools/web-ingest.sh scrape "<url>" --out /tmp/ingest/<query_id> # fetch one page
tools/web-ingest.sh crawl "<seed-url>" --depth 1 --out /tmp/ingest/<query_id>  # fetch a small set
```
**The manifest is the set of URLs you FETCHED — not the ones you discovered.** Build it from the
`url` field of each fetched record:
- with `--out DIR`: the `url` values in `DIR/index.json`.
- to stdout: the `.url` of each scrape/crawl record.

> Never build the manifest from `map` output or a record's `links[]` — those are *discovered*, not
> *fetched*. Grounding a fact against a link you never opened is exactly the hole this gate closes.
> `map` only tells Step 2 *what to scrape next*.

### Step 3 — Distill (feynman)
One fact = one verifiable `claim` + the **exact page URL it came from** (the URL of the page whose
markdown you read, not a parent or a sibling link). No URL → drop it. *(= semantic-ingest-loop Phase 3.)*

### Step 4 — Verify at the source (popper)
Read the actual passage in the fetched markdown that supports each load-bearing claim — do not trust
a snippet. Optionally record the proof inline by annotating the source:
`"<url> -> \"the exact quoted passage\""`. The gate strips the `-> "…"` suffix before comparing, so
the annotation is free to keep. Use `two-independent-methods` for high-stakes facts.

### Step 5 — GATE on the manifest (lavoisier + liskov) — INV-2
Mass-balance the entry against what you fetched: every claimed source must appear as a fetched input.
Build `{"entry": <draft>, "manifest": [<fetched urls>]}` and pipe it through the membership gate:
```bash
echo "$payload" | tools/manifest-gate.sh            # all grounded -> entry on stdout, exit 0
echo "$payload" | tools/manifest-gate.sh --drop     # keep grounded facts, demote the rest to gaps
```
- **exit 0** → the emitted entry is grounded; carry it to Step 6.
- **exit 3** → ≥1 ungrounded fact. The gate emits `{"gaps":[…]}` and withholds the entry. **Do not
  weaken the gate.** Either fetch the missing page (back to Step 2) or run `--drop` to persist the
  grounded survivors and let the ungrounded claims become gaps. If `--drop` leaves zero facts, the
  fetched pages support no claim — widen acquisition; do not lower the bar.
- exit 2 → malformed payload (e.g. you forgot the manifest). Fix the payload.

### Step 6 — Persist (dual write; presence gate runs here)
1. `cortex remember` each grounded, durable fact → returns a memory id.
2. Build the final entry: put the ids in `facts[].cortex_id` and `pointers.cortex_memories`; **auto-
   fill `sources[]` from the manifest** — one `{ref: <url>, kind: web, accessed: <date>, valuable: …}`
   per fetched page.
3. `echo '<entry-json>' | tools/semantic-layer.sh record`. This runs the **presence** gate
   (`validate_entry`, §8) — the second gate in the series — and upserts by `query_id`.
*(Persist mechanics = semantic-ingest-loop Phase 4, with sources[] sourced from the manifest.)*

### Step 7 — Feedback, the learn signal (INV-4)
```bash
echo '{"outcome":{...},"gaps":[...],"status":"fresh"}' | tools/semantic-layer.sh feedback <query_id>
```
`gaps` = everything you could not ground: pages blocked by `robots.txt`, TLS/network failures, and
every fact the manifest gate dropped (the gate's `{"gaps":[…]}` output drops straight in here). Set
`freshness` by volatility — fast-moving topic → short `ttl_days`; `watch: true` to resurface it.
*(= semantic-ingest-loop Phase 5; never skipped, even on a clean HIT.)*

## Output Format

```
## Web -> Semantic: [query]

### query_id: [slug]   recall: [HIT-fresh | HIT-stale | MISS]   manifest: [N pages fetched]

### Grounded facts persisted (each fetched + sourced):
- [claim]  — [url]  (cortex: [id])

### Gate result: [all-grounded | dropped K ungrounded | --drop survivors=M]

### Gaps recorded (next ingest backlog):
- [topic] — [open|researching]   (blocked / TLS / ungrounded)

### Outcome: [good|partial|bad]   Revalidate after: [date]
```

## Invariants recap (the gate is the point)

- **Two gates in series, both mandatory:** membership (fetched?) then presence (sourced?). A fact
  that passes one but not the other is **not** stored.
- **Manifest = fetched, never discovered.** `map`/`links[]` describe what *could* be fetched; only
  the `url` of a fetched record may enter the manifest.
- **Fail closed.** The gate's default is exit 3 (withhold the whole entry). `--drop` is a deliberate
  choice to keep survivors, not a way to wave claims through.
- **No coupling, no forking.** The tools stay decoupled; this skill stays a thin specialization of
  `semantic-ingest-loop` — fix the loop once, both inherit it.
