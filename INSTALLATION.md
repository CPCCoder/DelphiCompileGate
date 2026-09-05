# Installation

This guide installs DelphiCompileGate for Delphi 13 Community Edition on
Windows and verifies the installation with the bundled public example.

## Prerequisites

- Windows 10 or Windows 11
- Delphi 13 Community Edition (`CompilerVersion = 37.0`)
- Python 3.9 or newer
- Git, when installing from a clone
- Permission to install a design-time package in the current Delphi user
  profile

Delphi 12 and other Delphi versions are not supported. Do not reuse DCUs, DCPs,
or BPLs built by another Delphi version.

## Obtain the Source

Clone the repository:

```powershell
git clone https://github.com/CPCCoder/DelphiCompileGate.git
Set-Location DelphiCompileGate
```

Alternatively, download a source archive from the matching GitHub release and
extract it to any writable directory. DelphiCompileGate does not need to be
installed below `%LOCALAPPDATA%`.

## Install the Python Client

Creating a virtual environment is recommended:

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install .
```

Verify that the client imports successfully:

```powershell
python -c "from delphi_compile_gate import DelphiCompileGateClient; print(DelphiCompileGateClient)"
```

The Python client has no runtime dependencies outside the Python standard
library.

`DelphiCompileGateClient.compile_project()` is the only supported compile API.

```python
client = DelphiCompileGateClient(timeout=90)
result = client.compile_project(
    source_path=r"C:\Path\To\Project.dpr",
    platform="Win32",
    configuration="Debug",
)
```

Omit `project_path` for source-only mode. Provide it when project-specific
defines, packages, search paths, imports, or build events are required.

## Build the Delphi Package

1. Start Delphi 13 Community Edition.
2. Open `Package\DelphiCompileGate.dproj` or
   `Package\DelphiCompileGate.dpk`.
3. Select the package platform that matches the IDE host:
   - **Win32** for the 32-bit `bin\bds.exe` IDE.
   - **Win64** for the 64-bit `bin64\bds.exe` IDE.
   Project targets remain independent; either IDE host can compile Win32 and
   Win64 projects.
4. Select **Release** for a distributable local package, or **Debug** while
   developing the plugin.
5. Select **Project > Build DelphiCompileGate** or press `Ctrl+F9`.
6. Confirm that the build completes without compiler errors.

Package outputs are written below:

```text
%BDSCOMMONDIR%\DelphiCompileGate\<Win32-or-Win64>\<Config>
```

Do not copy a BPL, DCP, or DCU from another Delphi installation.
Do not load a Win32 design-time BPL into the 64-bit IDE or a Win64 BPL into the
32-bit IDE.

## Install the Delphi Package

1. Keep the compiled package project open in Delphi.
2. Select **Install** from the package project context menu or package editor.
3. Confirm that Delphi reports that `DelphiCompileGate` was installed.
4. Open **Help > Help Wizards > Delphi Compile Gate Settings / Status...**.
   In a German IDE, use
   **Hilfe > Hilfe-Experten > Delphi Compile Gate Settings / Status...**.
5. Confirm the displayed identity:

```text
Plugin: 2.0.1
Protocol: 2
Compiler: 37.0
Build ID: dcg-v2-20260905-searchpathfix-04
```

If the build ID differs, Delphi is still loading another BPL. Remove the older
package entry, close Delphi, delete or relocate the stale BPL, restart Delphi,
and install the current package again.

## Start the Watcher

The watcher never starts automatically and does not start with the IDE.

1. Open **Help > Help Wizards > Delphi Compile Gate Settings / Status...**.
   In a German IDE, use
   **Hilfe > Hilfe-Experten > Delphi Compile Gate Settings / Status...**.
2. Review the watch interval and compile-timeout threshold.
3. Leave experimental hidden-module close disabled unless its documented risk
   is acceptable for the current session.
4. Select **Start Watch**. This only records a pending start.
5. Select **OK** to save settings and start the watcher.

The status must show `Running`. Selecting **Cancel** instead discards the
pending start. Selecting **Stop Watch** while running requests an immediate
graceful drain.

## Runtime Directory

The plugin and Python client use the same per-user default:

```text
%LOCALAPPDATA%\DelphiCompileGate\Run
```

The directory contains:

```text
Input\
Output\
Processed\
Failed\
Logs\
Projects\
```

To use another directory, set the following environment variable before
starting both Delphi and the Python process:

```powershell
$env:DELPHI_COMPILE_GATE_BASE_DIR = "D:\DelphiCompileGateRuntime"
```

The plugin and client must resolve the same runtime directory. Do not place the
runtime queue in a network share or a broadly writable directory.

### Generated Wrapper Retention

The Gate retains generated directories below `Run\Projects` for two days by
default. Each new compile removes at most four stale wrapper directories,
including generated source, project, executable, package, DCU, and related
artifacts. A larger backlog is removed gradually over subsequent builds.

To change the retention period, set this variable before starting Delphi:

```powershell
$env:DELPHI_COMPILE_GATE_TEMP_MAX_AGE_DAYS = "7"
```

Values below one day are raised to one day. Cleanup runs only when a new wrapper
is created. The `Processed`, `Failed`, and `Logs` directories are not removed by
this age-based wrapper cleanup.

## Verify the Installation

From the repository root with the watcher running:

```powershell
python -c "from pathlib import Path; from delphi_compile_gate import DelphiCompileGateClient; root=Path.cwd(); result=DelphiCompileGateClient(timeout=90).compile_project(source_path=str((root/'examples'/'HelloGate'/'HelloGate.dpr').resolve()), project_path=str((root/'examples'/'HelloGate'/'HelloGate.dproj').resolve()), platform='Win32', configuration='Debug'); print(result)"
```

A successful result must contain:

```text
status: ok
success: true
protocol: 2
plugin_version: 2.0.1
package_build_id: dcg-v2-20260905-searchpathfix-04
compiler_version: 37.0
target_matched: true
release_eligible: true
```

The generated wrapper and EXE must be below
`%LOCALAPPDATA%\DelphiCompileGate\Run\Projects`. The original example directory
must not receive a generated EXE, DCU, DCP, or BPL.

## Update an Existing Installation

1. Select **Stop Watch** and wait for the status to become `Stopped`.
2. Close Delphi. This releases the loaded BPL and any DelphiLSP processes.
3. Update or replace the source checkout.
4. Restart Delphi 13.
5. Open and rebuild `Package\DelphiCompileGate.dproj`.
6. Install the rebuilt package.
7. Open Settings / Status and verify the expected build ID.
8. Select **Start Watch**, then **OK**.
9. Run the bundled verification command again.

Changing source files does not update the BPL already loaded by Delphi.

## Uninstall

1. Select **Stop Watch** and wait for `Stopped`.
2. Open Delphi's installed-package management dialog.
3. Locate `DelphiCompileGate` and remove or disable it.
4. Close Delphi.
5. Delete the installed DelphiCompileGate BPL only after confirming that no
   Delphi process is running.
6. Remove the Python package if installed:

```powershell
python -m pip uninstall DelphiCompileGate
```

7. Optionally remove per-user state:

```text
%LOCALAPPDATA%\DelphiCompileGate
%APPDATA%\DelphiCompileGate
```

Removing these directories deletes runtime evidence, logs, generated wrappers,
and saved settings.

## Troubleshooting

### The Python client times out

- Confirm Delphi 13 is running.
- Confirm the current package is installed.
- Confirm Settings / Status reports `Running`.
- Close the Settings / Status dialog; queue processing is deferred while it is
  visible.
- Inspect `%LOCALAPPDATA%\DelphiCompileGate\Run\Logs`.
- Confirm the plugin and client use the same
  `DELPHI_COMPILE_GATE_BASE_DIR` value.

### The client reports a package identity mismatch

The Python client and loaded BPL are from different releases. Rebuild and
install the package from the same checkout used to install the Python client.

### A job moves to `Failed`

Inspect the adjacent `.error.txt` file and the watcher log. The watcher accepts
only exact Protocol 2 `.job.json` manifests created by `compile_project()`.

### Delphi displays a modal dialog

Unknown or unsafe dialogs deliberately block the job. The exact Community
Edition informational notice may be acknowledged through its sole `OK` button;
acceptance controls are never selected.

### Memory grows during long sessions

Hidden wrapper modules are closed after authorized results when the experimental
option is enabled. DelphiLSP can still retain project caches. Review
`KNOWN_ISSUES.md` before enabling indefinite unattended operation.

## Security Boundary

DelphiCompileGate accepts qualifying projects from any local workspace. The
local Windows account and private runtime queue form the trust boundary. A
supplied `.dproj` is trusted input and can execute custom build steps or
MSBuild imports under the Delphi process account. The Gate is not a sandbox. Keep
the runtime queue private to the current Windows account and compile only
trusted workspaces.
