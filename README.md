# DelphiCompileGate

DelphiCompileGate is an Open Tools API (OTA) plugin for Delphi 13 Community
Edition. It compiles Delphi projects with the compiler hosted inside the IDE.
The current and only supported contract is Protocol 2.

## Supported Contract

- `DelphiCompileGateClient.compile_project()` is the only supported compile API
  and the only supported producer of queue jobs.
- The Python client atomically publishes only
  `Input\<job_id>.job.json` manifests with `protocol: 2`, `schema_version: 2`,
  and `kind: project_wrapper_build`.
- The watcher processes only `*.job.json`. Other files in `Input` are not jobs.
- Callers provide an absolute `.dpr` or `.dpk` file and may provide the
  same-directory, same-stem `.dproj` file.
- Requests and results are validated against exact schemas, hashes, paths,
  identities, and target evidence. Missing or contradictory evidence fails
  closed.

Legacy client methods, source-file queue payloads, multi-unit queue formats,
and earlier result envelopes are not supported. Do not use historical behavior
as current operational guidance.

## Repository Layout

```text
DelphiCompileGate/
|-- Package/
|   |-- DelphiCompileGate.dpk
|   `-- DelphiCompileGate.dproj
|-- Src/
|   |-- DelphiCompileGate.BuildInfo.pas
|   |-- DelphiCompileGate.Compiler.pas
|   |-- DelphiCompileGate.Consts.pas
|   |-- DelphiCompileGate.MessageHook.pas
|   |-- DelphiCompileGate.ProtocolV2.pas
|   |-- DelphiCompileGate.Register.pas
|   |-- DelphiCompileGate.Settings.pas
|   |-- DelphiCompileGate.SettingsDialog.pas
|   |-- DelphiCompileGate.Watch.pas
|   `-- DelphiCompileGate.Wizard.pas
|-- delphi_compile_gate.py
|-- AGENTS.md
|-- ASSISTANT_GUIDE.md
|-- KNOWN_ISSUES.md
`-- README.md
```

## Installation

For complete prerequisites, package build, verification, update, uninstall, and
troubleshooting instructions, see [`INSTALLATION.md`](INSTALLATION.md).

1. Start Delphi 13 Community Edition.
2. Open `Package\DelphiCompileGate.dpk` in the IDE.
3. Compile the package with `Ctrl+F9`.
4. Select **Install** in the package editor.
5. Open **Help > Help Wizards > Delphi Compile Gate Settings / Status...**.
   In a German IDE, use
   **Hilfe > Hilfe-Experten > Delphi Compile Gate Settings / Status...**.
6. Select **Start Watch**, then select **OK**. The watcher starts only after
   this user action and a successful **OK** save; it does not start with the IDE.

After changing any Pascal source, rebuild and reinstall the package in the IDE.
Changing the checkout does not update the loaded BPL. The loaded instance must
report plugin version `2.0.0`, Protocol `2`, and build ID
`dcg-v2-20260904-releaseprep-02`.

## Prompt for AI Coding Assistants

Paste the following prompt into an AI coding assistant before asking it to
create or modify Delphi code in a workspace:

```text
Read AGENTS.md in the DelphiCompileGate repository before editing or compiling
Delphi code. Follow it as the authoritative compile contract.

Use only DelphiCompileGateClient.compile_project(). Never invoke dcc32, MSBuild,
or another external Delphi compiler, and never create queue manifests manually.

Find the workspace's existing .dpr or .dpk. If a same-directory, same-stem
.dproj already exists, pass both files to compile_project(). If no matching
.dproj exists, pass only the .dpr or .dpk; DelphiCompileGate creates its managed
temporary .dproj automatically. Never create, guess, or edit a .dproj merely to
use DelphiCompileGate.

Compile after making changes. Use only platform Win32 or Win64 and configuration
Debug or Release. Accept success only when status is "ok", success is true,
compile.target_matched is true, compile.release_eligible is true, and
interventions.policy_compliant is true. Otherwise report the exact failure_code
and compiler diagnostics.

