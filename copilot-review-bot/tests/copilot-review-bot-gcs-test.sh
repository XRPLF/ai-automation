#!/usr/bin/env bash
#
# copilot-review-bot-gcs-test.sh - exercise the gs:// state backend against a
# stub Cloud Storage JSON API, so the locking and the state round trip are
# covered without a real bucket.
#
# The gs:// path is what runs on Cloud Run, and none of it is reachable from the
# other two suites: they use a local state directory. What matters here is the
# lock, because it is the only thing standing between two overlapping executions
# and a lost write to the shared marker file.
#
# Needs python3 for the stub server. Skips itself, loudly, if that is missing.
#
# Usage: ./copilot-review-bot-gcs-test.sh [path-to-copilot-review-bot.sh]
#
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test-lib.sh
. "${SUITE_DIR}/test-lib.sh"

BOT="$(resolve_bot "${SUITE_DIR}/.." "${1:-}")"
require_tools jq curl
command -v python3 >/dev/null || {
    echo "SKIP: python3 is needed for the stub Cloud Storage server" >&2
    exit 0
}

ROOT="$(mktemp -d)"
BASH_BIN="${BASH}"
TOOL_PATH="$(build_tool_path curl)"

SERVER_PID=""
cleanup() {
    [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null
    rm -rf "${ROOT}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Stub Cloud Storage JSON API
# ---------------------------------------------------------------------------
# Implements only what the bot uses, but implements the part that matters
# faithfully: ifGenerationMatch on create and on delete, which is what turns the
# lock object into a mutex. /_control/ routes let a test plant an object with a
# chosen age, or force a status, neither of which real GCS offers.
cat >"${ROOT}/gcs-stub.py" <<'PY'
import datetime
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

STORE = {}          # object name -> {"generation": int, "created": str, "data": bytes}
FORCED = {}         # object name -> HTTP status to answer any request with
# "<METHOD> <name>" -> status. Needed because the lock cases have to fail one
# method while leaving the others working: forcing the whole object would break
# the acquire before the path under test is reached.
FORCED_METHOD = {}
FAIL_TIMES = {}     # object name -> [status, remaining count], for a transient fault
CONFLICT = {}       # object name -> bytes another writer publishes on next upload
# object name -> status to answer with *after* storing the object, once. Models a
# write that landed while its response was lost, which is the only way a caller
# can collide with its own object on a conditional create.
STORE_THEN_FAIL = {}
# object name -> bytes to re-plant immediately after the next DELETE. Models
# another run winning the race to re-create a lock this one has just broken,
# which is the one branch of the break path no other control route can reach.
RECREATE_AFTER_DELETE = {}
# When on, no response carries a generation: not in an upload's object
# resource and not in a media download's x-goog-generation header. That is the
# only way the bot ends up holding a lock it cannot name in a precondition.
OMIT_GENERATION = [False]
NEXT_GEN = [1000]
TOKEN_STATUS = [200]  # what the stub metadata server answers with


def now_iso(offset_minutes=0):
    t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=offset_minutes)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def meta(name):
    o = STORE[name]
    m = {"kind": "storage#object", "name": name,
         "generation": str(o["generation"]), "timeCreated": o["created"],
         "updated": o["created"], "size": str(len(o["data"]))}
    if OMIT_GENERATION[0]:
        del m["generation"]
    return m


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, body=b"", ctype="application/json", generation=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # A media download carries the generation only as a header, which is the
        # bot's only way to learn it before a conditional write.
        if generation is not None and not OMIT_GENERATION[0]:
            self.send_header("x-goog-generation", str(generation))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode())

    def _err(self, code, msg):
        self._json(code, {"error": {"code": code, "message": msg}})

    # A whole-object fault, or one scoped to a single method.
    def _forced(self, name, method):
        status = FORCED_METHOD.get(method + " " + name, FORCED.get(name))
        if status:
            self._err(status, "stub-forced %s failure for %s" % (method, name))
            return True
        return False

    def _authed(self):
        if not self.headers.get("Authorization", "").startswith("Bearer "):
            self._err(401, "Invalid Credentials")
            return False
        return True

    # Object name out of /storage/v1/b/<bucket>/o/<encoded name>
    def _object_path(self, path):
        parts = path.split("/")
        if len(parts) >= 7 and parts[1:4] == ["storage", "v1", "b"] and parts[5] == "o":
            return unquote(parts[6])
        return None

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n) if n else b""

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path == "/_control/preload":
            name = q["name"][0]
            age = int(q.get("age_minutes", ["0"])[0])
            NEXT_GEN[0] += 1
            STORE[name] = {"generation": NEXT_GEN[0], "created": now_iso(-age),
                           "data": self._body()}
            self._json(200, meta(name))
            return
        # status=0 clears the entry. Without a way to clear, "unforcing" by
        # setting 200 would still answer with an error body.
        if u.path == "/_control/force":
            name, status = q["name"][0], int(q["status"][0])
            if status == 0:
                FORCED.pop(name, None)
            else:
                FORCED[name] = status
            self._json(200, {"ok": True})
            return
        # Drop an object outright, so one scenario cannot leave a lock behind that
        # changes what the next one exercises.
        if u.path == "/_control/remove":
            STORE.pop(q["name"][0], None)
            self._json(200, {"ok": True})
            return
        if u.path == "/_control/omit_generation":
            OMIT_GENERATION[0] = q["on"][0] == "1"
            self._json(200, {"ok": True})
            return
        if u.path == "/_control/recreate_after_delete":
            RECREATE_AFTER_DELETE[q["name"][0]] = self._body()
            self._json(200, {"ok": True})
            return
        if u.path == "/_control/store_then_fail":
            STORE_THEN_FAIL[q["name"][0]] = int(q["status"][0])
            self._json(200, {"ok": True})
            return
        if u.path == "/_control/force_method":
            key = q["method"][0].upper() + " " + q["name"][0]
            status = int(q["status"][0])
            if status == 0:
                FORCED_METHOD.pop(key, None)
            else:
                FORCED_METHOD[key] = status
            self._json(200, {"ok": True})
            return
        if u.path == "/_control/dump":
            self._json(200, {k: v["data"].decode("utf-8", "replace") for k, v in STORE.items()})
            return
        # Fail the next N uploads of an object with a retryable status, so the
        # retry loop can be observed rather than assumed.
        if u.path == "/_control/fail_times":
            FAIL_TIMES[q["name"][0]] = [int(q["status"][0]), int(q["times"][0])]
            self._json(200, {"ok": True})
            return
        # Simulate another run publishing this object first: the body given here
        # replaces it, and its generation moves, so the next conditional upload
        # gets a 412.
        if u.path == "/_control/conflict":
            CONFLICT[q["name"][0]] = self._body()
            self._json(200, {"ok": True})
            return
        if u.path == "/_control/token_status":
            TOKEN_STATUS[0] = int(q["status"][0])
            self._json(200, {"ok": True})
            return

        if not u.path.startswith("/upload/storage/v1/b/"):
            self._err(404, "no such route: " + u.path)
            return
        if not self._authed():
            return
        name = q["name"][0]
        if self._forced(name, "POST"):
            return
        if name in FAIL_TIMES and FAIL_TIMES[name][1] > 0:
            FAIL_TIMES[name][1] -= 1
            self._err(FAIL_TIMES[name][0], "stub transient failure for " + name)
            return
        if name in CONFLICT:
            NEXT_GEN[0] += 1
            STORE[name] = {"generation": NEXT_GEN[0], "created": now_iso(),
                           "data": CONFLICT.pop(name)}
        data = self._body()
        # ifGenerationMatch=0 means "only if absent"; any other value must equal
        # the generation the caller last saw. Enforcing both is what makes the
        # lock a mutex and the state write safe against a lost race.
        want = q.get("ifGenerationMatch", [None])[0]
        if want is not None:
            have = str(STORE[name]["generation"]) if name in STORE else "0"
            if want != have:
                self._err(412, "At least one of the pre-conditions you specified did not hold.")
                return
        NEXT_GEN[0] += 1
        STORE[name] = {"generation": NEXT_GEN[0], "created": now_iso(), "data": data}
        if name in STORE_THEN_FAIL:
            self._err(STORE_THEN_FAIL.pop(name), "stub lost the response for " + name)
            return
        self._json(200, meta(name))

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        # Stub instance metadata server. This is the only way the bot gets a
        # token on Cloud Run, so it needs to be reachable from a test.
        if u.path.startswith("/computeMetadata/v1/"):
            if self.headers.get("Metadata-Flavor") != "Google":
                self._err(403, "missing Metadata-Flavor header")
                return
            if TOKEN_STATUS[0] != 200:
                self._err(TOKEN_STATUS[0], "stub metadata failure")
                return
            if u.path.endswith("/email"):
                self._send(200, b"bot-runtime@example.iam.gserviceaccount.com",
                           "text/plain")
            else:
                self._json(200, {"access_token": "stub-metadata-token",
                                 "expires_in": 3600, "token_type": "Bearer"})
            return
        name = self._object_path(u.path)
        if name is None:
            self._err(404, "no such route: " + u.path)
            return
        if not self._authed():
            return
        if self._forced(name, "GET"):
            return
        if name not in STORE:
            self._err(404, "No such object: " + name)
            return
        if q.get("alt", [""])[0] == "media":
            self._send(200, STORE[name]["data"], "application/octet-stream",
                       generation=STORE[name]["generation"])
        else:
            self._json(200, meta(name))

    def do_DELETE(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        name = self._object_path(u.path)
        if name is None:
            self._err(404, "no such route: " + u.path)
            return
        if not self._authed():
            return
        if self._forced(name, "DELETE"):
            return
        if name not in STORE:
            self._err(404, "No such object: " + name)
            return
        want = q.get("ifGenerationMatch", [None])[0]
        if want is not None and want != str(STORE[name]["generation"]):
            self._err(412, "At least one of the pre-conditions you specified did not hold.")
            return
        del STORE[name]
        body = RECREATE_AFTER_DELETE.pop(name, None)
        if body is not None:
            NEXT_GEN[0] += 1
            STORE[name] = {"generation": NEXT_GEN[0], "created": now_iso(0),
                           "data": body}
        self._send(204)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(srv.server_address[1], flush=True)
    srv.serve_forever()
PY

# ---------------------------------------------------------------------------
# The stub gh, same idea as the e2e suite: one fresh PR that is due a review.
# ---------------------------------------------------------------------------
BIN="${ROOT}/bin"
mkdir -p "${BIN}"
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
D="${FAKE_DIR}"
log="${D}/calls.log"
[[ "${1:-}" == auth ]] && exit 0

query=""; number=""; pr_id=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f | -F)
            case "${2%%=*}" in
                query) query="${2#*=}" ;;
                number) number="${2#*=}" ;;
                pullRequestId) pr_id="${2#*=}" ;;
            esac
            shift 2
            ;;
        *) shift ;;
    esac
