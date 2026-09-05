unit DelphiCompileGate.Watch;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.SyncObjs, System.JSON,
  System.Generics.Collections,
  Vcl.ExtCtrls,
  ToolsAPI,
  DelphiCompileGate.Compiler, DelphiCompileGate.ProtocolV2;

type
  TPendingProjectClose = record
    ProjectFile: string;
    DeferredChecks: Integer;
    StableTicks: Integer;
    CloseAttempted: Boolean;
    SettleTicks: Integer;
    AttemptFailed: Boolean;
  end;

  TDelphiCompileGateWatch = class
  private
    FTimer: TTimer;
    FCompiler: TDelphiCompileGateCompiler;
    FGlobalDialogCloser: TCompileDialogCloser;
    FLogLock: TCriticalSection;
    FInputDir: string;
    FOutputDir: string;
    FProcessedDir: string;
    FFailedDir: string;
    FLogDir: string;
    FIsRunning: Boolean;
    FIsBusy: Boolean;
    FDrainRequested: Boolean;
    FInitialized: Boolean;
    FPendingProjectCloses: TList<TPendingProjectClose>;
    FQueueDeferredBySettings: Boolean;
    FExperimentalHiddenModuleClose: Boolean;
    FHiddenModuleCloseFailed: Boolean;
    function GetPollIntervalMs: Cardinal;
    function GetCompileTimeoutMs: Cardinal;
    function GetPendingProjectCloseCount: Integer;
    procedure OnTimer(Sender: TObject);
    procedure WriteJSONAtomic(const AOutputName: string; const AJSON: string);
    procedure WriteLog(const AMsg: string);
    procedure ProcessInputQueue;
    procedure MoveToFailed(const AJobFile, AReason: string);
    function CanProcessNow: Boolean;
    procedure OnCompilerTrace(const AMsg: string);
    procedure ProcessV2Job(const AJobFile: string);
    procedure ClearReloadPromptPolicy;
    procedure CommitReloadPromptPolicy(const AJobId, AToken, AOriginalDpr,
      AWrapperDpr: string);
    function CanCommitReloadPromptPolicy(const ARequest: TV2Request;
      const AResult: TJSONObject): Boolean;
    function QueueGeneratedProjectClose(const AProjectFile: string): Boolean;
    procedure DisableExperimentalHiddenModuleClose(const AReason: string);
    function ProcessPendingProjectCloses: Boolean;
    function IsGateSettingsDialogOpen: Boolean;
    function HasAttemptedPendingModuleClose: Boolean;
    procedure SettleAttemptedModuleCloseBeforeStop;
    procedure CancelUnattemptedPendingModuleCloses;
    procedure ClearPendingProjectCloses;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure StopGraceful;
    procedure ProcessPending;
    procedure ApplyRuntimeSettings(const APollIntervalMs,
      ACompileTimeoutMs: Cardinal; const AExperimentalHiddenModuleClose: Boolean);
    property IsRunning: Boolean read FIsRunning;
    property IsBusy: Boolean read FIsBusy;
    property IsDraining: Boolean read FDrainRequested;
    property InputDir: string read FInputDir;
    property OutputDir: string read FOutputDir;
    property ProcessedDir: string read FProcessedDir;
    property FailedDir: string read FFailedDir;
    property LogDir: string read FLogDir;
    property PollIntervalMs: Cardinal read GetPollIntervalMs;
    property CompileTimeoutMs: Cardinal read GetCompileTimeoutMs;
    property ExperimentalHiddenModuleClose: Boolean
      read FExperimentalHiddenModuleClose;
    property PendingProjectCloseCount: Integer
      read GetPendingProjectCloseCount;
  end;

implementation

uses
  Winapi.Windows, Vcl.Forms,
  DelphiCompileGate.Consts;

type
  TJSONValueHelper = class helper for TJSONValue
  public
    function GetStringDef(const AName, ADefault: string): string;
    function GetBoolDef(const AName: string; const ADefault: Boolean): Boolean;
  end;

const
  RELOAD_POLICY_TTL_MS = 5 * 60 * 1000;
  AUTO_CLOSE_MAX_DEFERRED_CHECKS = 40;
  AUTO_CLOSE_STABLE_TICKS = 4;
  AUTO_CLOSE_SETTLE_TICKS = 4;

function TJSONValueHelper.GetStringDef(const AName, ADefault: string): string;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if Self = nil then Exit;
  V := Self.FindValue(AName);
  if Assigned(V) then
    Result := V.Value;
end;

function TJSONValueHelper.GetBoolDef(const AName: string; const ADefault: Boolean): Boolean;
var
  V: TJSONValue;
begin
  Result := ADefault;
  if Self = nil then Exit;
  V := Self.FindValue(AName);
  if Assigned(V) then
    Result := SameText(V.Value, 'true') or (V.Value = '1');
end;

{ TDelphiCompileGateWatch }

