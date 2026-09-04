# DelphiCompileGate Known Issues

Last updated: 2026-09-04

This document records defects discovered while using DelphiCompileGate. The
current and only supported contract is Delphi 13 Community Edition
(`CompilerVersion = 37.0`), strict Protocol 2,
`DelphiCompileGateClient.compile_project()` as the sole compile API, and only
`*.job.json` queue manifests produced by that API. Unversioned requests,
compatibility aliases, all other queue and result formats, and all other Delphi
releases are unsupported and must fail closed. Historical
behavior from removed APIs, queue formats, obsolete wrappers, result envelopes,
and dialog paths appears only under headings explicitly marked **Removed
history**. It is not supported and must not be used as operational guidance.

## Status Definitions

| Status | Meaning |
|---|---|
| Open | Reproduced and not solved |
| Partial | Some cases work, but acceptance criteria are not met |
| Fixed | A committed fix exists |
| Rejected | Investigated approach must not be restored |
| Infrastructure | Environment or IDE state prevents reliable evidence |
| Removed history | Behavior from deleted, unsupported implementations; never current guidance |

## Open Issues

### DCG-001: External source reload prompt blocks the watcher

Status: Open

Severity: High

Observed workflow:

1. A v2 wrapper project is compiled inside the Delphi IDE.
2. A compiler error causes Delphi to open the affected original source unit.
3. An external tool corrects that source file on disk.
4. Delphi displays a modal reload prompt.
5. The modal dialog blocks subsequent watcher jobs until a user responds.

Observed bilingual runtime matcher evidence follows. The localized strings are
data used to identify an exact `de-DE` dialog; they are not prose or operating
instructions.

English meaning of the prompt:

```text
Changes to module <absolute source path> were detected on disk. This module was
also changed in memory. Reloading it now will discard the in-memory changes.
Reload?
```

Exact `de-DE` prompt localization data:

```text
Bei Modul <absolute source path> wurden Änderungen auf der Festplatte
festgestellt. Auch im Hauptspeicher wurde dieses Modul geändert. Wenn Sie das
Modul jetzt laden, werden die Änderungen im Hauptspeicher verworfen. Erneut
laden?
```

Exact button localization data (`en-US` meaning | `de-DE` matcher token):

```text
Yes | Ja
No | Nein
No to All | Alle Nein
Yes to All | Alle Ja
```

Expected behavior:

- Only the exact technical reload prompt for a source path authorized by the
  latest v2 job may be confirmed automatically.
- Only the exact `de-DE` `Ja` token or exact English `Reload` token may be
  clicked.
- The localized `Alle Ja` and `Alle Nein` tokens and all license, EULA, save,
  overwrite, delete, close, and
  unknown dialogs must never be accepted automatically.
- The policy must work after the compile job has completed, because the external
  source edit normally happens later.

Current state:

- A persistent, path-allowlisted reload policy was added in `704bc50`.
- `de-DE` prompt handling was added in `9d9c065`.
- The observed four-button set was added in `65d14fb`.
- The persistent `dapReloadOnly` worker uses the strict Protocol-v2 dialog
  dispatcher, so its documented path, token, revision and button checks are
  reached.
- Real end-to-end attempts still left the dialog open. The feature must therefore
  be treated as non-functional until a repeatable live test records
  `reload_prompt_confirmed` and no modal dialog remains.
- Live predicate tracing showed that the visible RAD Studio dialog did not
  expose its complete text/path through the documented bounded window-text
  collection. The worker therefore correctly left it manual-required.

Acceptance test:

1. Compile a project containing a deliberate error in one allowlisted unit.
2. Confirm Delphi opens that unit.
3. Modify the exact unit externally after the compile result is persisted.
4. Verify no reload dialog remains visible.
5. Verify one `reload_prompt_confirmed` event containing only a hashed
   authorization fingerprint.
6. Repeat with a basename-only prompt, `.bak` suffix and unrelated full path;
   all must remain untouched.

Relevant commits:

