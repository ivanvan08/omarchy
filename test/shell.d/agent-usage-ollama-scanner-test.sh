#!/bin/bash

# The Ollama Cloud collector's own parts: the ollama-cloud filter over pi and
# omp sessions with model tags merged, the configured model prefix, Ollama's
# usage and plan answers, and its key. Roots, forks, cloud-tagged models
# through the local daemon, both opencode stores, OPENCODE_DB and untrusted
# values are held by the shared and partition tests, as is the
# unused-machine record; the limits and scan caches go through the contract
# checks.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/agent-usage-helpers.sh"

agent_sandbox

python3 - <<'PY'
from agent_usage_fixtures import *

import sqlite3

# The checks below compare today's totals with rows stamped now.
freeze_today()
USAGE = "ollama.com/api/usage"
ME = "ollama.com/api/me"
ROUTES = {
  USAGE: {
    "activity": {"cost": "0.00"},
    "limits": {
      "session": {"usage": 0.434, "models": [{"name": "deepseek-v4-pro:0813", "request_count": 340}]},
      "weekly": {"usage": 0.298, "models": [{"name": "kimi-k3", "request_count": 377}]},
    },
  },
  ME: {"Plan": "pro"},
}


def ollama(*args, routes=None, mode="up"):
  with FakeHttp(ROUTES if routes is None else routes, mode=mode) as http:
    record = collect("ollama", *(args or ("--force",)))
  ollama.requests = http.count
  return record


def sessions():
  return home() / ".pi" / "agent" / "sessions"


def prefix(value):
  if value is None:
    (config_home() / "omarchy" / "agents" / "ollama.json").unlink()
  else:
    write_json(config_home() / "omarchy" / "agents" / "ollama.json", {"modelPrefix": value})


# ------------------------------------------------------------ local stats

