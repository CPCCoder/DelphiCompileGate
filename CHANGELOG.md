# Changelog

All notable changes to this project are documented in this file.

The format follows the principles of Keep a Changelog, and release versions use
semantic versioning.

## [Unreleased]

No changes yet.

## [2.0.0] - 2026-09-04

### Added

- MIT licensing for source and Python distributions.
- A strict Protocol 2 Python client for authenticated project and package build
  requests.
- Delphi 13 Community Edition OTA integration with validated compile evidence.
- Contract tests for protocol, settings, reload policy, and wrapper isolation.

### Changed

- Removed legacy protocols and unsupported queue formats from the public
  contract.
- Restricted supported build targets to Win32 and Win64 Debug or Release
  configurations.
- Accepts canonical project inputs from any workspace readable by the local
  Windows account; the private runtime queue remains the request trust boundary.
