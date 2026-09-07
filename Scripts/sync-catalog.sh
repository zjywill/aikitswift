#!/usr/bin/env bash
#
# Syncs the provider catalog from a models.dev checkout or live API.
#
# models.dev owns the provider/model metadata. AIKit keeps its small, stable
# JSON shape as a compatibility boundary and only copies fields that its
# Codable types understand at runtime.
#
# Usage:
#   Scripts/sync-catalog.sh <path-to-models.dev-checkout>
#
# Set AIKIT_CATALOG_SRC to avoid passing the path every time.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${AIKIT_CATALOG_SRC:-}}"
DEST="$REPO_ROOT/Sources/AIKit/Catalog/providers"

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "error: pass a models.dev repository checkout" >&2
    echo "       Scripts/sync-catalog.sh <path-to-models.dev-checkout>" >&2
    echo "       (or set AIKIT_CATALOG_SRC)" >&2
    exit 1
fi

UPSTREAM_SHA="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"

API_JSON="${AIKIT_CATALOG_API:-$SRC/.sync/aikit-api.json}"

if [ -n "${AIKIT_CATALOG_API:-}" ] && [ ! -f "$API_JSON" ]; then
    echo "error: AIKIT_CATALOG_API does not exist: $API_JSON" >&2
    exit 1
elif [ -f "$SRC/packages/web/dist/_api.json" ]; then
    mkdir -p "$SRC/.sync"
    cp "$SRC/packages/web/dist/_api.json" "$SRC/.sync/aikit-api.json"
    API_JSON="$SRC/.sync/aikit-api.json"
elif [ -f "$API_JSON" ] && [ "$(find "$API_JSON" -mmin -60 2>/dev/null)" ]; then
    :
else
    mkdir -p "$SRC/.sync"
    echo "fetching https://models.dev/api.json"
    curl -fsSL --max-time 120 "https://models.dev/api.json" -o "$API_JSON"
fi

python3 - "$SRC" "$API_JSON" "$DEST" "$UPSTREAM_SHA" <<'PY'
import json, os, sys, glob, collections
try:
    import tomllib
except ImportError:
    tomllib = None

src_root, api_path, dest, sha = sys.argv[1:5]

with open(api_path) as fh:
    upstream = json.load(fh)

# These are the protocol families AIKit implements. Provider packages with a
# bespoke SDK are intentionally left out until AIKit has a matching wire
# implementation; including them as OpenAI-compatible would be misleading.
SUPPORTED_NPM = {
    "@ai-sdk/anthropic": "anthropic",
    "@ai-sdk/google": "gemini",
    "@ai-sdk/google-vertex": "gemini",
    "@ai-sdk/google-vertex/anthropic": "anthropic",
    "@ai-sdk/openai": "openai",
    "@ai-sdk/openai-compatible": "openai",
    "@ai-sdk/xai": "openai",
    "@openrouter/ai-sdk-provider": "openai",
}

# models.dev also lists local runtimes. Their endpoint and model list are
# facts about one machine, not about a service — an app offers them by
# pointing a custom entry at localhost, so the catalog leaves them out.
LOCAL_RUNTIMES = {"lmstudio", "ollama"}

DEFAULT_APIS = {
    "anthropic": "https://api.anthropic.com",
    "openai": "https://api.openai.com/v1",
    "google": "https://generativelanguage.googleapis.com",
    "deepseek": "https://api.deepseek.com",
}


def read_provider_toml(provider_id):
    if tomllib is None:
        return {}
    path = os.path.join(src_root, "providers", provider_id, "provider.toml")
    if not os.path.isfile(path):
        return {}
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def adapter_for(npm, provider_id, existing):
    if existing:
        return existing
    if provider_id == "openai":
        return "openai-responses"
    return SUPPORTED_NPM.get(npm)


def infer_type(model):
    modalities = model.get("modalities") or {}
    inputs = set(modalities.get("input") or [])
    outputs = set(modalities.get("output") or [])
    label = f"{model.get('id', '')} {model.get('name', '')} {model.get('family', '')}".lower()

    if "realtime" in label:
        return "realtime"
    if outputs == {"image"}:
        return "image-generation"
    if "image" in outputs and any(token in label for token in ("image", "banana", "imagen", "dall")):
        return "image-generation"
    if outputs == {"audio"} and "text" in inputs:
        if any(token in label for token in ("tts", "speech", "voice")):
            return "speech-synthesis"
    if outputs == {"text"} and "audio" in inputs and any(
        token in label for token in ("asr", "transcrib", "whisper", "speech")
    ):
        return "speech-transcription"
    if "embedding" in label:
        return "other"
    return "chat"


def normalize_reasoning(value, previous):
    if isinstance(value, dict):
        return value
    if value is True:
        if isinstance(previous, dict):
            supported = previous.get("supported", True)
            default = previous.get("default", False)
            budget = previous.get("budget")
            out = {"supported": supported, "default": default}
            if budget is not None:
                out["budget"] = budget
            return out
        return {"supported": True, "default": False}
    if value is False:
        return {"supported": False}
    if isinstance(previous, dict):
        return previous
    return None