done
case "${query}" in
    # This suite is about the state bucket, so the request only has to be counted.
    # The PR reaches it as a node id, and this stub serves exactly one PR.
    *requestReviewsByLogin*)
        printf 'request\t%s\n' "${pr_id#PR_}" >>"${log}"
        printf '{"data":{"requestReviewsByLogin":{"clientMutationId":null}}}\n' ;;
    *"viewer { login }"*) printf 'xrplf-bot\n' ;;
    *"pullRequests(states: OPEN"*)
        printf 'list\n' >>"${log}"
        printf '{"data":{"repository":{"defaultBranchRef":{"name":"develop"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[{"number":42}]}}}}\n' ;;
    *reviewThreads*)
        printf 'pr\t%s\n' "${number}" >>"${log}"
        printf '{"data":{"repository":{"pullRequest":{"id":"PR_42","number":42,"isDraft":false,"baseRefName":"develop","headRefOid":"head1","mergeable":"MERGEABLE","commits":{"nodes":[{"commit":{"oid":"head1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}}]}}}}}\n' ;;
    *) printf 'stub gh: unexpected query\n' >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "${BIN}/gh"

# ---------------------------------------------------------------------------
python3 "${ROOT}/gcs-stub.py" >"${ROOT}/port" 2>"${ROOT}/stub.err" &
SERVER_PID=$!
for _ in $(seq 1 50); do
    [[ -s "${ROOT}/port" ]] && break
    sleep 0.1
