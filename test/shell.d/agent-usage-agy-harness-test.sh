#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3
require_command sqlite3

COLLECTOR="$ROOT/bin/omarchy-agent-usage-agy"

# Antigravity signed in through another harness, with agy itself absent: the
# record still carries the plan and limits, asked with that harness' token.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
cat >"$test_tmp/bin/secret-tool" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$test_tmp/bin/secret-tool"

in_ms() {
  python3 -c "import sys, time; print(round((time.time() + float(sys.argv[1])) * 1000))" "$1"
}

omp_login() {
  mkdir -p "$test_tmp/.omp/agent"
  rm -f "$test_tmp/.omp/agent/agent.db"
  sqlite3 "$test_tmp/.omp/agent/agent.db" \
    "CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT);
     INSERT INTO auth_credentials (provider, credential_type, data) VALUES
       ('google-antigravity', 'oauth', '{\"access\":\"$1\",\"refresh\":\"r\",\"expires\":$2,\"email\":\"$3\"}');"
}

pi_login() {
  mkdir -p "$test_tmp/.pi/agent"
  printf '{"google-antigravity":{"type":"oauth","access":"%s","refresh":"r","expires":%s,"email":"%s"}}\n' "$1" "$2" "$3" \
    >"$test_tmp/.pi/agent/auth.json"
}

# Google answers every token in ACCEPTED and refuses the rest; each request's
# token is logged so a test can tell which sign-in was asked.
collect() {
  env -u PI_CODING_AGENT_DIR -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
    HOME="$test_tmp" XDG_CACHE_HOME="$test_tmp/cache" PATH="$test_tmp/bin:$PATH" \
    COLLECTOR="$COLLECTOR" ACCEPTED="$1" ASKED="$test_tmp/asked" python3 - <<'PY'
import importlib.machinery, importlib.util, io, json, os, sys, urllib.error

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

answers = {
  "loadCodeAssist": {"paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"}},
  "retrieveUserQuotaSummary": {"groups": [{"displayName": "Gemini Models", "buckets": [
    {"window": "5h", "remainingFraction": 0.75, "resetTime": "2999-01-01T00:00:00Z"}
  ]}]},
}

def urlopen(request, timeout=None):
  token = request.get_header("Authorization").removeprefix("Bearer ")
  with open(os.environ["ASKED"], "a") as asked:
    asked.write(token + "\n")
  if token not in os.environ["ACCEPTED"].split():
    raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, io.BytesIO())
  return io.BytesIO(json.dumps(answers[request.full_url.rsplit(":", 1)[1]]).encode())

collector.urllib.request.urlopen = urlopen
sys.argv = ["omarchy-agent-usage-agy", "--force"]
collector.main()
PY
}

asked() {
  sort -u "$test_tmp/asked" | paste -sd' '
  rm -f "$test_tmp/asked"
}

omp_login omp-token "$(in_ms 3600)" me@example.com
record=$(collect omp-token)
[[ $(jq -c '{ready, tierLabel, stale: .limitsStale, percent: .limits[0].percent}' <<<"$record") == '{"ready":true,"tierLabel":"Pro","stale":false,"percent":0.25}' ]] ||
  fail "Antigravity collector reports limits from an omp sign-in without agy" "$record"
[[ $(asked) == "omp-token" ]] || fail "Antigravity collector asks Google with omp's token" "$record"
pass "Antigravity collector reports limits from an omp sign-in without agy"

pi_login pi-token "$(in_ms 7200)" me@example.com
record=$(collect "omp-token pi-token")
[[ $(asked) == "pi-token" ]] ||
  fail "Antigravity collector asks with the most recently refreshed sign-in" "$record"
pass "Antigravity collector asks with the most recently refreshed sign-in"

record=$(collect omp-token)
[[ $(asked) == "omp-token pi-token" && $(jq -c '{stale: .limitsStale, usageStatusText}' <<<"$record") == '{"stale":false,"usageStatusText":""}' ]] ||
  fail "Antigravity collector moves on from a sign-in Google refuses" "$record"
pass "Antigravity collector moves on from a sign-in Google refuses"

rm -rf "$test_tmp/.pi"
omp_login omp-token "$(in_ms -60)" me@example.com
record=$(collect omp-token)
[[ ! -e $test_tmp/asked ]] || fail "Antigravity collector sends no lapsed token to Google" "$(asked)"
[[ $(jq -c '{ready, stale: .limitsStale, usageStatusText, authHelpText, percent: .limits[0].percent}' <<<"$record") == '{"ready":true,"stale":true,"usageStatusText":"Sign-in expired","authHelpText":"The Antigravity sign-in omp keeps expired. Start omp to refresh it.","percent":0.25}' ]] ||
  fail "Antigravity collector keeps the last limits and names the harness whose sign-in lapsed" "$record"
pass "Antigravity collector keeps the last limits and names the harness whose sign-in lapsed"

omp_login other-token "$(in_ms -60)" other@example.com
record=$(collect "")
[[ $(jq -c '{limits, tierLabel}' <<<"$record") == '{"limits":[],"tierLabel":""}' ]] ||
  fail "Antigravity collector shows no other Google account's kept limits" "$record"
pass "Antigravity collector shows no other Google account's kept limits"

# opencode files any Google sign-in under "google"; only the Antigravity
# plugin's accounts file makes it an Antigravity one.
rm -rf "$test_tmp/.omp" "$test_tmp/cache"
mkdir -p "$test_tmp/.local/share/opencode"
printf '{"google":{"type":"oauth","access":"opencode-token","refresh":"r|p","expires":%s}}\n' "$(in_ms 3600)" \
  >"$test_tmp/.local/share/opencode/auth.json"
record=$(collect opencode-token)
[[ $(jq -c '{ready, limits}' <<<"$record") == '{"ready":false,"limits":[]}' && ! -e $test_tmp/asked ]] ||
  fail "Antigravity collector ignores opencode's Google sign-in without the Antigravity plugin" "$record"
mkdir -p "$test_tmp/.config/opencode"
echo '{"version":3,"accounts":[]}' >"$test_tmp/.config/opencode/antigravity-accounts.json"
record=$(collect opencode-token)
[[ $(asked) == "opencode-token" && $(jq '.limits[0].percent' <<<"$record") == "0.25" ]] ||
  fail "Antigravity collector reads opencode's Antigravity plugin sign-in" "$record"
pass "Antigravity collector reads opencode's Antigravity plugin sign-in only with the plugin"