```text
704bc50 fix: reload authorized source prompts
4fdfbc1 fix: declare reload button helper
be014a9 fix: expose reload policy types
9d9c065 fix: recognize de-DE reload prompts
65d14fb fix: accept de-DE reload button set
```

### DCG-002: Wide compiler diagnostics are absent from v2 JSON

Status: Fixed and live-verified on Delphi 13

Severity: Critical

#### Removed history: diagnostic-capture gap

Status: Removed history

The following observations describe the fixed, superseded capture behavior and
are not current operating guidance:

- `IOTAProject.Compile` and its notifier report `crOTAFailed`.
- The v2 result contains only an informational CRLF normalization message.
- The actual `dcc32` errors appear in Delphi's Message View and may navigate to a
  source unit, but they are not present in the JSON report.
- This prevents an automated client from determining what source change is needed.

Historical cause:

- The superseded message hook captured only narrow message-service calls.
- Delphi 13 emits relevant compiler diagnostics through Wide message-service
  overloads that the original safe hook did not capture.

#### Current strict Protocol-2 resolution

Resolution:

- All verified Delphi 13 `IOTAMessageServices` narrow and WideString slots
  are installed transactionally and verified after patching.
- The verified WideString compiler slots 31, 32 and 33 and tool slots 37, 38
  and 39 forward to capture-only trampolines with their Delphi 13 signatures.
- Slot ownership conflicts fail closed without replacing a foreign hook chain.
- A live Protocol-2 wrapper run on 2026-07-19 captured 69 compiler diagnostics
  without RTTI, clipboard, focus, or keyboard fallback.
- Localization test evidence used canonical English
  `F2613 Unit 'DependencyUnit' not found.` with exact `de-DE` raw text
  `F2613 Unit 'DependencyUnit' nicht gefunden.` Temporary raw-result artifacts
  were removed after verification.

Rejected solutions:

- Guessing or patching additional global VMT slots without a safe hook-chain and
  package-unload contract.
- Clipboard, focus, selection or synthesized keyboard scraping of Message View.
- Accepting every rendered diagnostic code, because stale rows from earlier jobs
  can be misattributed.

Required solution properties:

- Exact diagnostics with file, line, column, code and severity.
- No global VMT corruption or unsafe package unload.
- No focus, clipboard or keyboard automation.
- No stale Message View rows attributed to a new job.
- Explicit provenance identifying the diagnostic source.

Acceptance test:

1. Compile a wrapper with one unique `dcc32` error.
2. Verify the notifier reports failure.
3. Verify JSON contains exactly that error with its source location.
4. Compile a clean wrapper and verify no previous error is returned.
5. Repeat while unrelated IDE messages are generated; they must remain excluded.

### DCG-003: IDE may compile stale editor buffers after external edits

Status: Partial

Severity: High

Observed behavior:

- A source unit opened by a previous compiler error remains in the IDE editor.
- The file is corrected externally.
- If the reload prompt is not handled, a later wrapper build can compile the old
  editor buffer rather than current disk content.
- The produced executable is new, but contains stale code from selected units.

Impact:

- A code fix appears ineffective because the next test executable reproduces the
  exact previous failure.
- Artifact timestamps and hashes alone do not prove that every source buffer came
  from current disk bytes.

Required evidence:

- Before compile, every referenced source must either be unopened or proven to
  match its requested source hash.
- A changed editor buffer must be reloaded from disk through a verified technical
  action or the job must fail with a stable source-buffer mismatch code.
- The result should report source-buffer provenance or a limitation when this
  cannot be established.

Current state:

- Unmodified editor buffers are accepted in the dedicated build-worker model;
  the worker never edits source through the IDE.
- A modified buffer is read through documented `IOTAEditorContent` and compared
  byte-for-byte with disk. A changed buffer fails closed as
  `source_buffer_mismatch`; an unreadable, oversized or otherwise unverifiable
  modified editor fails closed as
  `source_buffer_unverified`.
- A live acceptance test externally inserted invalid Delphi syntax while the
  source was open; the next v2 build compiled the current disk bytes and returned
  the corresponding `E2029` diagnostic. The explicit modified-buffer mismatch
  and authorized reload workflow still require complete live acceptance.

