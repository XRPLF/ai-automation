#!/usr/bin/env bash
#
# copilot-review-bot-test.sh — exercise copilot-review-bot.sh's decision logic
# against synthetic pull request payloads. No network and no GitHub token
# needed: each case is fed to `copilot-review-bot.sh --explain`, which runs the
# same jq programs the live path uses.
#
# Usage: ./copilot-review-bot-test.sh [path-to-copilot-review-bot.sh]
#
set -euo pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    echo "bash 4.4+ required (this is ${BASH_VERSION:-unknown} at ${BASH})" >&2
    exit 2
fi

BOT="${1:-$(dirname "$0")/copilot-review-bot.sh}"
[[ -x "${BOT}" ]] || {
    echo "cannot execute ${BOT}" >&2
    exit 2
}
command -v jq >/dev/null || {
    echo "jq is required" >&2
    exit 2
}

export VIEWER_LOGIN="xrplf-bot"
export MENTION_SINCE="2000-01-01T00:00:00Z"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

# Field indices in the decision line emitted by --explain.
#   1 id  2 number  3 draft  4 base  5 head  6 has_review  7 pending
#   8 threads  9 unresolved  10 reviewed_head  11 new_work  12 basis
#   13 new_count  14 new_oid  15 new_date  16 last_review  17 reviewed_oid
declare -A FIELD=(
    [draft]=3 [base]=4 [head]=5 [has_review]=6 [pending]=7
    [threads]=8 [unresolved]=9 [reviewed_head]=10 [new_work]=11
    [basis]=12 [new_count]=13 [new_oid]=14
)

