#!/usr/bin/env python3
"""Fail closed on CodeRabbit transport success without a current-head review.

Offline: verify-coderabbit-review.py SNAPSHOT.json (0 pass, 1 reject, 2 wait).
Live: --live uses REPO, SHA, PR_NUMBER and GH_TOKEN; polls twelve times at 30-second intervals (job timeout: 15 minutes).
Only fixed diagnostics are printed; raw bot bodies are never echoed.
"""

import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.request

BOT_LOGINS = {"coderabbitai", "coderabbitai[bot]"}
APP_SLUGS = {"coderabbit", "coderabbitai"}
BLOCKED = re.compile(
    r"rate[ -]limit|review limit reached|review skipped|skipped review|"
    r"no review(?: was)? (?:performed|happened|generated|occurred)\b|"
    r"no review\s*(?:[.!]|$)|"
    r"review (?:was |is )?(?:not performed|not completed|disabled)|"
    r"reviews? (?:paused|disabled)|auto-generated comment:.*(?:skipped|rate limited)",
    re.I,
)
SUBSTANTIVE = re.compile(
    r"actionable comments posted:\s*\d+|"
    r"no actionable comments were generated in the recent review|"
    r"no additional comments|(?:code )?review completed|review finished",
    re.I,
)
RANGE = re.compile(
    r"Reviewing files.*?between\s+`?([0-9a-f]{40})`?\s+and\s+`?([0-9a-f]{40})`?",
    re.I | re.S,
)


def text_of(record):
    output = record.get("output") or {}
    return " ".join(str(value or "") for value in (
        record.get("description"), record.get("body"), output.get("title"),
        output.get("summary"), output.get("text"),
    ))


def timestamp(record):
    return record.get("updated_at") or record.get("submitted_at") or record.get("created_at") or ""


def latest(records, key):
    selected = {}
    for record in records:
        identity = key(record)
        if identity not in selected or timestamp(record) >= timestamp(selected[identity]):
            selected[identity] = record
    return list(selected.values())


def latest_check_runs(records):
    selected = {}
    for record in records:
        run_id = record.get("id")
        if type(run_id) is not int or run_id <= 0:
            return None
        identity = (record.get("name"), (record.get("app") or {}).get("slug"))
        # REST check runs have attempt IDs, not updated_at/created_at. An older
        # attempt finishing later must not replace the newer queued attempt.
        if identity not in selected or run_id > selected[identity]["id"]:
            selected[identity] = record
    return list(selected.values())


def review_body(record):
    body = record.get("body") or ""
    # Walkthroughs/release notes can outlive a review. Only the recent section
    # may establish the range/completion when the rolling comment supplies it.
    match = re.search(r"<!-- recent_review_start -->(.*?)<!-- recent_review_end -->", body, re.S)
    return match.group(1) if match else body