Delphi 13 Community Edition must already be running with the current
DelphiCompileGate package installed. The watcher must show Running, and the
Settings / Status dialog must be closed while waiting for a result. If those
conditions are not met, report the prerequisite instead of using another
compiler.
```

The prompt is intentionally self-contained so a weak assistant cannot infer an
obsolete API or invent a project file. `AGENTS.md` contains the complete rules
and copy-ready Python examples.

## Runtime Directories

By default, both the plugin and client use
`%LOCALAPPDATA%\DelphiCompileGate\Run`. If `LOCALAPPDATA` is unavailable, they
use `%USERPROFILE%\AppData\Local\DelphiCompileGate\Run`, then the system temp
directory. To use another shared runtime base, set this variable before
starting Delphi and the client:

```text
DELPHI_COMPILE_GATE_BASE_DIR=C:\Path\To\DelphiCompileGate\Run
```

```text
Run\
|-- Input\       strict Protocol-2 manifests: <job_id>.job.json
|-- Output\      authenticated plugin results: <job_id>.json
|-- Processed\   successfully consumed manifests
|-- Failed\      rejected manifests and *.error.txt
|-- Logs\        watcher logs
`-- Projects\    generated wrapper projects and artifacts
```

The watcher accepts only files with the exact `.job.json` suffix. It moves
manifests with invalid schemas, mismatched identities, or unverifiable evidence
to `Failed`. Do not create or rename queue manifests manually;
`compile_project()` is the sole supported producer.

## Settings And Status

Settings are stored atomically at:

```text
%APPDATA%\DelphiCompileGate\DelphiCompileGate.ini
```

Only these runtime values are editable:

- Watch interval: 250 to 60000 ms
- Compile-timeout threshold: 60000 to 600000 ms
- Experimental close of completed hidden Protocol-2 modules

Settings edits and a pending watcher start take effect only after **OK** saves
the settings successfully. **Cancel** discards unsaved edits and a pending
start. Stopping an active watcher takes effect immediately as a graceful drain;
holding Shift requests the hard-stop path. Queue processing is deferred while
the Settings/Status dialog is open and resumes after it closes.

Crossing the timeout threshold marks the job as failed. The Gate still waits
fail-closed until the IDE compiler is actually inactive before removing its
evidence monitors.

The hidden-module close option is off by default, Delphi-13-only, and
experimental rather than release-accepted. It is authorized only after an
authenticated, policy-compliant result has been published successfully or has
the exact `compile_failed` failure code. Runtime, dialog, evidence,
malformed-request, timeout, target, artifact, identity, and other failures do
not authorize a close.

For an authorized result, the watcher retains only the canonical path of the
wrapper module that was loaded through hidden `OpenModule` and never shown. It
reacquires that exact module after four quiet timer turns, calls
`IOTAModule.CloseModule(True)` once, and verifies absence during the settle
phase. It never uses `RemoveProject`, `CloseFile`, saving, or retries. A close
or absence-verification failure disables the experiment for the current IDE
session.

A 1,000-job acceptance run kept compile latency stable and closed every hidden
module, but two DelphiLSP processes still grew to approximately 1.08 GB each.
The IDE language-server cache is not released by `IOTAModule.CloseModule`.
This is an accepted release limitation; indefinite unattended sessions are not
a supported claim, and users should monitor IDE/LSP memory during large runs.

## Python API

Before calling the API for the first time, select **Start Watch** in
`Delphi Compile Gate Settings / Status...`, then select **OK**.

```python
from delphi_compile_gate import DelphiCompileGateClient

client = DelphiCompileGateClient(timeout=180)

result = client.compile_project(
    source_path=r"C:\Path\To\Example\Example.dpr",
    project_path=r"C:\Path\To\Example\Example.dproj",
    job_id="example_debug_01",
    platform="Win32",
    configuration="Debug",
    raw_result_path=r"C:\Path\To\BuildEvidence\example_debug_01.json",
)

if not result["success"]:
    raise RuntimeError(result.get("failure_code", "compile failed"))
```

`source_path` must identify an absolute, canonical, regular, non-reparse-point
`.dpr` or `.dpk` file.
`project_path` is optional. When supplied, it must identify an absolute,
canonical, regular, non-reparse-point `.dproj` with the same directory and file
stem as `source_path`. When it is omitted, the Gate creates a managed minimal
`.dproj`.

