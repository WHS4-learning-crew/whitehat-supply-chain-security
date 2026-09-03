#!/usr/bin/env python3
"""CycloneDX SBOM diff and npm package risk gate."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from difflib import SequenceMatcher
from pathlib import Path


POPULAR_PACKAGES = {
    "axios", "chalk", "commander", "debug", "dotenv", "express", "lodash",
    "moment", "next", "react", "react-dom", "typescript", "vite", "webpack",
}


def load_components(path: Path) -> dict[tuple[str, str], dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return {
        (item["name"], item["version"]): item
        for item in data.get("components", [])
        if item.get("name") and item.get("version") and item.get("type") != "application"
    }


def load_lock_packages(path: Path) -> set[tuple[str, str]]:
    if not path.exists():
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    result = set()
    for location, meta in data.get("packages", {}).items():
        if not location or not meta.get("version"):
            continue
        name = meta.get("name")
        if not name and "node_modules/" in location:
            name = location.rsplit("node_modules/", 1)[-1]
        if name:
            result.add((name, str(meta["version"])))
    return result


def load_project_identity(path: Path) -> tuple[str, str] | None:
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    root = data.get("packages", {}).get("", {})
    if root.get("name") and root.get("version"):
        return root["name"], str(root["version"])
    return None


def get_json(url: str, retries: int = 5) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "whitehat-sbom-gate/1.0"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            if exc.code != 429 or attempt == retries - 1:
                raise
            retry_after = exc.headers.get("Retry-After")
            server_delay = int(retry_after) if retry_after and retry_after.isdigit() else 0
            delay = max(server_delay, 2 ** (attempt + 1))
            print(f"npm rate limit reached; retrying in {delay}s", file=sys.stderr)
            time.sleep(delay)
    raise RuntimeError("unreachable")


def npm_metadata(name: str, version: str) -> dict:
    encoded = urllib.parse.quote(name, safe="")
    registry = get_json(f"https://registry.npmjs.org/{encoded}")
    version_data = registry.get("versions", {}).get(version, {})
    version_data["published"] = registry.get("time", {}).get(version)
    return version_data


def weekly_downloads(packages: list[tuple[str, str]]) -> dict[str, int | None]:
    result: dict[str, int | None] = {}
    names = sorted({name for name, _ in packages})
    for start in range(0, len(names), 50):
        batch = names[start:start + 50]
        encoded = ",".join(urllib.parse.quote(name, safe="") for name in batch)
        data = get_json(f"https://api.npmjs.org/downloads/point/last-week/{encoded}")
        if len(batch) == 1 and "downloads" in data:
            result[batch[0]] = data.get("downloads")
        else:
            for name in batch:
                item = data.get(name) or {}
                result[name] = item.get("downloads")
    return result


def published_within_30_days(value: str | None) -> bool:
    if not value:
        return True
    published = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return (dt.datetime.now(dt.timezone.utc) - published).days < 30


def looks_like_typosquat(name: str) -> tuple[bool, str | None]:
    candidate = name.split("/")[-1]
    for trusted in POPULAR_PACKAGES:
        ratio = SequenceMatcher(None, candidate, trusted).ratio()
        if candidate != trusted and ratio >= 0.86:
            return True, trusted
    return False, None


def calculate_score(name: str, metadata: dict, downloads: int | None) -> tuple[int, list[str]]:
    score, reasons = 0, []
    scripts = metadata.get("scripts") or {}
    if any(key in scripts for key in ("preinstall", "install", "postinstall")):
        score += 40
        reasons.append("install script +40")
    if published_within_30_days(metadata.get("published")):
        score += 25
        reasons.append("published within 30 days/unknown +25")
    typo, target = looks_like_typosquat(name)
    if typo:
        score += 20
        reasons.append(f"name resembles {target} +20")
    if downloads is None or downloads < 1000:
        score += 10
        reasons.append("weekly downloads below 1000/unknown +10")
    dist = metadata.get("dist") or {}
    if not (metadata.get("provenance") or dist.get("attestations")):
        score += 5
        reasons.append("provenance absent +5")
    return score, reasons


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--baseline-lock", type=Path, required=True)
    parser.add_argument("--current-lock", type=Path, required=True)
    parser.add_argument("--threshold", type=int, default=60)
    parser.add_argument("--report", type=Path, default=Path("sbom-risk-report.json"))
    args = parser.parse_args()

    baseline = load_components(args.baseline)
    current = load_components(args.current)
    project_identity = load_project_identity(args.current_lock)
    new_packages = sorted(
        package for package in set(current) - set(baseline)
        if package != project_identity
    )
    added_to_lock = load_lock_packages(args.current_lock) - load_lock_packages(args.baseline_lock)
    findings, failed = [], False

    try:
        download_counts = weekly_downloads(new_packages)
    except (urllib.error.URLError, TimeoutError, ValueError, json.JSONDecodeError) as exc:
        print(f"weekly download lookup failed; treating counts as unknown: {exc}", file=sys.stderr)
        download_counts = {}

    for name, version in new_packages:
        finding = {"name": name, "version": version}
        if (name, version) not in added_to_lock:
            finding.update(result="FAIL", reason="new SBOM package is not matched by lockfile change")
            failed = True
        else:
            try:
                metadata = npm_metadata(name, version)
                downloads = download_counts.get(name)
                time.sleep(0.25)
                risk, reasons = calculate_score(name, metadata, downloads)
                finding.update(score=risk, reasons=reasons, weekly_downloads=downloads)
                finding["result"] = "FAIL" if risk >= args.threshold else "PASS"
                failed |= risk >= args.threshold
            except (urllib.error.URLError, TimeoutError, ValueError, json.JSONDecodeError) as exc:
                finding.update(result="FAIL", reason=f"npm metadata lookup failed: {exc}")
                failed = True
        findings.append(finding)

    report = {
        "baseline_packages": len(baseline),
        "current_packages": len(current),
        "new_packages": len(new_packages),
        "threshold": args.threshold,
        "result": "FAIL" if failed else "PASS",
        "findings": findings,
    }
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