constructor TDelphiCompileGateWatch.Create;
var
  BaseDir: string;
begin
  inherited;
  FLogLock := TCriticalSection.Create;
  try
    FTimer := TTimer.Create(nil);
    FTimer.Enabled := False;
    FTimer.Interval := DEFAULT_WATCH_INTERVAL_MS;
    FTimer.OnTimer := OnTimer;

    FCompiler := TDelphiCompileGateCompiler.Create;
    FCompiler.OnTrace := OnCompilerTrace;
    FPendingProjectCloses := TList<TPendingProjectClose>.Create;
    FQueueDeferredBySettings := False;
    FExperimentalHiddenModuleClose :=
      DEFAULT_EXPERIMENTAL_HIDDEN_MODULE_CLOSE;
    FHiddenModuleCloseFailed := False;

    BaseDir := ResolveDelphiCompileGateBaseDir;

    FInputDir := TPath.Combine(BaseDir, 'Input');
    FOutputDir := TPath.Combine(BaseDir, 'Output');
    FProcessedDir := TPath.Combine(BaseDir, 'Processed');
    FFailedDir := TPath.Combine(BaseDir, 'Failed');
    FLogDir := TPath.Combine(BaseDir, 'Logs');

    ForceDirectories(FInputDir);
    ForceDirectories(FOutputDir);
    ForceDirectories(FProcessedDir);
    ForceDirectories(FFailedDir);
    ForceDirectories(FLogDir);
    FInitialized := True;
  except
    FreeAndNil(FCompiler);
    FreeAndNil(FPendingProjectCloses);
    FreeAndNil(FTimer);
    FreeAndNil(FLogLock);
    raise;
  end;
end;

function TDelphiCompileGateWatch.GetPollIntervalMs: Cardinal;
begin
  Result := FTimer.Interval;
end;

function TDelphiCompileGateWatch.GetCompileTimeoutMs: Cardinal;
begin
  Result := FCompiler.BackgroundCompileTimeoutMs;
end;

function TDelphiCompileGateWatch.GetPendingProjectCloseCount: Integer;
begin
  if Assigned(FPendingProjectCloses) then
    Result := FPendingProjectCloses.Count
  else
    Result := 0;
end;

procedure TDelphiCompileGateWatch.ApplyRuntimeSettings(const APollIntervalMs,
  ACompileTimeoutMs: Cardinal; const AExperimentalHiddenModuleClose: Boolean);
begin
  if (APollIntervalMs < MIN_WATCH_INTERVAL_MS) or
     (APollIntervalMs > MAX_WATCH_INTERVAL_MS) then
    raise EArgumentOutOfRangeException.CreateFmt(
      'Watch interval must be between %d and %d ms.',
      [MIN_WATCH_INTERVAL_MS, MAX_WATCH_INTERVAL_MS]);
  FCompiler.BackgroundCompileTimeoutMs := ACompileTimeoutMs;
  FTimer.Interval := APollIntervalMs;
  FExperimentalHiddenModuleClose := AExperimentalHiddenModuleClose and
    not FHiddenModuleCloseFailed;
  if AExperimentalHiddenModuleClose and FHiddenModuleCloseFailed then
    WriteLog('Experimental hidden-module close remains disabled after session failure');
  if not FExperimentalHiddenModuleClose then
    CancelUnattemptedPendingModuleCloses;
  WriteLog(Format('Runtime settings applied: poll_ms=%d compile_timeout_ms=%d experimental_hidden_close=%s',
    [APollIntervalMs, ACompileTimeoutMs,
     BoolToStr(FExperimentalHiddenModuleClose, True)]));
end;

procedure TDelphiCompileGateWatch.OnCompilerTrace(const AMsg: string);
begin
  WriteLog('CompilerTrace: ' + AMsg);
end;

procedure TDelphiCompileGateWatch.ClearReloadPromptPolicy;
begin
  if Assigned(FGlobalDialogCloser) then
    FGlobalDialogCloser.ClearReloadPolicy;
end;

procedure TDelphiCompileGateWatch.CommitReloadPromptPolicy(const AJobId,
  AToken, AOriginalDpr, AWrapperDpr: string);
var
  AllowedFiles: TArray<string>;
begin
  if not Assigned(FGlobalDialogCloser) or (AJobId = '') or (AToken = '') then
    Exit;
  AllowedFiles := FCompiler.CollectWrapperReloadAllowedFiles(AOriginalDpr,
    AWrapperDpr);
  if Length(AllowedFiles) = 0 then
  begin
    WriteLog('Reload policy not committed: no authorized wrapper paths for ' + AJobId);
    Exit;
  end;
  FGlobalDialogCloser.UpdateReloadPolicy(AJobId, AToken, AllowedFiles,
    GetTickCount + RELOAD_POLICY_TTL_MS);
  WriteLog('Reload policy committed for v2 job ' + AJobId + ' paths=' +
    IntToStr(Length(AllowedFiles)));
