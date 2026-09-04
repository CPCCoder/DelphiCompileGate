# Agent Instructions

Use DelphiCompileGate to compile Delphi projects with the compiler hosted in a
running Delphi 13 Community Edition IDE.

## Simple Decision Rule

Follow these steps exactly:

1. Find the project's existing `.dpr` or `.dpk` file.
2. Check whether a same-directory, same-stem `.dproj` already exists.
3. If the `.dproj` exists, pass both files to `compile_project()`.
4. If no `.dproj` exists, pass only the `.dpr` or `.dpk`. DelphiCompileGate
   creates a managed temporary `.dproj` automatically.
5. Never create, guess, or edit a `.dproj` merely to use DelphiCompileGate.

Use this pattern:

```python
from pathlib import Path

from delphi_compile_gate import DelphiCompileGateClient

source = Path(r"C:\Projects\Example\Example.dpr").resolve()
project = source.with_suffix(".dproj")

arguments = {
    "source_path": str(source),
    "platform": "Win32",
    "configuration": "Debug",
}
if project.is_file():
    arguments["project_path"] = str(project.resolve())

result = DelphiCompileGateClient(timeout=180).compile_project(**arguments)
```

Do not call any other compile function.

## Required State

Before submitting a job:

1. Delphi 13 Community Edition must be running.
2. The current DelphiCompileGate package must be installed.
3. Open **Help > Help Wizards > Delphi Compile Gate Settings / Status...**.
   In a German IDE, use
   **Hilfe > Hilfe-Experten > Delphi Compile Gate Settings / Status...**.
4. Select **Start Watch**, then select **OK**.
5. The status must show `Running`.

The watcher does not start with the IDE.

Queue processing pauses while the Settings / Status dialog is visible. Close
that dialog before waiting for a compile result.

## Only Supported API

`DelphiCompileGateClient.compile_project()` is the only supported compile API.

Do not:

- create queue manifests manually;
- write files directly into `Run\Input`;
- use removed validation or wrapper APIs;
- invoke an external Delphi command-line compiler;
- treat an unauthenticated or incomplete result as successful.

## Compile a DPR Without a DPROJ

Use source-only mode for a conventional program or package that does not depend
on project-specific defines, runtime packages, custom search paths, build
events, or MSBuild imports.

Do not create a `.dproj` for this case. Omitting `project_path` is intentional.

```python
from pathlib import Path

from delphi_compile_gate import DelphiCompileGateClient

source = Path(r"C:\Projects\Example\Example.dpr").resolve()
client = DelphiCompileGateClient(timeout=90)

result = client.compile_project(
    source_path=str(source),
    platform="Win32",
    configuration="Debug",
)
```

## Compile an Existing Delphi Project

Provide `project_path` when the project depends on settings in its `.dproj`.
The `.dpr`/`.dpk` and `.dproj` must be absolute existing files with the same
directory and stem.

```python
from pathlib import Path

from delphi_compile_gate import DelphiCompileGateClient

root = Path(r"C:\Projects\Example").resolve()
client = DelphiCompileGateClient(timeout=180)

result = client.compile_project(
    source_path=str(root / "Example.dpr"),
    project_path=str(root / "Example.dproj"),
    platform="Win64",
    configuration="Release",
)
```

Allowed target values are exact:

```text
platform: Win32 or Win64
configuration: Debug or Release
```

Let the client generate the job ID unless durable evidence requires an explicit
unique ID. Never reuse a job ID or evidence path.

## Decide Whether the Compile Passed

Accept a build only when all of these conditions hold:

```python
assert result["status"] == "ok"
assert result["success"] is True
assert result["compile"]["target_matched"] is True
assert result["compile"]["release_eligible"] is True
assert result["interventions"]["policy_compliant"] is True
```

Also verify that:

- `identity.protocol == 2`;
- `identity.plugin_version` matches the client release;
- `identity.package_build_id` is accepted by the client;
- the requested, selected, and compiler-reported targets agree;
- `artifact.path`, `artifact.size`, and `artifact.sha256` are present for a
  successful build.

Do not infer success from the presence of an EXE or BPL alone.

## Report a Compiler Failure

`failure_code == "compile_failed"` means the compiler ran and rejected the
source. Report concise diagnostics from `result["compile"]["errors"]` with file,
line, column, code, and message.

Example:

```python
if result["failure_code"] == "compile_failed":
    for error in result["compile"]["errors"]:
        if not error["warning"]:
            print(
                error["file"],
                error["line"],
                error["column"],
                error["code"],
                error["canonical_message_en"],
            )
```

For any other failure code, report the infrastructure, evidence, dialog, target,
or artifact failure exactly. Do not silently retry with another protocol or
compiler.

## Community Edition Notice

The exact informational Community Edition notice may be acknowledged through
its sole `OK` button. A result can then contain:

```json
{
  "legal_notice": {
    "detected": true,
    "classification": "community_edition_usage_notice",
    "action": "acknowledged",
    "accepted_terms": false
  }
}
```

The Gate never selects an acceptance, agreement, or continuation control.
Unknown legal dialogs remain open and block the job.

## Runtime Location

The default local queue is:

```text
%LOCALAPPDATA%\DelphiCompileGate\Run
```

If `DELPHI_COMPILE_GATE_BASE_DIR` is set, the Delphi process and Python client
must receive the same value before either starts.

The local Windows account and private runtime queue are the trust boundary. A
supplied `.dproj` is trusted input and may execute custom build steps or MSBuild
imports. DelphiCompileGate is not a sandbox.

## Troubleshooting

- Timeout: confirm Delphi is running, the watcher status is `Running`, and the
  Settings / Status dialog is closed.
- Identity mismatch: rebuild and install the package from the same checkout as
  the Python client.
- Job in `Failed`: inspect the adjacent `.error.txt` and watcher log.
- Modal dialog: do not automate it manually unless its meaning and action are
  understood; unknown dialogs fail closed.
- Project-specific compile failure in source-only mode: provide the matching
  `.dproj` through `project_path`.

See `INSTALLATION.md` for setup and `KNOWN_ISSUES.md` for current safety and
DelphiLSP memory limitations.