done
PORT="$(tr -d '[:space:]' <"${ROOT}/port")"
[[ -n "${PORT}" ]] || {
    echo "stub server did not start: $(cat "${ROOT}/stub.err")" >&2
    exit 2
}
API="http://127.0.0.1:${PORT}"
BUCKET="xrplf-bot-state"
# What goes in STATE_DIR, and where the bot actually puts its objects. The bot
# namespaces both the lock and requested.json by the repository it watches, so every
# object below lands under the root plus <owner>/<name>. Split in two rather than
# spelling the repo out at each of the two dozen object names, so the layout is stated
# once and the run() below still passes the root it was given.
STATE_ROOT="copilot"
PREFIX="${STATE_ROOT}/XRPLF/rippled"

control() { curl -sS -X POST "${API}/_control/$1"; }
bucket_dump() { curl -sS -X POST "${API}/_control/dump"; }
bucket_has() { bucket_dump | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1; }

# The object routes take the name percent-encoded, the way the bot sends it: the stub
# splits the request path on '/' to find it, so a raw slash from the prefix above would
# be read as another path segment and match no route at all.
obj_url() { # <object-name>
    printf '%s/storage/v1/b/%s/o/%s' "${API}" "${BUCKET}" "${1//\//%2F}"
}

# Both date flavors, for the same reason the bot probes for them: this suite runs on
# Linux in CI and on macOS by hand.
minutes_ago() { # <minutes>
    date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
        date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ
}

# Plant a lock of a given age. The age goes in the body as well as on the object,
# because started_at is what the bot ages a lock by: it is in the half of an
# ?alt=media response that cannot go missing, unlike the x-goog-generation header.
preload_lock() { # <holder> <age-minutes>
    printf '{"holder":"%s","started_at":"%s"}' "$1" "$(minutes_ago "$2")" |
        curl -sS -X POST --data-binary @- \
            "${API}/_control/preload?name=${PREFIX}/lock&age_minutes=$2" >/dev/null
}

# Extra VAR=VALUE entries for the next run(), reset after it. Used to check a
# setting that has no command-line flag.
RUN_ENV=()

run() { # [args...]
    : >"${ROOT}/calls.log"
    rc=0
    # RUN_ENV comes last so a test can override a default, including setting
    # GOOGLE_OAUTH_ACCESS_TOKEN empty to force the metadata-server path.
    #
    # GCS_RETRY_BASE_SECONDS=0, because every assertion here is on the retry having
    # happened and none is on how long it waited. At the production default of 2 the
    # two 503 scenarios alone sleep 12 seconds to prove nothing.
    env -i \
        PATH="${BIN}:${TOOL_PATH}:/usr/bin:/bin" \
        HOME="${ROOT}" \
        FAKE_DIR="${ROOT}" \
        GH_TOKEN=stub-token \
        GOOGLE_OAUTH_ACCESS_TOKEN=stub-oauth-token \
        GCS_API_ROOT="${API}" \
        GCS_METADATA_ROOT="${API}" \
        STATE_DIR="gs://${BUCKET}/${STATE_ROOT}" \
        SLEEP_BETWEEN_MUTATIONS=0 \
        GCS_RETRY_BASE_SECONDS=0 \
        LOG_FORMAT=json \
        ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
        "${BASH_BIN}" "${BOT}" --repo XRPLF/rippled "$@" \
        >"${ROOT}/out.log" 2>&1 || rc=$?
    LAST_LOG="${ROOT}/out.log"
    RUN_ENV=()
}

