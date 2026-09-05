# DelphiCompileGate Assistant Guide

Use this guide when an automated assistant must compile an existing Delphi
project through the local Delphi 13 IDE.

## Supported Contract

The current and only supported runtime is Delphi 13 Community Edition
(`CompilerVersion = 37.0`) using strict Protocol 2. Unversioned requests, legacy
queue formats, legacy result envelopes, and every other Delphi release are
unsupported. Such inputs and package builds must fail closed rather than fall
back.

`DelphiCompileGateClient.compile_project()` is the sole supported compile API
and the sole supported producer of queue jobs. Every produced job is an atomic
`Input\<job_id>.job.json` manifest with exact Protocol 2 fields,
`schema_version: 2`, and `kind: project_wrapper_build`.

The watcher processes only `*.job.json`. Do not place source files or any other
ad hoc payload in `Run\Input`, do not construct manifests manually, and do not
call any other client method as a compile entry point.

## Prerequisites

- Delphi 13 Community Edition is running.
- `Package\DelphiCompileGate.dpk` has been built and installed in Delphi 13.
- `Delphi Compile Gate Settings / Status...` reports Protocol `2`, plugin
  version `2.0.0`, and build ID `dcg-v2-20260905-searchpathfix-03`.
- The user selected **Start Watch** and then **OK** in Settings/Status. The
  watcher starts only after those actions; it does not start with the IDE.

## Paths

```text
Tool root:  %DELPHI_COMPILE_GATE_ROOT%
Client:     %DELPHI_COMPILE_GATE_ROOT%\delphi_compile_gate.py
Runtime:    %DELPHI_COMPILE_GATE_BASE_DIR%
Input:      %DELPHI_COMPILE_GATE_BASE_DIR%\Input
Output:     %DELPHI_COMPILE_GATE_BASE_DIR%\Output
Processed:  %DELPHI_COMPILE_GATE_BASE_DIR%\Processed
Failed:     %DELPHI_COMPILE_GATE_BASE_DIR%\Failed
Logs:       %DELPHI_COMPILE_GATE_BASE_DIR%\Logs
Wrappers:   %DELPHI_COMPILE_GATE_BASE_DIR%\Projects
```

Set `DELPHI_COMPILE_GATE_ROOT` to the checkout directory.
`DELPHI_COMPILE_GATE_BASE_DIR` is optional; both sides otherwise use
`%LOCALAPPDATA%\DelphiCompileGate\Run`, then
`%USERPROFILE%\AppData\Local\DelphiCompileGate\Run`, then the system temp
directory. Keep the runtime directory private to the local Windows account.

## Health Check

Use a real, small DPR or DPK fixture. The health check uses the same strict API
and queue contract as every other compile. First select **Start Watch** in
Settings/Status and select **OK**:

```powershell
$env:DELPHI_COMPILE_GATE_ROOT = 'C:\Path\To\DelphiCompileGate'
$env:HEALTH_CHECK_DPR = 'C:\Path\To\Fixtures\HealthCheck.dpr'
python -c "import os,sys,json,uuid; sys.path.insert(0,os.environ['DELPHI_COMPILE_GATE_ROOT']); from delphi_compile_gate import DelphiCompileGateClient; c=DelphiCompileGateClient(timeout=45); r=c.compile_project(source_path=os.environ['HEALTH_CHECK_DPR'],job_id='health_'+uuid.uuid4().hex[:24],platform='Win32',configuration='Debug'); print(json.dumps(r,ensure_ascii=False))"
```

A timeout usually means the watcher is stopped, the wrong package is loaded,
or a modal Delphi dialog is waiting for manual handling.

## Compile A Project

Use an absolute, canonical, regular, non-reparse-point `.dpr` or `.dpk` source
path. Supply `project_path` only when an existing canonical, regular,
non-reparse-point, same-directory, same-stem `.dproj` is required for
project-specific defines, packages, imports, search paths, or build settings.

