#!/bin/bash

# Tokens are counted once, under the provider that bills them: pi, omp and
# opencode sessions are split by provider into the matching collector, and
# the `local` collector is the exact complement for self-hosted runtimes. Each
# collector's own test checks its own filter; this one runs every collector
# against one machine holding usage on every provider any of them claims, and
# checks the filters add up to a partition: each provider counted by exactly
# one collector, an unclaimed provider by none, and no copy counted twice.
# Every collector reads those shared sources the same way, so the fixture
# also holds each case where the copies once drifted: forks, compactions, a
# relocated opencode database, a moved pi tree, and a root nested in another.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3
require_command rg
require_command timeout

COLLECTOR_TIMEOUT=${AGENT_USAGE_PARTITION_TIMEOUT:-60}
TIMEOUT=$(command -v timeout)

# Every fixture row is today's, and the collectors run as their own processes,
# where no frozen clock reaches. A run that crossed local midnight would see
# its rows land on yesterday, so one that would start that close waits for the
# new day instead.
seconds_to_midnight=$(( $(date -d 'tomorrow 00:00' +%s) - $(date +%s) ))
if (( seconds_to_midnight < 120 )); then
  sleep $(( seconds_to_midnight + 1 ))
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

collectors=()
for collector in "$ROOT"/bin/omarchy-agent-usage-*; do
  [[ ${collector##*/omarchy-agent-usage-} == "update" ]] && continue
  collectors+=("${collector##*/omarchy-agent-usage-}")
done
(( ${#collectors[@]} > 0 )) || fail "agent usage collectors are found under bin/"

# Only what the collectors need to read their sources: Python and rg. No
# agent CLI (codex, gh, omp, secret-tool, mise) can be found, so none is
# spawned, and nothing holds a credential.
mkdir -p "$WORK/bin"
ln -s "$(command -v python3)" "$WORK/bin/python3"
ln -s "$(command -v rg)" "$WORK/bin/rg"

# Each run gets the environment below and nothing else: no API key from the
# developer's shell leaks in, and every HTTP(S) request goes to a proxy on a
# port nothing listens on, so a collector that does reach for the network
# fails at once instead of talking to a real service.
run_collector() {
  local home="$1" id="$2" out="$3" status=0
  shift 3
  env -i \
    HOME="$home" \
    PATH="$WORK/bin" \
    LANG=C.UTF-8 \
    ${TZ+TZ="$TZ"} \
    OMARCHY_PATH="$ROOT" \
    OMARCHY_LANGUAGE_FILE="$OMARCHY_LANGUAGE_FILE" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_RUNTIME_DIR="$home/.run" \
    http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    ALL_PROXY=http://127.0.0.1:9 \
    "$@" \
    "$TIMEOUT" --kill-after=5 "$COLLECTOR_TIMEOUT" "$ROOT/bin/omarchy-agent-usage-$id" --force \
    >"$out.json" 2>"$out.err" || status=$?
  echo "$status" >"$out.status"
}

# Runs every collector against one home, in parallel, into a results dir.
run_all() {
  local home="$1" results="$2" id
  shift 2
  mkdir -p "$results" "$home/.cache" "$home/.run"
  for id in "${collectors[@]}"; do
    run_collector "$home" "$id" "$results/$id" "$@" &
  done
  wait
}

# ------------------------------------------------------------------ fixture

# One machine with usage on every provider id a collector claims, in every
# store pi, omp and opencode keep:
#
# - pi and omp's default session roots, a profiles/<name>/agent/sessions root
#   under each, and a pi tree PI_CODING_AGENT_DIR moves elsewhere, read as
#   well as the default one.
# - A forked pi session repeating its parent's lines with their ids and
#   timestamps, which count once.
# - A pi profile symlinked into the default root, so its sessions sit inside
#   another root: its lines carry no id, so only dropping the nested root
#   keeps them from counting twice.
# - Usage kept only as totalTokens, which still counts, and a line dated at
#   the epoch's zero, which counts nowhere.
# - A compaction's usage, which names no provider and bills the model of the
#   reply before it.
# - opencode's database with rows only in the original `message` store, rows
#   only in the V2 `session_message` store, rows migrated into both under one
#   id (counted once), compactions (counted like replies), thinking tokens
#   (counted as output), a forked session whose copies of its source's
#   messages count nowhere while its own reply does, and a row dated at zero,
#   which counts nowhere either.
# - Codex rollouts on the built-in provider, on `--oss`'s local daemon (a
#   cloud-tagged model and a local one), on a provider named `ollama-cloud`,
#   on LM Studio, and on a custom provider nothing can place.
# - DeepSeek Harness logs on its DeepSeek routes, pi-ai's openrouter route
#   and a hand-declared gateway; Kimchi harness sessions on its gateway,
#   `--provider openrouter` and a custom provider; and MiniMax Code replies
#   on its own route and on custom providers at MiniMax, OpenRouter, Z.ai,
#   this machine, an unplaceable gateway, and one gone from its config.
#
# Every row carries a unique tag (zqNNN) in its model name and a
# recognizable token total, 100 * provider + source, so a collector's
# modelUsage says exactly which rows it counted and how many times.
FIXTURE_HOME="$WORK/home"
mkdir -p "$FIXTURE_HOME"

python3 - "$FIXTURE_HOME" "$WORK/cells.json" <<'PY'
import json
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

home = Path(sys.argv[1])
cells_path = Path(sys.argv[2])

# (provider, model stem, api, owner on pi/omp, owner on opencode). An owner of
# None means nobody may count it; "-" means the harness never records it.
#
# - pi's `openai` is an OpenAI API key, which no collector bills; opencode's
#   `openai` is the ChatGPT sign-in the Codex collector reads.
# - pi records an Antigravity sign-in as `google-antigravity`; opencode's
#   Antigravity plugin records a `google` provider (`google`, `google-vertex`)
#   with an `antigravity-` model.
PROVIDERS = [
  ("anthropic", "claude-pt", "", "claude", "claude"),
  ("openai-codex", "gpt-pt", "openai-codex-responses", "codex", "-"),
  ("openai", "gpt-pt", "openai-codex-responses", "codex", "-"),
  ("openai", "gpt-pt", "", "-", "codex"),
  ("opencode", "zen-pt", "", "opencode", "opencode"),
  ("opencode-go", "go-pt", "", "opencode", "opencode"),
  ("ollama-cloud", "cloud-pt", "", "ollama", "ollama"),
  ("ollama", "tagged-pt@:cloud", "", "ollama", "ollama"),
  ("ollama", "tagged-pt@:120b-cloud", "", "ollama", "ollama"),
  ("ollama", "plain-pt@:8b", "", "local", "local"),
  ("lmstudio", "plain-pt", "", "local", "local"),
  ("deepseek", "deepseek-pt", "", "deepseek", "deepseek"),
  ("zai", "glm-pt", "", "zai", "zai"),
  ("zhipu", "glm-pt", "", "zai", "zai"),
  ("minimax", "minimax-pt", "", "minimax", "minimax"),
  ("minimax-cn", "minimax-pt", "", "minimax", "minimax"),
  ("minimax-coding-plan", "minimax-pt", "", "minimax", "minimax"),
  ("minimax-cn-coding-plan", "minimax-pt", "", "minimax", "minimax"),
  ("openrouter", "router-pt", "", "openrouter", "openrouter"),
  ("google-antigravity", "antigravity-pt", "", "agy", "-"),
  ("google", "antigravity-pt", "", "-", "agy"),
  ("google-vertex", "antigravity-pt", "", "-", "agy"),
  ("devin", "devin-pt", "", "devin", "devin"),
  ("synthetic", "synthetic-pt", "", "synthetic", "synthetic"),
  ("mistral", "devstral-pt", "", "vibe", "vibe"),
  ("meta", "muse-spark-pt", "", "muse", "muse"),
  ("alibaba-coding-plan", "qwen-pt", "", "qwen", "qwen"),
  ("alibaba-coding-plan-cn", "qwen-pt", "", "qwen", "qwen"),
  ("alibaba-token-plan", "qwen-pt", "", "qwen", "qwen"),
  ("alibaba-token-plan-cn", "qwen-pt", "", "qwen", "qwen"),
  ("qwen-token-plan", "qwen-pt", "", "qwen", "qwen"),
  ("qwen-token-plan-cn", "qwen-pt", "", "qwen", "qwen"),
  ("qwen-token-plan-individual", "qwen-pt", "", "qwen", "qwen"),
  ("qwen-portal", "qwen-pt", "", "qwen", "qwen"),
  ("kimi-coding", "kimi-pt", "", "kimi", "kimi"),
  ("kimi-code-plan-global", "kimi-pt", "", "kimi", "kimi"),
  ("kimi-code-plan-cn", "kimi-pt", "", "kimi", "kimi"),
  # Moonshot's pay-as-you-go API counts under Kimi, as Claude Code's turns
  # to it do; Alibaba's pay-as-you-go keys carry no plan.
  ("alibaba", "qwen-pt", "", None, None),
  ("moonshotai", "kimi-pt", "", "kimi", "kimi"),
  ("moonshotai-cn", "kimi-pt", "", "kimi", "kimi"),
  ("acme-unclaimed", "acme-pt", "", None, None),
]

PI_SOURCES = [
  ("pi", home / ".pi/agent/sessions/project"),
  ("omp", home / ".omp/agent/sessions/project"),
  ("pi-profile", home / ".pi/profiles/work/agent/sessions/project"),
  ("omp-profile", home / ".omp/profiles/work/agent/sessions/project"),
  # PI_CODING_AGENT_DIR=$HOME/pi-moved on every fixture run.
  ("pi-moved", home / "pi-moved/sessions/project"),
  # ~/.pi/profiles/nest links here, inside the default root.
  ("pi-nested", home / ".pi/agent/sessions/nest-profile/agent/sessions/project"),
  ("omp-total", home / ".omp/agent/sessions/total"),
  ("omp-zero-stamp", home / ".omp/agent/sessions/zero"),
  ("pi-compaction", home / ".pi/agent/sessions/compacted"),
]
OC_SOURCES = ["opencode-message", "opencode-session_message", "opencode-migrated", "opencode-compaction",
              "opencode-reasoning", "opencode-fork-copy", "opencode-fork-reply", "opencode-zero-stamp",
              "opencode-message-fork-copy", "opencode-message-fork-reply"]

now = datetime.now(timezone.utc)
stamp = now.isoformat(timespec="milliseconds").replace("+00:00", "Z")
now_ms = int(time.time() * 1000) - 1000
# The forked session began a minute ago: its copies of the source session's
# messages predate it, its own reply doesn't.
fork_ms = now_ms - 60_000

cells = []
lines = {name: [] for name, _ in PI_SOURCES}
message_rows, session_rows = [], []


def model_for(stem, tag):
  # A stem of "name@:tag" keeps the Ollama tag after the unique marker, so a
  # collector that strips tags still sees which row it counted.
  base, _, suffix = stem.partition("@")
  return f"{base}-{tag}{suffix}"


for p, (provider, stem, api, pi_owner, oc_owner) in enumerate(PROVIDERS, 1):
  for s, (source, _) in enumerate(PI_SOURCES, 1):
    if pi_owner == "-":
      continue
    tag = f"zq{len(cells):03d}"
    tokens = 100 * p + s
    usage = {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0}
    if source == "omp-total":
      usage = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": tokens}
    message = {"role": "assistant", "provider": provider, "model": model_for(stem, tag), "usage": usage}
    if api:
      message["api"] = api
    line = {"type": "message", "id": f"{source}-{tag}", "timestamp": 0 if source == "omp-zero-stamp" else stamp, "message": message}
    if source == "pi-nested":
      del line["id"]
    if source == "pi-compaction":
      # A compaction names no provider: it ran on the model of the reply
      # before it, here one that spent nothing itself.
      lines[source].append({**line, "id": f"{source}-{tag}-reply", "message": {**message, "usage": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}})
      line = {"type": "compaction", "id": f"{source}-{tag}", "timestamp": stamp, "summary": "s", "firstKeptEntryId": "x", "tokensBefore": tokens, "usage": usage}
    lines[source].append(line)
    owner = None if source == "omp-zero-stamp" else pi_owner
    cells.append({"tag": tag, "provider": provider, "api": api, "source": source, "tokens": tokens, "owner": owner})
  for s, source in enumerate(OC_SOURCES, len(PI_SOURCES) + 1):
    if oc_owner == "-":
      continue
    tag = f"zq{len(cells):03d}"
    tokens = 100 * p + s
    model = model_for(stem, tag)
    counts = {"input": tokens, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}
    if source == "opencode-reasoning":
      counts = {"input": tokens - 7, "output": 0, "reasoning": 7, "cache": {"read": 0, "write": 0}}
    created = 0 if source == "opencode-zero-stamp" else now_ms
    v1 = json.dumps({"role": "assistant", "providerID": provider, "modelID": model, "tokens": counts, "time": {"created": created}})
    v2 = json.dumps({"model": {"providerID": provider, "id": model}, "tokens": counts, "time": {"created": now_ms}})
    message_id = f"msg_{tag}"
    if source in ("opencode-message", "opencode-migrated", "opencode-reasoning", "opencode-zero-stamp"):
      message_rows.append((message_id, f"ses_{source}", now_ms, now_ms, v1))
    if source in ("opencode-session_message", "opencode-migrated"):
      session_rows.append((message_id, f"ses_{source}", "assistant", now_ms, v2))
    if source == "opencode-compaction":
      session_rows.append((message_id, f"ses_{source}", "compaction", now_ms, v2))
    if source == "opencode-fork-copy":
      session_rows.append((message_id, "ses_fork", "assistant", fork_ms - 5_000, v2))
    if source == "opencode-fork-reply":
      session_rows.append((message_id, "ses_fork", "assistant", now_ms, v2))
    if source == "opencode-message-fork-copy":
      # As opencode 1.19.3's `run --fork` writes one into the original store:
      # a plain new session, the copy under a new id, its time the source's.
      message_rows.append((message_id, "ses_message_fork", now_ms, now_ms, json.dumps({**json.loads(v1), "time": {"created": fork_ms - 5_000}})))
    if source == "opencode-message-fork-reply":
      message_rows.append((message_id, "ses_message_fork", now_ms, now_ms, v1))
    owner = None if source in ("opencode-fork-copy", "opencode-zero-stamp", "opencode-message-fork-copy") else oc_owner
    cells.append({"tag": tag, "provider": provider, "api": "", "source": source, "tokens": tokens, "owner": owner})

for source, directory in PI_SOURCES:
  directory.mkdir(parents=True, exist_ok=True)
  with (directory / "session.jsonl").open("w") as handle:
    for line in lines[source]:
      handle.write(json.dumps(line) + "\n")

# A fork of the default pi session, in another project: its parent's lines
# again, under the same ids and timestamps.
fork = home / ".pi/agent/sessions/forked"
fork.mkdir(parents=True)
with (fork / "session.jsonl").open("w") as handle:
  for line in lines["pi"]:
    handle.write(json.dumps(line) + "\n")

# Relative, so a copy of this home keeps pointing into itself.
(home / ".pi/profiles/nest").symlink_to("../agent/sessions/nest-profile")

# The schema the opencode collector's own tests build: the original store and
# the V2 one side by side, as a database opencode has migrated looks.
db = home / ".local/share/opencode/opencode.db"
db.parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db)
conn.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
conn.execute("CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, time_created integer NOT NULL, data text NOT NULL)")
conn.execute("CREATE TABLE session_v2 (id text PRIMARY KEY, fork_session_id text, time_created integer NOT NULL)")
conn.execute("INSERT INTO session_v2 VALUES ('ses_fork', 'ses_opencode-session_message', ?)", (fork_ms,))
conn.execute("CREATE TABLE session (id text PRIMARY KEY, parent_id text, title text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL)")
conn.execute("INSERT INTO session VALUES ('ses_message_fork', NULL, 'Mock reply (fork #1)', ?, ?)", (fork_ms, fork_ms))
conn.executemany("INSERT INTO message VALUES (?, ?, ?, ?, ?)", message_rows)
conn.executemany("INSERT INTO session_message VALUES (?, ?, ?, ?, ?)", session_rows)
conn.commit()
conn.close()


# Codex rollouts, as Codex 0.163 writes them: the built-in `openai` provider
# is the Codex collector's, `--oss` on the local daemon's `ollama` provider is
# the local collector's unless the model is cloud-tagged (Ollama Cloud's), a
# provider named `ollama-cloud` is Ollama Cloud's, LM Studio is local, and a
# custom provider nothing can place is nobody's.
CODEX_ROLLOUTS = [
  ("openai", "gpt-codex@", "codex"),
  ("ollama", "gpt-oss@:120b-cloud", "ollama"),
  ("ollama-cloud", "qwen-codex@", "ollama"),
  ("ollama", "plain-codex@:20b", "local"),
  ("lmstudio", "plain-codex@", "local"),
  ("acme-unclaimed", "acme-codex@", None),
]
rollouts = home / ".codex/sessions" / datetime.now().strftime("%Y/%m/%d")
rollouts.mkdir(parents=True)
for n, (provider, stem, owner) in enumerate(CODEX_ROLLOUTS):
  tag = f"zq{len(cells):03d}"
  tokens = 80000 + 100 * n
  base, _, suffix = stem.partition("@")
  lines = [
    {"timestamp": stamp, "type": "session_meta", "payload": {"model_provider": provider}},
    {"timestamp": stamp, "type": "turn_context", "payload": {"model": f"{base}-{tag}{suffix}"}},
    {"timestamp": stamp, "type": "event_msg", "payload": {"type": "user_message", "message": "go"}},
    {"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count", "info": {
      "last_token_usage": {"input_tokens": tokens, "output_tokens": 0}, "total_token_usage": {"input_tokens": tokens}}}},
  ]
  (rollouts / f"rollout-{tag}.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
  cells.append({"tag": tag, "provider": provider, "api": "", "source": "codex-rollout", "tokens": tokens, "owner": owner})


# DeepSeek Harness session logs, one per route, as dsh 0.2 writes them (left
# uncompressed): its DeepSeek routes and pi-ai's `deepseek` are DeepSeek's,
# pi-ai's `openrouter` OpenRouter's, and a hand-declared gateway nobody's.
DSH_ROUTES = [
  ("deepseek-official", "deepseek-dsh@", "deepseek"),
  ("deepseek", "deepseek-piai@", "deepseek"),
  ("openrouter", "router-dsh@", "openrouter"),
  ("acme-gateway", "acme-dsh@", None),
]
for n, (provider, stem, owner) in enumerate(DSH_ROUTES):
  tag = f"zq{len(cells):03d}"
  tokens = 81000 + 100 * n
  log = home / f".dsh/sessions/--home-me--/session-{tag}/session.v4.jsonl"
  log.parent.mkdir(parents=True)
  log.write_text("".join(json.dumps(record) + "\n" for record in (
    {"type": "session", "version": 4, "id": f"dsh-{tag}", "createdAt": now_ms, "isSeeded": False},
    {"type": "request/header", "seq": 1, "time": now_ms, "data": {"header": {"config": {"provider": provider, "model": model_for(stem, tag)}}}},
    {"type": "assistant/message", "seq": 2, "time": now_ms, "data": {"turn": 1, "step": 1, "usage": {"inputTokens": tokens}}},
  )))
  cells.append({"tag": tag, "provider": provider, "api": "", "source": "dsh", "tokens": tokens, "owner": owner})

# Kimchi's harness sessions, in pi's format: its own gateway routes are
# Kimchi's, a session run with `--provider openrouter` OpenRouter's, and one
# on a custom provider nobody's.
kimchi_lines = []
for n, (provider, stem, owner) in enumerate([
  ("kimchi-dev/zai", "glm-kimchi@", "kimchi"),
  ("openrouter", "router-kimchi@", "openrouter"),
  ("my-gateway", "acme-kimchi@", None),
]):
  tag = f"zq{len(cells):03d}"
  tokens = 82000 + 100 * n
  kimchi_lines.append({"type": "message", "id": f"kimchi-{tag}", "timestamp": stamp,
                       "message": {"role": "assistant", "provider": provider, "model": model_for(stem, tag), "usage": {"input": tokens}}})
  cells.append({"tag": tag, "provider": provider, "api": "", "source": "kimchi-harness", "tokens": tokens, "owner": owner})
kimchi_sessions = home / ".config/kimchi/harness/sessions/--home-me--"
kimchi_sessions.mkdir(parents=True)
(kimchi_sessions / "session.jsonl").write_text("".join(json.dumps(line) + "\n" for line in kimchi_lines))

# MiniMax Code sessions, one per route, and the custom providers its
# config.yaml declares: its own routes are MiniMax's, a custom provider
# whatever its baseURL's host bills (MiniMax, OpenRouter, Z.ai, this
# machine), and one at a gateway nothing can place, or gone from the config,
# nobody's.
MCODE_ROUTES = [
  ("minimax", "MiniMax-mcode@", "minimax"),
  ("custom_provider:mm", "MiniMax-custom@", "minimax"),
  ("custom_provider:router", "router-mcode@", "openrouter"),
  ("custom_provider:zed", "glm-mcode@", "zai"),
  ("custom_provider:box", "plain-mcode@", "local"),
  ("custom_provider:acme", "acme-mcode@", None),
  ("custom_provider:gone", "acme-gone@", None),
]
(home / ".minimax").mkdir()
(home / ".minimax/config.yaml").write_text("""logLevel: info
custom_provider:
  mm:
    name: mm
    kind: custom
    options:
      apiKey: sk-placeholder
      baseURL: https://api.minimax.io/anthropic
  router:
    name: router
    api: openai-completions
    options:
      apiKey: sk-placeholder
      baseURL: https://openrouter.ai/api/v1
  zed:
    options:
      baseURL: "https://api.z.ai/api/coding/paas/v4"
  box:
    options:
      baseURL: http://127.0.0.1:8080/v1 # llama.cpp
  acme:
    options:
      baseURL: https://llm.acme.example/v1
""")
for n, (provider, stem, owner) in enumerate(MCODE_ROUTES):
  tag = f"zq{len(cells):03d}"
  tokens = 83000 + 100 * n
  session = home / f".minimax/v2/sessions/2026/01/01/{tag}/messages.jsonl"
  session.parent.mkdir(parents=True)
  session.write_text("".join(json.dumps(line) + "\n" for line in (
    {"message": {"role": "user", "timestamp": now_ms, "content": "go"}},
    {"message": {"role": "assistant", "timestamp": now_ms, "provider": provider, "model": model_for(stem, tag), "usage": {"input": tokens}}},
  )))
  cells.append({"tag": tag, "provider": provider, "api": "", "source": "mcode", "tokens": tokens, "owner": owner})


# Codex 0.163 rollouts with a remote compaction, as it writes one: a
# token_usage_record for every response, the compaction's included, where the
# token_count after the compaction spends nothing and the next one counts only
# the reply. A record repeated under the same id and running total is one
# response.
CODEX_RECORD_ROLLOUTS = [
  ("openai", "gpt-record@", "codex"),
  ("ollama-cloud", "qwen-record@", "ollama"),
  ("lmstudio", "plain-record@", "local"),
]
for n, (provider, stem, owner) in enumerate(CODEX_RECORD_ROLLOUTS):
  tag = f"zq{len(cells):03d}"
  compaction, reply = 84000 + 100 * n, 1000 + n
  first = {"input_tokens": compaction, "output_tokens": 0}
  thread = {"input_tokens": compaction + reply, "output_tokens": 0}
  usage_record = {"timestamp": stamp, "type": "token_usage_record", "payload": {
    "turn_id": "turn-1", "response_id": "resp_mock_0002", "usage": {"input_tokens": reply, "output_tokens": 0}, "thread_token_usage": thread}}
  lines = [
    {"timestamp": stamp, "type": "session_meta", "payload": {"model_provider": provider, "source": "exec"}},
    {"timestamp": stamp, "type": "turn_context", "payload": {"model": model_for(stem, tag)}},
    {"timestamp": stamp, "type": "token_usage_record", "payload": {
      "turn_id": "turn-1", "response_id": "resp_mock_0001", "usage": first, "thread_token_usage": first}},
    {"timestamp": stamp, "type": "compacted", "payload": {"message": ""}},
    {"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count", "info": {
      "last_token_usage": {"input_tokens": 0, "output_tokens": 0}, "total_token_usage": {}}}},
    {"timestamp": stamp, "type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "UserMessage", "id": "u1", "content": []}}},
    usage_record,
    {"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count", "info": {
      "last_token_usage": {"input_tokens": reply, "output_tokens": 0}, "total_token_usage": {"input_tokens": reply, "output_tokens": 0}}}},
    usage_record,
  ]
  (rollouts / f"rollout-{tag}.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
  cells.append({"tag": tag, "provider": provider, "api": "", "source": "codex-record-rollout", "tokens": compaction + reply, "owner": owner})

cells_path.write_text(json.dumps(cells))
PY

EMPTY_HOME="$WORK/empty"
mkdir -p "$EMPTY_HOME"

# The empty home runs in a zone whose day differs from the system zone's, so
# a collector dating its record by /etc/localtime rather than the caller's TZ
# shows. +14 and -12 hours are never both on the system's day; the days on
# either side of the run cover one that straddles that zone's midnight.
EMPTY_TZ=Pacific/Kiritimati
if [[ $(TZ=$EMPTY_TZ date +%F) == "$(env -u TZ date +%F)" ]]; then
  EMPTY_TZ=Etc/GMT+12
fi
TZ=$EMPTY_TZ date +%F >"$WORK/empty-days"
TZ=$EMPTY_TZ run_all "$EMPTY_HOME" "$WORK/empty-results"
TZ=$EMPTY_TZ date +%F >>"$WORK/empty-days"
run_all "$FIXTURE_HOME" "$WORK/results" PI_CODING_AGENT_DIR="$FIXTURE_HOME/pi-moved"

# The same machine with opencode's database moved by OPENCODE_DB. A relative
# name resolves beside the default one, as opencode itself resolves it.
RELOCATED_HOME="$WORK/relocated"
cp -a "$FIXTURE_HOME" "$RELOCATED_HOME"
rm -rf "$RELOCATED_HOME/.cache"
mkdir -p "$RELOCATED_HOME/.local/share/opencode/moved"
mv "$RELOCATED_HOME/.local/share/opencode/opencode.db" "$RELOCATED_HOME/.local/share/opencode/moved/elsewhere.db"
run_all "$RELOCATED_HOME" "$WORK/relocated-results" PI_CODING_AGENT_DIR="$RELOCATED_HOME/pi-moved" OPENCODE_DB=moved/elsewhere.db

# A local.json naming every claimed provider (and a self-hosted box of its
# own) must not pull any of them into the local collector. Fireworks counts
# its whole account rather than these rows, so no cell owns its pi turns, but
# naming fireworks or fireworks-ai in local.json must not count them twice.
CONFIGURED_HOME="$WORK/configured"
cp -a "$FIXTURE_HOME" "$CONFIGURED_HOME"
rm -rf "$CONFIGURED_HOME/.cache"
mkdir -p "$CONFIGURED_HOME/.config/omarchy/agents" "$CONFIGURED_HOME/.pi/agent/sessions/fireworks"
python3 - "$WORK/cells.json" "$CONFIGURED_HOME/.config/omarchy/agents/local.json" "$CONFIGURED_HOME/.pi/agent/sessions/fireworks/session.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timezone

cells = json.load(open(sys.argv[1]))
providers = sorted({cell["provider"] for cell in cells if cell["owner"] and cell["owner"] != "local"} | {"fireworks", "fireworks-ai"})
json.dump({"providers": providers}, open(sys.argv[2], "w"))
stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
with open(sys.argv[3], "w") as handle:
  for provider in ("fireworks", "fireworks-ai"):
    message = {"role": "assistant", "provider": provider, "model": f"{provider}-account-pt", "usage": {"input": 77, "output": 0, "cacheRead": 0, "cacheWrite": 0}}
    handle.write(json.dumps({"type": "message", "id": f"fw-{provider}", "timestamp": stamp, "message": message}) + "\n")
PY
mkdir -p "$CONFIGURED_HOME/.cache" "$CONFIGURED_HOME/.run"
run_collector "$CONFIGURED_HOME" local "$WORK/configured-local" PI_CODING_AGENT_DIR="$CONFIGURED_HOME/pi-moved"

# OpenRouter reads no local usage at all without a key, so the keyless run
# above can only show it missing everything. A placeholder key, with every
# request going to the dead proxy, shows what its own filter counts.
run_collector "$FIXTURE_HOME" openrouter "$WORK/keyed-openrouter" OPENROUTER_API_KEY=sk-or-placeholder PI_CODING_AGENT_DIR="$FIXTURE_HOME/pi-moved"


# Claude Code fronts whatever ANTHROPIC_BASE_URL names, and its transcripts
# record only the model that answered each reply. One home holds a reply by
# each kind of model (and a fork's copy of one), and every collector runs
# against it once per endpoint Claude Code can be sent to; each reply must
# land in exactly the collector that bills it there, or in none.
CLAUDE_HOME="$WORK/claude-code"
mkdir -p "$CLAUDE_HOME"
python3 - "$CLAUDE_HOME" "$WORK/claude-cells.json" "$WORK/claude-endpoints" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

home = Path(sys.argv[1])
stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
# (model, owner with no endpoint, owner behind a self-hosted one, owner
# behind a gateway nothing can place). A provider's own host owns them all.
MODELS = [
  ("claude-sonnet-zq900", "claude", "claude", "claude"),
  ("glm-zq901", "zai", "local", None),
  ("MiniMax-zq902", "minimax", "local", None),
  ("deepseek-zq903", "deepseek", "local", None),
  ("kimi-zq904", "kimi", "local", None),
  ("moonshot-zq905", "kimi", "local", None),
  ("gpt-oss-zq906:120b-cloud", "ollama", "ollama", "ollama"),
  ("qwen3-zq907", None, "local", None),
]
ENDPOINTS = {
  "": 1, "https://api.z.ai/api/anthropic": "zai", "https://ollama.com": "ollama", "https://openrouter.ai/api": "openrouter",
  "https://api.minimax.io/anthropic": "minimax", "https://api.deepseek.com/anthropic": "deepseek",
  "https://api.kimi.com/coding/": "kimi", "http://localhost:11434": 2, "https://llm-proxy.example.com/anthropic": 3,
}
projects = home / ".claude/projects/project"
projects.mkdir(parents=True)
lines, cells = [], []
for n, (model, *owners) in enumerate(MODELS):
  tokens = 90000 + 100 * n
  lines.append({"type": "user", "uuid": f"prompt-{n}", "sessionId": "main", "timestamp": stamp, "message": {"role": "user", "content": "go"}})
  lines.append({"type": "assistant", "sessionId": "main", "timestamp": stamp, "requestId": f"req-{n}",
                "message": {"id": f"msg-{n}", "role": "assistant", "model": model, "usage": {"input_tokens": tokens, "output_tokens": 0}}})
  for index, (url, owner) in enumerate(ENDPOINTS.items()):
    cells.append({"endpoint": index, "url": url, "tag": re.search(r"zq\d{3}", model).group(0), "model": model, "tokens": tokens,
                  "owner": owners[owner - 1] if isinstance(owner, int) else owner})
(projects / "main.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
# A fork copies the first reply into a session of its own.
(projects / "fork.jsonl").write_text(json.dumps({**lines[1], "sessionId": "fork"}) + "\n")
Path(sys.argv[2]).write_text(json.dumps(cells))
Path(sys.argv[3]).write_text("".join(url + "\n" for url in ENDPOINTS))
PY
mapfile -t claude_endpoints <"$WORK/claude-endpoints"
for endpoint in "${!claude_endpoints[@]}"; do
  url=${claude_endpoints[endpoint]}
  if [[ -n $url ]]; then
    run_all "$CLAUDE_HOME" "$WORK/claude-results-$endpoint" ANTHROPIC_BASE_URL="$url"
  else
    run_all "$CLAUDE_HOME" "$WORK/claude-results-$endpoint"
  fi
done

# ----------------------------------------------------------------- analysis

python3 - "$WORK" "${collectors[@]}" >"$WORK/report.tsv" <<'PY'
import json
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
collectors = sys.argv[2:]
cells = {cell["tag"]: cell for cell in json.load(open(work / "cells.json"))}
empty_days = set((work / "empty-days").read_text().split())

STATS = ["todayPrompts", "todaySessions", "todayTotalTokens", "todayTokensByModel", "recentDays",
         "totalPrompts", "totalSessions", "activeDays", "activeDates", "modelUsage"]
# The fields every record carries, per the contract's record table and the
# reference collector. retryAdvised, hasPromptStats, scope, balance and
# accounts are conditional and checked only for shape when present.
REQUIRED = ["schemaVersion", "id", "name", "updatedAt", "ready", "tierLabel", "usageStatusText",
            "authHelpText", "limits", "limitsStale", "limitsFetchedAt", "hasLocalStats"] + STATS
BUCKET = ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"]

results = []


def report(check, ok, detail=""):
  results.append((check, ok, detail))


def load(prefix):
  status = (work / f"{prefix}.status").read_text().strip()
  raw = (work / f"{prefix}.json").read_text()
  err = (work / f"{prefix}.err").read_text().strip()
  if status != "0":
    return None, f"exited {status}{' (timed out)' if status in ('124', '137') else ''}: {err[-400:]}"
  try:
    record = json.loads(raw)
  except ValueError:
    return None, f"printed no JSON record: {raw[:200]!r} {err[-200:]}"
  if not isinstance(record, dict):
    return None, f"printed a non-object: {raw[:200]!r}"
  return record, ""


def shape_problems(cid, record):
  problems = [f"missing {key}" for key in REQUIRED if key not in record]
  if record.get("schemaVersion") != 1:
    problems.append(f"schemaVersion {record.get('schemaVersion')!r}")
  if record.get("id") != cid:
    problems.append(f"id {record.get('id')!r}")
  for key in ("ready", "limitsStale", "hasLocalStats"):
    if key in record and not isinstance(record[key], bool):
      problems.append(f"{key} is not a boolean")
  for key in ("retryAdvised", "hasPromptStats"):
    if key in record and not isinstance(record[key], bool):
      problems.append(f"{key} is not a boolean")
  if "scope" in record and record["scope"] != "account":
    problems.append(f"scope {record['scope']!r}")
  for key in ("name", "updatedAt", "tierLabel", "usageStatusText", "authHelpText"):
    if key in record and not isinstance(record[key], str):
      problems.append(f"{key} is not a string")
  if "limits" in record and not isinstance(record["limits"], list):
    problems.append("limits is not a list")
  if "recentDays" in record and (not isinstance(record["recentDays"], list) or len(record["recentDays"]) != 7):
    problems.append("recentDays is not seven days")
  if "modelUsage" in record and isinstance(record["modelUsage"], dict):
    for model, bucket in record["modelUsage"].items():
      if not isinstance(bucket, dict) or any(key not in bucket for key in BUCKET):
        problems.append(f"modelUsage[{model}] lacks the token buckets")
  elif "modelUsage" in record:
    problems.append("modelUsage is not an object")
  return problems


# 1. Every collector in an empty home: the unused-machine record.
for cid in collectors:
  record, error = load(f"empty-results/{cid}")
  if record is None:
    report("empty-home", False, f"{cid}: {error}")
    continue
  problems = shape_problems(cid, record)
  if record.get("ready") is not False:
    problems.append(f"ready {record.get('ready')!r}")
  if record.get("usageStatusText") != "":
    problems.append(f"usageStatusText {record.get('usageStatusText')!r} (authHelpText {record.get('authHelpText')!r})")
  elif record.get("authHelpText") != "":
    problems.append(f"authHelpText {record.get('authHelpText')!r} with no status")
  if record.get("limits"):
    problems.append("limits not empty")
  if record.get("tierLabel") != "":
    problems.append(f"tierLabel {record.get('tierLabel')!r}")
  if "balance" in record:
    problems.append("has a balance")
  if any(record.get(key) for key in ("todayPrompts", "todaySessions", "todayTotalTokens", "totalPrompts", "totalSessions", "activeDays")) \
      or record.get("todayTokensByModel") or record.get("modelUsage") or record.get("activeDates"):
    problems.append("stats not empty")
  if record.get("retryAdvised"):
    problems.append("retryAdvised with nothing to retry")
  days = record.get("recentDays") or [{}]
  if days[-1].get("date") not in empty_days:
    problems.append(f"recentDays ends {days[-1].get('date')!r}, not the caller's TZ day ({', '.join(sorted(empty_days))})")
  report("empty-home", not problems, f"{cid}: {'; '.join(problems)}" if problems else cid)


def counted(record):
  """tag -> tokens a record counted for that fixture row, and keys matching none."""
  per_tag, strays = {}, []
  for model, bucket in (record.get("modelUsage") or {}).items():
    total = sum(bucket.get(key) or 0 for key in BUCKET) if isinstance(bucket, dict) else 0
    tags = re.findall(r"zq\d{3}", model)
    if len(tags) != 1 or tags[0] not in cells:
      if total:
        strays.append(f"{model}={total}")
      continue
    per_tag[tags[0]] = per_tag.get(tags[0], 0) + total
  return per_tag, strays


# 2. The partition.
counts = {tag: {} for tag in cells}
collector_totals = {}
fixture_counts = {}
for cid in collectors:
  record, error = load(f"results/{cid}")
  if record is None:
    report("fixture-run", False, f"{cid}: {error}")
    continue
  problems = shape_problems(cid, record)
  report("fixture-shape", not problems, f"{cid}: {'; '.join(problems)}" if problems else cid)
  per_tag, strays = counted(record)
  fixture_counts[cid] = per_tag
  for tag, total in per_tag.items():
    counts[tag][cid] = total
  if strays:
    report("attribution", False, f"{cid}: modelUsage keys that name no fixture row: {', '.join(strays)}")
  today = record.get("todayTotalTokens") or 0
  collector_totals[cid] = today
  model_sum = sum(per_tag.values())
  if today != model_sum:
    report("today-matches-models", False, f"{cid}: todayTotalTokens {today} but modelUsage over fixture rows sums to {model_sum}")
  else:
    report("today-matches-models", True, cid)

claimed_total = 0
for tag, cell in sorted(cells.items()):
  owner, tokens = cell["owner"], cell["tokens"]
  label = f"{cell['provider']}{' api=' + cell['api'] if cell['api'] else ''} via {cell['source']} ({tag}, {tokens} tokens)"
  seen = counts[tag]
  if owner:
    claimed_total += tokens
  wrong = []
  for cid, total in sorted(seen.items()):
    times = total / tokens
    if cid != owner:
      wrong.append(f"{cid} counted it" + (f" {times:g}x" if times != 1 else ""))
    elif total != tokens:
      wrong.append(f"{cid} counted it {times:g}x")
  if owner is None:
    report("unclaimed", not wrong, f"{label}: {'; '.join(wrong)}" if wrong else label)
    continue
  if owner not in seen:
    wrong.insert(0, f"{owner} missed it")
  report("partition", not wrong, f"{label}, expected {owner}: {'; '.join(wrong)}" if wrong else label)

grand = sum(collector_totals.values())
report("sum", grand == claimed_total, f"claimed providers total {claimed_total}, collectors' todayTotalTokens sum to {grand}"
       + "".join(f"\n    {cid}={total}" for cid, total in sorted(collector_totals.items()) if total))

# 3. The database moved by OPENCODE_DB counts exactly the rows it did in place.
for cid in collectors:
  record, error = load(f"relocated-results/{cid}")
  if record is None:
    report("opencode-db-env", False, f"{cid}: {error}")
    continue
  if cid not in fixture_counts:
    continue
  per_tag, _ = counted(record)
  before = fixture_counts[cid]
  changed = []
  for tag in sorted(set(per_tag) | set(before)):
    if per_tag.get(tag, 0) != before.get(tag, 0):
      cell = cells[tag]
      changed.append(f"{cell['provider']} via {cell['source']} ({tag}) {before.get(tag, 0)} -> {per_tag.get(tag, 0)}")
  report("opencode-db-env", not changed, f"{cid}: {'; '.join(changed)}" if changed else cid)

# 4. A local.json naming every claimed provider.
record, error = load("configured-local")
if record is None:
  report("local-config", False, f"local: {error}")
else:
  per_tag, strays = counted(record)
  leaked = sorted({f"{cells[tag]['provider']}" for tag in per_tag if cells[tag]["owner"] != "local"} |
                  {stray.partition("-account-pt=")[0] for stray in strays if "-account-pt=" in stray})
  missed = sorted({cells[tag]["provider"] + " via " + cells[tag]["source"] for tag in cells if cells[tag]["owner"] == "local" and tag not in per_tag})
  problems = ([f"counts claimed providers it was configured with: {', '.join(leaked)}"] if leaked else []) + \
             ([f"missed {', '.join(missed)}"] if missed else [])
  report("local-config", not problems, f"local: {'; '.join(problems)}" if problems else "local")

# 5. OpenRouter with a key: its own filter, once each, and nothing else.
record, error = load("keyed-openrouter")
if record is None:
  report("openrouter-keyed", False, f"openrouter: {error}")
else:
  per_tag, strays = counted(record)
  problems = [f"stray {', '.join(strays)}"] if strays else []
  for tag, cell in sorted(cells.items()):
    total = per_tag.get(tag, 0)
    label = f"{cell['provider']} via {cell['source']} ({tag})"
    if cell["owner"] == "openrouter" and total != cell["tokens"]:
      problems.append(f"{label} counted {total / cell['tokens']:g}x")
    elif cell["owner"] != "openrouter" and total:
      problems.append(f"{label} counted, owned by {cell['owner']}")
  report("openrouter-keyed", not problems, f"openrouter: {'; '.join(problems)}" if problems else "openrouter")

# 6. Claude Code's replies, behind every endpoint it can be sent to.
claude_cells = json.load(open(work / "claude-cells.json"))
for endpoint in sorted({cell["endpoint"] for cell in claude_cells}):
  cells_here = {cell["tag"]: cell for cell in claude_cells if cell["endpoint"] == endpoint}
  url = next(iter(cells_here.values()))["url"] or "Anthropic (no ANTHROPIC_BASE_URL)"
  seen = {tag: {} for tag in cells_here}
  for cid in collectors:
    record, error = load(f"claude-results-{endpoint}/{cid}")
    if record is None:
      report("claude-code", False, f"{url}: {cid}: {error}")
      continue
    for model, bucket in (record.get("modelUsage") or {}).items():
      total = sum(bucket.get(key) or 0 for key in BUCKET) if isinstance(bucket, dict) else 0
      for tag in re.findall(r"zq\d{3}", model):
        if tag in seen and total:
          seen[tag][cid] = seen[tag].get(cid, 0) + total
  for tag, cell in sorted(cells_here.items()):
    owner, tokens = cell["owner"], cell["tokens"]
    wrong = [f"{cid} counted it {total / tokens:g}x" for cid, total in sorted(seen[tag].items()) if cid != owner or total != tokens]
    if owner and owner not in seen[tag]:
      wrong.insert(0, f"{owner} missed it")
    label = f"{cell['model']} sent to {url}, expected {owner or 'nobody'}"
    report("claude-code", not wrong, f"{label}: {'; '.join(wrong)}" if wrong else label)

for check, ok, detail in results:
  print(f"{check}\t{'ok' if ok else 'fail'}\t{detail}".replace("\n", "\\n"))
PY

# ------------------------------------------------------------------ verdict

declare -A DESCRIPTIONS=(
  [empty-home]="every collector prints the unused-machine record in an empty home: ready false, no plan, status or help, no limits, no balance, empty stats, the full field set, dated by the caller's TZ"
  [fixture-run]="every collector prints a record against the fixture home, offline and in time"
  [fixture-shape]="every collector's fixture record has the contract's full field set"
  [attribution]="every token a collector counts comes from a fixture row"
  [today-matches-models]="each collector's todayTotalTokens equals the fixture rows in its modelUsage"
  [partition]="each claimed provider's tokens are counted by exactly its collector, once, from every root and store, forks and nesting included"
  [unclaimed]="a provider no collector claims, a fork's copies of its source's messages, and rows dated at zero are counted by nobody"
  [sum]="the claimed providers' tokens equal the collectors' todayTotalTokens summed"
  [opencode-db-env]="with opencode's database moved by a relative OPENCODE_DB, every collector counts the same rows"
  [local-config]="a local.json naming claimed providers doesn't pull them into the local collector"
  [openrouter-keyed]="with a key, the OpenRouter collector counts exactly the OpenRouter rows, once each"
  [claude-code]="each Claude Code reply is counted once, by the collector that bills it behind every endpoint Claude Code can be sent to, or by none"
)
order=(empty-home fixture-run fixture-shape attribution today-matches-models partition unclaimed sum opencode-db-env local-config openrouter-keyed claude-code)

failed=()
details=""
for check in "${order[@]}"; do
  lines=$(awk -F'\t' -v c="$check" '$1 == c && $2 == "fail" { print "  " $3 }' "$WORK/report.tsv")
  if [[ -z $lines ]]; then
    pass "${DESCRIPTIONS[$check]}"
  else
    failed+=("$check")
    details+="${DESCRIPTIONS[$check]}:"$'\n'"${lines//\\n/$'\n'}"$'\n'
  fi
done

if (( ${#failed[@]} > 0 )); then
  fail "agent usage collectors partition tokens by provider (failing: ${failed[*]})" "$details"
fi

# ------------------------------------------------------- harness provider ids

# pi, omp and opencode each name a plan's provider their own way, so a plan
# a collector meters can reach it under several ids. One home holds a reply
# on each id below, written as pi 1.4.0, omp 18.12.6 and opencode 1.19.3
# wrote them for that provider, and each must be counted once, by its owner
# (Moonshot's pay-as-you-go API by Kimi).
IDS_HOME="$WORK/provider-ids"
mkdir -p "$IDS_HOME"
python3 - "$IDS_HOME" "$WORK/ids-cells.json" <<'PY'
import json
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

home = Path(sys.argv[1])
stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
now_ms = int(time.time() * 1000) - 1000
# (harness, provider, owner)
IDS = [
  ("pi", "zai-coding-cn", "zai"),
  ("omp", "zhipu-coding-plan", "zai"),
  ("omp", "kimi-code", "kimi"),
  ("omp", "muse-code", "muse"),
  ("omp", "moonshot", "kimi"),
  ("opencode", "zai-coding-plan", "zai"),
  ("opencode", "zhipuai-coding-plan", "zai"),
  ("opencode", "zhipuai", "zai"),
]
cells = []
rows = []
for n, (harness, provider, owner) in enumerate(IDS):
  tag = f"zq{700 + n}"
  model = f"ids-{tag}"
  tokens = 70000 + 100 * n
  usage = {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": tokens, "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}
  if harness == "opencode":
    rows.append((f"msg_{tag}", f"ses_{tag}", now_ms, now_ms, json.dumps({
      "parentID": f"msg_{tag}_u", "role": "assistant", "mode": "build", "agent": "build", "cost": 0,
      "tokens": {"total": tokens, "input": tokens, "output": 0, "reasoning": 0, "cache": {"write": 0, "read": 0}},
      "modelID": model, "providerID": provider, "time": {"created": now_ms, "completed": now_ms}, "finish": "stop"})))
  elif harness == "omp":
    runtime = {"version": "18.12.6"}
    lines = [
      {"type": "session", "version": 3, "id": f"s-{tag}", "timestamp": stamp, "cwd": "/home/me"},
      {"type": "model_change", "id": f"mc-{tag}", "parentId": None, "timestamp": stamp, "runtime": runtime, "model": f"{provider}/{model}", "resolvedModelIsFallback": False},
      {"type": "message", "id": f"u-{tag}", "parentId": f"mc-{tag}", "timestamp": stamp, "runtime": runtime, "message": {"role": "user", "content": [{"type": "text", "text": "Say hi"}], "attribution": "user", "timestamp": now_ms}},
      {"type": "message", "id": f"a-{tag}", "parentId": f"u-{tag}", "timestamp": stamp, "runtime": runtime, "message": {
        "role": "assistant", "content": [{"type": "text", "text": "hi"}], "api": "openai-completions", "provider": provider, "model": model,
        "usage": usage, "stopReason": "stop", "timestamp": now_ms}},
    ]
    path = home / f".omp/agent/sessions/-/{tag}.jsonl"
  else:
    lines = [
      {"type": "session", "version": 3, "id": f"s-{tag}", "timestamp": stamp, "cwd": "/home/me"},
      {"type": "model_change", "id": f"mc-{tag}", "parentId": None, "timestamp": stamp, "provider": provider, "modelId": model},
      {"type": "message", "id": f"u-{tag}", "parentId": f"mc-{tag}", "timestamp": stamp, "message": {"role": "user", "content": [{"type": "text", "text": "Say hi"}], "timestamp": now_ms}},
      {"type": "message", "id": f"a-{tag}", "parentId": f"u-{tag}", "timestamp": stamp, "message": {
        "role": "assistant", "content": [{"type": "text", "text": "hi"}], "api": "openai-completions", "provider": provider, "model": model,
        "usage": usage, "stopReason": "stop", "timestamp": now_ms}},
    ]
    path = home / f".pi/agent/sessions/--home-me--/{tag}.jsonl"
  if harness != "opencode":
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(line) + "\n" for line in lines))
  cells.append({"tag": tag, "harness": harness, "provider": provider, "tokens": tokens, "owner": owner})

db = home / ".local/share/opencode/opencode.db"
db.parent.mkdir(parents=True)
conn = sqlite3.connect(db)
conn.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
conn.executemany("INSERT INTO message VALUES (?, ?, ?, ?, ?)", rows)
conn.commit()
conn.close()
Path(sys.argv[2]).write_text(json.dumps(cells))
PY
run_all "$IDS_HOME" "$WORK/ids-results"

python3 - "$WORK" "${collectors[@]}" >"$WORK/ids-report.txt" <<'PY'
import json
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
cells = {cell["tag"]: cell for cell in json.load(open(work / "ids-cells.json"))}
seen = {tag: {} for tag in cells}
for cid in sys.argv[2:]:
  try:
    record = json.loads((work / f"ids-results/{cid}.json").read_text())
  except ValueError:
    print(f"{cid} printed no record: {(work / f'ids-results/{cid}.err').read_text()[-300:]}")
    continue
  for model, bucket in (record.get("modelUsage") or {}).items():
    total = sum(bucket.get(key) or 0 for key in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"))
    for tag in re.findall(r"zq\d{3}", model):
      if tag in seen and total:
        seen[tag][cid] = seen[tag].get(cid, 0) + total
for tag, cell in sorted(cells.items()):
  owner, tokens = cell["owner"], cell["tokens"]
  wrong = [f"{cid} counted it {total / tokens:g}x" for cid, total in sorted(seen[tag].items()) if cid != owner or total != tokens]
  if owner and owner not in seen[tag]:
    wrong.insert(0, f"{owner} missed it")
  if wrong:
    print(f"{cell['harness']}'s {cell['provider']} ({tag}), expected {owner or 'nobody'}: {'; '.join(wrong)}")
PY
if [[ -s $WORK/ids-report.txt ]]; then
  fail "each harness's own id for a plan is counted once, by the collector that meters it" "$(cat "$WORK/ids-report.txt")"
fi
pass "each harness's own id for a plan is counted once, by the collector that meters it"

# ----------------------------------------------------- harness stores' routes

# Kimi Code, Qwen Code, Hermes and Mistral Vibe keep stores of their own and
# record where each request went: each request on a route counts once, by
# the harness's own collector when its service billed it, by `local` on a
# server you run, and by nobody on any other provider or a gateway, since no
# other collector reads these stores.
HARNESS_HOME="$WORK/harnesses"
mkdir -p "$HARNESS_HOME"
python3 - "$HARNESS_HOME" "$WORK/harness-cells.json" <<'PY'
import json
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

home = Path(sys.argv[1])
now = time.time()
now_ms = int(now * 1000)
stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
cells = []


def cell(source, route, owner):
  tag = f"zq{900 + len(cells)}"
  tokens = 91000 + 100 * len(cells)
  cells.append({"tag": tag, "source": source, "route": route, "tokens": tokens, "owner": owner})
  return tag, tokens


# Kimi Code: a model alias per route in config.toml, one usage.record each.
KIMI_ROUTES = [
  ("plan", 'type = "kimi"\nbase_url = "https://api.kimi.com/coding/v1"', "kimi"),
  ("box", 'type = "kimi"\nbase_url = "http://192.168.1.20:8000/v1"', "local"),
  ("anth", 'type = "anthropic"', None),
  ("acme", 'type = "openai"\nbase_url = "https://llm.acme.example/v1"', None),
]
config, wire = [], []
for name, provider, owner in KIMI_ROUTES:
  tag, tokens = cell("kimi-code", name, owner)
  config.append(f'[providers.{name}]\n{provider}\napi_key = "k"\n\n[models."{name}/m-{tag}"]\nprovider = "{name}"\nmodel = "m-{tag}"\nmax_context_size = 1000\n')
  wire.append({"type": "usage.record", "agentId": "main", "model": f"{name}/m-{tag}", "usage": {"inputOther": tokens, "output": 0, "inputCacheRead": 0, "inputCacheCreation": 0}, "usageScope": "turn", "time": now_ms})
(home / ".kimi-code").mkdir()
(home / ".kimi-code" / "config.toml").write_text("\n".join(config))
path = home / ".kimi-code" / "sessions" / "wd_p_1" / "session_1" / "agents" / "main" / "wire.jsonl"
path.parent.mkdir(parents=True)
path.write_text("".join(json.dumps(line) + "\n" for line in wire))

# Qwen Code: settings.json's modelProviders say where each model goes.
QWEN_ROUTES = [
  ("openai", "https://coding-intl.dashscope.aliyuncs.com/v1", "qwen"),
  ("openai", None, "qwen"),
  ("openai", "http://localhost:1234/v1", "local"),
  ("openai", "https://openrouter.ai/api/v1", None),
  ("anthropic", None, None),
]
providers, lines = {}, []
for auth, url, owner in QWEN_ROUTES:
  tag, tokens = cell("qwen-code", f"{auth} {url}", owner)
  if url:
    providers.setdefault(auth, []).append({"id": f"q-{tag}", "baseUrl": url})
  lines.append({"uuid": tag, "sessionId": "s", "timestamp": stamp, "type": "system", "subtype": "ui_telemetry", "systemPayload": {"uiEvent": {
    "event.name": "qwen-code.api_response", "event.timestamp": stamp, "response_id": tag, "model": f"q-{tag}", "auth_type": auth,
    "input_token_count": tokens, "output_token_count": 0, "cached_content_token_count": 0}}})
(home / ".qwen" / "projects" / "p" / "chats").mkdir(parents=True)
(home / ".qwen" / "settings.json").write_text(json.dumps({"modelProviders": providers}))
(home / ".qwen" / "projects" / "p" / "chats" / "s.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))

# Hermes: each session and request names the base URL it was billed through.
(home / ".hermes").mkdir()
conn = sqlite3.connect(home / ".hermes" / "state.db")
conn.executescript("""
CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT, started_at REAL NOT NULL, billing_provider TEXT, billing_base_url TEXT);
CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, timestamp REAL NOT NULL);
CREATE TABLE session_model_usage (session_id TEXT NOT NULL, model TEXT NOT NULL, billing_provider TEXT NOT NULL DEFAULT '', billing_base_url TEXT NOT NULL DEFAULT '',
  input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_write_tokens INTEGER NOT NULL DEFAULT 0);
""")
HERMES_ROUTES = [
  ("nous", "https://inference-api.nousresearch.com/v1", "hermes"),
  ("custom", "http://127.0.0.1:8080/v1", "local"),
  ("openrouter", "https://openrouter.ai/api/v1", None),
]
for provider, url, owner in HERMES_ROUTES:
  tag, tokens = cell("hermes", provider, owner)
  conn.execute("INSERT INTO sessions VALUES (?, ?, ?, ?, ?)", (tag, f"h-{tag}", now, provider, url))
  conn.execute("INSERT INTO session_model_usage (session_id, model, billing_provider, billing_base_url, input_tokens) VALUES (?, ?, ?, ?, ?)", (tag, f"h-{tag}", provider, url, tokens))
conn.commit()
conn.close()

# Mistral Vibe: a legacy session per provider, its config dumped beside it.
VIBE_ROUTES = [
  ("mistral", {"name": "mistral", "backend": "mistral"}, "vibe"),
  ("llamacpp", {"name": "llamacpp", "api_base": "http://127.0.0.1:8080/v1", "backend": "generic"}, "local"),
  ("proxy", {"name": "proxy", "api_base": "https://llm.acme.example/v1", "backend": "generic"}, None),
]
for n, (provider, entry, owner) in enumerate(VIBE_ROUTES):
  tag, tokens = cell("vibe", provider, owner)
  session = home / ".vibe" / "logs" / "session" / f"session_20260101_12000{n}_{tag}"
  session.mkdir(parents=True)
  (session / "meta.json").write_text(json.dumps({"session_id": session.name, "start_time": stamp, "config": {
    "active_model": f"v-{tag}", "models": {f"v-{tag}": {"name": f"v-{tag}", "provider": provider, "alias": f"v-{tag}"}}, "providers": [entry]},
    "stats": {"session_prompt_tokens": tokens, "session_cached_tokens": 0, "session_completion_tokens": 0}}))

Path(sys.argv[2]).write_text(json.dumps(cells))
PY
run_all "$HARNESS_HOME" "$WORK/harness-results"

harness_report=$(python3 - "$WORK" "${collectors[@]}" <<'PY'
import json
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
cells = {cell["tag"]: cell for cell in json.load(open(work / "harness-cells.json"))}
seen = {tag: {} for tag in cells}
for cid in sys.argv[2:]:
  try:
    record = json.loads((work / "harness-results" / f"{cid}.json").read_text())
  except ValueError:
    print(f"{cid} printed no JSON record")
    continue
  for model, bucket in (record.get("modelUsage") or {}).items():
    total = sum(bucket.get(key) or 0 for key in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"))
    for tag in re.findall(r"zq9\d\d", model):
      if tag in seen and total:
        seen[tag][cid] = seen[tag].get(cid, 0) + total
for tag, cell in sorted(cells.items()):
  owner, tokens = cell["owner"], cell["tokens"]
  wrong = [f"{cid} counted it {total / tokens:g}x" for cid, total in sorted(seen[tag].items()) if cid != owner or total != tokens]
  if owner and owner not in seen[tag]:
    wrong.insert(0, f"{owner} missed it")
  if wrong:
    print(f"{cell['source']} on {cell['route']} ({tag}), expected {owner or 'nobody'}: {'; '.join(wrong)}")
PY
)
if [[ -z $harness_report ]]; then
  pass "each Kimi Code, Qwen Code, Hermes and Vibe request is counted once, by the collector that bills its recorded route, or by none"
else
  fail "each Kimi Code, Qwen Code, Hermes and Vibe request is counted once, by the collector that bills its recorded route, or by none" "$harness_report"
fi