printf '\n== a first run creates the lock, writes state, and lets go ==\n'
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the review request was filed" 1 "$(calls "${ROOT}/calls.log" request)"
if bucket_has "${PREFIX}/requested.json"; then
    ok "the markers were stored under the repo, below the root it was given"
else
    bad "the markers were stored under the repo, below the root it was given" "$(bucket_dump)"
fi
if bucket_has "${PREFIX}/lock"; then
    bad "the lock was released" "lock object is still there"
else
    ok "the lock was released"
fi
assert_eq "the marker names the head commit" "head1" \
    "$(bucket_dump | jq -r --arg k "${PREFIX}/requested.json" '.[$k]' | jq -r '."XRPLF/rippled#42".head')"
assert_eq "the backend was reported as gcs" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.start" and .state_backend=="gcs"')"

printf '\n== a bucket root with no prefix is the deployed shape ==\n'
# What deploy-job.sh actually sets: gs://<bucket>, nothing after it. Every other case
# here runs with a prefix, so without this the one STATE_DIR production uses is the one
# STATE_DIR nothing covers, and an off-by-one slash in the prefix join would only show
# up in the bucket.
control "remove?name=${PREFIX}/requested.json" >/dev/null
RUN_ENV=(STATE_DIR="gs://${BUCKET}")
run
assert_eq "exit status is 0" 0 "${rc}"
if bucket_has "XRPLF/rippled/requested.json"; then
    ok "the markers land at <owner>/<name>, with no leading slash"
else
    bad "the markers land at <owner>/<name>, with no leading slash" "$(bucket_dump | jq -r 'keys')"
fi
if bucket_has "XRPLF/rippled/lock"; then
    bad "and that lock was released too" "lock object is still there"
else
    ok "and that lock was released too"
fi
# Restored before the cases below, which all assume the prefixed root and a marker
# already in place from the first run.
curl -sS -X DELETE "$(obj_url "XRPLF/rippled/requested.json")" \
    -H 'Authorization: Bearer t' >/dev/null
printf '{"XRPLF/rippled#42":{"head":"head1","at":"2026-08-01T10:00:00Z"}}' |
    curl -sS -X POST --data-binary @- \
        "${API}/_control/preload?name=${PREFIX}/requested.json" >/dev/null

printf '\n== the stored markers are read back, so nothing is re-filed ==\n'
run -v
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no second request" 0 "$(calls "${ROOT}/calls.log" request)"
assert_eq "and it says the marker matched" 1 \
    "$(events "${ROOT}/out.log" '.event=="pr.skipped" and .reason=="already_requested"')"

printf '\n== a fresh lock held by somebody else stops the run dead ==\n'
preload_lock other-execution 1
run
assert_eq "exit status is 0, because this is not an error" 0 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${ROOT}/calls.log" pr)"
assert_eq "it reported the lock" 1 "$(events "${ROOT}/out.log" '.event=="run.skipped" and .reason=="locked"')"
if bucket_has "${PREFIX}/lock"; then
    ok "somebody else's lock was left alone"
else
    bad "somebody else's lock was left alone" "the lock was deleted"
fi

printf '\n== a dry run ignores a fresh lock held by somebody else ==\n'
# A dry run takes no lock of its own, so somebody else's lock is not its
# business either. It reads GitHub concurrently with whatever the lock holder
# is doing, which is fine: a dry run makes no mutation for either run to race
# against.
run --dry-run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it was not skipped" 0 "$(events "${ROOT}/out.log" '.event=="run.skipped"')"
assert_eq "the PR was still evaluated" 1 "$(calls "${ROOT}/calls.log" pr)"
if bucket_has "${PREFIX}/lock"; then
    ok "the other run's lock is still untouched"
else
    bad "the other run's lock is still untouched" "the lock was deleted"
fi

printf '\n== a lock left behind by a dead run is broken after its TTL ==\n'
preload_lock dead-execution 90
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the stale lock was broken, with a warning" 1 \
    "$(events "${ROOT}/out.log" '.event=="lock.broken" and .severity=="WARNING"')"
assert_eq "the run then did its work" 1 "$(calls "${ROOT}/calls.log" pr)"
if bucket_has "${PREFIX}/lock"; then
    bad "the lock was released again" "lock object is still there"
else
    ok "the lock was released again"
fi

printf '\n== a lock just inside its TTL is still respected ==\n'
preload_lock slow-execution 20
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${ROOT}/calls.log" pr)"
assert_eq "a lock inside the TTL is not broken" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.skipped" and .reason=="locked"')"
assert_eq "and it was not reported as broken" 0 "$(events "${ROOT}/out.log" '.event=="lock.broken"')"