end;

function TDelphiCompileGateWatch.CanCommitReloadPromptPolicy(
  const ARequest: TV2Request; const AResult: TJSONObject): Boolean;
var
  Interventions: TJSONObject;
  InterventionsValue: TJSONValue;
  SchemaVersion: TJSONValue;
  Protocol: TJSONValue;
  FailureCode: TJSONValue;
  PolicyCompliant: TJSONValue;
begin
  Result := False;
  if not Assigned(ARequest) or not Assigned(AResult) then Exit;
  SchemaVersion := AResult.FindValue('schema_version');
  Protocol := AResult.FindValue('protocol');
  if not Assigned(SchemaVersion) or not Assigned(Protocol) or
     (SchemaVersion.Value <> '2') or (Protocol.Value <> '2') then
    Exit;
  if (AResult.GetStringDef('job_id', '') <> ARequest.JobId) or
     (AResult.GetStringDef('nonce', '') <> ARequest.Nonce) or
     (AResult.GetStringDef('request_hash', '') <> ARequest.RequestHash) then
    Exit;
  InterventionsValue := AResult.FindValue('interventions');
  if not (InterventionsValue is TJSONObject) then Exit;
  Interventions := TJSONObject(InterventionsValue);
  PolicyCompliant := Interventions.FindValue('policy_compliant');
  if not ((PolicyCompliant is TJSONBool) and
    SameText(PolicyCompliant.Value, 'true')) then
    Exit;
  FailureCode := AResult.FindValue('failure_code');
  if SameText(AResult.GetStringDef('status', ''), 'ok') then
    Exit(FailureCode is TJSONNull);
  Result := SameText(AResult.GetStringDef('status', ''), 'failed') and
    (FailureCode is TJSONString) and
    (SameText(FailureCode.Value, 'compile_failed') or
     SameText(FailureCode.Value, 'compile_error_details_unavailable'));
end;

function IsCompileFailureResult(const AResult: TJSONObject): Boolean;
var
  FailureCode: TJSONValue;
begin
  Result := False;
  if not Assigned(AResult) or
     not SameText(AResult.GetStringDef('status', ''), 'failed') then
    Exit;
  FailureCode := AResult.FindValue('failure_code');
  Result := (FailureCode is TJSONString) and
    SameText(FailureCode.Value, 'compile_failed');
end;

function TDelphiCompileGateWatch.QueueGeneratedProjectClose(
  const AProjectFile: string): Boolean;
var
  I: Integer;
  Item: TPendingProjectClose;
begin
  Result := False;
  if FDrainRequested or not FExperimentalHiddenModuleClose or
      (Trim(AProjectFile) = '') or
      not Assigned(FPendingProjectCloses) then
    Exit;
  for I := 0 to FPendingProjectCloses.Count - 1 do
    if SameText(FPendingProjectCloses[I].ProjectFile,
      ExpandFileName(AProjectFile)) then
      Exit;
  Item.ProjectFile := ExpandFileName(AProjectFile);
  Item.DeferredChecks := 0;
  Item.StableTicks := 0;
  Item.CloseAttempted := False;
  Item.SettleTicks := 0;
  Item.AttemptFailed := False;
  FPendingProjectCloses.Add(Item);
  WriteLog('Queued experimental hidden-module close: ' + Item.ProjectFile);
  Result := True;
end;

procedure TDelphiCompileGateWatch.DisableExperimentalHiddenModuleClose(
  const AReason: string);
begin
  FHiddenModuleCloseFailed := True;
  FExperimentalHiddenModuleClose := False;
  WriteLog('Experimental hidden-module close disabled for this IDE session: ' +
    AReason);
end;

function TDelphiCompileGateWatch.ProcessPendingProjectCloses: Boolean;
var
  Item: TPendingProjectClose;
  CloseResult: TGeneratedModuleCloseResult;