Acceptance test:

1. Open a source through a compiler error.
2. Modify it externally without reloading.
3. Start another v2 job.
4. Verify the gate either reloads the exact file safely or rejects the job before
   compilation. It must not silently build stale content.

### DCG-004: Wrapper compile can fail without actionable diagnostics

Status: Fixed

Severity: High

Observed behavior:

- A wrapper job returns `compile_failed` and notifier result `crOTAFailed`.
- JSON contains no error-severity diagnostic, only one informational warning.
- This issue is the externally visible consequence of DCG-002 and can also hide
  wrapper-construction or IDE-state failures.

Required behavior:

- `compile_failed` must include at least one actionable compiler diagnostic, or a
  stable reason such as `compile_error_details_unavailable`.
- It must not represent an informational message as the compile failure.

Resolution:

- Capture-only jobs with incomplete hook coverage fail closed as
  `message_capture_unavailable`.
- A failed project notifier with no non-warning diagnostic returns the stable
  `compile_error_details_unavailable` code.
- A real captured compiler error returns `compile_failed` with the captured
  diagnostics. The 2026-07-19 live v2 run verified this path.

### DCG-005: Unknown or legal modal dialogs can block synchronous OpenModule

Status: Open

Severity: Medium

Observed architecture:

- `OpenModule` executes synchronously on the IDE thread.
- A modal dialog creates a nested message loop.
- Known technical dialogs can be handled by a narrow worker.
- Unknown or legal dialogs without an exact safe Reject/Cancel button cannot be
  clicked under policy and can leave the job blocked.

Policy:

- Do not accept license or EULA dialogs.
- Do not click unknown affirmative actions.
- It is preferable to require manual action or return an explicit limitation than
  to weaken the policy.

## Partially Solved Issues

### DCG-006: Wrapper project XML sanitization

Status: Partial

Severity: Medium

Fixed cases:

- `IXMLDocument.XML` serialization uses `Doc.XML.Text`.
- Nested `<Source>` metadata no longer raises `EXMLDocError`.
- Original `DCCReference` items are preserved because removing them caused valid
  Delphi projects to fail compilation.
- `MainSource` and `DelphiCompile` are redirected to the wrapper DPR.

Remaining risk:

- More `.dproj` shapes may contain source-bearing metadata not represented in the
  current fixtures.
- The wrapper must preserve all compile semantics while avoiding accidental
  mutation of the original project.
- The emitted wrapper is now reparsed and must contain exactly one wrapper
  `DelphiCompile` item and only wrapper `MainSource` values; invalid output
  fails as `wrapper_project_invalid`.

### DCG-007: Diagnostic source-scope filtering

Status: Fixed

Severity: Medium

Fixed cases:

- Sibling source roots referenced by a wrapper are included in the capture scope.
- Known bare filenames from absolute wrapper `in` references can be recognized.
- Documented WideString compiler diagnostics are captured through the verified
  message-service hooks.
- A live Protocol-2 wrapper compile captured diagnostics from sibling source
  roots.

Remaining risk:

- Full-path diagnostics remain preferred; a bare filename is deliberately
  rejected when more than one referenced source owns that basename.

## Fixed Issues

### DCG-008: Protocol-v2 wrapper output identity mismatch

Status: Fixed

Relevant commits:

```text
be9f100 fix: preserve wrapper executable output
9525a14 fix: resolve compiler output from source project
344991a fix: stage exact wrapper artifact after compile
48d4c5a fix: preserve matching project target state
```

### DCG-009: Protocol-v2 provenance and target evidence incomplete

Status: Fixed

Relevant commit:

```text
fc16bed feat: add authenticated compile protocol v2
```

### DCG-010: CE technical dialogs prevented normal wrapper compilation

Status: Fixed for the known dialog fingerprints

Relevant commits:

```text
fb11ef2 feat: automate policy-approved v2 dialogs
fe8972c fix: start v2 dialog worker compatibly
f25120c fix: harden v2 dialog classification
4bba28a fix: acknowledge CE informational build dialog
```

The policy must remain narrow. A new dialog fingerprint is not automatically
safe because it is emitted by Delphi 13 CE.

### DCG-011: Informational CRLF message classified as compile error

Status: Fixed

Relevant commit:

```text
d7e42e8 fix: classify informational wrapper diagnostics
```

### DCG-012: Reload-policy Delphi build failures

Status: Fixed

### DCG-013: Automatic generated-project close crashed the IDE

Status: Fixed

#### Removed history: unsupported queue and close implementations

Status: Removed history

The following bullets describe deleted behavior and must not be restored or
used as current operating instructions:

- The old optional cleanup called `IOTAActionServices.SaveFile` and `CloseFile`
  separately for the generated `.dproj` and `.dpr` while project and notifier
  interfaces were still alive in the compile call stack.
- `Sleep` delays blocked the IDE thread and did not provide a safe VCL message
  turn or notifier-lifecycle boundary.

Resolution:

- An unsupported source-pair and multi-source queue extension once queued
  temporary projects. Under rapid jobs, Delphi retained source modules while
  the watcher moved their inputs, producing IDE application errors. That queue
  format and its result envelope were removed.
- The 2026-08-14 Delphi 13 stress run proved that the former successful-wrapper
  `CloseModule(True)` path was still unsafe: two closes produced `bds.exe`
  exceptions and the second terminated the IDE with `0x0eedfade`.
- The revised path required four consecutive compile-, progress- and modal-free
  timer ticks, reacquired the exact project below the controlled wrapper root,
  and invoked `IOTAProjectGroup.RemoveProject` once.
- A remove attempt was never retried, including when Delphi raised after a
  partial internal graph mutation. A failure disabled auto-close for that IDE
  session.
- Only one pending project was processed per timer callback. Four further timer
  turns isolated the mutation from the next `OpenProject`.
- A later Delphi 13 experiment attempted a separate one-shot
  `IOTAActionServices.CloseFile` phase for generated wrapper editors after
  confirmed project-group removal. The save prompt could be declined and module
  absence verified, but the third open/close cycle produced delayed
  `rtl370`/`coreide370` access violations and destabilized the IDE. That phase
  and its dialog automation were removed completely.
- Global and project-builder compile notifiers were kept inert and alive through
  the post-remove settle phase. Notifier-removal uncertainty failed the job and
  prevented auto-close.
- Incomplete message-hook restoration retained every still-needed forwarding
  pointer and failed closed instead of leaving a live trampoline with a nil
  predecessor.
- The queue retained paths and scalar state only; it never retained project or
  module interfaces.

Safety boundary:

- A second live experiment released all project/group/module interfaces and
  invoked the documented filename-targeted `IOTAActionServices.CloseFile`
  exactly once. It initially closed and verified removal, but repeated failed
  builds again terminated the IDE after a delayed internal dialog/state fault.
- Failed generated projects were not auto-closed by either obsolete cleanup
  API. Controlled build-worker recycle was the only established cleanup.
- Builds `dcg-v2-20260724-stable-02` through `stable-05` tested the removed
  queue, file-retention, and generic-dialog paths. Those package identities are
  not supported.

#### Current strict Protocol-2 resolution

- The current queue accepts only strict `*.job.json` Protocol-2 manifests
  produced through `compile_project()`.
- After publishing a successful or exact `compile_failed` result, the optional
  Delphi-13-only hidden-module close experiment queues only the canonical
  wrapper path.
- Runtime, dialog, evidence, malformed-request, timeout, target, artifact, and
  identity failures do not authorize close.
- The current close path uses a unique wrapper loaded by hidden `OpenModule`,
  reacquires it by exact path after four quiet timer turns, and calls
  `IOTAModule.CloseModule(True)` once. It never uses `RemoveProject`,
  `CloseFile`, saving, or retries.

#### Removed history: intermediate Delphi 13 lifecycle experiments

Status: Removed history