# The same 20 minute old lock, under a 5 minute TTL, is stale. The window has to
# be configurable because it has to sit just above the platform's task timeout.
RUN_ENV=(LOCK_TTL_MINUTES=5)
run
assert_eq "the same lock is stale under a shorter TTL" 1 "$(events "${ROOT}/out.log" '.event=="lock.broken"')"
assert_eq "and the run then proceeded" 1 "$(calls "${ROOT}/calls.log" pr)"

printf '\n== losing the race to break a stale lock ends the run, it does not double up ==\n'
# The whole point of making the break conditional. Two runs that both find the same
# stale lock must not both proceed, or every due PR gets two review requests and every
# mention two replies. The DELETE is answered 412, which is what a run whose
# competitor broke the lock first would see.
preload_lock dead-execution 90
control "force_method?method=DELETE&name=${PREFIX}/lock&status=412" >/dev/null
run
control "force_method?method=DELETE&name=${PREFIX}/lock&status=0" >/dev/null
assert_eq "exit status is 0, because being second is not an error" 0 "${rc}"
assert_eq "it says the other run broke it first" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.skipped" and .reason=="locked" and .http_status=="412"')"
assert_eq "and it inspected no pull request" 0 "$(calls "${ROOT}/calls.log" pr)"

printf '\n== losing the race to re-create after a successful break also stops ==\n'
# The second lap of the acquire loop: this run broke the stale lock, and another run
# created its own before this one could. Reached only when the break succeeds and the
# create then fails, so no other control route gets here.
preload_lock dead-execution 90
printf '{"holder":"faster-execution","started_at":"%s"}' "$(minutes_ago 0)" |
    curl -sS -X POST --data-binary @- \
        "${API}/_control/recreate_after_delete?name=${PREFIX}/lock" >/dev/null
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it broke the stale lock" 1 "$(events "${ROOT}/out.log" '.event=="lock.broken"')"
assert_eq "then stood down for the run that got there first" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.skipped" and .reason=="locked"')"
assert_eq "and inspected no pull request" 0 "$(calls "${ROOT}/calls.log" pr)"
# The faster run's lock is still in the bucket, and it is fresh, so clear it rather
# than let it decide the next scenario.
control "remove?name=${PREFIX}/lock" >/dev/null

printf '\n== a lock whose generation was never learned is still released ==\n'
# Releasing without a precondition races a run that already broke this lock. Returning
# without deleting costs *every* run until the TTL expires instead, and says nothing,
# so the unconditional delete is the lesser harm. With no generation anywhere in the
# stub's responses, the bot holds a lock it cannot name in a precondition.
control "omit_generation?on=1" >/dev/null
run
control "omit_generation?on=0" >/dev/null
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it said the release was unconditional" 1 \
    "$(events "${ROOT}/out.log" '.event=="lock.release_unconditional" and .severity=="WARNING"')"
if bucket_has "${PREFIX}/lock"; then
    bad "the lock was released anyway" "lock object is still there"
else
    ok "the lock was released anyway"
fi

printf '\n== no bucket permission is a clean fatal, naming the bucket ==\n'
control "force?name=${PREFIX}/lock&status=403" >/dev/null
run
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${ROOT}/calls.log" pr)"
assert_eq "the bucket is named and a remedy given" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.fatal" and .reason=="state_bucket_unusable" and .bucket=="'"${BUCKET}"'"')"
assert_eq "the 403 is reported" 1 "$(events "${ROOT}/out.log" '.http_status=="403"')"

printf '\n== the bucket holds the markers and nothing else ==\n'
# One object, not two. The reviewer travels as a login on every request, so there is
# no node id to cache and nothing else needs storing.
control "force?name=${PREFIX}/lock&status=200" >/dev/null
run -v
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no bot-id object was created" "null" \
    "$(bucket_dump | jq -r --arg k "${PREFIX}/copilot-bot-id" '.[$k] // "null"')"

printf '\n== a dry run touches neither GitHub nor the bucket ==\n'
curl -sS -X DELETE "$(obj_url "${PREFIX}/requested.json")" \
    -H 'Authorization: Bearer stub' >/dev/null
run -v --dry-run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no request was filed" 0 "$(calls "${ROOT}/calls.log" request)"
if bucket_has "${PREFIX}/requested.json"; then
    bad "no markers were written" "requested.json was created by a dry run"
else
    ok "no markers were written"
fi
assert_eq "it still reported what it would do" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.done" and .would_file==1 and .requests_filed==0')"
assert_eq "it took no lock" 1 \
    "$(events "${ROOT}/out.log" '.event=="lock.skipped" and .reason=="dry_run"')"
assert_eq "and never touched the lock object" 0 \
    "$(events "${ROOT}/out.log" '.event=="lock.acquired" or .event=="lock.adopted"')"

