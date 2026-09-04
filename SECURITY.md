# Security Policy

## Supported Versions

Security fixes are considered for the current Protocol 2 release line.

| Version | Supported |
| ------- | --------- |
| 2.x     | Yes       |
| < 2.0   | No        |

## Reporting a Vulnerability

Do not disclose suspected vulnerabilities in a public issue, discussion, pull
request, log, or test fixture.

Use GitHub's private vulnerability reporting feature from the repository's
**Security** tab when it is available. If private reporting is unavailable,
contact a maintainer privately through the contact information on their GitHub
profile. Include only the information needed to reproduce and assess the issue:

- A description of the impact and affected component.
- Reproduction steps or a minimal proof of concept.
- The Delphi, plugin, and Python versions involved.
- Relevant configuration with credentials, source code, and personal data
  removed.
- Any known mitigations or workarounds.

Maintainers will acknowledge reports on a best-effort basis, assess severity,
and coordinate disclosure after a fix or mitigation is available. Please allow
reasonable time for investigation before publishing details.

## Scope

The trust boundary is the local Windows account and the runtime queue. The Gate
accepts qualifying source and project files from any workspace readable by that
account. Any process that can write a manifest to the runtime `Input` directory
can request an IDE compile with the account's permissions, so the runtime base
must not be shared or broadly writable.

Project files are trusted executable build configuration. A supplied `.dproj`
can import targets or run custom build steps under the Delphi process account;
DelphiCompileGate does not sandbox those actions.

Relevant reports include request or result authentication bypasses, unsafe file
operations, queue manipulation, path traversal, unintended source disclosure,
and execution outside the documented compile boundary. General support requests
and non-security defects belong in the appropriate public issue template.
