# Release Checklist

Use this checklist for every public release. Complete it from a clean checkout
of the intended release commit.

## Scope and Metadata

- [ ] Confirm the release contains only intended changes.
- [ ] Confirm `pyproject.toml` requires Python 3.9 or newer and has no runtime
  dependencies.
- [ ] Synchronize the version in `pyproject.toml` and
  `Src/DelphiCompileGate.BuildInfo.pas`.
- [ ] Replace the relevant `Unreleased` entries in `CHANGELOG.md` with a dated
  version section.
- [ ] Review `README.md`, `INSTALLATION.md`, `KNOWN_ISSUES.md`, `SECURITY.md`, and installation
  instructions for accuracy.
- [ ] Confirm the documentation identifies the local Windows account and
  runtime queue as the trust boundary and warns that trusted `.dproj` build
  steps can execute commands.
- [x] Confirm the explicit MIT license decision is reflected in `LICENSE`,
  `pyproject.toml`, README, CI, and both distributions.

## Validation

- [ ] Run `python -m pytest` on a supported Python version.
- [ ] Run `python -m py_compile delphi_compile_gate.py tests/test_*.py` in a
  shell that expands file globs, or list each test module explicitly.
- [ ] Run `python -m build`, then run
  `python .github/scripts/verify_distributions.py` to inspect both artifacts,
  extract the source archive into a clean temporary directory, install it in a
  clean virtual environment, and run its bundled tests.
- [ ] Confirm the source archive contains the Python client, `Src`, `Package`,
  `examples`, tests and fixtures, documentation, and release metadata; confirm
  it excludes runtime/build output, caches, binaries, and secrets, and includes
  the MIT license.
- [ ] Confirm the wheel contains only `delphi_compile_gate.py` and wheel
  metadata, with no Pascal sources, examples, tests, or repository documents.
- [ ] Run `git diff --check` and confirm `git status --short` is clean.
- [ ] Confirm CI passes on Python 3.9, 3.10, and 3.11.
- [ ] Build and install the OTA package with Delphi 13 Community Edition.
- [ ] Confirm the loaded plugin reports the expected protocol, plugin version,
  compiler identity, and package build ID.
- [ ] Exercise a successful compile and an expected compile failure without
  reusing queue identifiers or evidence paths.
- [ ] Exercise a canonical project path outside the Gate checkout and confirm
  noncanonical or reparse-point input paths are rejected.
- [x] Complete 1,000 alternating success/`compile_failed` jobs with stable
  compile latency and no unexpected result.
- [x] Accept and document the measured DelphiLSP growth to approximately
  1.08 GB per active process after 1,000 jobs as a release limitation.

## Publication

- [ ] Review the final commit and generated release notes.
- [ ] Create the release tag from the reviewed commit.
- [ ] Publish the GitHub release with the matching changelog section.
- [ ] Attach only intentionally distributed artifacts and verify their hashes.
- [ ] Recheck installation instructions from the published release.