begin
  Result := True;
  if not Assigned(FPendingProjectCloses) or
     (FPendingProjectCloses.Count = 0) then
    Exit;

  // Handle only one path per timer callback. A project-graph mutation must be
  // surrounded by complete VCL/OTA message turns, never batched with another
  // close or OpenProject call.
  Result := False;
  Item := FPendingProjectCloses[0];

  if Item.CloseAttempted then
  begin
    Inc(Item.SettleTicks);
    if Item.SettleTicks < AUTO_CLOSE_SETTLE_TICKS then
    begin
      FPendingProjectCloses[0] := Item;
      Exit;
    end;

    if not Item.AttemptFailed then
      Item.AttemptFailed := FCompiler.IsGeneratedModuleOpen(Item.ProjectFile);
    FCompiler.ReleasePendingNotifiers;
    if Item.AttemptFailed then
    begin
      WriteLog('Generated hidden module close failed and was not retried: ' +
        Item.ProjectFile);
      DisableExperimentalHiddenModuleClose('close or absence verification failed');
    end
    else
      WriteLog('Generated hidden module close settled: ' + Item.ProjectFile);
    FPendingProjectCloses.Delete(0);
    Exit;
  end;

  if not FCompiler.IsIDEQuiescentForProjectClose then
  begin
    Item.StableTicks := 0;
    Inc(Item.DeferredChecks);
    if Item.DeferredChecks >= AUTO_CLOSE_MAX_DEFERRED_CHECKS then
    begin
      WriteLog('Generated hidden module close abandoned before attempt; IDE did not become quiescent: ' +
        Item.ProjectFile);
      DisableExperimentalHiddenModuleClose('IDE did not become quiescent');
      FPendingProjectCloses.Delete(0);
      Exit;
    end;
    FPendingProjectCloses[0] := Item;
    Exit;
  end;

  Inc(Item.StableTicks);
  if Item.StableTicks < AUTO_CLOSE_STABLE_TICKS then
  begin
    FPendingProjectCloses[0] := Item;
    Exit;
  end;

  try
    CloseResult := FCompiler.TryCloseGeneratedModule(Item.ProjectFile);
  except
    on E: Exception do
    begin
      Item.CloseAttempted := True;
      Item.SettleTicks := 0;
      Item.AttemptFailed := True;
      FPendingProjectCloses[0] := Item;
      DisableExperimentalHiddenModuleClose('close preparation exception: ' +
        E.ClassName);
      WriteLog('Generated hidden module close preparation exception (not retried): ' +
        E.ClassName + ': ' + E.Message);
      Exit;
    end;
  end;
  case CloseResult of
    gmcrDeferred:
      begin
        Item.StableTicks := 0;
        Inc(Item.DeferredChecks);
        if Item.DeferredChecks >= AUTO_CLOSE_MAX_DEFERRED_CHECKS then
        begin
          WriteLog('Generated hidden module close abandoned before attempt after bounded deferrals: ' +
            Item.ProjectFile);
          DisableExperimentalHiddenModuleClose('bounded close deferrals exhausted');
          FPendingProjectCloses.Delete(0);
        end
        else
          FPendingProjectCloses[0] := Item;
      end;
    gmcrAlreadyAbsent:
      begin
        FCompiler.ReleasePendingNotifiers;
        WriteLog('Generated hidden module already absent: ' + Item.ProjectFile);
        FPendingProjectCloses.Delete(0);
      end;
    gmcrCloseRequested, gmcrAttemptFailed:
      begin
        Item.CloseAttempted := True;
        Item.SettleTicks := 0;
        Item.AttemptFailed := CloseResult = gmcrAttemptFailed;
        FPendingProjectCloses[0] := Item;
        WriteLog('Generated hidden module close invoked once; entering settle phase: ' +
          Item.ProjectFile);
      end;
  end;
end;

function TDelphiCompileGateWatch.IsGateSettingsDialogOpen: Boolean;
var
  Window: HWND;
  ProcessID: DWORD;
begin
  Result := False;
  Window := FindWindowEx(0, 0, PChar('TDelphiCompileGateSettingsForm'), nil);
  while Window <> 0 do
  begin
    ProcessID := 0;
    GetWindowThreadProcessId(Window, ProcessID);
    if (ProcessID = GetCurrentProcessId) and IsWindowVisible(Window) then
      Exit(True);
    Window := FindWindowEx(0, Window,
      PChar('TDelphiCompileGateSettingsForm'), nil);
  end;
end;

function TDelphiCompileGateWatch.HasAttemptedPendingModuleClose: Boolean;
var
  I: Integer;
begin
  Result := False;
  if not Assigned(FPendingProjectCloses) then
    Exit;
  for I := 0 to FPendingProjectCloses.Count - 1 do
    if FPendingProjectCloses[I].CloseAttempted then
      Exit(True);
end;

procedure TDelphiCompileGateWatch.SettleAttemptedModuleCloseBeforeStop;
var
  Pass: Integer;
begin
  CancelUnattemptedPendingModuleCloses;
  if not HasAttemptedPendingModuleClose then
    Exit;
  if Assigned(FTimer) then
    FTimer.Enabled := False;
  Pass := 0;
  while HasAttemptedPendingModuleClose and
        (Pass < AUTO_CLOSE_SETTLE_TICKS + 2) do
  begin
    Sleep(GetPollIntervalMs);
    Application.ProcessMessages;
    ProcessPendingProjectCloses;
    Inc(Pass);
  end;
  if HasAttemptedPendingModuleClose then
    WriteLog('Hard stop could not complete hidden-module settle phase');
end;

procedure TDelphiCompileGateWatch.CancelUnattemptedPendingModuleCloses;
var
  I: Integer;
begin
  if not Assigned(FPendingProjectCloses) then
    Exit;
  for I := FPendingProjectCloses.Count - 1 downto 0 do
    if not FPendingProjectCloses[I].CloseAttempted then
      FPendingProjectCloses.Delete(I);
