"""Deploy the CMA facilitator manifests to the Managed Agents API (issue #26 Phase B).

Compiles enterprise/managed-agents manifests onto the Managed Agents beta
(`managed-agents-2026-04-01`, anthropic SDK >= 0.116) following the create-once /
versioned-update discipline (issue #26, anti-pattern 4):

- *.agent.yaml            -> agents (upsert: update-with-version, never duplicate)
- pilot.environment.yaml  -> environment (create-once, left untouched if it exists)
- pilot.engagement.yaml   -> memory stores + vaults (create-once by name;
                             credentials are registered out-of-band, never here)
- *.deployment.yaml       -> deployments (upsert by name; agent/environment/
                             memory-store/vault NAMES resolved to IDs at deploy
                             time, agent pinned to its current version)

Request-shape sources of truth: the SDK generated types
`anthropic/types/beta/{agent,environment,deployment,memory_store,vault}_create_params.py`
(+ `deployment_update_params.py`), the API reference
platform.claude.com/docs/en/api/beta (deployments, sessions, memory stores,
vaults), and the workshop reference implementation
`cwc-workshops/ship-your-first-managed-agent/agent_complete.py`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

import yaml

HERE = Path(__file__).resolve().parent

# source: SDK agent_create_params.py / agent_update_params.py (accepted fields)
AGENT_FIELDS = ("name", "model", "description", "system", "tools", "skills",
                "mcp_servers", "metadata", "multiagent")
# source: SDK environment_create_params.py (accepted fields)
ENVIRONMENT_FIELDS = ("name", "description", "metadata", "scope", "config")
# source: SDK deployment_create_params.py — fields copied verbatim from the
# manifest; agent/environment/resources/vaults are name-resolved separately.
DEPLOYMENT_VERBATIM_FIELDS = ("name", "description", "schedule",
                              "initial_events", "metadata")
DEPLOYMENT_MANIFEST_FIELDS = DEPLOYMENT_VERBATIM_FIELDS + (
    "agent", "environment", "resources", "vaults")


def load_agent_manifests() -> list[tuple[str, dict[str, Any]]]:
    return [(p.name, yaml.safe_load(p.read_text()))
            for p in sorted(HERE.glob("*.agent.yaml"))]


def load_deployment_manifests() -> list[tuple[str, dict[str, Any]]]:
    return [(p.name, yaml.safe_load(p.read_text()))
            for p in sorted(HERE.glob("*.deployment.yaml"))]


def load_engagement() -> dict[str, Any]:
    path = HERE / "pilot.engagement.yaml"
    if not path.exists():
        return {"memory_stores": [], "vaults": []}
    raw = yaml.safe_load(path.read_text())
    return {"memory_stores": raw.get("memory_stores") or [],
            "vaults": raw.get("vaults") or []}


def compile_agent(manifest: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    payload = {k: manifest[k] for k in AGENT_FIELDS if k in manifest}
    unsupported = [k for k in manifest if k not in AGENT_FIELDS]
    return payload, unsupported


def compile_environment() -> tuple[dict[str, Any], list[str]]:
    raw = yaml.safe_load((HERE / "pilot.environment.yaml").read_text())
    payload = {k: raw[k] for k in ENVIRONMENT_FIELDS if k in raw}
    # source: workshop agent_complete.py setup_environment — minimal cloud config
    payload.setdefault("config", {"type": "cloud"})
    unsupported = [k for k in raw if k not in ENVIRONMENT_FIELDS]
    return payload, unsupported


class IdResolver:
    """Name -> ID maps for the objects deployments reference.

    Empty maps (dry-run) resolve every name to an explicit placeholder so
    the compiled payload shows exactly what will be substituted live.
    """

    def __init__(self, agents: dict[str, tuple[str, int]] | None = None,
                 environments: dict[str, str] | None = None,
                 memory_stores: dict[str, str] | None = None,
                 vaults: dict[str, str] | None = None) -> None:
        self.agents = agents or {}
        self.environments = environments or {}
        self.memory_stores = memory_stores or {}
        self.vaults = vaults or {}

    def agent_ref(self, name: str) -> dict[str, Any]:
        if name in self.agents:
            agent_id, version = self.agents[name]
            return {"type": "agent", "id": agent_id, "version": version}
        return {"type": "agent", "id": f"<unresolved:agent:{name}>"}

    def lookup(self, mapping: dict[str, str], kind: str, name: str) -> str:
        return mapping.get(name, f"<unresolved:{kind}:{name}>")


def compile_deployment(manifest: dict[str, Any],
                       ids: IdResolver) -> tuple[dict[str, Any], list[str]]:
    payload = {k: manifest[k] for k in DEPLOYMENT_VERBATIM_FIELDS if k in manifest}
    payload["agent"] = ids.agent_ref(manifest["agent"])
    payload["environment_id"] = ids.lookup(
        ids.environments, "environment", manifest["environment"])
    resources = []
    for res in manifest.get("resources") or []:
        if res.get("type") == "memory_store":
            res = dict(res)
            res["memory_store_id"] = ids.lookup(
                ids.memory_stores, "memory_store", res.pop("memory_store"))
        resources.append(res)
    if resources:
        payload["resources"] = resources
    if manifest.get("vaults"):
        payload["vault_ids"] = [
            ids.lookup(ids.vaults, "vault", name) for name in manifest["vaults"]
        ]
    unsupported = [k for k in manifest if k not in DEPLOYMENT_MANIFEST_FIELDS]
    return payload, unsupported


def make_client() -> Any:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("ANTHROPIC_API_KEY is not set. Export it in your shell before "
                 "running a real deployment (dry-run needs no key).")
    from anthropic import Anthropic
    return Anthropic()


def upsert_agent(client: Any, payload: dict[str, Any],
                 existing: dict[str, Any]) -> tuple[str, Any]:
    name = payload["name"]
    if name in existing:
        current = client.beta.agents.retrieve(existing[name].id)
        updated = client.beta.agents.update(
            current.id, version=current.version,
            **{k: v for k, v in payload.items() if k != "name"})
        return "updated", updated
    created = client.beta.agents.create(**payload)
    return "created", created


def upsert_environment(client: Any, payload: dict[str, Any]) -> tuple[str, str]:
    for env in client.beta.environments.list():
        if env.name == payload["name"]:
            return "exists (left untouched)", env.id
    created = client.beta.environments.create(**payload)
    return "created", created.id


def upsert_memory_store(client: Any, spec: dict[str, Any]) -> tuple[str, str]:
    for store in client.beta.memory_stores.list():
        if store.name == spec["name"]:
            return "exists (left untouched)", store.id
    created = client.beta.memory_stores.create(
        name=spec["name"], description=spec.get("description"))
    return "created", created.id


def upsert_vault(client: Any, spec: dict[str, Any]) -> tuple[str, str]:
    for vault in client.beta.vaults.list():
        if vault.display_name == spec["display_name"]:
            return "exists (left untouched)", vault.id
    created = client.beta.vaults.create(display_name=spec["display_name"])
    return "created", created.id


def upsert_deployment(client: Any, payload: dict[str, Any]) -> tuple[str, str]:
    # source: SDK deployment_update_params.py — update accepts the same
    # fields as create (initial_events/resources are full replacement,
    # passing agent re-pins), so the compiled payload is reused verbatim.
    for depl in client.beta.deployments.list():
        if depl.name == payload["name"]:
            updated = client.beta.deployments.update(
                depl.id, **{k: v for k, v in payload.items() if k != "name"})
            return "updated", updated.id
    created = client.beta.deployments.create(**payload)
    return "created", created.id


def summarize(payload: dict[str, Any]) -> dict[str, Any]:
    out = dict(payload)
    if isinstance(out.get("system"), str):
        out["system"] = out["system"][:120] + f"... [{len(payload['system'])} chars]"
    return out


def print_compiled(env_payload: dict[str, Any], env_unsupported: list[str],
                   agents: list[tuple[str, dict[str, Any], list[str]]],
                   deployments: list[tuple[str, dict[str, Any], list[str]]]) -> None:
    print("== Compiled environment ==")
    print(json.dumps(summarize(env_payload), indent=2))
    if env_unsupported:
        print(f"   FINDING: keys not in CreateEnvironment schema: {env_unsupported}")
    for fname, payload, unsupported in agents:
        print(f"== Compiled agent {fname} ==")
        print(json.dumps(summarize(payload), indent=2))
        if unsupported:
            print(f"   FINDING: keys not in CreateAgent schema: {unsupported}")
    for fname, payload, unsupported in deployments:
        print(f"== Compiled deployment {fname} ==")
        print(json.dumps(summarize(payload), indent=2))
        if unsupported:
            print(f"   FINDING: keys not in the deployment manifest schema: "
                  f"{unsupported}")


def deploy_core(client: Any, env_payload: dict[str, Any],
                agents: list[tuple[str, dict[str, Any], list[str]]],
                ids: IdResolver) -> int:
    failures = 0
    try:
        action, env_id = upsert_environment(client, env_payload)
        ids.environments[env_payload["name"]] = env_id
        print(f"environment {env_payload['name']}: {action} -> {env_id}")
    except Exception as exc:  # report and continue: env rejection must not block agents
        failures += 1
        print(f"environment {env_payload['name']}: REJECTED -> {exc}")

    existing = {a.name: a for a in client.beta.agents.list()}
    for _, payload, _ in agents:
        try:
            action, agent = upsert_agent(client, payload, existing)
            ids.agents[payload["name"]] = (agent.id, agent.version)
            print(f"agent {payload['name']}: {action} -> {agent.id} "
                  f"(version {agent.version})")
        except Exception as exc:
            failures += 1
            print(f"agent {payload['name']}: REJECTED -> {exc}")
    return failures


def deploy_engagement(client: Any, engagement: dict[str, Any],
                      ids: IdResolver) -> int:
    failures = 0
    for spec in engagement["memory_stores"]:
        try:
            action, store_id = upsert_memory_store(client, spec)
            ids.memory_stores[spec["name"]] = store_id
            print(f"memory store {spec['name']}: {action} -> {store_id}")
        except Exception as exc:
            failures += 1
            print(f"memory store {spec['name']}: REJECTED -> {exc}")
    for spec in engagement["vaults"]:
        try:
            action, vault_id = upsert_vault(client, spec)
            ids.vaults[spec["display_name"]] = vault_id
            print(f"vault {spec['display_name']}: {action} -> {vault_id}")
        except Exception as exc:
            failures += 1
            print(f"vault {spec['display_name']}: REJECTED -> {exc}")
    return failures


def deploy_deployments(client: Any,
                       manifests: list[tuple[str, dict[str, Any]]],
                       ids: IdResolver) -> int:
    failures = 0
    for fname, manifest in manifests:
        payload, _ = compile_deployment(manifest, ids)
        unresolved = sorted(set(re.findall(r"<unresolved:[^>]+>",
                                           json.dumps(payload))))
        if unresolved:
            failures += 1
            print(f"deployment {payload['name']}: SKIPPED -> unresolved "
                  f"references {unresolved} (a prerequisite object failed above)")
            continue
        try:
            action, depl_id = upsert_deployment(client, payload)
            print(f"deployment {payload['name']}: {action} -> {depl_id}")
        except Exception as exc:
            failures += 1
            print(f"deployment {payload['name']}: REJECTED -> {exc}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="compile and print payloads without calling the API")
    args = parser.parse_args()

    env_payload, env_unsupported = compile_environment()
    agents = [(fname, *compile_agent(manifest))
              for fname, manifest in load_agent_manifests()]
    engagement = load_engagement()
    deployment_manifests = load_deployment_manifests()
    previews = [
        (fname, *compile_deployment(manifest, IdResolver()))
        for fname, manifest in deployment_manifests
    ]
    print_compiled(env_payload, env_unsupported, agents, previews)

    if args.dry_run:
        return 0

    client = make_client()
    ids = IdResolver()
    failures = deploy_core(client, env_payload, agents, ids)
    failures += deploy_engagement(client, engagement, ids)
    failures += deploy_deployments(client, deployment_manifests, ids)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