- The removed Delphi 13 `RemoveProject` experiment remained opt-in during its
  historical acceptance and is not part of the current close path.
- Delphi 13 live acceptance on 2026-08-14 completed five consecutive successful
  compile/remove/open cycles. Every wrapper was absent from the project group
  after the settle phase, all VMT slots and parked notifier references were
  released, `bds.exe` remained responsive, and Windows recorded no `bds.exe` or
  `DelphiLSP.exe` application error during or after the run.
- Generated project modules remained loaded but were not explicitly shown in an
  editor. In-process module removal remained outside the Delphi 13 safety
  boundary.
- Build `dcg-v2-20260904-hiddenmodule-*` replaced v2 `OpenProject` with
  `IOTAModuleServices.OpenModule` and deliberately never called `Show`. This was
  an experimental mitigation for visible editor-tab growth, not proof that the
  underlying IDE/LSP project module was unloaded. Release acceptance required a
  long alternating success/failure stress run with module count, working set,
  compile latency, IDE and LSP crash monitoring.
- Delphi 13 live acceptance on 2026-09-04 completed 101 hidden-module jobs
  (alternating success and intentional compile failure) without a new
  `bds.exe`/`DelphiLSP.exe` application-error event. Compile latency did not
  degrade: jobs 21-40 averaged 392.4 ms and jobs 81-100 averaged 383.6 ms.
  However, `bds.exe` working set grew from 106.1 MB before the first project to
  316.5 MB after the run (467.3 MB private), and did not shrink after 30 seconds
  idle. Hidden `OpenModule` therefore mitigates editor UI/tab growth but does
  not solve unbounded in-process project/LSP memory retention.
- An unsupported resident-project reuse experiment reused one hidden project with
  an atomically replaced include payload. The first compile succeeded, but the
  second compile reproducibly failed inside Delphi dependency checking. The IDE
  message view contained repeated access violations at offset `EA239` in
  `delphicoreide370.bpl`, with neither compile notifier nor message-service hook
  evidence. Timestamp refresh, direct `IOTAProjectBuilder.BuildProject`, and an
  RTTI failure fallback did not make project reuse safe. The complete resident
  path was removed; those package build IDs are intentionally not client-
  allowlisted.

#### Current hidden-module close evidence

- Build `dcg-v2-20260904-v2only-03` retains the verified hidden-close lifecycle:
  a unique wrapper loaded by `OpenModule`, never shown, then reacquired by exact
  path and closed once through `IOTAModule.CloseModule(True)` after four quiet
  timer turns and full compile cleanup. It never uses `RemoveProject` or
  `CloseFile`. The option is off by default, Delphi-13-only, and not release-
  accepted until success/failure and long memory/crash tests complete. The first
  build completed 100 successful open/close cycles without an IDE/LSP crash or
  compile-latency regression; `bds.exe` rose from 193.2 MB after warm-up to
  212.1 MB, while two LSP processes still reached about 116 MB each. The second
  build extends the same exact close to authenticated `compile_failed` results.
- Final Protocol-2-only acceptance covered source-only success, exact
  `compile_failed`, a localized Community Edition notice from a large
  DebugServer fixture, hidden close for both outcomes, obsolete-manifest
  quarantine, and a valid job immediately behind that rejection. All results
  used package identity
  `dcg-v2-20260904-v2only-03`; no `bds.exe` or `DelphiLSP.exe` application-error
  event occurred.
- Release-preparation stress acceptance completed 1,000 alternating public
  example jobs in 3,597.5 seconds with zero unexpected results and no
  `bds.exe`/`DelphiLSP.exe` application-error event during the stress window.
  Compile latency remained stable (first 100 average 373.77 ms; final 100
  average 362.89 ms), and every hidden module was verified absent after close.
  This did not bound DelphiLSP memory: two LSP processes grew approximately
  linearly to 1,084.0 MB and 1,083.5 MB working set (about 1,077 MB private
  each). `bds.exe` grew from 198.5 MB to 383.9 MB working set. DelphiLSP
  retention is an accepted release limitation; indefinite IDE sessions are not
  a supported claim and users must monitor memory during large runs.