# ---------------------------------------------------------------------------
printf '\n== the token comes from the metadata server, which is the production path ==\n'
# Every other case here short-circuits on GOOGLE_OAUTH_ACCESS_TOKEN, so without
# this the only way the bot authenticates on Cloud Run is never executed.
control "reset" >/dev/null 2>&1 || true
curl -sS -X POST "${API}/_control/token_status?status=200" >/dev/null
control "force?name=none&status=200" >/dev/null
: >"${ROOT}/out.log"
RUN_ENV=(GOOGLE_OAUTH_ACCESS_TOKEN=)
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the request was filed using a metadata token" 1 \
    "$(calls "${ROOT}/calls.log" request)"
if bucket_has "${PREFIX}/requested.json"; then
    ok "and the markers were stored"
else
    bad "and the markers were stored" "$(bucket_dump)"
fi

printf '\n== a metadata server that will not answer is fatal, and says so ==\n'
curl -sS -X POST "${API}/_control/token_status?status=500" >/dev/null
RUN_ENV=(GOOGLE_OAUTH_ACCESS_TOKEN=)
run
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it reported no token, once" 1 \
    "$(events "${ROOT}/out.log" '.event=="gcs.no_token" and .reason=="no_metadata_token"')"
assert_eq "nothing was queried" 0 "$(calls "${ROOT}/calls.log" pr)"
curl -sS -X POST "${API}/_control/token_status?status=200" >/dev/null

# ---------------------------------------------------------------------------
printf '\n== a transient Cloud Storage fault is retried, not fatal ==\n'
# Without the retry, a single 503 on the state write loses every marker.
curl -sS -X DELETE "$(obj_url "${PREFIX}/requested.json")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
curl -sS -X POST "${API}/_control/fail_times?name=${PREFIX}/requested.json&status=503&times=2" >/dev/null
run --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the write was retried" 2 \
    "$(events "${ROOT}/out.log" '.event=="gcs.retry"')"
assert_eq "and it was not reported as a failure" 0 \
    "$(events "${ROOT}/out.log" '.event=="state.write_failed"')"
if bucket_has "${PREFIX}/requested.json"; then
    ok "the markers survived the fault"
else
    bad "the markers survived the fault" "$(bucket_dump)"
fi

printf '\n== a fault that outlasts the retries is reported, not silent ==\n'
# The object has to be absent, or the marker from the previous case makes this run
# skip the PR, write nothing, and have no failure to report.
curl -sS -X DELETE "$(obj_url "${PREFIX}/requested.json")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
curl -sS -X POST "${API}/_control/fail_times?name=${PREFIX}/requested.json&status=503&times=9" >/dev/null
run
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "the write failure was reported" 1 \
    "$(events "${ROOT}/out.log" '.event=="state.write_failed" and .severity=="ERROR"')"
curl -sS -X POST "${API}/_control/fail_times?name=${PREFIX}/requested.json&status=503&times=0" >/dev/null

# ---------------------------------------------------------------------------
printf '\n== losing the race to publish markers merges, it does not clobber ==\n'
# The write carries ifGenerationMatch, so a run whose lock was broken cannot
# overwrite the run that took over. A naive retry would drop the other markers.
curl -sS -X DELETE "$(obj_url "${PREFIX}/requested.json")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
# What this run reads at startup.
printf '{"XRPLF/rippled#1":{"head":"aaa","at":"2026-08-27T00:00:00Z"}}' |
    curl -sS -X POST --data-binary @- \
        "${API}/_control/preload?name=${PREFIX}/requested.json" >/dev/null
# What another run publishes before this one gets there.
printf '{"XRPLF/rippled#1":{"head":"aaa","at":"2026-08-27T00:00:00Z"},"XRPLF/clio#9":{"head":"zzz","at":"2026-08-27T12:00:00Z"}}' |
    curl -sS -X POST --data-binary @- \
        "${API}/_control/conflict?name=${PREFIX}/requested.json" >/dev/null
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the conflict was reported once" 1 \
    "$(events "${ROOT}/out.log" '.event=="state.write_conflict" and .severity=="WARNING"')"
final="$(bucket_dump | jq -r --arg k "${PREFIX}/requested.json" '.[$k]')"
assert_eq "this run's marker was written" "head1" \
    "$(jq -r '."XRPLF/rippled#42".head' <<<"${final}")"
assert_eq "the other run's marker survived" "zzz" \
    "$(jq -r '."XRPLF/clio#9".head' <<<"${final}")"
assert_eq "and the pre-existing marker survived" "aaa" \
    "$(jq -r '."XRPLF/rippled#1".head' <<<"${final}")"

# ---------------------------------------------------------------------------
printf '\n== a bucket that will not answer a read degrades, it does not stop ==\n'
# Losing the markers costs one redundant request per PR, which is a wasted call
# rather than a duplicate review, so a read fault must not end the run.
curl -sS -X POST "${API}/_control/force?name=${PREFIX}/requested.json&status=403" >/dev/null
run --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the unreadable marker object was reported" 1 \
    "$(events "${ROOT}/out.log" '.event=="state.read_failed" and .object=="requested.json"')"
assert_eq "and the work still got done" 1 "$(calls "${ROOT}/calls.log" request)"
curl -sS -X POST "${API}/_control/force?name=${PREFIX}/requested.json&status=0" >/dev/null

