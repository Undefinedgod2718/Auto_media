#!/usr/bin/env bash
# PR-0: Empirical n8n 2.21.x HITL semantics (Q1-Q4). Requires running n8n + N8N_API_KEY
# and the verify-wait-probe workflow imported + ACTIVE.
#   Q1 execution status sequence around Wait (expect running -> waiting)
#   Q2 limitWaitTime TTL: which output resumes + $json shape on timeout
#   Q3 DELETE a waiting execution: HTTP code + post-delete status
#   Q4 resume_url after the execution is no longer waiting: HTTP code
# Writes real answers to data/logs/n8n_semantics.json. NEVER fakes passed=true.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
OUT="${DATA_ROOT}/logs/n8n_semantics.json"
mkdir -p "$(dirname "$OUT")"

load_env_file() {
  [[ -f "${REPO_ROOT}/.env" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "${REPO_ROOT}/.env"
  set +a
  N8N_API_KEY="${N8N_API_KEY:-}"
  N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
}

load_env_file

n8n_up=false
if curl -fsS "${N8N_API_URL}/healthz" >/dev/null 2>&1; then
  n8n_up=true
fi

export N8N_API_URL N8N_API_KEY

python3 - "$OUT" "$n8n_up" <<'PY'
import json, os, sys, time
import urllib.error
import urllib.request

out_path = sys.argv[1]
n8n_up = sys.argv[2] == "true"
BASE = os.environ.get("N8N_API_URL", "").rstrip("/")
KEY = os.environ.get("N8N_API_KEY", "")
PROBE_PATH = "/webhook/verify-wait-probe"
WF_NAME = "verify-wait-probe"

result = {
    "n8n_reachable": n8n_up,
    "n8n_api_url": BASE,
    "has_api_key": bool(KEY),
    "tested_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "q1_wait_status_sequence": {"status": "skipped"},
    "q2_limit_wait_ttl_payload": {"status": "skipped"},
    "q3_delete_waiting_execution": {"status": "skipped"},
    "q4_resume_url_when_not_waiting": {"status": "skipped"},
    "passed": False,
}


def _write_and_exit(note):
    result["note"] = note
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    sys.exit(0)


if not n8n_up:
    _write_and_exit("n8n not reachable; import workflows/verify-wait-probe.json, activate, set N8N_API_KEY, re-run")
if not KEY:
    _write_and_exit("N8N_API_KEY missing — cannot query Executions API")


def http(method, url, body=None, headers=None, timeout=15):
    hdrs = {"Content-Type": "application/json", "X-N8N-API-KEY": KEY}
    if headers:
        hdrs.update(headers)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode(errors="replace")
            try:
                return resp.status, json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                return resp.status, {"raw": raw[:500]}
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw[:500]}
    except Exception as e:  # noqa: BLE001
        return 0, {"error": str(e)}


def api(path):
    return f"{BASE}/api/v1{path}"


def find_workflow_id():
    code, data = http("GET", api("/workflows?limit=200"))
    if code != 200 or not isinstance(data, dict):
        return None, f"list workflows HTTP {code}"
    for wf in data.get("data", []):
        if wf.get("name") == WF_NAME:
            if not wf.get("active"):
                return None, "verify-wait-probe found but NOT active"
            return wf.get("id"), None
    return None, "verify-wait-probe workflow not found (import + activate it)"


def newest_exec_id(wf_id):
    code, data = http("GET", api(f"/executions?workflowId={wf_id}&limit=1"))
    if code != 200 or not isinstance(data, dict):
        return None
    rows = data.get("data", [])
    return rows[0].get("id") if rows else None


def exec_status(eid, include_data=False):
    suffix = "?includeData=true" if include_data else ""
    code, data = http("GET", api(f"/executions/{eid}{suffix}"))
    if code != 200 or not isinstance(data, dict):
        return None, code, data
    d = data.get("data", data)
    return str(d.get("status", "")).lower(), code, d


def trigger_probe(probe_id):
    return http("POST", f"{BASE}{PROBE_PATH}", {"probe_id": probe_id}, timeout=10)


def trigger_and_capture(wf_id, probe_id, appear_timeout=12.0):
    before = newest_exec_id(wf_id)
    trigger_probe(probe_id)
    deadline = time.time() + appear_timeout
    while time.time() < deadline:
        cur = newest_exec_id(wf_id)
        if cur and cur != before:
            return cur
        time.sleep(0.4)
    return None


def resume_url(eid):
    # n8n Wait(resume=webhook) listens at /webhook-waiting/{executionId}
    return f"{BASE}/webhook-waiting/{eid}"


wf_id, err = find_workflow_id()
if not wf_id:
    _write_and_exit(err)

# ---- Q1: status sequence around Wait (expect running -> waiting) ----
eid1 = trigger_and_capture(wf_id, "q1")
seq = []
if eid1:
    deadline = time.time() + 8.0
    while time.time() < deadline:
        st, _, _ = exec_status(eid1)
        if st and (not seq or seq[-1] != st):
            seq.append(st)
        if st == "waiting":
            break
        time.sleep(0.3)
result["q1_wait_status_sequence"] = {
    "status": "tested" if eid1 else "no_execution",
    "execution_id": eid1,
    "observed_sequence": seq,
    "waiting_observed": "waiting" in seq,
}

# ---- Q4: resume url AFTER execution leaves waiting ----
# First resume eid1 normally, let it finish, then GET resume_url again.
q4 = {"status": "skipped"}
if eid1 and "waiting" in seq:
    code_resume, _ = http("GET", resume_url(eid1))
    # let it finish
    fin_deadline = time.time() + 6.0
    final_status = None
    while time.time() < fin_deadline:
        st, _, _ = exec_status(eid1)
        if st in ("success", "error", "crashed", "canceled", "cancelled", "failed"):
            final_status = st
            break
        time.sleep(0.3)
    code_again, _ = http("GET", resume_url(eid1))
    q4 = {
        "status": "tested",
        "first_resume_http": code_resume,
        "post_finish_status": final_status,
        "resume_url_http_when_not_waiting": code_again,
    }
result["q4_resume_url_when_not_waiting"] = q4

# ---- Q3: DELETE a waiting execution ----
q3 = {"status": "skipped"}
eid3 = trigger_and_capture(wf_id, "q3")
if eid3:
    # wait until waiting
    wdl = time.time() + 10.0
    reached = False
    while time.time() < wdl:
        st, _, _ = exec_status(eid3)
        if st == "waiting":
            reached = True
            break
        time.sleep(0.3)
    del_code, _ = http("DELETE", api(f"/executions/{eid3}"))
    post_st, post_http, _ = exec_status(eid3)
    q3 = {
        "status": "tested",
        "execution_id": eid3,
        "reached_waiting": reached,
        "delete_http": del_code,
        "post_delete_status": post_st,
        "post_delete_get_http": post_http,
    }
result["q3_delete_waiting_execution"] = q3

# ---- Q2: limitWaitTime TTL (10s) — do NOT resume, inspect resume output ----
q2 = {"status": "skipped"}
eid2 = trigger_and_capture(wf_id, "q2")
if eid2:
    # wait > limitWaitTime (10s) + margin
    time.sleep(13.0)
    st, _, full = exec_status(eid2, include_data=True)
    after_payload = None
    try:
        run_data = full.get("data", {}).get("resultData", {}).get("runData", {})
        node_runs = run_data.get("After wait", [])
        if node_runs:
            after_payload = node_runs[0]["data"]["main"][0][0]["json"]
    except Exception:  # noqa: BLE001
        after_payload = "unparseable"
    q2 = {
        "status": "tested",
        "execution_id": eid2,
        "final_status": st,
        "after_wait_json_on_timeout": after_payload,
        "note": "Wait has a single output; TTL resume re-enters via the same edge. "
                "Distinguish approve vs TTL by presence of callback fields in $json.",
    }
result["q2_limit_wait_ttl_payload"] = q2

# ---- verdict ----
result["passed"] = bool(
    result["q1_wait_status_sequence"].get("waiting_observed")
    and result["q2_limit_wait_ttl_payload"].get("status") == "tested"
    and result["q3_delete_waiting_execution"].get("status") == "tested"
    and result["q4_resume_url_when_not_waiting"].get("status") == "tested"
)
result["note"] = "real probe executed" if result["passed"] else "probe ran but one or more Q did not complete; inspect fields"

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(json.dumps(result, indent=2, ensure_ascii=False))
PY

rc=$?
if [[ "$n8n_up" != true ]]; then
  echo "warn: n8n not running — wrote template $OUT (re-run when n8n is up)" >&2
  exit 0
fi
[[ $rc -eq 0 ]] || exit $rc
json_ok "$OUT"
