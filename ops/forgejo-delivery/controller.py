#!/usr/bin/env python3
"""Fail-closed Forgejo review, merge, and repository-owned deployment controller."""

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

META_PREFIX = "<!-- sprucegoose-review-v1 "
META_SUFFIX = " -->"
VERDICTS = {"pass", "concerns", "blocked"}


class Refusal(RuntimeError):
    pass


def api(base, token, path, *, method="GET", body=None, raw=False):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    headers = {"Accept": "application/json", "Authorization": f"token {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base.rstrip("/") + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read()
            if raw:
                return payload.decode(errors="strict")
            return None if not payload else json.loads(payload)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        raise Refusal(f"Forgejo HTTP {error.code} for {path}: {detail}") from error


def pages(base, token, path, *, limit=20):
    items = []
    for page in range(1, limit + 1):
        separator = "&" if "?" in path else "?"
        batch = api(base, token, f"{path}{separator}limit=50&page={page}")
        if not isinstance(batch, list):
            raise Refusal("paginated Forgejo response is not a list")
        items.extend(batch)
        if len(batch) < 50:
            return items
    raise Refusal("Forgejo response exceeded pagination limit")


def load_policy(path):
    policy = json.loads(pathlib.Path(path).read_text())
    required = {"api", "repositories", "reviewer_command", "evidence_dir"}
    if set(policy) != required or not isinstance(policy["repositories"], dict):
        raise Refusal("policy must contain exactly api, repositories, reviewer_command, evidence_dir")
    return policy


def token(path):
    value = pathlib.Path(path).read_text().strip()
    if not value:
        raise Refusal("token file is empty")
    return value


def repo_policy(policy, repository):
    config = policy["repositories"].get(repository)
    required = {"base", "required_checks", "reviewer", "merger", "checkout", "adapter", "adapter_sha256"}
    if not isinstance(config, dict) or set(config) != required:
        raise Refusal("repository is unsupported or its policy is incomplete")
    if not config["required_checks"]:
        raise Refusal("repository has no required checks")
    return config


def pr_identity(repository, pull):
    head = pull.get("head") or {}
    base = pull.get("base") or {}
    identity = {
        "repository": repository,
        "number": pull.get("number"),
        "base": base.get("sha"),
        "head": head.get("sha"),
        "target": base.get("ref"),
    }
    if not all(identity.values()):
        raise Refusal("pull request lacks a complete identity")
    return identity


def check_identity(identity, config):
    if identity["target"] != config["base"]:
        raise Refusal("pull request targets an unsupported branch")


def successful_checks(statuses, head, required):
    matched = {}
    for status in statuses:
        if status.get("sha") not in (None, head):
            continue
        context = status.get("context")
        if context in required and context not in matched:
            matched[context] = {key: status.get(key) for key in ("id", "status", "target_url")}
    missing = [name for name in required if (matched.get(name) or {}).get("status") != "success"]
    if missing:
        raise Refusal("required checks are not successful: " + ", ".join(missing))
    return hashlib.sha256(json.dumps(matched, sort_keys=True).encode()).hexdigest()


def review_payload(output, identity, ci_digest):
    value = json.loads(output)
    required = {"repository", "number", "base", "head", "target", "ci_digest", "verdict", "summary", "findings"}
    if not isinstance(value, dict) or set(value) != required:
        raise Refusal("review output has an invalid schema")
    for key in ("repository", "number", "base", "head", "target"):
        if value[key] != identity[key]:
            raise Refusal(f"review output has stale {key}")
    if value["ci_digest"] != ci_digest or value["verdict"] not in VERDICTS:
        raise Refusal("review output has stale CI or invalid verdict")
    if not isinstance(value["summary"], str) or not isinstance(value["findings"], list):
        raise Refusal("review output has invalid content")
    return value


def meta(review):
    bound = {key: review[key] for key in ("repository", "number", "base", "head", "target", "ci_digest", "verdict")}
    return META_PREFIX + urllib.parse.quote(json.dumps(bound, sort_keys=True, separators=(",", ":")), safe="") + META_SUFFIX


def parse_meta(body):
    if not isinstance(body, str):
        return None
    line = body.rstrip().splitlines()[-1]
    if not line.startswith(META_PREFIX) or not line.endswith(META_SUFFIX):
        return None
    try:
        return json.loads(urllib.parse.unquote(line[len(META_PREFIX):-len(META_SUFFIX)]))
    except (ValueError, json.JSONDecodeError):
        return None


def render(review):
    summary = review["summary"].replace("@", "&#64;").replace("<", "&lt;").replace(">", "&gt;")
    return f"Automated review: {review['verdict']}\n\n{summary}\n\n{meta(review)}"


def run_reviewer(command, payload):
    try:
        result = subprocess.run(command, input=json.dumps(payload), text=True, capture_output=True,
                                timeout=600, check=True)
    except subprocess.TimeoutExpired as error:
        raise Refusal("reviewer timed out") from error
    except subprocess.CalledProcessError as error:
        raise Refusal(f"reviewer exited {error.returncode}") from error
    return result.stdout


def current_pull(base, token_value, repository, number):
    return api(base, token_value, f"/repos/{repository}/pulls/{number}")


def review(policy, token_value, repository, number):
    config = repo_policy(policy, repository)
    if api(policy["api"], token_value, "/user").get("login") != config["reviewer"]:
        raise Refusal("review token identity does not match policy")
    pull = current_pull(policy["api"], token_value, repository, number)
    identity = pr_identity(repository, pull)
    check_identity(identity, config)
    statuses = pages(policy["api"], token_value, f"/repos/{repository}/commits/{identity['head']}/statuses")
    ci_digest = successful_checks(statuses, identity["head"], config["required_checks"])
    reviews = pages(policy["api"], token_value, f"/repos/{repository}/pulls/{number}/reviews")
    try:
        review_id = approved_review(reviews, identity, ci_digest, (pull.get("user") or {}).get("login"),
                                    config["reviewer"])
        return {"head": identity["head"], "review_id": review_id, "status": "already-approved"}
    except Refusal:
        pass
    diff = api(policy["api"], token_value, f"/repos/{repository}/pulls/{number}.diff", raw=True)
    if not isinstance(diff, str) or not diff or len(diff.encode()) > 200_000:
        raise Refusal("pull request diff is empty, unavailable, or oversized")
    output = run_reviewer(policy["reviewer_command"], {**identity, "ci_digest": ci_digest, "diff": diff})
    verdict = review_payload(output, identity, ci_digest)
    latest = pr_identity(repository, current_pull(policy["api"], token_value, repository, number))
    if latest != identity:
        raise Refusal("pull request changed during review")
    api(policy["api"], token_value, f"/repos/{repository}/pulls/{number}/reviews", method="POST",
        body={"body": render(verdict), "event": "APPROVED" if verdict["verdict"] == "pass" else "COMMENT"})
    return verdict


def approved_review(reviews, identity, ci_digest, author, reviewer):
    for item in reversed(reviews):
        user = (item.get("user") or {}).get("login")
        bound = parse_meta(item.get("body"))
        if user != reviewer or user == author or item.get("state", "").upper() != "APPROVED" or not bound:
            continue
        expected = {**identity, "ci_digest": ci_digest, "verdict": "pass"}
        if bound == expected:
            return item.get("id")
    raise Refusal("no independent exact-head approving review")


def verify_adapter(config):
    checkout = pathlib.Path(config["checkout"]).resolve()
    adapter = (checkout / config["adapter"]).resolve()
    if checkout not in adapter.parents or not adapter.is_file() or not os.access(adapter, os.X_OK):
        raise Refusal("deployment adapter is missing, outside checkout, or not executable")
    digest = hashlib.sha256(adapter.read_bytes()).hexdigest()
    if digest != config["adapter_sha256"]:
        raise Refusal("deployment adapter digest is not approved")
    return adapter


def deliver(policy, token_value, repository, number):
    config = repo_policy(policy, repository)
    if api(policy["api"], token_value, "/user").get("login") != config["merger"]:
        raise Refusal("merge token identity does not match policy")
    pull = current_pull(policy["api"], token_value, repository, number)
    identity = pr_identity(repository, pull)
    check_identity(identity, config)
    if (pull.get("user") or {}).get("login") == config["merger"]:
        raise Refusal("merger cannot merge its own pull request")
    statuses = pages(policy["api"], token_value, f"/repos/{repository}/commits/{identity['head']}/statuses")
    ci_digest = successful_checks(statuses, identity["head"], config["required_checks"])
    reviews = pages(policy["api"], token_value, f"/repos/{repository}/pulls/{number}/reviews")
    review_id = approved_review(reviews, identity, ci_digest, (pull.get("user") or {}).get("login"), config["reviewer"])
    adapter = verify_adapter(config)
    latest = pr_identity(repository, current_pull(policy["api"], token_value, repository, number))
    if latest != identity:
        raise Refusal("pull request changed before merge")
    result = api(policy["api"], token_value, f"/repos/{repository}/pulls/{number}/merge", method="POST",
                 body={"Do": "merge", "head_commit_id": identity["head"]})
    merged = result.get("sha") if isinstance(result, dict) else None
    if not merged:
        refreshed = current_pull(policy["api"], token_value, repository, number)
        merged = refreshed.get("merge_commit_sha") if refreshed.get("merged") else None
    if not merged:
        raise Refusal("Forgejo did not return an exact merged commit")
    evidence_dir = pathlib.Path(policy["evidence_dir"])
    evidence_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    receipt = evidence_dir / f"{repository.replace('/', '-')}-{number}-{merged}.json"
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "")}
    env.update({"DELIVERY_REPOSITORY": repository, "DELIVERY_PR": str(number), "DELIVERY_HEAD": identity["head"],
                "DELIVERY_MERGED_COMMIT": merged, "DELIVERY_REVIEW_ID": str(review_id),
                "DELIVERY_CI_DIGEST": ci_digest, "DELIVERY_RECEIPT": str(receipt)})
    try:
        subprocess.run([str(adapter)], cwd=config["checkout"], env=env, timeout=900, check=True)
    except (subprocess.SubprocessError, OSError) as error:
        raise Refusal("repository deployment adapter failed; its rollback contract must restore service") from error
    if not receipt.is_file():
        raise Refusal("deployment adapter did not write its required receipt")
    recorded = json.loads(receipt.read_text())
    if recorded.get("merged_commit") != merged or recorded.get("health") != "healthy" or not recorded.get("rollback_ready"):
        raise Refusal("deployment receipt does not prove exact commit, health, and rollback readiness")
    return {"merged_commit": merged, "receipt": str(receipt)}