The client securely generates an empty `job_id`. Explicit IDs must match
`[a-z0-9][a-z0-9_-]{0,63}` and be unique for every run. The client refuses to
overwrite preexisting job, result, quarantine, processed, wrapper, or raw
evidence paths.

The allowed targets are exactly:

- `Win32` / `Debug`
- `Win32` / `Release`
- `Win64` / `Debug`
- `Win64` / `Release`

The default is `Win32` / `Debug`.

When `raw_result_path` is supplied, the client atomically preserves the exact
result bytes before parsing JSON or cleaning queue state. The returned Python
object adds the preserved path, size, and SHA-256 under `_client_evidence`.
This client metadata is not part of the preserved plugin JSON.

## Protocol-2 Manifest

Callers use the Python API and do not write this format themselves. The client
produces canonical UTF-8 JSON with exactly these top-level fields:

```json
{
  "input": {
    "main_source": {"path": "<absolute .dpr/.dpk>", "size": 123, "sha256": "<64 lowercase hex>"},
    "project": {"path": null, "size": null, "sha256": null}
  },
  "job_id": "example_01",
  "kind": "project_wrapper_build",
  "nonce": "<32 lowercase hex>",
  "protocol": 2,
  "request_hash": "<64 lowercase hex>",
  "schema_version": 2,
  "target": {"configuration": "Debug", "platform": "Win32"}
}
```

When a `.dproj` is supplied, `input.project` contains its absolute path, size,
and hash evidence. The request hash binds the canonical manifest bytes with the
hash field set to zeroes.

## Wrapper Build

The Gate never opens the original project. It creates one unique managed
wrapper per job under:

```text
<runtime-base>\Projects\<job_id>\
```

The wrapper reads the original `.dpr` or `.dpk`, rewrites relative `in '...'`
unit paths to absolute paths, and preserves relevant project options from a
supplied `.dproj`. Without a `.dproj`, it creates conventional Win32/Win64 and
Debug/Release settings. The original directory is not modified.

Source-only mode cannot reconstruct project-specific defines, runtime
packages, build events, or custom MSBuild imports. Projects that require these
must provide `project_path`. Source-only `.dpr` supports `program`; `.dpk` is
generated as a package project.

The Gate accepts qualifying source and project files from any workspace the
local Windows account can read. The local account and the runtime queue are the
trust boundary: any process that can write to `Input` can request an IDE compile
with that account's access. Keep the runtime directory private to the account
and do not expose it through a shared or broadly writable location.

A supplied `.dproj` is trusted input. Its imports, targets, and custom build
steps can execute commands under the Delphi process account; the Gate is not a
build sandbox. Use `project_path` only for projects whose build configuration
you trust.

## Result Contract

The raw plugin result is an exact Protocol-2 object. The client rejects unknown
or missing fields. Its top-level fields are:

```text
schema_version, protocol, job_id, nonce, request_hash, status, success,
failure_code, requested_target, effective_target, input, wrapper, artifact,
identity, compile, interventions, legal_notice
```

Important interpretation rules:

- `success` is true only with `status: "ok"` and `failure_code: null`.
- `compile.errors` contains structured diagnostics for the current job.
- `compile.target_matched` requires exact agreement among requested, selected,
  compiler-reported, and effective targets.
- `compile.release_eligible` is true only with complete compile, artifact,
  identity, file, and intervention evidence. It does not mean that the selected
  configuration was necessarily `Release`.
- `artifact` contains the path, size, and SHA-256 of the generated `.exe` or
  `.bpl`; these values are nullable on failure.
- `identity` binds the protocol, plugin version, package build, loaded BPL, and
  Delphi 13 compiler identity.
- `interventions` records dialog and policy activity. A policy-approved known
  technical dialog can make `intervention_free` false while leaving
  `policy_compliant` true.
- `legal_notice` always records consistent Community Edition notice evidence,
  including whether it was detected and whether it was acknowledged or left
  open. It always reports `accepted_terms: false`.

A client timeout, quarantined job, or invalid result returns a local
`status: "client_failure"` value with `success: false`. This is not an
authenticated plugin result and must not be treated as build evidence.