end;

procedure TDelphiCompileGateWatch.ClearPendingProjectCloses;
begin
  if Assigned(FPendingProjectCloses) then
  begin
    FPendingProjectCloses.Clear;
  end;
end;

destructor TDelphiCompileGateWatch.Destroy;
begin
  if FInitialized then
    Stop;
  FreeAndNil(FTimer);
  FreeAndNil(FPendingProjectCloses);
  FreeAndNil(FCompiler);
  FreeAndNil(FLogLock);
  inherited;
end;

procedure TDelphiCompileGateWatch.Start;
begin
  if FIsRunning then Exit;
  ForceDirectories(FInputDir);
  ForceDirectories(FOutputDir);
  ForceDirectories(FProcessedDir);
  ForceDirectories(FFailedDir);
  ForceDirectories(FLogDir);
  FIsRunning := True;
  FIsBusy := False;
  FDrainRequested := False;

  // This worker is reload-only: it has no CE, legal, or unknown-dialog
  // automation and remains inactive until a v2 job commits an allowlist.
  FGlobalDialogCloser := TCompileDialogCloser.Create(OnCompilerTrace, dapReloadOnly);

  FTimer.Enabled := True;
  OutputDebugString(PChar('[DelphiCompileGate] Watch.Start enabled timer'));
  WriteLog('Watch started. Input=' + FInputDir);

  // Process queued files immediately at startup
  ProcessPending;
end;

procedure TDelphiCompileGateWatch.Stop;
begin
  SettleAttemptedModuleCloseBeforeStop;
  FIsRunning := False;
  FTimer.Enabled := False;
  FIsBusy := False;
  FDrainRequested := False;
  ClearReloadPromptPolicy;
  ClearPendingProjectCloses;

  // The reload-only worker is owned by the active watcher lifetime.
  if Assigned(FGlobalDialogCloser) then
  begin
    try
      FGlobalDialogCloser.Terminate;
      FGlobalDialogCloser.WaitFor;
    except
      on E: Exception do
        WriteLog('Dialog closer stop exception: ' + E.ClassName + ': ' + E.Message);
    end;
    FreeAndNil(FGlobalDialogCloser);
  end;

  OutputDebugString(PChar('[DelphiCompileGate] Watch.Stop'));
  WriteLog('Watch stopped (hard).');
end;

procedure TDelphiCompileGateWatch.StopGraceful;
begin
  if not FIsRunning then
  begin
    WriteLog('StopGraceful: watch not running, nothing to do.');
    Exit;
  end;
  if FDrainRequested then
  begin
    WriteLog('StopGraceful: drain already in progress.');
    Exit;
  end;

  FDrainRequested := True;
  CancelUnattemptedPendingModuleCloses;
  OutputDebugString(PChar('[DelphiCompileGate] Watch.StopGraceful drain requested'));

  if FIsBusy or (GetPendingProjectCloseCount > 0) then
    WriteLog('Watch drain requested - current job will finish, no new jobs will start.')
  else
  begin
    // No job is running, so stop cleanly immediately.
    FIsRunning := False;
    FTimer.Enabled := False;
    FDrainRequested := False;
    ClearReloadPromptPolicy;
    ClearPendingProjectCloses;
    if Assigned(FGlobalDialogCloser) then
    begin
      FGlobalDialogCloser.Terminate;
      FGlobalDialogCloser.WaitFor;
      FreeAndNil(FGlobalDialogCloser);
    end;
    WriteLog('Watch drained - safe to close IDE.');
  end;
end;

procedure TDelphiCompileGateWatch.WriteLog(const AMsg: string);
var
  LogFile: string;
  Lines: TStringList;
begin
  FLogLock.Acquire;
  try
    LogFile := IncludeTrailingPathDelimiter(FLogDir) +
      'watch_' + FormatDateTime('yyyymmdd', Now) + '.log';
    Lines := TStringList.Create;
    try
      try
        if FileExists(LogFile) then
          Lines.LoadFromFile(LogFile);
        Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AMsg);
        Lines.SaveToFile(LogFile);
      except
        // Ignore log errors
      end;
    finally
      Lines.Free;
    end;
  finally
    FLogLock.Release;
  end;
end;

procedure TDelphiCompileGateWatch.MoveToFailed(const AJobFile, AReason: string);
var
  FailedJob: string;
  ErrFile: string;
  L: TStringList;
begin
  try
    if FileExists(AJobFile) then
    begin
      FailedJob := IncludeTrailingPathDelimiter(FFailedDir) +
        ExtractFileName(AJobFile);
      if FileExists(FailedJob) then
        TFile.Delete(FailedJob);
      TFile.Move(AJobFile, FailedJob);

      ErrFile := ChangeFileExt(FailedJob, '.error.txt');
      L := TStringList.Create;
      try
        L.Add('reason=' + AReason);
        L.Add('time=' + DateTimeToStr(Now));
        L.SaveToFile(ErrFile);
      finally
        L.Free;
      end;
    end;
  except
    on E: Exception do
      WriteLog('Failed to move job to Failed folder: ' + E.Message);
  end;