- After restarting Delphi following that run, two DelphiLSP processes crashed
  in `dcc32370.dll` before the first new Gate job. A subsequent
  `releaseprep-02` output-isolation build completed successfully, wrote its EXE
  only below `%LOCALAPPDATA%\DelphiCompileGate\Run\Projects`, closed its hidden
  module, and produced no matching artifact in the source workspace. The LSP
  startup failures appear related to retained IDE language-server state rather
  than the new compile, but still prevent an indefinite-session release claim.

#### Removed history: earlier Delphi 13 hidden-close evidence

Status: Removed history

The package identities in this subsection are historical evidence only and are
not currently supported:

- Build `dcg-v2-20260904-hiddenclose-ide13-03` completed a further 20-job mixed
  run (10 successful, 10 exact `compile_failed`) with every hidden module absent
  after settle, no session latch, and no `bds.exe`/`DelphiLSP.exe` application
  error. Compile time averaged 367.6 ms.
- A subsequent Win32/Debug build of a large DebugServer fixture produced the
  Community Edition notice. The worker matched exact
  `TCENotificationDialog`, modal ownership, sole exact OK, and no acceptance
  control; JSON reported `community_edition_usage_notice`, `action:
  acknowledged`, `accepted_terms:false`, and honest unavailable body text. The
  build remained release-eligible and its hidden module closed and verified
  absent without an IDE/LSP application error.

### DCG-014: Wizard execution showed obsolete RebuildAll notification

Status: Fixed

#### Removed history: RebuildAll wizard action

Status: Removed history

- Executing the IDE wizard triggered `RebuildAll` and showed an obsolete
  one-tick notification.

#### Current strict Protocol-2 resolution

- Executing the IDE wizard opens a settings/status dialog.
- Validated settings are stored atomically in
  `%APPDATA%\DelphiCompileGate\DelphiCompileGate.ini`.
- Only watch interval, compile timeout and experimental close of completed
  hidden Protocol-v2 modules are editable. Protocol-v2 safety boundaries remain
  fixed.

### DCG-015: Large external Win64 fixture does not compile

Status: Infrastructure

Severity: Medium

Observed on 2026-07-31:

- Protocol v2 selected `Win64`/`Debug` and `Win64`/`Release` deterministically.
- The project-builder compile notifier reported the same requested platform and
  configuration in both jobs, and `target_matched` was true.
- The large external read-only fixture failed under `dcc64` with 28 error
  diagnostics in each configuration. The reported codes were `E2250`, `E2532`,
  and final `F2063`.
- Both authenticated results correctly reported `compile_failed`, null artifact
  evidence, and `release_eligible: false`.
- Dialog evidence was policy-compliant: one known technical dialog closure, no
  unknown or legal/EULA dialog, and no swallowed exception.

Impact:

- The live runs prove Win64 target selection and compiler-target evidence, but
  they do not prove production of a Win64 executable from this fixture.
- Fixing the external fixture is outside the DelphiCompileGate repository and
  must not be attempted as part of Gate maintenance.

### DCG-016: Delphi 13 dependency and progress-form differences

Status: Partial

Current Delphi 13 dependency state:

- The Delphi 13 acceptance environment had no Win32 source or compiled DCU for
  `DUnitX.Loggers.Console`; the fixture initially failed with `F2613`.
- Official DUnitX source was pinned at commit
  `59868f55fd5a2b62cfb34dd0dd1a7bfcfa40bb2e` outside the IDE installation and
  exposed only to BDS 37.0 through the `DUnitX` environment variable.

#### Removed history: pre-fix Delphi 13 progress handling

Status: Removed history

- With that source, Delphi 13 compiled the fixture successfully and produced an
  authenticated Win32/Debug artifact.
- Delphi 13 exposed a transient modal `TProgressForm` with a Cancel button. The
  superseded unknown-dialog fallback clicked Cancel and disqualified the
  otherwise valid result.