# pi and omp sessions on the ollama-cloud provider are the local stats; other
# providers and prompts in the same files stay out, and model version tags
# merge.
sandbox()
write_pi_session(sessions() / "project" / "pi.jsonl", [
  pi_reply("ollama-cloud", id="pi-1", model="deepseek-v4-pro:0813", usage={"input": 10, "output": 4, "cacheRead": 3, "cacheWrite": 2, "totalTokens": 19}),
  pi_reply("ollama-cloud", id="pi-2", model="deepseek-v4-pro:0731", usage={"input": 5, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 6}),
  pi_reply("anthropic", id="pi-3", model="claude-test", usage={"input": 999, "output": 999}),
  {"type": "message", "id": "pi-4", "timestamp": iso_in(0), "message": {"role": "user", "provider": "ollama-cloud", "model": "deepseek-v4-pro:0813", "usage": {"input": 999, "output": 999}}},
  pi_reply("ollama-cloud", id="pi-5", model="deepseek-v4-pro:0813", usage={"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0}),
])
write_pi_session(home() / ".omp" / "agent" / "sessions" / "project" / "omp.jsonl", [
  pi_reply("ollama-cloud", id="omp-1", model="kimi-k3", usage={"input": 20, "output": 5, "cacheRead": 4, "cacheWrite": 1, "totalTokens": 30}),
])
record = ollama()
expect("Ollama counts ollama-cloud usage from pi and omp, merging model tags", [record["name"], record["todayTotalTokens"], record["modelUsage"]], ["Ollama Cloud", 55, {
  "deepseek-v4-pro": {"inputTokens": 15, "outputTokens": 5, "cacheReadInputTokens": 3, "cacheCreationInputTokens": 2},
  "kimi-k3": {"inputTokens": 20, "outputTokens": 5, "cacheReadInputTokens": 4, "cacheCreationInputTokens": 1},
}], record)

# In use here, but no key to ask for the account's limits.
expect("Ollama in use without a key waits for auth", [record["ready"], record["usageStatusText"], record["limitsStale"], ollama.requests],
       [True, "Waiting for auth", False, 0], record)

# A configured model prefix restricts the local stats to matching models, and
# a scan only answers for the filter it applied: the same filter reuses it,
# another scans again.
prefix("kimi")
expect("Ollama honors the configured model prefix", list(ollama()["modelUsage"]), ["kimi-k3"])
expect("Ollama reuses a scan made with the same model prefix", list(ollama("--limits-only")["modelUsage"]), ["kimi-k3"])
prefix(None)
expect("Ollama scans again when the model prefix changes", sorted(ollama("--limits-only")["modelUsage"]), ["deepseek-v4-pro", "kimi-k3"])

# ---------------------------------------------------------------- contract

sandbox()


def add_reply():
  add_reply.count = getattr(add_reply, "count", 0) + 1
  write_pi_session(sessions() / "grown" / f"{add_reply.count}.jsonl", [pi_reply("ollama-cloud", 5, id=f"grown-{add_reply.count}")])


# A probe asks for the usage and then the plan. Ollama's usage answer names no
# reset times, so no kept window can elapse; the contract's check that kept
# limits come back as they were measured covers how they are kept.
adapter = Adapter("ollama", plant=lambda: os.environ.update(OLLAMA_API_KEY="key"), answer=ROUTES, requests_per_probe=2,
                  skip=("elapsed",), grow=add_reply, pi_root=sessions)
fresh = check_limits_contract(adapter)
expect("Ollama's plan and its session and weekly fractions come from its answers, with no reset times made up", {
  "tierLabel": fresh["tierLabel"], "limits": fresh["limits"],
}, {
  "tierLabel": "Pro", "limits": [
    {"label": "Session (5-hour)", "percent": 0.434, "resetsAt": ""},
    {"label": "Weekly (7-day)", "percent": 0.298, "resetsAt": ""},
  ],
}, fresh)
check_scan_cache(adapter)

# ---------------------------------------------------------------- the key

# A rejected key is a sign-in to redo, and says so.
record = ollama(mode=401)
check("Ollama explains a rejected key", "rejected" in record["authHelpText"], record)

# A plan lookup that fails keeps the plan last named.
record = ollama(routes={**ROUTES, ME: urllib.error.URLError(OSError("plan lookup timed out"))})
expect("Ollama keeps the cached plan when the plan lookup fails", [record["tierLabel"], record["limitsStale"]], ["Pro", False], record)

# An answer never rolls back one another run stamped while this one waited
# on the network.
def later_run(request):
  edit_limits_cache("ollama", fetched_ago=-60)
  return ROUTES[USAGE]


ollama(routes={**ROUTES, USAGE: later_run})
expect("Ollama never overwrites a newer cached answer with its own",
       [json.loads(path.read_text())["fetchedAtMs"] > ms_in(30) for path in limits_cache_files("ollama")], [True])
edit_limits_cache("ollama", fetched_ago=0)

# Another key never shows this one's numbers or plan.
os.environ["OLLAMA_API_KEY"] = "other-key"
record = ollama(mode="down")
expect("Ollama keeps each key's limits and plan apart", [record["limits"], record["tierLabel"], record["usageStatusText"]],
       [[], "", "Ollama limits unavailable"], record)

# ---------------------------------------------------------- the answer

# With nothing kept, a failed check says the limits are unavailable; only an
# unreachable endpoint asks for an early retry.
sandbox()
os.environ["OLLAMA_API_KEY"] = "key"
record = ollama(mode="down")
expect("Ollama offline with nothing kept says its limits are unavailable and advises a retry",
       [record["usageStatusText"], record.get("retryAdvised")], ["Ollama limits unavailable", True], record)
record = ollama(mode=500)
expect("Ollama advises no retry for a server's error status", [record["usageStatusText"], record.get("retryAdvised")],
       ["Ollama limits unavailable", None], record)

# An answer with no usable windows explains itself instead of printing none.
record = ollama(routes={USAGE: {"limits": {"session": {"usage": "unknown"}, "weekly": None}}, ME: {"Plan": "pro"}})
expect("Ollama reports an answer without usable limits", [record["limits"], record["usageStatusText"], "no limits" in record["authHelpText"]],
       [[], "Ollama limits unavailable", True], record)

# A window used past its allowance reads as full, never above it.
record = ollama(routes={USAGE: {"limits": {"session": {"usage": 1.7}, "weekly": {"usage": 0.2}}}, ME: {"Plan": "pro"}})
expect("Ollama caps a window used past its allowance at full", [entry["percent"] for entry in record["limits"]], [1.0, 0.2], record)

# Without OLLAMA_API_KEY, the key pi or omp signed in with stands in, pi's
# first, and goes out as a Bearer token on both requests. A pi `$VAR` or
# `!command` entry is pi's to resolve, never a key to send.
sandbox()
pi_auth(home() / ".omp" / "agent", "ollama-cloud", "omp-key")
pi_auth(None, "ollama-cloud", "pi-key")
with FakeHttp(ROUTES) as http:
  record = collect("ollama", "--force")
expect("Ollama asks with pi's saved key before omp's, as a Bearer token",
       [sorted({request["headers"].get("authorization") for request in http.requests}), len(http.requests), len(record["limits"])],
       [["Bearer pi-key"], 2, 2], record)
pi_auth(None, "ollama-cloud", "$OLLAMA_KEY")
expect("Ollama passes over pi's $VAR entry to omp's key", load_collector("ollama").api_key(), "omp-key")
pi_auth(home() / ".omp" / "agent", "ollama-cloud", "!pass show ollama")
expect("Ollama never sends a pi $VAR or !command entry as a key", load_collector("ollama").api_key(), "")

# omp keeps the key it signed in with in its agent.db, never in an auth.json;
# a key it disabled is passed over, and PI_CODING_AGENT_DIR moves the
# database with the rest of omp's tree.
def omp_key(directory, *rows):
  database = Path(directory) / "agent.db"
  database.parent.mkdir(parents=True, exist_ok=True)
  conn = sqlite3.connect(database)
  conn.execute("CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT)")
  for provider, key, disabled in rows:
    conn.execute("INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause) VALUES (?, 'api_key', ?, ?)",
                 (provider, json.dumps({"key": key, "source": "login"}), disabled))
  conn.commit()
  conn.close()


sandbox()
omp_key(home() / ".omp" / "agent", ("ollama-cloud", "omp-db-key", None), ("ollama-cloud", "revoked-key", "revoked"), ("zai", "zai-key", None))
pi_auth(home() / ".omp" / "agent", "ollama-cloud", "omp-json-key")
expect("Ollama asks with the key omp keeps in its agent.db, passing over a disabled one", load_collector("ollama").api_key(), "omp-db-key")
sandbox()
omp_key(home() / "moved", ("ollama-cloud", "moved-key", None))
os.environ["PI_CODING_AGENT_DIR"] = str(home() / "moved")
expect("Ollama finds omp's agent.db where PI_CODING_AGENT_DIR puts it", load_collector("ollama").api_key(), "moved-key")

# ------------------------------------------------------------- the credits

# A plan on Ollama's credit pricing answers with the dollars spent and no
# windows. The plan's monthly credit, from Ollama's pricing, is the funded
# side, an estimate since the credit resets on a day the API doesn't name; a
# spend past it stops the balance at zero; a plan with no published credit
# shows none, and none of it is trouble.
sandbox()
os.environ["OLLAMA_API_KEY"] = "key"
CREDITS = {"range": "30d", "scope": "self", "totals": {"request_count": 40, "usage_usd": 12.5, "input_tokens": 9000, "cached_input_tokens": 100, "output_tokens": 800}, "buckets": []}
with FakeHttp({USAGE: CREDITS, ME: {"Plan": "pro"}}) as http:
  record = collect("ollama", "--force")
expect("Ollama shows a credit plan's spend against its monthly credit, asking for the last 30 days",
       [record["tierLabel"], record["limits"], record["usageStatusText"], record["limitsStale"], record.get("balance"),
        [request["url"] for request in http.requests if USAGE in request["url"]]],
       ["Pro", [], "", False, {"remaining": 47.5, "funded": 60.0, "spent": 12.5, "currency": "USD", "estimated": True},
        ["https://ollama.com/api/usage?range=30d"]], record)

record = ollama("--limits-only", routes={USAGE: CREDITS, ME: {"Plan": "pro"}})
expect("Ollama reuses a recent credit answer, which has no windows", [ollama.requests, record["balance"]["spent"]], [0, 12.5], record)

record = ollama("--force", mode="down")
expect("Ollama keeps a credit plan's balance past a failed check", [record.get("balance", {}).get("remaining"), record["limitsStale"], record["usageStatusText"]],
       [47.5, True, ""], record)

record = ollama(routes={USAGE: {**CREDITS, "totals": {"usage_usd": 75}}, ME: {"Plan": "max"}})
expect("Ollama measures Max against its own credit", record.get("balance"),
       {"remaining": 225.0, "funded": 300.0, "spent": 75.0, "currency": "USD", "estimated": True}, record)
record = ollama(routes={USAGE: {**CREDITS, "totals": {"usage_usd": 75}}, ME: {"Plan": "pro"}})
expect("Ollama stops a spend past the credit at an empty balance", record.get("balance", {}).get("remaining"), 0.0, record)

record = ollama(routes={USAGE: CREDITS, ME: {"Plan": "free"}})
expect("Ollama shows a plan with no published credit without a balance or trouble",
       ["balance" in record, record["tierLabel"], record["usageStatusText"], record["ready"]], [False, "Free", "", True], record)

record = ollama(routes={USAGE: {**CREDITS, "totals": {"usage_usd": "lots"}}, ME: {"Plan": "pro"}})
expect("Ollama reports a credit answer without a usable spend", ["balance" in record, record["usageStatusText"]],
       [False, "Ollama limits unavailable"], record)
PY