end;

procedure TDelphiCompileGateWatch.ProcessV2Job(const AJobFile: string);
var
  Request: TV2Request;
  FailureCode: string;
  ResultJSON: TCompileResult;
  ResultObject: TJSONObject;
  WrapperProject: string;
  WrapperMainSource: string;
  SelectedPlatform: string;
  SelectedConfiguration: string;
  CompilePlatform: string;
  CompileConfiguration: string;
  CompileEvidenceAvailable: Boolean;
  CompileSucceeded: Boolean;
  DialogHits: Integer;
  DialogCloseAttempts: Integer;
  KnownTechnicalDialogHits: Integer;
  ExceptionsSwallowed: Integer;
  LicenseOrEulaDetected: Boolean;
  UnknownDialogDetected: Boolean;
  LegalNoticeEvidence: TLegalNoticeEvidence;
  Destination: string;
  ExistingProcessed: string;
  ExistingFailed: string;
  ExistingWrapper: string;
  ReloadPolicyCommitted: Boolean;
  JobPublished: Boolean;
begin
  // A new v2 job invalidates the previous authorization until this job has
  // produced its wrapper and committed a fresh immutable allowlist.
  ClearReloadPromptPolicy;
  ReloadPolicyCommitted := False;
  JobPublished := False;
  WrapperProject := '';
  WrapperMainSource := '';
  ResultJSON := Default(TCompileResult);
  SelectedPlatform := '';
  SelectedConfiguration := '';
  CompilePlatform := '';
  CompileConfiguration := '';
  CompileEvidenceAvailable := False;
  CompileSucceeded := False;
  DialogHits := 0;
  DialogCloseAttempts := 0;
  KnownTechnicalDialogHits := 0;
  ExceptionsSwallowed := 0;
  LicenseOrEulaDetected := False;
  UnknownDialogDetected := False;
  LegalNoticeEvidence := Default(TLegalNoticeEvidence);
  Request := nil;
  ResultObject := nil;
  try
    Destination := IncludeTrailingPathDelimiter(FOutputDir) +
      ChangeFileExt(ChangeFileExt(ExtractFileName(AJobFile), ''), '') + '.json';
    if FileExists(Destination) then
    begin
      MoveToFailed(AJobFile, 'preexisting_job_state');
      Exit;
    end;

    if not TryLoadV2Request(AJobFile, Request, FailureCode) then
    begin
      if Assigned(Request) and (Request.JobId <> '') and (Request.Nonce <> '') and
         (Request.RequestHash <> '') and (Request.Platform <> '') and
         (Request.Configuration <> '') then
      begin
        ResultObject := BuildV2Failure(Request, FailureCode);
        WriteJSONAtomic(Request.JobId, ResultObject.ToJSON);
      end;
      MoveToFailed(AJobFile, FailureCode);
      Exit;
    end;

    ExistingProcessed := IncludeTrailingPathDelimiter(FProcessedDir) +
      ExtractFileName(AJobFile);
    ExistingFailed := IncludeTrailingPathDelimiter(FFailedDir) +
      ExtractFileName(AJobFile);
    ExistingWrapper := TPath.Combine(TPath.Combine(ExtractFileDir(FInputDir),
      'Projects'), Request.JobId);
    if FileExists(ExistingProcessed) or FileExists(ExistingFailed) or
       DirectoryExists(ExistingWrapper) then
    begin
      ResultObject := BuildV2Failure(Request, 'preexisting_job_state');
      WriteJSONAtomic(Request.JobId, ResultObject.ToJSON);
      if FileExists(ExistingFailed) then
        TFile.Delete(AJobFile)
      else
        MoveToFailed(AJobFile, 'preexisting_job_state');
      Exit;
    end;

    if not CanProcessNow then Exit;
    if not VerifyV2InputEvidence(Request) then
    begin
      ResultObject := BuildV2Failure(Request, 'input_hash_mismatch');
      WriteJSONAtomic(Request.JobId, ResultObject.ToJSON);
      MoveToFailed(AJobFile, 'input_hash_mismatch');
      Exit;
    end;
    try
      // V2 starts policy-based dialog automation before OpenProject. Technical
      // closures are evidence; legal or unknown dialogs remain fail-closed.
      ResultJSON := FCompiler.ValidateProjectWrapperV2(Request.Project.Path,
        Request.MainSource.Path, Request.JobId, Request.Platform,
        Request.Configuration, WrapperProject, WrapperMainSource,
        SelectedPlatform, SelectedConfiguration, CompilePlatform,
        CompileConfiguration, CompileEvidenceAvailable, CompileSucceeded,
        Request.Project.Size, Request.MainSource.Size, Request.Project.SHA256,
        Request.MainSource.SHA256, DialogHits, DialogCloseAttempts,
        KnownTechnicalDialogHits, ExceptionsSwallowed, LicenseOrEulaDetected,
        UnknownDialogDetected, LegalNoticeEvidence);
      ResultObject := BuildV2Result(Request, ResultJSON, WrapperProject,
        WrapperMainSource, SelectedPlatform, SelectedConfiguration,
        CompilePlatform, CompileConfiguration, CompileEvidenceAvailable,
        CompileSucceeded, DialogHits, DialogCloseAttempts,
        KnownTechnicalDialogHits, ExceptionsSwallowed, LicenseOrEulaDetected,
        UnknownDialogDetected, LegalNoticeEvidence, '');
    except
      on E: Exception do
      begin
        WriteLog(Format('Protocol v2 job %s exception: %s: %s',
          [Request.JobId, E.ClassName, E.Message]));
        if E.Message = 'dialog_blocked' then
          FailureCode := 'dialog_blocked'
        else if E.Message = 'dialog_closer_stop_timeout' then
          FailureCode := 'dialog_closer_stop_timeout'
        else if E.Message = 'message_capture_unavailable' then
          FailureCode := 'message_capture_unavailable'
        else if E.Message = 'compile_error_details_unavailable' then
          FailureCode := 'compile_error_details_unavailable'
        else if (E.Message = 'source_buffer_mismatch') or
           (E.Message = 'source_buffer_unverified') then
          FailureCode := E.Message
        else if E.Message = 'wrapper_project_invalid' then
          FailureCode := 'wrapper_project_invalid'
        else if E.Message = 'source_only_main_kind_unsupported' then
          FailureCode := 'source_only_main_kind_unsupported'
        else if E.Message = 'unit_search_path_unavailable' then
          FailureCode := 'unit_search_path_unavailable'
        else if E.Message = 'unit_search_path_invalid' then
          FailureCode := 'unit_search_path_invalid'
        else if (E.Message = 'project_builder_unavailable') or
            (E.Message = 'compile_notifier_unavailable') or
            (E.Message = 'target_selection_unavailable') then
          FailureCode := 'target_evidence_unavailable'
        else if (E.Message = 'preexisting_wrapper_directory') or
           (E.Message = 'wrapper_project_invalid') or
           (E.Message = 'input_hash_mismatch') or
           (E.Message = 'input_hash_changed') then
          FailureCode := E.Message
        else
          FailureCode := 'runtime_failure';
        ResultObject := BuildV2Result(Request, ResultJSON, WrapperProject,
          WrapperMainSource, SelectedPlatform, SelectedConfiguration,
          CompilePlatform, CompileConfiguration, CompileEvidenceAvailable,
          CompileSucceeded, DialogHits, DialogCloseAttempts,
          KnownTechnicalDialogHits, ExceptionsSwallowed,
          LicenseOrEulaDetected, UnknownDialogDetected,
          LegalNoticeEvidence, FailureCode);
      end;
    end;
    WriteJSONAtomic(Request.JobId, ResultObject.ToJSON);

    Destination := IncludeTrailingPathDelimiter(FProcessedDir) + ExtractFileName(AJobFile);
    if FileExists(Destination) then TFile.Delete(Destination);
    TFile.Move(AJobFile, Destination);
    JobPublished := True;
    if CanCommitReloadPromptPolicy(Request, ResultObject) then
    begin
      CommitReloadPromptPolicy(Request.JobId, Request.Nonce,
        Request.MainSource.Path, WrapperMainSource);
      ReloadPolicyCommitted := True;
    end
    else
      WriteLog('Reload policy not committed: V2 result is not reload-authorized for job ' +
        Request.JobId);
  finally
    // Queue only the path. The compile routine has returned, so all project and
    // project-builder interfaces are out of scope before later timer ticks
    // reacquire the never-shown module and invoke CloseModule exactly once.
    // Failed wrappers stay open during this initial experimental phase.
    if JobPublished and Assigned(ResultObject) and
       ((SameText(ResultObject.GetStringDef('status', ''), 'ok') and
         ResultObject.GetBoolDef('success', False)) or
        IsCompileFailureResult(ResultObject)) then
      QueueGeneratedProjectClose(WrapperProject)
    else if WrapperProject <> '' then
      WriteLog('Experimental hidden-module close skipped for non-compile result: ' +
        WrapperProject);
    if not ReloadPolicyCommitted then
      ClearReloadPromptPolicy;
    ResultObject.Free;
    Request.Free;
  end;
