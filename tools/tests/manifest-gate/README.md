# manifest-gate tests

Regression tests for `tools/manifest-gate.sh` / `tools/manifest_gate.py` — the
membership gate that sits between the web-ingest engine (A) and the semantic
layer (B).

## What it proves

The gate exists to close one specific hole: `semantic_layer.validate_entry`
checks only that a fact carries a **source string** (presence), not that the
source is a page we **actually fetched** (membership). A plausible-but-never-
fetched URL would sail through the presence check. This gate refuses it.

| Fixture | Asserts |
|---|---|
| `fixture-all-grounded.json` | Both facts ground; exercises RFC 3986 §6 normalization — uppercase scheme/host, explicit default `:443`, trailing slash, `#fragment`, and the `-> "passage"` provenance suffix all canonicalize to the manifest URL. Exit 0, entry emitted. |
| `fixture-one-ungrounded.json` | One fact cites a URL not in the manifest. Default mode: exit 3, `{"gaps":[…]}` emitted, the entry withheld. `--drop` mode: exit 0, survivor keeps only the grounded fact and demotes the ungrounded one to a gap. |
| `fixture-empty-manifest.json` | Empty manifest grounds nothing → exit 3 (fail closed). |
| `fixture-malformed.json` | `manifest` key missing → exit 2 (refuse, never assume a manifest). |

Exit 3 (grounding failure) is deliberately distinct from the semantic layer's
exit 2 (schema/usage) so a pipeline can tell the two failure modes apart.

## Run

```bash
bash tools/tests/manifest-gate/run-tests.sh
```

Exits non-zero if any case fails. Pure stdlib; no network (fixtures carry their
own manifests, so the test never fetches).
