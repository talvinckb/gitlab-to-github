#!/usr/bin/env python3
"""
migrate.py — GitLab -> GitHub metadata migration (labels, milestones, issues, MRs)

Called by migrate.sh for tier-3 ("full") migrations. Handles what git alone
can't: REST API calls, JSON payloads, pagination and rate limiting.

Stdlib only (urllib) — no pip install required.

Known limitation (read this before running on a large project):
  A GitLab merge request can only become a *real* GitHub pull request if its
  source branch still exists in the target repo. If the branch was deleted
  after merge (the GitLab default), there is nothing to open a PR against —
  GitHub has no concept of a "PR" without a diff. By default (--mr-fallback
  report) this script does NOT create anything for those MRs individually;
  it collects them into a single MIGRATION_REPORT.md committed to the repo,
  so the issue tracker isn't flooded with historical, already-closed items.
  Pass --mr-fallback issue to restore the old per-MR GitHub issue behavior.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ─── Console helpers (mirrors migrate.sh styling) ────────────────────────────

BLUE, GREEN, YELLOW, RED, CYAN, BOLD, RESET = (
    "\033[0;34m",
    "\033[0;32m",
    "\033[1;33m",
    "\033[0;31m",
    "\033[0;36m",
    "\033[1m",
    "\033[0m",
)


def info(msg: str) -> None:
    print(f"{BLUE}[INFO]{RESET}  {msg}")


def success(msg: str) -> None:
    print(f"{GREEN}[OK]{RESET}    {msg}")


def warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET}  {msg}")


def error(msg: str) -> None:
    print(f"{RED}[ERROR]{RESET} {msg}", file=sys.stderr)


# ─── Generic HTTP client with retry + rate-limit awareness ──────────────────


class ApiError(RuntimeError):
    def __init__(self, status: int, url: str, body: str):
        super().__init__(f"HTTP {status} on {url}: {body[:300]}")
        self.status = status
        self.body = body


def _request(
    method: str,
    url: str,
    headers: dict,
    payload: dict | None = None,
    max_retries: int = 5,
) -> tuple[dict | list | None, dict]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)

    for attempt in range(1, max_retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                body = json.loads(raw) if raw else None
                return body, dict(resp.headers)
        except urllib.error.HTTPError as e:
            resp_headers = dict(e.headers) if e.headers else {}
            raw = e.read()
            text = raw.decode("utf-8", errors="replace") if raw else ""

            # GitHub secondary/primary rate limit
            if e.code == 403 and resp_headers.get("X-RateLimit-Remaining") == "0":
                reset = int(resp_headers.get("X-RateLimit-Reset", time.time() + 60))
                sleep_for = max(reset - int(time.time()), 1) + 1
                warn(f"Rate limit hit, sleeping {sleep_for}s...")
                time.sleep(sleep_for)
                continue
            if e.code == 403 and "secondary rate limit" in text.lower():
                sleep_for = 2**attempt
                warn(f"Secondary rate limit, backing off {sleep_for}s...")
                time.sleep(sleep_for)
                continue
            # Transient server errors -> retry with backoff
            if e.code >= 500 and attempt < max_retries:
                sleep_for = 2**attempt
                warn(
                    f"HTTP {e.code} on {url}, retrying in {sleep_for}s ({attempt}/{max_retries})..."
                )
                time.sleep(sleep_for)
                continue
            raise ApiError(e.code, url, text) from None
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < max_retries:
                sleep_for = 2**attempt
                warn(f"Network error ({e}), retrying in {sleep_for}s...")
                time.sleep(sleep_for)
                continue
            raise

    raise RuntimeError(f"Exhausted retries for {method} {url}")


def _parse_link_header(link_header: str | None) -> dict[str, str]:
    """RFC 5988 Link header parsing, used by both GitHub and GitLab."""
    links: dict[str, str] = {}
    if not link_header:
        return links
    for part in link_header.split(","):
        m = re.match(r'\s*<([^>]+)>;\s*rel="([^"]+)"', part)
        if m:
            links[m.group(2)] = m.group(1)
    return links


def paginated_get(url: str, headers: dict) -> list:
    """Follow Link: rel="next" headers (works for both GitHub and GitLab APIs)."""
    results: list = []
    next_url: str | None = url
    while next_url:
        body, resp_headers = _request("GET", next_url, headers)
        if isinstance(body, list):
            results.extend(body)
        elif body is not None:
            results.append(body)
        links = _parse_link_header(resp_headers.get("Link"))
        next_url = links.get("next")
    return results


# ─── GitLab client ────────────────────────────────────────────────────────────


class GitLab:
    def __init__(self, domain: str, project_path: str, token: str):
        self.base = f"https://{domain}/api/v4"
        self.project = urllib.parse.quote(project_path, safe="")
        self.headers = {"PRIVATE-TOKEN": token, "Content-Type": "application/json"}

    def get(self, path: str, params: dict | None = None) -> list:
        qs = f"?{urllib.parse.urlencode(params)}" if params else ""
        url = f"{self.base}/projects/{self.project}/{path}{qs}"
        return paginated_get(url, self.headers)

    def labels(self) -> list:
        return self.get("labels", {"per_page": 100})

    def milestones(self) -> list:
        return self.get("milestones", {"per_page": 100, "state": "all"})

    def issues(self) -> list:
        return self.get(
            "issues",
            {"per_page": 100, "order_by": "created_at", "sort": "asc", "scope": "all"},
        )

    def issue_notes(self, iid: int) -> list:
        return self.get(f"issues/{iid}/notes", {"per_page": 100, "sort": "asc"})

    def merge_requests(self) -> list:
        return self.get(
            "merge_requests",
            {"per_page": 100, "order_by": "created_at", "sort": "asc", "scope": "all"},
        )

    def mr_notes(self, iid: int) -> list:
        return self.get(f"merge_requests/{iid}/notes", {"per_page": 100, "sort": "asc"})


# ─── GitHub client ────────────────────────────────────────────────────────────


class GitHub:
    def __init__(self, repo: str, token: str):
        self.base = f"https://api.github.com/repos/{repo}"
        self.headers = {
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        }

    def get(self, path: str) -> list | dict | None:
        return paginated_get(f"{self.base}/{path}", self.headers)

    def get_one(self, path: str) -> dict | None:
        body, _ = _request("GET", f"{self.base}/{path}", self.headers)
        return body

    def post(self, path: str, payload: dict) -> dict:
        body, _ = _request("POST", f"{self.base}/{path}", self.headers, payload)
        return body

    def patch(self, path: str, payload: dict) -> dict:
        body, _ = _request("PATCH", f"{self.base}/{path}", self.headers, payload)
        return body

    def put(self, path: str, payload: dict) -> dict:
        body, _ = _request("PUT", f"{self.base}/{path}", self.headers, payload)
        return body

    def branch_exists(self, branch: str) -> bool:
        try:
            self.get_one(f"branches/{urllib.parse.quote(branch, safe='')}")
            return True
        except ApiError as e:
            if e.status == 404:
                return False
            raise

    def create_or_update_file(self, path: str, content: str, message: str) -> dict:
        """Create/update a file via the Contents API (used for MIGRATION_REPORT.md)."""
        existing_sha = None
        try:
            existing = self.get_one(f"contents/{path}")
            if isinstance(existing, dict):
                existing_sha = existing.get("sha")
        except ApiError as e:
            if e.status != 404:
                raise
        payload = {
            "message": message,
            "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
        }
        if existing_sha:
            payload["sha"] = existing_sha
        return self.put(f"contents/{path}", payload)


# ─── Migration logic ─────────────────────────────────────────────────────────


def attribution_footer(author: str, created_at: str, kind: str = "issue") -> str:
    return f"\n\n---\n_Originally {kind} by **{author}** on {created_at[:10]} (migrated from GitLab)._"


def migrate_labels(gl: GitLab, gh: GitHub) -> None:
    info("Migrating labels...")
    existing = {label["name"] for label in (gh.get("labels") or [])}
    labels = gl.labels()
    created = 0
    for label in labels:
        name = label["name"]
        if name in existing:
            continue
        color = label.get("color", "#ededed").lstrip("#")
        try:
            gh.post(
                "labels",
                {
                    "name": name,
                    "color": color,
                    "description": (label.get("description") or "")[:100],
                },
            )
            created += 1
        except ApiError as e:
            if e.status != 422:  # already exists / validation — skip
                warn(f"Could not create label '{name}': {e}")
    success(f"Labels: {created} created, {len(labels) - created} already present.")


def migrate_milestones(gl: GitLab, gh: GitHub) -> dict[str, int]:
    info("Migrating milestones...")
    mapping: dict[str, int] = {}
    existing = {m["title"]: m["number"] for m in (gh.get("milestones?state=all") or [])}
    milestones = gl.milestones()
    created = 0
    for ms in milestones:
        title = ms["title"]
        if title in existing:
            mapping[title] = existing[title]
            continue
        payload = {
            "title": title,
            "description": (ms.get("description") or "")[:1000],
            "state": "closed" if ms.get("state") in ("closed",) else "open",
        }
        if ms.get("due_date"):
            payload["due_on"] = f"{ms['due_date']}T00:00:00Z"
        try:
            resp = gh.post("milestones", payload)
            mapping[title] = resp["number"]
            created += 1
        except ApiError as e:
            warn(f"Could not create milestone '{title}': {e}")
    success(
        f"Milestones: {created} created, {len(milestones) - created} already present."
    )
    return mapping


def migrate_issues(
    gl: GitLab, gh: GitHub, milestone_map: dict[str, int]
) -> dict[int, int]:
    info("Migrating issues...")
    iid_to_number: dict[int, int] = {}
    issues = gl.issues()
    for i, issue in enumerate(issues, 1):
        iid = issue["iid"]
        author = issue["author"]["username"]
        body = (issue.get("description") or "") + attribution_footer(
            author, issue["created_at"]
        )
        payload: dict = {"title": issue["title"], "body": body}

        labels = issue.get("labels") or []
        if labels:
            payload["labels"] = labels
        ms_title = (issue.get("milestone") or {}).get("title")
        if ms_title and ms_title in milestone_map:
            payload["milestone"] = milestone_map[ms_title]

        try:
            created = gh.post("issues", payload)
        except ApiError as e:
            warn(f"Could not create issue for GitLab #{iid} ('{issue['title']}'): {e}")
            continue

        number = created["number"]
        iid_to_number[iid] = number

        # Comments
        for note in gl.issue_notes(iid):
            if note.get("system"):
                continue  # skip GitLab's auto-generated system notes (label changes, etc.)
            note_body = note["body"] + attribution_footer(
                note["author"]["username"], note["created_at"], "commented"
            )
            try:
                gh.post(f"issues/{number}/comments", {"body": note_body})
            except ApiError as e:
                warn(f"Could not migrate a comment on issue #{number}: {e}")

        if issue.get("state") == "closed":
            try:
                gh.patch(f"issues/{number}", {"state": "closed"})
            except ApiError as e:
                warn(f"Could not close issue #{number}: {e}")

        info(f"  [{i}/{len(issues)}] issue !{iid} -> #{number}")

    success(f"Issues: {len(iid_to_number)}/{len(issues)} migrated.")
    return iid_to_number


def build_mr_report(entries: list[dict]) -> str:
    lines = [
        "# Migrated merge requests\n",
        "The merge requests below could not be recreated as GitHub pull requests: "
        "their source branch no longer exists in this repository (typically deleted "
        "on GitLab after merging), so there was no diff left to open a PR against. "
        "Their metadata is preserved here; full discussion threads remain on the "
        "original GitLab project via the links below.\n",
        "---\n",
    ]
    for e in entries:
        lines.append(f"## !{e['iid']} — {e['title']}")
        lines.append(f"- **State:** {e['state']}")
        lines.append(f"- **Author:** {e['author']}")
        lines.append(f"- **Created:** {e['created_at'][:10]}")
        lines.append(f"- **Branches:** `{e['source']}` → `{e['target']}`")
        if e.get("web_url"):
            lines.append(f"- **Original MR:** {e['web_url']}")
        lines.append("")
        if e.get("description"):
            lines.append(e["description"])
        lines.append("\n---\n")
    return "\n".join(lines)


def migrate_merge_requests(
    gl: GitLab, gh: GitHub, milestone_map: dict[str, int], fallback_mode: str = "report"
) -> None:
    info(f"Migrating merge requests (fallback mode: {fallback_mode})...")
    mrs = gl.merge_requests()
    real_pr_count = 0
    fallback_count = 0
    report_entries: list[dict] = []

    if fallback_mode == "issue":
        # Make sure the fallback label exists
        try:
            gh.post(
                "labels",
                {
                    "name": "migrated-mr",
                    "color": "d4c5f9",
                    "description": "Migrated GitLab MR whose source branch no longer exists",
                },
            )
        except ApiError:
            pass  # already exists

    for i, mr in enumerate(mrs, 1):
        iid = mr["iid"]
        author = mr["author"]["username"]
        body = (mr.get("description") or "") + attribution_footer(
            author, mr["created_at"]
        )
        source, target = mr["source_branch"], mr["target_branch"]

        branch_present = gh.branch_exists(source)
        number = None

        if branch_present:
            try:
                pr = gh.post(
                    "pulls",
                    {
                        "title": mr["title"],
                        "body": body,
                        "head": source,
                        "base": target,
                    },
                )
                number = pr["number"]
                real_pr_count += 1

                if mr.get("state") == "merged":
                    try:
                        gh.put(f"pulls/{number}/merge", {"merge_method": "merge"})
                    except ApiError as e:
                        warn(
                            f"Could not merge PR #{number} (merging manually may be required): {e}"
                        )
                elif mr.get("state") == "closed":
                    gh.patch(f"pulls/{number}", {"state": "closed"})

            except ApiError as e:
                warn(f"Could not open PR for GitLab MR !{iid}, falling back: {e}")
                branch_present = False

        if not branch_present:
            fallback_count += 1

            if fallback_mode == "skip":
                info(
                    f"  [{i}/{len(mrs)}] MR !{iid} -> skipped (no branch to diff against)"
                )
                continue  # nothing created on GitHub, so no comments to attach

            if fallback_mode == "report":
                report_entries.append(
                    {
                        "iid": iid,
                        "title": mr["title"],
                        "author": author,
                        "created_at": mr["created_at"],
                        "state": mr.get("state", "unknown"),
                        "source": source,
                        "target": target,
                        "web_url": mr.get("web_url"),
                        "description": mr.get("description") or "",
                    }
                )
                info(
                    f"  [{i}/{len(mrs)}] MR !{iid} -> report entry (no branch to diff against)"
                )
                continue  # nothing created on GitHub, so no comments to attach

            note = (
                "\n\n_⚠ Source branch no longer exists in the target repo — "
                "this was migrated as an issue instead of a pull request._"
            )
            payload = {
                "title": f"[MR] {mr['title']}",
                "body": body + note,
                "labels": ["migrated-mr"],
            }
            try:
                created = gh.post("issues", payload)
                number = created["number"]
                if mr.get("state") in ("merged", "closed"):
                    gh.patch(f"issues/{number}", {"state": "closed"})
            except ApiError as e:
                warn(f"Could not create fallback issue for MR !{iid}: {e}")
                continue

        for note in gl.mr_notes(iid):
            if note.get("system"):
                continue
            note_body = note["body"] + attribution_footer(
                note["author"]["username"], note["created_at"], "commented"
            )
            try:
                gh.post(f"issues/{number}/comments", {"body": note_body})
            except ApiError as e:
                warn(f"Could not migrate a comment on !{iid}: {e}")

        info(
            f"  [{i}/{len(mrs)}] MR !{iid} -> {'PR' if branch_present else 'issue'} #{number}"
        )

    if fallback_mode == "report" and report_entries:
        report_md = build_mr_report(report_entries)
        try:
            gh.create_or_update_file(
                "MIGRATION_REPORT.md",
                report_md,
                "Add report for MRs migrated without a source branch",
            )
            success(
                f"Merge requests: {real_pr_count} opened as real PRs, {fallback_count} listed in "
                f"MIGRATION_REPORT.md (source branch missing)."
            )
        except ApiError as e:
            error(f"Could not commit MIGRATION_REPORT.md: {e}")
            info("Report content follows so you don't lose it:\n" + report_md)
    elif fallback_mode == "skip":
        success(
            f"Merge requests: {real_pr_count} opened as real PRs, {fallback_count} skipped "
            f"(source branch missing, nothing created on GitHub)."
        )
    else:
        success(
            f"Merge requests: {real_pr_count} opened as real PRs, {fallback_count} migrated as issues "
            f"(source branch missing)."
        )


# ─── Entry point ──────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="GitLab -> GitHub metadata migration")
    parser.add_argument("--gitlab-domain", required=True)
    parser.add_argument(
        "--gitlab-project", required=True, help="namespace/project path"
    )
    parser.add_argument("--gitlab-token", required=True)
    parser.add_argument("--github-repo", required=True, help="owner/repo")
    parser.add_argument("--github-token", required=True)
    parser.add_argument(
        "--mr-fallback",
        choices=["report", "issue", "skip"],
        default="report",
        help="How to handle MRs whose source branch no longer exists: "
        "'report' (default) collects them into a single MIGRATION_REPORT.md; "
        "'issue' creates one GitHub issue per MR (old behavior); "
        "'skip' does nothing for them at all (just counted and logged).",
    )
    args = parser.parse_args()

    gl = GitLab(args.gitlab_domain, args.gitlab_project, args.gitlab_token)
    gh = GitHub(args.github_repo, args.github_token)

    try:
        migrate_labels(gl, gh)
        milestone_map = migrate_milestones(gl, gh)
        migrate_issues(gl, gh, milestone_map)
        migrate_merge_requests(gl, gh, milestone_map, fallback_mode=args.mr_fallback)
    except ApiError as e:
        error(str(e))
        sys.exit(1)


if __name__ == "__main__":
    main()