end;

procedure TDelphiCompileGateWatch.ProcessInputQueue;
var
  Jobs: TArray<string>;
begin
  if IsGateSettingsDialogOpen then
  begin
    if not FQueueDeferredBySettings then
    begin
      WriteLog('Input queue deferred while Gate settings dialog is open');
      FQueueDeferredBySettings := True;
    end;
    Exit;
  end;
  if FQueueDeferredBySettings then
  begin
    WriteLog('Input queue resumed after Gate settings dialog closed');
    FQueueDeferredBySettings := False;
  end;

  Jobs := TDirectory.GetFiles(FInputDir, '*.job.json');
  if Length(Jobs) > 0 then
  begin
    try
      ProcessV2Job(Jobs[0]);
    except
      on E: Exception do
      begin
        // A parallel client can remove a manifest after enumeration. Every
        // other failure is terminal for that immutable job: quarantine it so
        // one unsupported/corrupt request cannot starve the complete queue.
        if not FileExists(Jobs[0]) then
          WriteLog('Job manifest disappeared before dispatch: ' +
            ExtractFileName(Jobs[0]))
        else
        begin
          WriteLog('Job manifest dispatch failed; quarantining ' +
            ExtractFileName(Jobs[0]) + ': ' + E.ClassName + ': ' + E.Message);
          MoveToFailed(Jobs[0], E.Message);
        end;
      end;
    end;
  end;