- A failed compile later changed the same HWND class into a terminal build
  summary with an OK button. Ignoring the class unconditionally left that
  result modal open and caused the client to time out.

#### Current strict Protocol-2 resolution

Resolution:

- Protocol v2 distinguishes active progress from terminal result by required
  bounded status/target/count labels and complete button-set evidence. It never
  clicks Cancel. It acknowledges a terminal result only when exactly one visible
  enabled control exists and its normalized text is exact OK; unexpected
  controls remain fail-closed.
- No legal, CE-notification or generic unknown-dialog rule was relaxed.

#### Removed history: earlier Delphi 13 acceptance evidence

Status: Removed history

The package identity and raw result in this subsection are historical evidence
only and are not currently supported:

- Live acceptance with package build `dcg-v2-20260814-ide13-02` succeeded on
  2026-08-14: exact Win32/Debug selected/compiler target, `target_matched: true`,
  authenticated artifact, `release_eligible: true`, one known CE notification,
  no unknown/legal dialog and no swallowed exception.
- The trace confirmed `TProgressForm` was ignored without interaction before
  the successful compile completed in 4042 ms.

## Rejected Approaches

### DCG-R001: Guessed Wide message-service VMT hooks

Status: Rejected

Reasons:

- Global VMT mutation affects the entire IDE process.
- Partial install/uninstall and hook chaining are difficult to make safe.
- A later package hook can depend on the original forwarding pointer.
- Package unload can leave dangling callbacks or overwrite another plugin's hook.
- Incorrect slot/signature assumptions can crash the IDE.

Do not restore this approach without a documented ToolsAPI ABI, transactional
hook-chain ownership and a package-unload proof. The hook implementation first
added in `67c823b` is not this rejected approach: the current Delphi-13-only
path uses verified `ToolsAPI.pas` WideString signatures and slots,
transactionally verifies every patch and refuses unknown slot ownership.

### DCG-R002: Message View clipboard or keyboard scraping

Status: Rejected

Reasons:

- Mutates IDE focus and selection.
- Mutates the user's clipboard.
- Can synthesize Ctrl+A/C keystrokes.
- Cannot reliably separate current-job rows from stale diagnostics.

### DCG-R003: Removing all DCCReference project items

Status: Rejected

Reason:

- The wrapper no longer preserved the compile semantics of real Delphi projects.
- `IOTAProject.Compile` could fail while exposing only an informational message.

### DCG-R004: Treating CLI dcc32 as the Community Edition solution

Status: Rejected for the current environment

Reason:

- Delphi Community Edition in this environment does not support the required
  command-line compiler workflow.
- The product requirement is explicitly to compile inside the IDE through
  DelphiCompileGate.

## Validation Checklist for Future Fixes

- Build the Win32 design-time BPL through Delphi 13 CE only.
- Never reuse DCUs, DCPs or BPLs from another IDE version.
- Confirm the installed BPL hash and source commit in v2 evidence.
- Confirm the IDE-specific package identity and compiler version match the
  active IDE before treating a v2 result as trusted.
- Run a clean wrapper compile.
- Run a wrapper compile with one unique compiler error.
- Correct the opened source externally and test the reload prompt.
- Confirm no legal, save, overwrite, delete or unknown affirmative button was
  clicked.
- Confirm a second clean compile cannot return stale diagnostics or stale source
  bytes.
- Confirm watcher stop/start and package unload do not crash the IDE.
- Run the strict Protocol-2 Python contract tests and `py_compile`.
- Run at least one complete downstream Protocol-v2 gate.

## GitHub Release Readiness

- Resolve or explicitly document every open and partial issue above.
- Run the strict Protocol-2 Python contract tests and Delphi 13 acceptance suite.
- Verify that published prose and fixture JSON contain no machine-specific paths
  or downstream-project identities.
- Confirm release artifacts report the documented plugin, protocol, build, and
  Delphi 13 identities.
- Keep hidden-module close opt-in because it does not release DelphiLSP caches.
- The project is licensed under MIT; users remain responsible for Embarcadero
  and project-specific license terms.
