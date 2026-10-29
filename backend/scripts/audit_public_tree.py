"""Audit Git candidates without printing secret values. Run before staging/committing."""

import re
import subprocess
from pathlib import Path

from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[2]


def main():
    paths = set()
    for args in [["--cached"], ["--others", "--exclude-standard"]]:
        raw = subprocess.check_output(["git", "ls-files", "-z", *args], cwd=ROOT)
        paths.update(p for p in raw.decode().split("\0") if p)
    secrets = {}
    for name in ["backend/.env", "frontend/.env", "frontend/.env.json"]:
        path = ROOT / name
        if not path.exists():
            continue
        if path.suffix == ".json" or name.startswith("frontend/"):
            import json

            values = json.loads(path.read_text(encoding="utf-8"))
        else:
            values = dotenv_values(path)
        for key, value in values.items():
            if (
                value
                and re.search("KEY|PASSWORD|SECRET|TOKEN|LIVE_TEST_EMAIL", key)
                and len(str(value)) >= 8
            ):
                secrets[key] = str(value).encode()
    problems = []
    if subprocess.run(["git", "diff", "--quiet"], cwd=ROOT, check=False).returncode:
        problems.append(("Git index", "staged files differ from working files; restage and rerun"))
    total = 0
    for name in sorted(paths):
        path = ROOT / name
        if not path.is_file():
            continue
        data = path.read_bytes()
        total += len(data)
        parts = path.relative_to(ROOT).parts
        if any(
            p in {".venv", "evidence", ".local-postgres", "__pycache__", ".dart_tool", "build"}
            for p in parts
        ):
            problems.append((name, "local/runtime directory"))
        if path.name.startswith(".env") and not path.name.endswith(".example"):
            problems.append((name, "real environment file"))
        if len(data) > 10_000_000:
            problems.append((name, "file exceeds 10 MB"))
        for key, value in secrets.items():
            if value in data:
                problems.append((name, "matches local " + key))
        if re.search(
            rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}",
            data,
        ):
            problems.append((name, "credential signature"))
        if re.search(
            rb"eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}"
            rb"|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}"
            rb"|[?&](?:token|Signature|X-Amz-Signature)=[A-Za-z0-9%._-]{24,}",
            data,
        ):
            problems.append((name, "token or signed-URL signature"))
    print(f"Audited {len(paths)} Git candidates ({total / 1024 / 1024:.2f} MB).")
    for name, reason in problems:
        print(f"FAIL: {name}: {reason}")
    if problems:
        raise SystemExit(1)
    print(
        "PASS: no matching local credentials, environment files, runtime data or oversized files."
    )
    print("This is a bounded automated check, not a guarantee against every possible secret.")


if __name__ == "__main__":
    main()