end;

function TDelphiCompileGateWatch.CanProcessNow: Boolean;
var
  CompileServices: IOTACompileServices;
begin
  Result := True;
  if Supports(BorlandIDEServices, IOTACompileServices, CompileServices) then
  begin
    if CompileServices.IsBackgroundCompileActive then
      Exit(False);
  end;
end;

procedure TDelphiCompileGateWatch.ProcessPending;
begin
  OutputDebugString(PChar('[DelphiCompileGate] ProcessPending'));
  ProcessInputQueue;
end;

procedure TDelphiCompileGateWatch.WriteJSONAtomic(const AOutputName,
  AJSON: string);
var
  JSONFile: string;
  TempFile: string;
  Token: TGUID;
begin
  JSONFile := IncludeTrailingPathDelimiter(FOutputDir) + AOutputName + '.json';
  CreateGUID(Token);
  TempFile := IncludeTrailingPathDelimiter(FOutputDir) + '.' + AOutputName + '.' +
    StringReplace(GUIDToString(Token), '-', '', [rfReplaceAll]) + '.tmp';
  try
    TFile.WriteAllBytes(TempFile, TEncoding.UTF8.GetBytes(AJSON));
    if not MoveFileEx(PChar(TempFile), PChar(JSONFile),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
  except
    on E: Exception do
    begin
      if FileExists(TempFile) then TFile.Delete(TempFile);
      WriteLog('ERROR: failed to atomically write result JSON ' + JSONFile +
        ' - ' + E.ClassName + ': ' + E.Message);
      raise;
    end;
  end;
end;

procedure TDelphiCompileGateWatch.OnTimer(Sender: TObject);
begin
  OutputDebugString(PChar('[DelphiCompileGate] OnTimer tick'));
  if not FIsRunning then Exit;
  if FIsBusy then Exit;

  // Do not start another job after a drain has been requested.
  if FDrainRequested then
  begin
    if GetPendingProjectCloseCount > 0 then
    begin
      ProcessPendingProjectCloses;
      Exit;
    end;
    FIsRunning := False;
    FTimer.Enabled := False;
    FDrainRequested := False;
    ClearReloadPromptPolicy;
    ClearPendingProjectCloses;
    if Assigned(FGlobalDialogCloser) then
    begin
      FGlobalDialogCloser.Terminate;
      FGlobalDialogCloser.WaitFor;
      FreeAndNil(FGlobalDialogCloser);
    end;
    WriteLog('Watch drained - safe to close IDE.');
    Exit;
  end;

  FIsBusy := True;

  // Prevent re-entrant timer execution while compile is running
  FTimer.Enabled := False;

  try
    try
      if not CanProcessNow then
      begin
        WriteLog('Skip tick: IDE compile still active');
        Exit;
      end;

      // Generated projects are closed only after the compile call stack has
      // returned and the IDE has processed at least one timer/message turn.
      // Do not open another wrapper while a bounded close retry is pending.
      if not ProcessPendingProjectCloses then
        Exit;

      ProcessPending;
    except
      on E: Exception do
        WriteLog('Timer error: ' + E.Message);
    end;
  finally
    FIsBusy := False;

    // If a drain was requested during the job, stop cleanly now.
    if FDrainRequested then
    begin
      FIsRunning := False;
      FTimer.Enabled := False;
      FDrainRequested := False;
      ClearReloadPromptPolicy;
      ClearPendingProjectCloses;
      if Assigned(FGlobalDialogCloser) then
      begin
        FGlobalDialogCloser.Terminate;
        FGlobalDialogCloser.WaitFor;
        FreeAndNil(FGlobalDialogCloser);
      end;
      WriteLog('Watch drained - safe to close IDE.');
    end
    else if FIsRunning then
      FTimer.Enabled := True;
  end;
end;

end.