# ---------------------------------------------------------------------------
printf '\n== an unreadable marker object is left alone, not overwritten ==\n'
# The read fault that actually matters. The object can hold every marker from every
# previous run, and an empty in-memory table is not the same fact as "there are no
# markers", so publishing this run's handful over the top destroys the lot.
curl -sS -X DELETE "$(obj_url "${PREFIX}/lock")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
printf '{"XRPLF/clio#7":{"head":"ccc","at":"2026-08-27T00:00:00Z"},"XRPLF/rippled#900":{"head":"ddd","at":"2026-08-27T00:00:00Z"}}' |
    curl -sS -X POST --data-binary @- \
        "${API}/_control/preload?name=${PREFIX}/requested.json" >/dev/null
# 403 on the GET only: a 404 means a first run and may be created, whereas an
# unreadable object must not be replaced. The upload has to keep working, or the
# skip would be indistinguishable from a write that failed.
curl -sS -X POST "${API}/_control/force_method?method=GET&name=${PREFIX}/requested.json&status=403" >/dev/null
run --verbose
curl -sS -X POST "${API}/_control/force_method?method=GET&name=${PREFIX}/requested.json&status=0" >/dev/null
assert_eq "exit status is 0, this degrades rather than failing" 0 "${rc}"
assert_eq "the unreadable markers were reported" 1 \
    "$(events "${ROOT}/out.log" '.event=="state.read_failed" and .object=="requested.json"')"
assert_eq "and the write was skipped, loudly" 1 \
    "$(events "${ROOT}/out.log" '.event=="state.write_skipped" and .severity=="WARNING"')"
assert_eq "the stored markers survived untouched" \
    "XRPLF/clio#7 XRPLF/rippled#900" \
    "$(bucket_dump | jq -r --arg k "${PREFIX}/requested.json" \
        '.[$k] | fromjson | keys | join(" ")')"

printf '\n== a permission error names the service account that was denied ==\n'
curl -sS -X POST "${API}/_control/force?name=${PREFIX}/lock&status=403" >/dev/null
RUN_ENV=(GOOGLE_SERVICE_ACCOUNT=bot-runtime@example.iam.gserviceaccount.com)
run
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "the account is named in the event" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.fatal" and .service_account=="bot-runtime@example.iam.gserviceaccount.com"')"
curl -sS -X POST "${API}/_control/force?name=${PREFIX}/lock&status=0" >/dev/null

# ---------------------------------------------------------------------------
printf '\n== a lock that cannot be inspected is respected, not broken ==\n'
# Breaking a lock this run cannot read would be guessing, so it defers instead.
# The lock exists and is stale, so the acquire gets 412 and the bot goes to read
# it. Only that read fails, which is the path under test.
printf '{"holder":"other/pid-1","started_at":"2026-08-28T00:00:00Z"}' |
    curl -sS -X POST --data-binary @- \
        "${API}/_control/preload?name=${PREFIX}/lock&age_minutes=99" >/dev/null
curl -sS -X POST "${API}/_control/force_method?name=${PREFIX}/lock&method=GET&status=403" >/dev/null
run
assert_eq "exit status is 0, being late is not an error" 0 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${ROOT}/calls.log" pr)"
assert_eq "it reported the lock rather than breaking it" 1 \
    "$(events "${ROOT}/out.log" '.event=="run.skipped" and .reason=="locked"')"
assert_eq "and it did not claim to have broken one" 0 \
    "$(events "${ROOT}/out.log" '.event=="lock.broken"')"
curl -sS -X POST "${API}/_control/force_method?name=${PREFIX}/lock&method=GET&status=0" >/dev/null
curl -sS -X DELETE "$(obj_url "${PREFIX}/lock")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true

printf '\n== a lock that cannot be released says so, and expires anyway ==\n'
# Losing the release is survivable because of the TTL, but it has to be visible:
# the next tick is a no-op and somebody needs to know why. Only DELETE fails, so
# the run itself completes normally and the failure lands in the exit trap.
curl -sS -X POST "${API}/_control/force_method?name=${PREFIX}/lock&method=DELETE&status=503" >/dev/null
run --verbose
curl -sS -X POST "${API}/_control/force_method?name=${PREFIX}/lock&method=DELETE&status=0" >/dev/null
assert_eq "the run itself still succeeded" 0 "${rc}"
assert_eq "the failed release was reported" 1 \
    "$(events "${ROOT}/out.log" '.event=="lock.release_failed" and .severity=="WARNING"')"