# check <name> <json> <expect-mentions> <field=value>...
check() {
    local name="$1" json="$2" want_mentions="$3"
    shift 3
    local file="${tmp}/pr.json" out decision mentions ok=true
    printf '%s' "${json}" >"${file}"

    if ! out="$("${BOT}" --explain "${file}" 2>&1)"; then
        printf 'FAIL %s\n     --explain failed:\n%s\n' "${name}" "${out}"
        fail=$((fail + 1))
        return
    fi
    decision="$(sed -n '2p' <<<"${out}")"
    mentions="$(sed -n '/^--- mentions/,$p' <<<"${out}" | tail -n +2 | grep -c . || true)"

    local spec key want got
    for spec in "$@"; do
        key="${spec%%=*}"
        want="${spec#*=}"
        got="$(cut -f "${FIELD[${key}]}" <<<"${decision}")"
        if [[ "${got}" != "${want}" ]]; then
            printf 'FAIL %s\n     %s: expected %q, got %q\n' "${name}" "${key}" "${want}" "${got}"
            ok=false
        fi
    done
    if [[ "${mentions}" != "${want_mentions}" ]]; then
        printf 'FAIL %s\n     mentions: expected %s, got %s\n' "${name}" "${want_mentions}" "${mentions}"
        ok=false
    fi

    if [[ "${ok}" == true ]]; then
        printf 'ok   %s\n' "${name}"
        pass=$((pass + 1))
    else
        printf '     decision line: %s\n' "${decision}"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------------

check "fresh PR, never reviewed" '{
  "id":"PR_1","number":1,"isDraft":false,"baseRefName":"develop","headRefOid":"c2",
  "commits":{"nodes":[
    {"commit":{"oid":"c1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"c2","authoredDate":"2026-08-01T11:00:00Z","committedDate":"2026-08-01T11:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=0 pending=0 unresolved=0 reviewed_head=0 new_work=0

check "reviewed head, nothing new" '{
  "id":"PR_2","number":2,"isDraft":false,"baseRefName":"develop","headRefOid":"c2",
  "reviews":{"nodes":[
    {"state":"COMMENTED","submittedAt":"2026-08-02T09:00:00Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"c2"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"c1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"c2","authoredDate":"2026-08-01T11:00:00Z","committedDate":"2026-08-01T11:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 reviewed_head=1 new_work=0 unresolved=0

check "merge commit only since review -> no new work" '{
  "id":"PR_3","number":3,"isDraft":false,"baseRefName":"develop","headRefOid":"m1",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-02T09:00:00Z",
     "author":{"login":"Copilot","id":"BOT_x"},"commit":{"oid":"c2"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"c1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"c2","authoredDate":"2026-08-01T11:00:00Z","committedDate":"2026-08-01T11:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"m1","authoredDate":"2026-08-03T11:00:00Z","committedDate":"2026-08-03T11:00:00Z","parents":{"totalCount":2}}}
  ]}
}' 0 has_review=1 reviewed_head=0 new_work=0 unresolved=0

check "real commit after a merge commit -> new work" '{
  "id":"PR_4","number":4,"isDraft":false,"baseRefName":"develop","headRefOid":"c3",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-02T09:00:00Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"c2"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"c2","authoredDate":"2026-08-01T11:00:00Z","committedDate":"2026-08-01T11:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"m1","authoredDate":"2026-08-03T11:00:00Z","committedDate":"2026-08-03T11:00:00Z","parents":{"totalCount":2}}},
    {"commit":{"oid":"c3","authoredDate":"2026-08-04T11:00:00Z","committedDate":"2026-08-04T11:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 reviewed_head=0 new_work=1 unresolved=0

check "unresolved Copilot thread blocks" '{
  "id":"PR_5","number":5,"isDraft":false,"baseRefName":"develop","headRefOid":"c3",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-02T09:00:00Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"c2"}}
  ]},
  "reviewThreads":{"nodes":[
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[
      {"id":"RC_1","createdAt":"2026-08-02T09:00:00Z","body":"nit: rename this",
       "author":{"login":"copilot-pull-request-reviewer"},"reactionGroups":[]}]}},
    {"isResolved":true,"isOutdated":false,"comments":{"nodes":[
      {"id":"RC_2","createdAt":"2026-08-02T09:00:00Z","body":"typo",
       "author":{"login":"copilot-pull-request-reviewer"},"reactionGroups":[]}]}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"c2","authoredDate":"2026-08-01T11:00:00Z","committedDate":"2026-08-01T11:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"c3","authoredDate":"2026-08-04T11:00:00Z","committedDate":"2026-08-04T11:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 threads=2 unresolved=1 new_work=1

check "human threads are not counted" '{
  "id":"PR_6","number":6,"isDraft":false,"baseRefName":"develop","headRefOid":"c3",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-02T09:00:00Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"c2"}}
  ]},
  "reviewThreads":{"nodes":[
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[
      {"id":"RC_3","createdAt":"2026-08-02T09:00:00Z","body":"I disagree",
       "author":{"login":"alice"},"reactionGroups":[]}]}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"c2","authoredDate":"2026-08-01T11:00:00Z","committedDate":"2026-08-01T11:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"c3","authoredDate":"2026-08-04T11:00:00Z","committedDate":"2026-08-04T11:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 threads=0 unresolved=0 new_work=1

check "force-push, commits authored after the review -> new work" '{
  "id":"PR_7","number":7,"isDraft":false,"baseRefName":"develop","headRefOid":"d2",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-02T09:00:00Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"gone"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"d1","authoredDate":"2026-08-05T10:00:00Z","committedDate":"2026-08-05T10:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"d2","authoredDate":"2026-08-05T10:01:00Z","committedDate":"2026-08-05T10:01:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 reviewed_head=0 new_work=1 basis=authored new_count=2

# The regression this suite exists for. A restack re-commits work that was
# authored before the review: the committer date moves, the author date does
# not. Keying on the committer date reported the reviewed commit itself as new.
check "restack only: committed after review, authored before -> no new work" '{
  "id":"PR_8","number":8,"isDraft":false,"baseRefName":"develop","headRefOid":"e1",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-03T21:27:56Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"gone"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"e1","authoredDate":"2026-08-02T01:35:54Z","committedDate":"2026-08-25T21:57:40Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 new_work=0 basis=rewritten new_count=0

# PR 7941 as GitHub reports it: one restacked commit (authored before the
# review) plus one genuinely new one. Only the latter counts.
check "restack plus one new commit -> exactly one counts" '{
  "id":"PR_8b","number":81,"isDraft":false,"baseRefName":"develop","headRefOid":"f2",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-03T21:27:56Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"gone"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"f1","authoredDate":"2026-08-02T01:35:54Z","committedDate":"2026-08-25T21:57:40Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"f2","authoredDate":"2026-08-26T14:25:23Z","committedDate":"2026-08-26T14:25:23Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 new_work=1 basis=authored new_count=1 new_oid=f2

# With the anchor still present, position decides and author dates are
# irrelevant — a cherry-picked old commit appended after the review is new work.
check "anchor present: old authored date still counts as new work" '{
  "id":"PR_8c","number":82,"isDraft":false,"baseRefName":"develop","headRefOid":"g2",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-10T09:00:00Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"g1"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"g1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}},
    {"commit":{"oid":"g2","authoredDate":"2026-07-01T10:00:00Z","committedDate":"2026-08-11T10:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=1 new_work=1 basis=position new_count=1

check "restack of only merge commits -> not even ambiguous" '{
  "id":"PR_8d","number":83,"isDraft":false,"baseRefName":"develop","headRefOid":"h1",
  "reviews":{"nodes":[
    {"submittedAt":"2026-08-03T21:27:56Z",
     "author":{"login":"copilot-pull-request-reviewer","id":"BOT_x"},"commit":{"oid":"gone"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"h1","authoredDate":"2026-08-25T10:00:00Z","committedDate":"2026-08-25T10:00:00Z","parents":{"totalCount":2}}}
  ]}
}' 0 has_review=1 new_work=0 basis=none

check "pending Copilot request is detected" '{
  "id":"PR_9","number":9,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "reviewRequests":{"nodes":[
    {"requestedReviewer":{"__typename":"Bot","id":"BOT_x","login":"copilot-pull-request-reviewer"}},
    {"requestedReviewer":{"__typename":"User","login":"bob"}}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"c1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 has_review=0 pending=1

check "draft targeting another branch is still parsed" '{
  "id":"PR_10","number":10,"isDraft":true,"baseRefName":"release-2.6","headRefOid":"c1",
  "commits":{"nodes":[
    {"commit":{"oid":"c1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 0 draft=1 base=release-2.6

check "mention in a PR comment is picked up" '{
  "id":"PR_11","number":11,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "comments":{"nodes":[
    {"id":"IC_1","createdAt":"2026-08-20T10:00:00Z","body":"hey @xrplf-bot please look",
     "author":{"login":"alice"},"reactionGroups":[]}
  ]},
  "commits":{"nodes":[
    {"commit":{"oid":"c1","authoredDate":"2026-08-01T10:00:00Z","committedDate":"2026-08-01T10:00:00Z","parents":{"totalCount":1}}}
  ]}
}' 1 has_review=0

check "mention already answered is skipped" '{
  "id":"PR_12","number":12,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "comments":{"nodes":[
    {"id":"IC_2","createdAt":"2026-08-20T10:00:00Z","body":"@xrplf-bot go",
     "author":{"login":"alice"},
     "reactionGroups":[{"content":"THUMBS_UP","viewerHasReacted":true},
                       {"content":"HEART","viewerHasReacted":false}]}
  ]}
}' 0 has_review=0

check "someone else reacted thumbs up -> still ours to answer" '{
  "id":"PR_13","number":13,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "comments":{"nodes":[
    {"id":"IC_3","createdAt":"2026-08-20T10:00:00Z","body":"@xrplf-bot go",
     "author":{"login":"alice"},
     "reactionGroups":[{"content":"THUMBS_UP","viewerHasReacted":false}]}
  ]}
}' 1 has_review=0

check "quoted mention and self-authored mention are ignored" '{
  "id":"PR_14","number":14,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "comments":{"nodes":[
    {"id":"IC_4","createdAt":"2026-08-20T10:00:00Z","body":"> @xrplf-bot go\nagreed",
     "author":{"login":"alice"},"reactionGroups":[]},
    {"id":"IC_5","createdAt":"2026-08-20T11:00:00Z","body":"@xrplf-bot ack",
     "author":{"login":"xrplf-bot"},"reactionGroups":[]},
    {"id":"IC_6","createdAt":"2026-08-20T12:00:00Z","body":"cc @xrplf-bot-staging only",
     "author":{"login":"alice"},"reactionGroups":[]}
  ]}
}' 0 has_review=0

check "mention inside a review comment thread counts" '{
  "id":"PR_15","number":15,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "reviewThreads":{"nodes":[
    {"isResolved":true,"isOutdated":false,"comments":{"nodes":[
      {"id":"RC_9","createdAt":"2026-08-02T09:00:00Z","body":"nit",
       "author":{"login":"copilot-pull-request-reviewer"},"reactionGroups":[]},
      {"id":"RC_10","createdAt":"2026-08-21T09:00:00Z","body":"fixed, @XRPLF-Bot recheck",
       "author":{"login":"alice"},"reactionGroups":[]}]}}
  ]}
}' 1 has_review=0 unresolved=0

check "old mentions fall outside the lookback window" '{
  "id":"PR_16","number":16,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "comments":{"nodes":[
    {"id":"IC_7","createdAt":"1999-01-01T10:00:00Z","body":"@xrplf-bot go",
     "author":{"login":"alice"},"reactionGroups":[]}
  ]}
}' 0 has_review=0

# CommonMark treats up to 3 leading spaces before ">" as still a block quote,
# so an indented quoted mention must be ignored the same as an unindented one.
check "indented quoted mention is still ignored" '{
  "id":"PR_17","number":17,"isDraft":false,"baseRefName":"develop","headRefOid":"c1",
  "comments":{"nodes":[
    {"id":"IC_8","createdAt":"2026-08-20T10:00:00Z","body":"  > @xrplf-bot go\nagreed, on it",
     "author":{"login":"alice"},"reactionGroups":[]}
  ]}
}' 0 has_review=0

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