```powershell
$env:PROJECT_ROOT = 'C:\Path\To\ExampleProject'
$env:EVIDENCE_DIR = 'C:\Path\To\BuildEvidence'
python -c "import os,sys,json,uuid; sys.path.insert(0,os.environ['DELPHI_COMPILE_GATE_ROOT']); from delphi_compile_gate import DelphiCompileGateClient; c=DelphiCompileGateClient(timeout=180); root=os.environ['PROJECT_ROOT']; evidence=os.environ['EVIDENCE_DIR']; r=c.compile_project(source_path=os.path.join(root,'ExampleProject.dpr'),project_path=os.path.join(root,'ExampleProject.dproj'),job_id='example_'+uuid.uuid4().hex,platform='Win32',configuration='Debug',raw_result_path=os.path.join(evidence,'example_debug.json')); print(json.dumps(r,ensure_ascii=False))"
```

Source-only build:

```python
from delphi_compile_gate import DelphiCompileGateClient

client = DelphiCompileGateClient(timeout=180)
result = client.compile_project(
    source_path=r"C:\Path\To\Application\Application.dpr",
    job_id="application_release_01",
    platform="Win64",
    configuration="Release",
    raw_result_path=r"C:\Path\To\BuildEvidence\application_release_01.json",
)
```

Allowed target pairs are exactly `Win32/Debug`, `Win32/Release`,
`Win64/Debug`, and `Win64/Release`. The default is `Win32/Debug`.

An explicit `job_id` must match `[a-z0-9][a-z0-9_-]{0,63}` and must be unique.
When omitted, the client generates one. Never reuse a job ID or raw evidence
path; the client refuses preexisting job state rather than overwriting it.

## Wrapper Behavior

For each request the Gate:

- authenticates the source and optional project file before compiling;
- creates a unique managed wrapper under `Run\Projects\<job_id>`;
- rewrites relative unit references and relevant search paths safely;
- generates a conventional managed `.dproj` when `project_path` is omitted;
- opens only the wrapper through hidden `IOTAModuleServices.OpenModule`;
- compiles the requested exact target through the IDE compiler;
- leaves the original project files unchanged;
- publishes an exact authenticated Protocol-2 result.

Source-only mode cannot reconstruct custom defines, runtime packages, build
events, or custom MSBuild imports. Pass the original `.dproj` when those are
required. A supplied `.dproj` is trusted input: imports, targets, and custom
build steps can execute commands under the Delphi process account. The Gate is
not a build sandbox.

A supplied `project_path` also carries its project-specific unit search path.
Resolve every relative `DCC_UnitSearchPath` segment against the original DPROJ
directory, preserve the inherited macro tail, and reject missing or reparse
directories. Verify the official `DCCStrs.sUnitSearchPath` value on the selected
active configuration before compile. If it is materialized while the derived
OTA `UnitSearchPath` is empty, compile the unique wrapper through
`IOTAProjectBuilder.BuildProject`; never guess or write an option key. Generated
wrapper property groups must precede the `CodeGear.Delphi.Targets` import.
Transitive units do not belong in the consumer DPR.

The local Windows account and runtime queue are the trust boundary. The Gate
accepts qualifying files from any workspace that account can read, and any
process able to write to `Run\Input` can request a compile. Do not place the
runtime queue in a shared or broadly writable directory.

## Queue Contract

The Python client atomically creates `<job_id>.job.json` only after validating
the paths, target, job ID, collisions, file evidence, nonce, and canonical
request hash. The exact manifest has these top-level fields:

```text
input, job_id, kind, nonce, protocol, request_hash, schema_version, target
```

Required fixed values are:

```text
kind = project_wrapper_build
protocol = 2
schema_version = 2
```

The watcher rejects extra, missing, malformed, mismatched, noncanonical, or
unsupported fields and quarantines the immutable job under `Run\Failed`.

## Result Contract

The raw plugin result has exactly these top-level fields:

```text
schema_version, protocol, job_id, nonce, request_hash, status, success,
failure_code, requested_target, effective_target, input, wrapper, artifact,
identity, compile, interventions, legal_notice
```

Check all of the following before treating a build as trusted:

- The call did not return `status: "client_failure"`.
- `success` is true and `failure_code` is null.
- `job_id`, `nonce`, `request_hash`, `requested_target`, and input evidence echo
  the request.
