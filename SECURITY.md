# Security

Resim parses untrusted image files and invokes bundled codec tools. Reports about
file corruption, unexpected writes, code execution, or exposure of image metadata are welcome.

## Reporting a vulnerability

Use **Security → Advisories → Report a vulnerability** in the official GitHub
repository to send a private report. If this option is unavailable, private
reporting is not enabled; do not disclose vulnerability details, exploit files,
or affected personal images in a public issue.

Maintainers must enable private vulnerability reporting and verify the reporting
form before announcing the public repository. See the
[publication checklist](docs/PUBLISHING.md#github-launch-checklist).

Include the affected version, macOS version and architecture, reproduction steps,
and expected versus observed behavior. Use a minimal synthetic image when possible.
Remove personal paths, metadata, credentials, and unrelated images from reports.

Resim is pre-1.0. Fixes target the current development version; older releases do
not have a separate security maintenance commitment.

## Privacy

Image processing runs locally without an account. Removing metadata does not
anonymize visible image content. Some formats or metadata combinations are rejected
when Resim cannot preserve the required image properties safely; see [README.md](README.md).
