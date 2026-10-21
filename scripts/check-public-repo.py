#!/usr/bin/env python3
"""Check files eligible for Git publication without printing sensitive values.

Uses only Python's standard library and Git. This is a conservative local check,
not a substitute for reviewing the diff or for a dedicated secret scanner.
"""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

# Include tracked files even when .gitignore would now exclude them.
result = subprocess.run(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
)
if result.returncode:
    sys.exit("Cannot inspect publication files. Run this check inside the Git repository.")
files = sorted(set(pathlib.Path(p.decode("utf-8")) for p in result.stdout.split(b"\0") if p))

private_roots = {".build", ".build-tools", "dist", "vendor", "private", "local", "notas-de-avance"}
private_suffixes = {".p12", ".pfx", ".pem", ".key", ".cer", ".certSigningRequest", ".mobileprovision", ".provisionprofile", ".xcuserstate", ".pyc"}
patterns = {
    "private key": rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----",
    "GitHub token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b",
    "GitLab token": rb"\bglpat-[A-Za-z0-9_-]{20,}\b",
    "AWS access key": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "Slack token": rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b",
    "service secret key": rb"\b(?:sk_live_|rk_live_|sk-proj-|sk-ant-)[A-Za-z0-9_-]{20,}\b",
    "credential in URL": rb"https?://[^\s/:@]+:[^\s/@]+@",
    "personal macOS path": rb"/Users/(?!Shared/)[A-Za-z0-9_. -]+/",
    "personal Linux path": rb"/home/[A-Za-z0-9_.-]+/",
    "personal Windows path": rb"[A-Za-z]:\\Users\\[A-Za-z0-9_. -]+\\",
    "embedded Apple signing team": rb"(?:TeamIdentifier=|DEVELOPMENT_TEAM\s*=\s*\"?)[A-Z0-9]{10}\b",
    "literal credential": rb"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\b\s*[:=]\s*[\"'][A-Za-z0-9_+/=-]{24,}[\"']",
}
compiled = {name: re.compile(pattern) for name, pattern in patterns.items()}
findings = []
for relative in files:
    path = ROOT / relative
    if not path.exists() and not path.is_symlink():
        continue
    parts = relative.parts
    private = (
        parts[0] in private_roots
        or ".git" in parts or "xcuserdata" in parts or "__pycache__" in parts
        or relative.suffix in private_suffixes
        or relative.name == ".DS_Store"
        or (relative.name.startswith(".env") and relative.name != ".env.example")
        or (len(parts) == 1 and relative.match("PLAN*.md"))
        or parts[:3] == ("Resim", "Resources", "Codecs")
        or (parts[0] == "docs" and (relative.suffix == ".json" or "screenshots" in parts))
    )
    if private:
        findings.append((relative, "", "private or generated file is eligible for publication"))
    if path.is_symlink():
        if not path.resolve().is_relative_to(ROOT):
            findings.append((relative, "", "symlink points outside the repository"))
        continue
    if not path.is_file():
        continue
    if path.stat().st_size > 10 * 1024 * 1024:
        findings.append((relative, "", "file larger than 10 MiB requires manual review"))
        continue
    data = path.read_bytes()
    if data[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\x7fELF"):
        findings.append((relative, "", "compiled executable should be rebuilt from source"))
    for label, pattern in compiled.items():
        match = pattern.search(data)
        if match:
            line = f":{data[:match.start()].count(bytes([10])) + 1}" if b"\0" not in data else ""
            findings.append((relative, line, label))

if findings:
    for path, line, label in findings:
        print(f"{path}{line}: {label}")
    sys.exit(f"Publication check failed: {len(findings)} finding(s). Values were not printed.")
print(f"Publication check passed: {len(files)} eligible files; no configured patterns found.")