## Dialog And Diagnostic Policy

Protocol 2 starts a narrowly scoped policy worker before the hidden
`OpenModule`. It uses no keyboard input, focus, clipboard, default button,
Escape, or `WM_CLOSE`. It posts `BM_CLICK` only after revalidating an exact,
visible, enabled, policy-approved descendant button.

Dialog text and button fingerprints support both English and German Delphi
localizations. Known technical dialogs require a narrow class, text, and button
fingerprint. License or EULA terms are never accepted; only an exact localized
reject action is permitted, and the result remains ineligible. Unknown dialogs
may receive only an exact localized cancel action. Otherwise the dialog is left
untouched and the job remains blocked or ineligible.

Delphi 13 uses `TProgressForm` for both active progress and some terminal build
summaries. The Gate never activates the active-progress Cancel button. It
acknowledges a terminal form only when exactly one visible, enabled actionable
button remains and its normalized text is exactly `OK`.

Delphi 13 Community Edition can display an informational
`TCENotificationDialog` during a build. The Gate acknowledges it only when it
is a same-process modal dialog with exactly one visible, enabled `OK` action
and no acceptance, agreement, or continue control. The result records
`classification: "community_edition_usage_notice"`, the window class, optional
native title, available button, action, and `accepted_terms: false`. If the
non-windowed VCL body cannot be observed through Win32 text APIs,
`text_available` is false and text/hash evidence is null. A safely acknowledged
informational notice can remain policy-compliant and release-eligible; it is
never represented as acceptance of license terms.

Compiler diagnostics are captured only during the active Gate compile and are
limited to the authenticated wrapper or source scope. Message-service hooks are
restored during job cleanup.

## Delphi 13 Compatibility

The package supports only Delphi 13 Community Edition
(`CompilerVersion = 37.0`). Every other compiler version fails at package build
time. The diagnostic-capture VMT layout is verified only against the Delphi 13
`ToolsAPI.pas`. Do not mix DCUs, DCPs, or BPLs from other IDE versions.

## Queue Behavior

- The watcher processes an existing `*.job.json` queue when it starts.
- At most one job starts per timer cycle.
- An existing same-name result is never silently overwritten. The client
  rejects colliding state before creating a job.
- Invalid or unprocessable manifests move to `Failed` so they cannot
  permanently block the queue.
- The queue is deferred while the Settings/Status dialog is open.

## Troubleshooting

**The plugin does not process a job**

Inspect `Run\Logs\watch_YYYYMMDD.log`. Confirm that Delphi 13 is running, the
current package is installed, the watcher is active, and the filename ends
exactly in `.job.json`.

**The Python client reports a timeout**

Inspect the Settings/Status dialog and visible Delphi dialogs. A modal dialog
that cannot be classified safely under the legal or technical policy is
deliberately not acknowledged.

**Compilation fails even though the source appears valid**

Inspect `compile.errors`, `failure_code`, target evidence, and the watcher log.
Provide the original `.dproj` through `project_path` when the project depends on
project-specific defines, packages, imports, search paths, or build steps.

## Architecture

```text
[compile_project]
       |
       v
[Input/<job_id>.job.json, Protocol 2]
       |
       v
[OTA watcher -> managed wrapper -> Delphi 13 IDE compiler]
       |
       v
[Output/<job_id>.json, authenticated Protocol-2 evidence]
```

## GitHub Release Readiness

- Public documentation describes only strict Protocol 2 and Delphi 13 Community
  Edition.
- Examples use neutral paths and environment variables; no machine-specific or
  downstream-project paths are required.
- A release must pass the Python contract tests and a Delphi 13 package build.
- Published artifacts must identify plugin version `2.0.0`, Protocol `2`, and
  build ID `dcg-v2-20260904-releaseprep-02`.
- Security and dialog-policy limitations in `KNOWN_ISSUES.md` must be reviewed
  before publishing.
- The project is distributed under the MIT License.

## License

DelphiCompileGate is distributed under the [MIT License](LICENSE). The plugin
does not modify Embarcadero binaries. Users remain responsible for the terms
that apply to their Delphi Community Edition installation and projects.