def evaluate(data):
    sha = data["sha"]
    if data.get("head_sha") != sha:
        return 1, "PR head changed; evidence belongs to a superseded head."
    runs = latest_check_runs([
        run for run in data["check_runs"]
        if run.get("head_sha") == sha
        and run.get("name", "").lower() != "coderabbit-gate"
        and (run.get("app") or {}).get("slug", "").lower() in APP_SLUGS
    ])
    if runs is None:
        return 1, "CodeRabbit check-run attempt identity is missing or invalid."
    statuses = latest([
        status for status in data["statuses"]
        if status.get("context", "").lower() in {"coderabbit", "coderabbitai"}
    ], lambda status: status["context"].lower())
    signals = runs + statuses
    for signal in signals:
        if BLOCKED.search(text_of(signal)):
            return 1, "CodeRabbit explicitly skipped or rate-limited this head."
        conclusion = signal.get("conclusion") if "conclusion" in signal else signal.get("state")
        if conclusion in {"failure", "error", "cancelled", "timed_out", "skipped", "neutral", "action_required", "stale"}:
            return 1, "CodeRabbit did not complete a successful review on this head."
    if any(run.get("status") != "completed" or run.get("conclusion") != "success" for run in runs) or any(
        status.get("state") != "success" for status in statuses
    ):
        return 2, "CodeRabbit review is still in progress."

    comments = latest([
        comment for comment in data["comments"]
        if (comment.get("user") or {}).get("login", "").lower() in BOT_LOGINS
    ], lambda comment: "rolling-comment")
    reviews = latest([
        review for review in data["reviews"]
        if review.get("commit_id") == sha
        and (review.get("user") or {}).get("login", "").lower() in BOT_LOGINS
    ], lambda review: "review")
    evidence = []
    for record in comments + reviews:
        body = review_body(record)
        ranges = RANGE.findall(body)
        current = record.get("commit_id") == sha or any(end.lower() == sha for _, end in ranges)
        # The newest unscoped refusal cannot be proven stale. Fail closed even
        # if its timestamp precedes a status by a few seconds. A refusal
        # explicitly scoped to an older range is irrelevant.
        unscoped = not ranges and not record.get("commit_id")
        if (current or unscoped) and BLOCKED.search(record.get("body") or ""):
            return 1, "CodeRabbit's current review evidence explicitly reports no review."
        if not current:
            continue
        if record.get("state") in {"CHANGES_REQUESTED", "DISMISSED"}:
            return 1, "CodeRabbit's current review is failing or dismissed."
        if "state" in record and record.get("state") not in {"APPROVED", "COMMENTED"}:
            return 2, "CodeRabbit's current review is pending."
        if SUBSTANTIVE.search(body):
            evidence.append(record)
    # Exact-head completed check output can itself carry a substantive review.
    # A generic success description on a legacy status cannot.
    evidence += [run for run in runs if run.get("conclusion") == "success"
                 and SUBSTANTIVE.search(text_of(run))]
    if evidence:
        return 0, "Completed substantive CodeRabbit review verified for this head."
    return 2, "No completed substantive CodeRabbit review evidence for this head."


def api(path):
    records = []
    url = f"https://api.github.com/repos/{os.environ['REPO']}/{path}"
    while url:
        request = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
            if isinstance(payload, dict) and "check_runs" in payload:
                records.extend(payload["check_runs"])
            elif isinstance(payload, list):
                records.extend(payload)
            else:
                return payload
            # Follow GitHub pagination without forwarding credentials elsewhere.
            next_link = re.search(r'<(https://api\.github\.com/[^>]+)>; rel="next"', response.headers.get("Link", ""))
            url = next_link.group(1) if next_link else None
    return records


def live():
    sha, number = os.environ["SHA"], os.environ["PR_NUMBER"]
    for attempt in range(12):
        data = {
            "sha": sha,
            "head_sha": api(f"pulls/{number}")["head"]["sha"],
            "check_runs": api(f"commits/{sha}/check-runs?per_page=100"),
            "statuses": api(f"commits/{sha}/statuses?per_page=100"),
            "comments": api(f"issues/{number}/comments?per_page=100"),
            "reviews": api(f"pulls/{number}/reviews?per_page=100"),
        }
        result, message = evaluate(data)
        print(message, flush=True)
        if result != 2:
            return result
        if attempt < 11:
            time.sleep(30)
    print("::error::CodeRabbit review evidence missing or pending after bounded wait.")
    return 1


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--live"]:
            code = live()
        elif len(sys.argv) == 2:
            code, message = evaluate(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")))
            print(message)
        else:
            raise ValueError("expected SNAPSHOT.json or --live")
    except (OSError, ValueError, KeyError, TypeError) as error:
        # API errors must fail closed; do not echo responses or credentials.
        print(f"::error::Unable to verify CodeRabbit evidence ({type(error).__name__}).", file=sys.stderr)
        code = 1
    sys.exit(code)