def run_all(action, policy, token_value):
    results = []
    failures = []
    for repository in sorted(policy["repositories"]):
        pulls = pages(policy["api"], token_value, f"/repos/{repository}/pulls?state=open")
        for pull in pulls:
            number = pull.get("number")
            try:
                results.append({"repository": repository, "pull": number,
                                "result": action(policy, token_value, repository, number)})
            except (Refusal, OSError, ValueError, json.JSONDecodeError) as error:
                failures.append({"repository": repository, "pull": number, "error": str(error)})
    if failures:
        raise Refusal("one or more pulls refused: " + json.dumps(failures, sort_keys=True))
    return results


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("review", "deliver", "review-all", "deliver-all"))
    parser.add_argument("--policy", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--repository")
    parser.add_argument("--pull", type=int)
    args = parser.parse_args(argv)
    policy = load_policy(args.policy)
    token_value = token(args.token_file)
    action = review if args.mode.startswith("review") else deliver
    if args.mode.endswith("-all"):
        result = run_all(action, policy, token_value)
    else:
        if not args.repository or args.pull is None:
            parser.error("--repository and --pull are required for single-pull modes")
        result = action(policy, token_value, args.repository, args.pull)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"delivery refused: {error}", file=sys.stderr)
        raise SystemExit(2)