- `compile.succeeded`, `compile.target_matched`, and
  `compile.release_eligible` are true.
- Selected, compiler-reported, effective, and requested platform/configuration
  values all match exactly.
- Artifact and loaded-package path, size, and SHA-256 evidence are valid.
- `interventions.policy_compliant` is true and legal-notice evidence is
  consistent.

`compile.release_eligible` means the complete evidence is eligible. It can be
true for any allowed target and does not by itself mean the requested
configuration was `Release`.

Compiler diagnostics are under `compile.errors`. Each entry has exact fields
for file, line, column, code, text, warning, source, kind, canonical code,
canonical English message, raw text, and locale.

When `raw_result_path` is supplied, the client preserves the exact output bytes
before parsing. It then adds `_client_evidence` to the returned Python object;
that client metadata is not present in the preserved plugin JSON.

Client-side timeout, watcher quarantine, or result-validation failures return a
local `status: "client_failure"` envelope. Such a value is not authenticated
plugin evidence even though it carries Protocol-2 request identity where
available.

## IDE And Dialog Safety

Only Delphi 13 CE (`CompilerVersion = 37.0`) is supported. The package source
must reject every other compiler version at build time. Build the Win32
design-time package with Delphi 13 and never mix DCUs, DCPs, or BPLs from other
IDE versions.

The current worker starts before hidden `OpenModule`, deduplicates dialog HWNDs,
and only posts `BM_CLICK` after revalidating an exact policy-approved button. It
does not use keyboard input, focus, clipboard, default buttons, Escape, or
`WM_CLOSE`.

Known technical automation requires a narrow class/text/button fingerprint.
License or EULA terms are never accepted; only an exact reject action can be
used, and the result remains ineligible. Unknown dialogs may receive only an
exact cancel action. The assistant itself must not click or automate Delphi
licensing dialogs.

The Delphi 13 `TProgressForm` can represent active progress or a terminal build
summary. The Gate never clicks active-progress Cancel. It acknowledges a
terminal result only when exactly one visible enabled control remains and its
normalized text is exactly `OK`.

If a compile times out, inspect `Run\Logs\watch_YYYYMMDD.log` and ask the user
to resolve any visible modal dialog. Do not weaken the dialog policy.

## Settings

`Delphi Compile Gate Settings / Status...` controls the watcher. Settings are
stored atomically in:

```text
%APPDATA%\DelphiCompileGate\DelphiCompileGate.ini
```

The Settings UI lists poll interval, compile-timeout threshold, and experimental
close of completed hidden Protocol-v2 modules. The close experiment is
Delphi-13-only, off by default, and applies only to published successful or
exact `compile_failed` results. Runtime, dialog, evidence, and other non-compile
failures remain open.

## Operational Rules

- Use `DelphiCompileGateClient.compile_project()` for every compile.
- Never manually write or rename queue files as a normal workflow.
- Never put source payloads directly in `Run\Input`.
- Never modify or open the original project from automation.
- Treat `Run\Projects` as generated output.
- Preserve unique raw result bytes when evidence will be reviewed later.
- Treat every client failure or evidence mismatch as a failed build.
- Do not delete wrapper files while Delphi is using them.
- Rebuild and reinstall the Pascal package after source changes; checkout
  contents do not prove the identity of the loaded BPL.

## Large Fixture Acceptance Note

Live Win64 runs against a large external fixture selected and reported the
requested target correctly, but the fixture sources failed under `dcc64` with
`E2250`, `E2532`, and `F2063`. For those runs,
`compile.target_matched` was true while artifact evidence was null and
`compile.release_eligible` was false. Do not report a downstream fixture
failure as a Gate target-selection failure.

## GitHub Release Readiness

- Keep all assistant instructions strict Protocol-2-only and Delphi-13-only.
- Run the Python contract tests and verify the installed Delphi 13 BPL identity.
- Confirm examples contain only neutral paths or environment-variable inputs.
- Review every open safety issue before publishing binaries.
- License selection and publication remain pending; do not describe the
  repository as ready for public release until a license is present.
