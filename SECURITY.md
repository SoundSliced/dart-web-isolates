# Security Policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Report it privately via
GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on `SoundSliced/dart-web-isolates`, or by email to the maintainers listed in
`pubspec.yaml` once packages are published.

Include the affected package and version, a description of the impact, and a
minimal reproduction. You can expect an acknowledgement within seven days.

## Scope

DWI executes Dart code in browser workers. The following are in scope:

- Worker bootstrap and module-loading paths (CSP `worker-src`/`script-src`
  interaction, `Blob` worker construction, cross-origin hosting).
- Message-envelope validation and dispatch: untrusted message content must never
  be turned into an arbitrary operation selection or code execution.
- Lifecycle and resource-exhaustion issues: worker leaks, unbounded task queues,
  denial of service through oversized payloads.
- Generated worker entrypoints and any code generation that could be influenced
  by input data.

## Supported versions

Until `1.0.0`, only the latest published minor version of each package receives
security fixes.