curl -sS -X DELETE "$(obj_url "${PREFIX}/lock")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
printf '\n== a cold bucket needs no bootstrapping ==\n'
# An empty bucket files a request on the first run, since no bootstrapping is needed.
curl -sS -X DELETE "$(obj_url "${PREFIX}/requested.json")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
curl -sS -X DELETE "$(obj_url "${PREFIX}/lock")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
: >"${ROOT}/calls.log"
rc=0
env -i PATH="${BIN}:${TOOL_PATH}:/usr/bin:/bin" HOME="${ROOT}" FAKE_DIR="${ROOT}" \
    GH_TOKEN=stub-token GOOGLE_OAUTH_ACCESS_TOKEN=stub-oauth-token \
    GCS_API_ROOT="${API}" GCS_METADATA_ROOT="${API}" \
    STATE_DIR="gs://${BUCKET}/${STATE_ROOT}" SLEEP_BETWEEN_MUTATIONS=0 LOG_FORMAT=json \
    GCS_RETRY_BASE_SECONDS=0 \
    "${BASH_BIN}" "${BOT}" --repo XRPLF/rippled --verbose \
    >"${ROOT}/out.log" 2>&1 || rc=$?
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the review was requested on the first run" 1 "$(calls "${ROOT}/calls.log" request)"
assert_eq "and the marker was published" "head1" \
    "$(bucket_dump | jq -r --arg k "${PREFIX}/requested.json" '.[$k] | fromjson | ."XRPLF/rippled#42".head')"

# ---------------------------------------------------------------------------
printf '\n== on Cloud Run the lock records the execution that holds it ==\n'
curl -sS -X DELETE "$(obj_url "${PREFIX}/lock")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
RUN_ENV=(CLOUD_RUN_EXECUTION=copilot-review-bot-abcde CLOUD_RUN_TASK_INDEX=0)
run --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the holder names the execution and task" 1 \
    "$(events "${ROOT}/out.log" '.event=="lock.acquired" and .holder=="copilot-review-bot-abcde/task-0"')"

# ---------------------------------------------------------------------------
printf '\n== a lock create whose response is lost is adopted, not skipped ==\n'
# The write lands and the reply does not come back, so gcs_curl retries the same
# ifGenerationMatch=0 create and collides with its own object. Reading that 412 as
# somebody else's lock would skip the run and leave a lock nobody releases until
# LOCK_TTL_MINUTES expires, costing two further ticks.
curl -sS -X DELETE "$(obj_url "${PREFIX}/lock")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
# An earlier case left a marker for this PR's head, which would correctly suppress
# the request and hide whether the run got past the lock at all.
curl -sS -X DELETE "$(obj_url "${PREFIX}/requested.json")" \
    -H 'Authorization: Bearer stub' >/dev/null 2>&1 || true
curl -sS -X POST "${API}/_control/store_then_fail?name=${PREFIX}/lock&status=503" >/dev/null
run --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it adopted its own lock" 1 \
    "$(events "${ROOT}/out.log" '.event=="lock.adopted"')"
assert_eq "adopting is a WARNING, since a lost response is worth knowing about" 1 \
    "$(events "${ROOT}/out.log" '.event=="lock.adopted" and .severity=="WARNING"')"
assert_eq "it did not skip the run" 0 "$(events "${ROOT}/out.log" '.event=="run.skipped"')"
assert_eq "the work still got done" 1 "$(calls "${ROOT}/calls.log" request)"
# The whole point: the lock must not outlive the run that took it.
assert_eq "and the lock was released" "null" \
    "$(bucket_dump | jq -r --arg k "${PREFIX}/lock" '.[$k] // "null"')"

# ---------------------------------------------------------------------------
printf '\n== a local gcloud login is never used as a credential ==\n'
# Deliberately not a fallback. A laptop run against a gs:// STATE_DIR would
# otherwise authenticate as whoever is logged in, and a non-dry-run laptop run
# against the production prefix would take, and on release delete, the lock the
# scheduled job depends on. (--dry-run takes no lock at all; see the dry-run
# case above.)
cat >"${BIN}/gcloud" <<'STUB'
#!/usr/bin/env bash
printf 'gcloud-was-called\n' >>"${FAKE_DIR}/gcloud-calls.log"
[[ "${1:-}" == auth && "${2:-}" == print-access-token ]] && { printf 'stub-gcloud-token\n'; exit 0; }
exit 1
STUB
chmod +x "${BIN}/gcloud"
: >"${ROOT}/gcloud-calls.log"
curl -sS -X POST "${API}/_control/token_status?status=500" >/dev/null
RUN_ENV=(GOOGLE_OAUTH_ACCESS_TOKEN=)
run
assert_eq "exit status is 2, with no token there is nothing to fall back to" 2 "${rc}"
assert_eq "it said the token could not be obtained" 1 \
    "$(events "${ROOT}/out.log" '.event=="gcs.no_token"')"
assert_eq "gcloud was never invoked" 0 "$(calls "${ROOT}/gcloud-calls.log" gcloud-was-called)"
rm -f "${BIN}/gcloud"
curl -sS -X POST "${API}/_control/token_status?status=200" >/dev/null

# ---------------------------------------------------------------------------
printf '\n== an unreadable marker object degrades, it does not stop the run ==\n'
curl -sS -X POST "${API}/_control/force?name=${PREFIX}/requested.json&status=0" >/dev/null
printf 'not json at all' |
    curl -sS -X POST --data-binary @- \
        "${API}/_control/preload?name=${PREFIX}/requested.json" >/dev/null
run --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it warned that the markers are unusable" 1 \
    "$(events "${ROOT}/out.log" '.event=="state.unreadable" and .severity=="WARNING"')"
assert_eq "and the work still got done" 1 "$(calls "${ROOT}/calls.log" request)"

# ---------------------------------------------------------------------------
summary