def transform_model(model, previous=None):
    previous = previous or {}
    out = {}
    for key, value in model.items():
        if key == "reasoning":
            normalized = normalize_reasoning(value, previous.get("reasoning"))
            if normalized is not None:
                out["reasoning"] = normalized
        else:
            out[key] = value

    name = out.get("name")
    if name:
        out.setdefault("display_name", name)
    # Prefer a confident non-chat inference over a stale previous "chat"
    # label (e.g. gpt-realtime-* previously kept as chat).
    if "type" not in out:
        inferred = infer_type(out)
        if inferred != "chat":
            out["type"] = inferred
        else:
            out["type"] = previous.get("type") or inferred
    return out


def provider_api(local_id, upstream_id, upstream_entry, existing, toml):
    if toml.get("api"):
        return toml["api"]
    if local_id in DEFAULT_APIS:
        return DEFAULT_APIS[local_id]
    return upstream_entry.get("api")


existing_paths = sorted(glob.glob(os.path.join(dest, "*.json")))
existing_by_id = {}
for path in existing_paths:
    with open(path) as fh:
        existing_by_id[json.load(fh)["id"]] = path

updated = 0
added = 0
skipped = 0
unsupported = 0
adapters = collections.Counter()
model_count = 0
seen_paths = set()

def sync_one(local_id, upstream_id, path, existing=None):
    global updated, added, model_count
    upstream_entry = upstream.get(upstream_id)
    if upstream_entry is None:
        return False

    toml = read_provider_toml(upstream_id)
    npm = upstream_entry.get("npm") or toml.get("npm")
    adapter = adapter_for(npm, local_id, (existing or {}).get("adapter"))
    if not adapter:
        return False

    previous_models = {m["id"]: m for m in (existing or {}).get("models", []) if "id" in m}
    models = [
        transform_model(
            dict(upstream_entry["models"][model_id], id=upstream_entry["models"][model_id].get("id", model_id)),
            previous_models.get(model_id),
        )
        for model_id in sorted(upstream_entry.get("models", {}))
    ]

    provider = {
        "id": local_id,
        "name": upstream_entry.get("name") or (existing or {}).get("name"),
        "adapter": adapter,
        "models": models,
    }

    api = provider_api(local_id, upstream_id, upstream_entry, existing or {}, toml)
    if api:
        provider["api"] = api

    for key in ("doc", "display_name", "reasoning_toggle"):
        if existing and key in existing:
            provider[key] = existing[key]
        elif key in upstream_entry:
            provider[key] = upstream_entry[key]
        elif key in toml:
            provider[key] = toml[key]

    if local_id in ("google", "google-vertex") and not provider.get("api"):
        provider["api"] = DEFAULT_APIS["google"]
    elif local_id == "openai" and not provider.get("api"):
        provider["api"] = DEFAULT_APIS["openai"]
    elif local_id == "anthropic" and not provider.get("api"):
        provider["api"] = DEFAULT_APIS["anthropic"]

    with open(path, "w") as fh:
        json.dump(provider, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    if existing:
        updated += 1
    else:
        added += 1
    adapters[adapter] += 1
    model_count += len(models)
    seen_paths.add(path)
    return True

for upstream_id in sorted(upstream):
    if upstream_id in LOCAL_RUNTIMES:
        unsupported += 1
        continue
    entry = upstream[upstream_id]
    toml = read_provider_toml(upstream_id)
    npm = entry.get("npm") or toml.get("npm")
    if npm not in SUPPORTED_NPM:
        unsupported += 1
        continue
    path = existing_by_id.get(upstream_id, os.path.join(dest, f"{upstream_id}.json"))
    existing = None
    if os.path.isfile(path):
        with open(path) as fh:
            existing = json.load(fh)
    sync_one(upstream_id, upstream_id, path, existing)

# The catalog is a mirror of models.dev's compatible subset. Remove files from
# previous sync sources so stale aliases and local-only providers cannot leak
# back into the shipped resource bundle.
for path in existing_paths:
    if path not in seen_paths and os.path.exists(path):
        os.remove(path)
        skipped += 1

count = len(glob.glob(os.path.join(dest, "*.json")))
lines = [
    "# Provider catalog provenance",
    "",
    "Vendored provider definitions. Each file names a provider's base URL, its",
    "models, and the `adapter` identifying which wire protocol it speaks.",
    "",
    f"- Upstream commit: `{sha}`",
    f"- Providers: {count}",
    f"- Models: {model_count}",
    f"- Updated from upstream: {updated}",
    f"- Added from upstream: {added}",
    f"- Removed from previous catalog: {skipped}",
    f"- Unsupported upstream providers omitted: {unsupported}",
    "",
    "## Adapters in use",
    "",
    "| Adapter | Providers |",
    "|---|---|",
]
for adapter, n in adapters.most_common():
    lines.append(f"| `{adapter}` | {n} |")
lines += [
    "",
    "This distribution is the argument for the whole architecture: many",
    "providers, few protocols. Implementing one adapter correctly serves every",
    "provider that points at it, and adding a provider is a config file that",
    "needs no new wire tests.",
    "",
    "Refresh with `Scripts/sync-catalog.sh`.",
]

with open(os.path.join(dest, os.pardir, "PROVENANCE.md"), "w") as fh:
    fh.write("\n".join(lines) + "\n")

print(f"  {count} providers, {model_count} models ({updated} updated, {added} added, {skipped} removed)")
for adapter, n in adapters.most_common():
    print(f"    {adapter}: {n}")
PY

echo "synced catalog from $UPSTREAM_SHA -> $DEST"
