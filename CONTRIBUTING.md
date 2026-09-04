# Contributing

Contributions should preserve the strict Protocol 2 contract and the supported
Delphi 13 Community Edition boundary. Open an issue before undertaking a large
behavioral change so its scope can be agreed upon.

## Development Setup

Python 3.9 or newer is required. Create an isolated environment and install the
development dependency from the repository root:

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -e ".[dev]"
```

On non-Windows systems, activate the environment with
`source .venv/bin/activate`. A Delphi installation is not required for the
Python contract tests. Building or manually validating the OTA package requires
Delphi 13 Community Edition.

## Validation

Run the checks relevant to CI before submitting a pull request:

```powershell
python -m pytest
python -m py_compile delphi_compile_gate.py tests/test_protocol_v2.py tests/test_reload_policy_contract.py tests/test_settings_contract.py tests/test_wrapper_isolation_contract.py
git diff --check
git status --short
```

Tests must not require a running IDE, alter tracked files, or depend on local
runtime queue contents. Add or update tests for behavior changes.

## Pull Requests

- Keep changes focused and explain the user-visible effect.
- Preserve fail-closed validation and exact protocol schemas unless the change
  explicitly revises the supported contract.
- Update `README.md`, `KNOWN_ISSUES.md`, and `CHANGELOG.md` when applicable.
- Do not commit generated Delphi binaries, Python caches, runtime queues, local
  IDE state, credentials, or private compile evidence.
- Complete the pull request template and identify checks that could not be run.

Report security-sensitive findings through the private process in
`SECURITY.md`, not through a pull request or public issue.
