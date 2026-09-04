unit DelphiCompileGate.Compiler;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections,
  System.Character,
  System.SyncObjs,
  Winapi.Windows,
  Vcl.Forms,
  ToolsAPI;

type
  TCompilerTraceProc = procedure(const AMsg: string) of object;

  TDialogAutomationPolicy = (dapProtocolV2, dapReloadOnly);

  TGeneratedModuleCloseResult = (gmcrDeferred, gmcrAlreadyAbsent,
    gmcrCloseRequested, gmcrAttemptFailed);

  TLegalNoticeEvidence = record
    Detected: Boolean;
    Classification: string;
    WindowClass: string;
    Title: string;
    TextAvailable: Boolean;
    Text: string;
    TextLength: Integer;
    TextSHA256: string;
    Action: string;
    Button: string;
    AcceptedTerms: Boolean;
  end;

  TCompileError = record
    FileName: string;
    Line: Integer;
    Column: Integer;
    ErrorCode: string;
    ErrorText: string;
    IsWarning: Boolean;
    // New normalized metadata for locale-independent training.
    Source: string;             // compiler | dfm_reader | watcher
    Kind: string;               // stable semantic label
    CanonicalCode: string;      // stable code (E2003 / DFM_INVALID_PROPERTY / ...)
    CanonicalMessageEn: string; // normalized English message
    RawText: string;            // original Delphi message (localized)
    Locale: string;             // e.g. de-DE, en-US
    function ToJSON: string;
  end;

  TCompileResult = record
    Success: Boolean;
    Errors: TArray<TCompileError>;
    OutputEXE: string;
    CompileTimeMs: Integer;
  end;

  // Policy-bound worker for protocol-v2 build dialogs or authenticated reload
  // prompts. It never performs generic dialog dismissal.
  TCompileDialogCloser = class(TThread)
  private
    FDialogHits: Integer;
    FDialogCloseAttempts: Integer;
    FKnownTechnicalDialogHits: Integer;
    FLicenseOrEulaDetected: Boolean;
    FUnknownDialogDetected: Boolean;
    FLegalNoticeEvidence: TLegalNoticeEvidence;
    FBlockLock: TCriticalSection;
    FBlockReason: string;
    FBlockDeadlineTick: Cardinal;
    FBlockDeadlineRecorded: Boolean;
    FPolicy: TDialogAutomationPolicy;
    FAllowedReloadFiles: TArray<string>;
    FReloadJobId: string;
    FReloadToken: string;
    FReloadExpiryTick: Cardinal;
    FReloadPolicyRevision: Cardinal;
    FOnTrace: TCompilerTraceProc;
    class function EnumWindowsProc(AWnd: HWND; LParam: LPARAM): BOOL; stdcall; static;
    procedure Trace(const AMsg: string);
    procedure TryDismissWindow(const AWnd: HWND);
    procedure TryDismissWindowV2(const AWnd: HWND);
    procedure TryDismissDialogs;
    procedure SetBlockReason(const AReason: string);
    function GetBlockReason: string;
    procedure MarkBlockDeadlineExceeded;
    function GetBlockDeadlineExceeded: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AOnTrace: TCompilerTraceProc;
      const APolicy: TDialogAutomationPolicy;
      const AAllowedReloadFiles: TArray<string> = nil);
    destructor Destroy; override;
    procedure UpdateReloadPolicy(const AJobId, AToken: string;
      const AAllowedReloadFiles: TArray<string>; const AExpiryTick: Cardinal);
    procedure ClearReloadPolicy;
    function StopAndWait(const ATimeoutMs: Cardinal): Boolean;
    property DialogHits: Integer read FDialogHits;
    property DialogCloseAttempts: Integer read FDialogCloseAttempts;
    property KnownTechnicalDialogHits: Integer read FKnownTechnicalDialogHits;
    property LicenseOrEulaDetected: Boolean read FLicenseOrEulaDetected;
    property UnknownDialogDetected: Boolean read FUnknownDialogDetected;
    property LegalNoticeEvidence: TLegalNoticeEvidence
      read FLegalNoticeEvidence;
    property BlockReason: string read GetBlockReason;
    property BlockDeadlineExceeded: Boolean read GetBlockDeadlineExceeded;
  end;

  TDelphiCompileGateCompiler = class
  private
    FOnTrace: TCompilerTraceProc;
    FPendingNotifiers: TList<IOTACompileNotifier>;
    FPendingProjectCompileNotifiers: TList<IOTAProjectCompileNotifier>;
    FNotifierLifetimeCompromised: Boolean;
    FBackgroundCompileTimeoutMs: Cardinal;
    procedure SetBackgroundCompileTimeoutMs(const AValue: Cardinal);
    procedure DrainPendingNotifiers;
    function GetCompileServices: IOTACompileServices;
    function WaitForBackgroundCompile(const ACompileServices: IOTACompileServices;
      const ATimeoutMs: Cardinal): Boolean;
    procedure CollectErrorsFromIDE(out AErrors: TArray<TCompileError>);
    procedure PopulateDiagnosticMetadata(var AError: TCompileError);
    function CurrentLocaleTag: string;
    procedure Trace(const AMsg: string);
    procedure CreateMinimalWrapperDproj(const AWrapperDproj,
      AWrapperMainSource, AOriginalSourceDir, APlatform,
      AConfiguration: string; const AIsPackage: Boolean);
    function BuildProjectWrapper(const AProjectFile, ADprFile, AJobId: string;
      const APlatform, AConfiguration: string): string;
    function DeriveWrapperCaptureSourceRoot(const AProjectFile, AOriginalDpr,
      AWrapperDpr: string): string;
    function CollectWrapperCaptureSourceFiles(const AOriginalDpr,
      AWrapperDpr: string): TArray<string>;
    function MakeDprReferencesAbsolute(const ADprText, ASourceDir: string): string;
    function MakeDprResourceReferencesAbsolute(const ADprText, ASourceDpr: string): string;
    function MakeDprojReferencesAbsolute(const ADprojText, ASourceDir,
      AWrapperDir: string): string;
    function SanitizeWrapperDprojSources(const ADprojText,
      AWrapperMainSource: string): string;
    procedure ValidateWrapperDproj(const AWrapperDproj,
      AWrapperMainSource: string);
    procedure EnsureSourceBuffersMatchDisk(const AModuleServices: IOTAModuleServices;
      const ASourceFiles: TArray<string>);
    function FindWrapperOutputEXE(const ASourceDpr, AWrapperProject,
      AJobId: string): string;
    function ValidateDprProject(const ADprFile, ASourceName,
      AOriginalDprFile: string;
      const APlatform, AConfiguration: string;
      out ASelectedPlatform,
      ASelectedConfiguration, ACompilePlatform, ACompileConfiguration: string;
      out ACompileEvidenceAvailable, ACompileSucceeded: Boolean;
       out ADialogHits, ADialogCloseAttempts, AKnownTechnicalDialogHits,
       AExceptionsSwallowed: Integer; out ALicenseOrEulaDetected,
       AUnknownDialogDetected: Boolean;
       out ALegalNoticeEvidence: TLegalNoticeEvidence): TCompileResult;
  public
    constructor Create;
    destructor Destroy; override;
    function ValidateProjectWrapperV2(const AProjectFile, ADprFile, AJobId,
      APlatform, AConfiguration: string; out AWrapperProject,
      AWrapperMainSource, ASelectedPlatform, ASelectedConfiguration,
      ACompilePlatform, ACompileConfiguration: string;
      out ACompileEvidenceAvailable, ACompileSucceeded: Boolean;
      const AExpectedProjectSize, AExpectedMainSourceSize: Int64;
      const AExpectedProjectHash, AExpectedMainSourceHash: string;
       out ADialogHits, ADialogCloseAttempts, AKnownTechnicalDialogHits,
       AExceptionsSwallowed: Integer; out ALicenseOrEulaDetected,
       AUnknownDialogDetected: Boolean;
       out ALegalNoticeEvidence: TLegalNoticeEvidence): TCompileResult;
    function CollectWrapperReloadAllowedFiles(const AOriginalDpr,
      AWrapperDpr: string): TArray<string>;
    function IsIDEQuiescentForProjectClose: Boolean;
    function IsGeneratedModuleOpen(const AProjectFile: string): Boolean;
    function TryCloseGeneratedModule(
      const AProjectFile: string): TGeneratedModuleCloseResult;
    procedure ReleasePendingNotifiers;
    property BackgroundCompileTimeoutMs: Cardinal
      read FBackgroundCompileTimeoutMs write SetBackgroundCompileTimeoutMs;
    property OnTrace: TCompilerTraceProc read FOnTrace write FOnTrace;
  end;

function ResolveDelphiCompileGateBaseDir: string;

implementation

uses
  Winapi.Messages, Winapi.ActiveX, System.DateUtils, System.StrUtils,
  System.Hash, System.Variants, Xml.XMLDoc, Xml.XMLIntf,
  DelphiCompileGate.Consts,
  DelphiCompileGate.MessageHook;

const
  V2_DIALOG_BLOCK_TIMEOUT_MS = 30000; // Evidence deadline only; never force-closes unsafe modals.
  DEFAULT_WRAPPER_MAX_AGE_DAYS = 2;

type
  TCompileWaitNotifier = class(TInterfacedObject, IOTACompileNotifier)
  private
    FDprFile: string;
    FDprojFile: string;
    FHasResult: Boolean;
    FCompileResult: TOTACompileResult;
    FActive: Boolean;
    function MatchesProject(const AProject: IOTAProject): Boolean;
  public
    constructor Create(const ADprFile: string);
    procedure Deactivate;
    procedure ProjectCompileStarted(const Project: IOTAProject; Mode: TOTACompileMode);
    procedure ProjectCompileFinished(const Project: IOTAProject; Result: TOTACompileResult);
    procedure ProjectGroupCompileStarted(Mode: TOTACompileMode);
    procedure ProjectGroupCompileFinished(Result: TOTACompileResult);
    property HasResult: Boolean read FHasResult;
    property CompileResult: TOTACompileResult read FCompileResult;
  end;

  TProjectCompileEvidenceNotifier = class(TInterfacedObject, IOTAProjectCompileNotifier)
  private
    FActive: Boolean;
    FAfterSeen: Boolean;
    FPlatform: string;
    FConfiguration: string;
    FResult: Boolean;
  public
    constructor Create;
    procedure Deactivate;
    procedure BeforeCompile(var CompileInfo: TOTAProjectCompileInfo);
    procedure AfterCompile(var CompileInfo: TOTAProjectCompileInfo);
    procedure Destroyed;
    property AfterSeen: Boolean read FAfterSeen;
    property Platform: string read FPlatform;
    property Configuration: string read FConfiguration;
    property CompileSucceeded: Boolean read FResult;
  end;

function ResolveDelphiCompileGateBaseDir: string;
var
  LocalRoot: string;
  TempRoot: string;
  UserProfile: string;
begin
  Result := Trim(GetEnvironmentVariable('DELPHI_COMPILE_GATE_BASE_DIR'));
  if Result <> '' then
    Exit;

  LocalRoot := Trim(GetEnvironmentVariable('LOCALAPPDATA'));
  if LocalRoot = '' then
  begin
    UserProfile := Trim(GetEnvironmentVariable('USERPROFILE'));
    if UserProfile <> '' then
      LocalRoot := TPath.Combine(TPath.Combine(UserProfile, 'AppData'), 'Local')
    else
    begin
      TempRoot := Trim(GetEnvironmentVariable('TEMP'));
      if TempRoot <> '' then
        LocalRoot := TempRoot
      else
        LocalRoot := TPath.GetTempPath;
    end;
  end;

  Result := TPath.Combine(TPath.Combine(LocalRoot, 'DelphiCompileGate'), 'Run');
end;

{ TCompileError }

constructor TCompileDialogCloser.Create(const AOnTrace: TCompilerTraceProc;
  const APolicy: TDialogAutomationPolicy; const AAllowedReloadFiles: TArray<string>);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOnTrace := AOnTrace;
  FPolicy := APolicy;
  FAllowedReloadFiles := Copy(AAllowedReloadFiles);
  FReloadJobId := '';
  FReloadToken := '';
  FReloadExpiryTick := 0;
  FReloadPolicyRevision := 0;
  FDialogHits := 0;
  FDialogCloseAttempts := 0;
  FKnownTechnicalDialogHits := 0;
  FLicenseOrEulaDetected := False;
  FUnknownDialogDetected := False;
  FLegalNoticeEvidence := Default(TLegalNoticeEvidence);
  FBlockLock := TCriticalSection.Create;
  FBlockReason := '';
  FBlockDeadlineTick := GetTickCount + V2_DIALOG_BLOCK_TIMEOUT_MS;
  FBlockDeadlineRecorded := False;
  Resume;
end;

destructor TCompileDialogCloser.Destroy;
begin
  Terminate;
  if Suspended then
    Resume;
  if GetCurrentThreadId <> ThreadID then
    WaitFor;
  FBlockLock.Free;
  inherited;
end;

procedure TCompileDialogCloser.Trace(const AMsg: string);
begin
  if Assigned(FOnTrace) then
    FOnTrace('[DialogCloser] ' + AMsg);
end;

procedure TCompileDialogCloser.SetBlockReason(const AReason: string);
begin
  FBlockLock.Enter;
  try
    if FBlockReason = '' then
      FBlockReason := AReason;
  finally
    FBlockLock.Leave;
  end;
end;

function TCompileDialogCloser.GetBlockReason: string;
begin
  FBlockLock.Enter;
  try
    Result := FBlockReason;
  finally
    FBlockLock.Leave;
  end;
end;

procedure TCompileDialogCloser.MarkBlockDeadlineExceeded;
begin
  FBlockLock.Enter;
  try
    FBlockDeadlineRecorded := True;
  finally
    FBlockLock.Leave;
  end;
end;

function TCompileDialogCloser.GetBlockDeadlineExceeded: Boolean;
begin
  FBlockLock.Enter;
  try
    Result := FBlockDeadlineRecorded;
  finally
    FBlockLock.Leave;
  end;
end;

class function TCompileDialogCloser.EnumWindowsProc(AWnd: HWND; LParam: LPARAM): BOOL;
var
  Closer: TCompileDialogCloser;
begin
  Closer := TCompileDialogCloser(Pointer(LParam));
  if Assigned(Closer) then
    Closer.TryDismissWindow(AWnd);
  Result := True;
end;

procedure TCompileDialogCloser.TryDismissWindow(const AWnd: HWND);
begin
  TryDismissWindowV2(AWnd);
end;

procedure TCompileDialogCloser.TryDismissWindowV2(const AWnd: HWND);
var
  ProcessID: DWORD;
  ClassBuf: array[0..127] of Char;
  WindowClass: string;
  OwnerWnd: HWND;
  OwnerProcessID: DWORD;
  HasModalOwner: Boolean;
  IsKnownTechnical: Boolean;
  IsLegal: Boolean;
  IsDialogCandidate: Boolean;
  ButtonWnd: HWND;
  UnsafeButtonWnd: HWND;
  ButtonText: string;
  UnsafeButtonText: string;
  NoticeCaption: string;
  NoticeCaptionLength: Integer;
  ReloadText: string;
  ReloadPath: string;
  ReloadPolicyActive: Boolean;
  ReloadJobId: string;
  ReloadToken: string;
  ReloadRevision: Cardinal;

const
  MAX_RECURSIVE_DEPTH = 16;

  function NormalizedButtonText(const AText: string): string;
  begin
    Result := LowerCase(Trim(StringReplace(AText, '&', '', [rfReplaceAll])));
  end;

  function TextMatches(const AText: string; const AValues: array of string): Boolean;
  var
    I: Integer;
    Normalized: string;
  begin
    Normalized := NormalizedButtonText(AText);
    for I := Low(AValues) to High(AValues) do
      if Normalized = AValues[I] then
        Exit(True);
    Result := False;
  end;

  function IsLegalText(const AText: string): Boolean;
  var
    L: string;
  begin
    L := LowerCase(AText);
    // German terms are localized Delphi 13 input fingerprints. Keep them
    // alongside the English fingerprints; they are never emitted as output.
    Result :=
      (Pos('end user license', L) > 0) or
      (Pos('license agreement', L) > 0) or
      (Pos('licence agreement', L) > 0) or
      (Pos('software license', L) > 0) or
      (Pos('license', L) > 0) or
      (Pos('licence', L) > 0) or
      (Pos('eula', L) > 0) or
      (Pos('lizenz', L) > 0) or
      (Pos('lizenzvereinbarung', L) > 0) or
      (Pos('lizenzbedingungen', L) > 0) or
      (Pos('nutzungsbedingungen', L) > 0) or
      (Pos('terms and conditions', L) > 0) or
      (Pos('terms & conditions', L) > 0) or
      (Pos('terms of use', L) > 0) or
      (Pos('terms of service', L) > 0) or
      (Pos('i agree', L) > 0) or
      (Pos('ich stimme zu', L) > 0) or
      TextMatches(AText, ['accept', 'akzeptieren', 'nicht akzeptieren',
        'ablehnen', 'decline', 'reject']);
  end;

  function IsBuildResultText(const AText: string): Boolean;
  var
    L: string;
  begin
    L := LowerCase(AText);
    // German terms are localized Delphi 13 input fingerprints only.
    Result :=
      ((Pos('fehlgeschlagen', L) > 0) or
       (Pos('fehler sind aufgetreten', L) > 0) or
       (Pos('erfolgreich', L) > 0) or
       (Pos('failed', L) > 0) or
       (Pos('errors occurred', L) > 0) or
       (Pos('successful', L) > 0) or
       (Pos('succeeded', L) > 0)) and
      ((Pos('build-konfiguration', L) > 0) or
       (Pos('build configuration', L) > 0)) and
      ((Pos('plattform', L) > 0) or (Pos('platform', L) > 0)) and
      ((Pos('projekt', L) > 0) or (Pos('project', L) > 0)) and
      ((Pos('fehler', L) > 0) or (Pos('errors', L) > 0)) and
      ((Pos('warnungen', L) > 0) or (Pos('warnings', L) > 0));
  end;

  function IsReloadDeniedText(const AText: string): Boolean;
  var
    L: string;
  begin
    L := LowerCase(AText);
    // German terms are localized Delphi 13 input fingerprints only.
    Result := (Pos('license', L) > 0) or (Pos('licence', L) > 0) or
      (Pos('eula', L) > 0) or (Pos('lizenz', L) > 0) or
      (Pos('save', L) > 0) or (Pos('speichern', L) > 0) or
      (Pos('discard', L) > 0) or (Pos('verwerfen', L) > 0) or
      (Pos('delete', L) > 0) or (Pos('l' + #$00F6 + 'schen', L) > 0) or
      (Pos('loeschen', L) > 0) or (Pos('overwrite', L) > 0) or
      (Pos(#$00FC + 'berschreiben', L) > 0) or
      (Pos('ueberschreiben', L) > 0) or
      (Pos('credential', L) > 0) or (Pos('password', L) > 0) or
      (Pos('kennwort', L) > 0) or (Pos('close', L) > 0) or
      (Pos('schlie' + #$00DF + 'en', L) > 0) or
      (Pos('schliessen', L) > 0);
  end;

  function CollectBoundedText(const AParent: HWND; const ADepth: Integer;
    var AText: string): Boolean;
  const MAX_RELOAD_TEXT = 4096;
  var Child: HWND; TextLen: Integer; Text: string;
  begin
    Result := True;
    if (ADepth > MAX_RECURSIVE_DEPTH) or (Length(AText) >= MAX_RELOAD_TEXT) then Exit;
    TextLen := GetWindowTextLength(AParent);
    if TextLen > 0 then
    begin
      SetLength(Text, TextLen);
      GetWindowText(AParent, PChar(Text), TextLen + 1);
      AText := Copy(AText + #10 + Text, 1, MAX_RELOAD_TEXT);
    end;
    Child := FindWindowEx(AParent, 0, nil, nil);
    while Child <> 0 do
    begin
      CollectBoundedText(Child, ADepth + 1, AText);
      Child := FindWindowEx(AParent, Child, nil, nil);
    end;
  end;

  function IsStrictReloadPromptText(const AText: string): Boolean;
  var L: string;
  begin
    L := LowerCase(AText);
    // German terms are localized Delphi 13 reload-dialog fingerprints only.
    Result := not IsReloadDeniedText(L) and
      (((Pos('changed outside the source editor', L) > 0) and
        (Pos('reload', L) > 0)) or
        ((Pos('bei modul ', L) > 0) and
         (Pos('wurden ' + #$00E4 + 'nderungen festgestellt', L) > 0) and
         (Pos('neu laden', L) > 0)) or
        ((Pos('bei modul ', L) > 0) and
         (Pos('wurden ' + #$00E4 +
           'nderungen auf der festplatte festgestellt', L) > 0) and
         (Pos('auch im hauptspeicher wurde dieses modul ge' + #$00E4 +
           'ndert', L) > 0) and
         (Pos('erneut laden', L) > 0)) or
         ((Pos('au' + #$00DF + 'erhalb des quelltexteditors ge' + #$00E4 +
           'ndert', L) > 0) and
        (Pos('neu laden', L) > 0)) or
       ((Pos('ausserhalb des quelltexteditors geaendert', L) > 0) and
        (Pos('neu laden', L) > 0)));
  end;

  function ResolveAllowedReloadPath(const AText: string; out APath, AJobId,
    AToken: string; out ARevision: Cardinal): Boolean;
  var
    I, TokenPos: Integer;
    Candidate, NormalizedText, NormalizedCandidate: string;
    AllowedFiles: TArray<string>;

    function NormalizePathToken(const AValue: string): string;
    begin
      Result := LowerCase(Trim(StringReplace(AValue, '/', '\\', [rfReplaceAll])));
    end;

    function IsAllowedPathBoundary(const AChar: Char): Boolean;
    begin
      // Whitelist display delimiters instead of trying to enumerate every
      // Windows filename/path continuation character.
      Result := TCharacter.IsWhiteSpace(AChar) or
        (AChar in ['"', '''', '(', ')', '[', ']', '{', '}', ',', ';', '=']);
    end;

    function HasBoundedToken(const AToken: string): Boolean;
    var
      SearchAt: Integer;
      AfterToken: Integer;
    begin
      Result := False;
      SearchAt := 1;
      while SearchAt <= Length(NormalizedText) do
      begin
        TokenPos := PosEx(AToken, NormalizedText, SearchAt);
        if TokenPos = 0 then
          Exit;
        AfterToken := TokenPos + Length(AToken);
        if ((TokenPos = 1) or IsAllowedPathBoundary(NormalizedText[TokenPos - 1])) and
           ((AfterToken > Length(NormalizedText)) or
              IsAllowedPathBoundary(NormalizedText[AfterToken])) then
          Exit(True);
        SearchAt := TokenPos + 1;
      end;
    end;
  begin
    Result := False;
    APath := '';
    AJobId := '';
    AToken := '';
    ARevision := 0;
    NormalizedText := NormalizePathToken(AText);
    FBlockLock.Enter;
    try
      if (FReloadJobId = '') or (FReloadToken = '') or (FReloadExpiryTick = 0) or
         (Integer(GetTickCount - FReloadExpiryTick) >= 0) then
        Exit;
      AllowedFiles := Copy(FAllowedReloadFiles);
      AJobId := FReloadJobId;
      AToken := FReloadToken;
      ARevision := FReloadPolicyRevision;
    finally
      FBlockLock.Leave;
    end;
    for I := 0 to High(AllowedFiles) do
    begin
      if not TPath.IsPathRooted(AllowedFiles[I]) then
        Continue;
      Candidate := ExpandFileName(Trim(StringReplace(AllowedFiles[I], '"', '', [rfReplaceAll])));
      NormalizedCandidate := NormalizePathToken(Candidate);
      if (NormalizedCandidate <> '') and HasBoundedToken(NormalizedCandidate) then
      begin
        APath := Candidate;
        Exit(True);
      end;
    end;
    APath := '';
    AJobId := '';
    AToken := '';
    ARevision := 0;
  end;

  function ReloadPolicyMatchesLocked(const APath, AJobId, AToken: string;
    const ARevision: Cardinal): Boolean;
  var
    I: Integer;
    Candidate: string;
  begin
    Result := False;
    if (APath = '') or (AJobId = '') or (AToken = '') or
       (FReloadPolicyRevision <> ARevision) or
       not SameText(FReloadJobId, AJobId) or
       not SameText(FReloadToken, AToken) or
       (FReloadExpiryTick = 0) or
       (Integer(GetTickCount - FReloadExpiryTick) >= 0) then
      Exit;
    for I := 0 to High(FAllowedReloadFiles) do
    begin
      if not TPath.IsPathRooted(FAllowedReloadFiles[I]) then
        Continue;
      Candidate := ExpandFileName(Trim(StringReplace(FAllowedReloadFiles[I],
        '"', '', [rfReplaceAll])));
      if SameText(Candidate, APath) then
        Exit(True);
    end;
  end;

  function ReloadAuthorizationSHA256(const AJobId, AToken, APath: string;
    const ARevision: Cardinal): string;
  begin
    Result := THashSHA2.GetHashString(AJobId + #0 + AToken + #0 +
      IntToStr(ARevision) + #0 + APath);
  end;

  function FindButtonRecursive(const AParent: HWND; const ADepth: Integer;
    const AValues: array of string; out AText: string): HWND; forward;

  function HasOnlyExactOkButton: Boolean;
  const
    // Win32 BS_TYPE is not declared by every Delphi Windows unit revision.
    BS_TYPE_MASK = $000F;
  var
    VisibleEnabledButtons: Integer;
    function IsPassiveCheckbox(const AButton: HWND): Boolean;
    var Style: NativeInt; ButtonType: NativeInt;
    begin
      Style := GetWindowLong(AButton, GWL_STYLE);
      ButtonType := Style and BS_TYPE_MASK;
      Result := ButtonType in [BS_CHECKBOX, BS_AUTOCHECKBOX, BS_3STATE,
        BS_AUTO3STATE];
    end;
    function Scan(const AParent: HWND; const ADepth: Integer): Boolean;
    var
      Child: HWND;
      ClassBuf: array[0..63] of Char;
      Text: string;
      TextLen: Integer;
    begin
      Result := True;
      if ADepth > MAX_RECURSIVE_DEPTH then Exit(False);
      Child := FindWindowEx(AParent, 0, nil, nil);
      while Child <> 0 do
      begin
        ClassBuf[0] := #0;
        GetClassName(Child, ClassBuf, Length(ClassBuf));
        if (Pos('button', LowerCase(string(ClassBuf))) > 0) and
           IsWindowVisible(Child) and IsWindowEnabled(Child) then
        begin
          TextLen := GetWindowTextLength(Child);
          SetLength(Text, TextLen);
          if TextLen > 0 then
            GetWindowText(Child, PChar(Text), TextLen + 1);
          if not IsPassiveCheckbox(Child) then
          begin
            Inc(VisibleEnabledButtons);
            if not TextMatches(Text, ['ok']) then Exit(False);
          end;
        end;
        if not Scan(Child, ADepth + 1) then Exit(False);
        Child := FindWindowEx(AParent, Child, nil, nil);
      end;
    end;
  begin
    VisibleEnabledButtons := 0;
    Result := Scan(AWnd, 0) and (VisibleEnabledButtons = 1);
  end;

  function HasUnsafeAcceptanceControl(const AParent: HWND;
    const ADepth: Integer): Boolean;
  var
    Child: HWND;
    ChildClass: array[0..127] of Char;
    ControlClass: string;
    ControlText: string;
    TextLength: Integer;
  begin
    Result := False;
    if (AParent = 0) or (ADepth > MAX_RECURSIVE_DEPTH) then
      Exit;
    Child := FindWindowEx(AParent, 0, nil, nil);
    while Child <> 0 do
    begin
      ChildClass[0] := #0;
      GetClassName(Child, ChildClass, Length(ChildClass));
      ControlClass := LowerCase(string(ChildClass));
      if ((Pos('button', ControlClass) > 0) or
          (Pos('checkbox', ControlClass) > 0)) and
         IsWindowVisible(Child) then
      begin
        TextLength := GetWindowTextLength(Child);
        SetLength(ControlText, TextLength);
        if TextLength > 0 then
          GetWindowText(Child, PChar(ControlText), TextLength + 1);
        ControlText := LowerCase(Trim(StringReplace(ControlText, '&', '',
          [rfReplaceAll])));
        // German terms are localized Delphi 13 control fingerprints only.
        if (Pos('i agree', ControlText) > 0) or
           (Pos('i accept', ControlText) > 0) or
           SameText(ControlText, 'agree') or
           (Pos('agree to', ControlText) > 0) or
           (Pos('accept terms', ControlText) > 0) or
           (Pos('ich stimme zu', ControlText) > 0) or
           SameText(ControlText, 'zustimmen') or
           (Pos('akzeptiere', ControlText) > 0) or
           SameText(ControlText, 'akzeptieren') or
           SameText(ControlText, 'accept') or
           SameText(ControlText, 'continue') or
           SameText(ControlText, 'weiter') then
          Exit(True);
      end;
      if HasUnsafeAcceptanceControl(Child, ADepth + 1) then
        Exit(True);
      Child := FindWindowEx(AParent, Child, nil, nil);
    end;
  end;

  function HasExactReloadButtonSet: Boolean;
  var YesText, NoText: string; YesBtn, NoBtn: HWND;
    function Scan(const AParent: HWND; const ADepth: Integer): Boolean;
    var Child: HWND; ClassBuf: array[0..63] of Char; Text: string; TextLen: Integer;
    begin
      Result := True;
      if ADepth > MAX_RECURSIVE_DEPTH then Exit(False);
      Child := FindWindowEx(AParent, 0, nil, nil);
      while Child <> 0 do
      begin
        ClassBuf[0] := #0;
        GetClassName(Child, ClassBuf, Length(ClassBuf));
        if Pos('button', LowerCase(string(ClassBuf))) > 0 then
        begin
          TextLen := GetWindowTextLength(Child); SetLength(Text, TextLen);
          if TextLen > 0 then GetWindowText(Child, PChar(Text), TextLen + 1);
          if not TextMatches(Text, ['yes', 'ja', 'reload', 'neu laden',
            'no', 'nein', 'cancel', 'abbrechen', 'all', 'alle',
            'all no', 'alle nein', 'all yes', 'alle ja']) then
            Exit(False);
        end;
        if not Scan(Child, ADepth + 1) then Exit(False);
        Child := FindWindowEx(AParent, Child, nil, nil);
      end;
    end;
  begin
    // German labels are localized Delphi 13 button fingerprints only.
    YesText := ''; NoText := '';
    YesBtn := FindButtonRecursive(AWnd, 0, ['yes', 'ja', 'reload', 'neu laden'], YesText);
    NoBtn := FindButtonRecursive(AWnd, 0, ['no', 'nein', 'cancel', 'abbrechen'], NoText);
    Result := (YesBtn <> 0) and (NoBtn <> 0) and Scan(AWnd, 0);
  end;

  function IsNarrowTechnicalText(const AText: string): Boolean;
  var
    L: string;
  begin
    L := LowerCase(AText);
    // German terms are localized Delphi 13 technical-dialog fingerprints only.
    Result :=
      (Pos('.dfm', L) > 0) or
      (Pos('property read', L) > 0) or
      (Pos('error reading', L) > 0) or
      (Pos('fehler beim lesen', L) > 0) or
      (Pos('form creation', L) > 0) or
      (Pos('creating form', L) > 0) or
      (Pos('erzeugen des formulars', L) > 0) or
      (Pos('cannot find the file', L) > 0) or
      (Pos('cannot open file', L) > 0) or
      (Pos('cannot be opened', L) > 0) or
      (Pos('angegebene datei nicht', L) > 0) or
      (Pos('kann nicht ge' + #$00F6 + 'ffnet', L) > 0) or
      (Pos('kann nicht geoeffnet', L) > 0) or
      (Pos('module header', L) > 0) or
      (Pos('modul-header', L) > 0);
  end;

  function WindowTreeMatches(const AParent: HWND; const ADepth: Integer;
    const ALegalTerms: Boolean): Boolean;
  var
    Child: HWND;
    TextLen: Integer;
    Text: string;
  begin
    Result := False;
    if ADepth > MAX_RECURSIVE_DEPTH then Exit;
    TextLen := GetWindowTextLength(AParent);
    if TextLen > 0 then
    begin
      SetLength(Text, TextLen);
      GetWindowText(AParent, PChar(Text), TextLen + 1);
      if ALegalTerms then
        Result := IsLegalText(Text)
      else
        Result := IsNarrowTechnicalText(Text);
      if Result then Exit;
    end;
    Child := FindWindowEx(AParent, 0, nil, nil);
    while Child <> 0 do
    begin
      if WindowTreeMatches(Child, ADepth + 1, ALegalTerms) then Exit(True);
      Child := FindWindowEx(AParent, Child, nil, nil);
    end;
  end;

  function FindButtonRecursive(const AParent: HWND; const ADepth: Integer;
    const AValues: array of string; out AText: string): HWND;
  var
    Child: HWND;
    ChildClassBuf: array[0..63] of Char;
    ChildText: string;
    ChildLen: Integer;
    Deeper: HWND;
  begin
    Result := 0;
    if ADepth > MAX_RECURSIVE_DEPTH then Exit;
    Child := FindWindowEx(AParent, 0, nil, nil);
    while Child <> 0 do
    begin
      if IsWindowVisible(Child) and IsWindowEnabled(Child) then
      begin
        ChildClassBuf[0] := #0;
        GetClassName(Child, ChildClassBuf, Length(ChildClassBuf));
        ChildLen := GetWindowTextLength(Child);
        SetLength(ChildText, ChildLen);
        if ChildLen > 0 then
          GetWindowText(Child, PChar(ChildText), ChildLen + 1);
        if (Pos('button', LowerCase(string(ChildClassBuf))) > 0) and
           TextMatches(ChildText, AValues) then
        begin
          AText := ChildText;
          Exit(Child);
        end;
        Deeper := FindButtonRecursive(Child, ADepth + 1, AValues, AText);
        if Deeper <> 0 then Exit(Deeper);
      end;
      Child := FindWindowEx(AParent, Child, nil, nil);
    end;
  end;

  function ButtonBelongsToDialog(const AButton: HWND): Boolean;
  var
    ParentWnd: HWND;
    Depth: Integer;
  begin
    Result := False;
    ParentWnd := AButton;
    for Depth := 0 to MAX_RECURSIVE_DEPTH do
    begin
      if ParentWnd = AWnd then Exit(True);
      ParentWnd := GetParent(ParentWnd);
      if ParentWnd = 0 then Exit;
    end;
  end;

  function PostVerifiedButtonClick(const AButton: HWND;
    const AValues: array of string; out AVerifiedText: string): Boolean;
  var
    ButtonProcessID: DWORD;
    ButtonClassBuf: array[0..63] of Char;
    TextLen: Integer;
  begin
    Result := False;
    AVerifiedText := '';
    if (AButton = 0) or not IsWindow(AButton) or
       not IsWindowVisible(AButton) or not IsWindowEnabled(AButton) or
       not ButtonBelongsToDialog(AButton) then Exit;
    GetWindowThreadProcessId(AButton, ButtonProcessID);
    if ButtonProcessID <> GetCurrentProcessId then Exit;
    ButtonClassBuf[0] := #0;
    if (GetClassName(AButton, ButtonClassBuf, Length(ButtonClassBuf)) = 0) or
       (Pos('button', LowerCase(string(ButtonClassBuf))) = 0) then Exit;
    TextLen := GetWindowTextLength(AButton);
    if TextLen <= 0 then Exit;
    SetLength(AVerifiedText, TextLen);
    GetWindowText(AButton, PChar(AVerifiedText), TextLen + 1);
    if not TextMatches(AVerifiedText, AValues) then Exit;
    if not IsWindow(AButton) or not IsWindowVisible(AButton) or
       not IsWindowEnabled(AButton) or not ButtonBelongsToDialog(AButton) then
      Exit;
    Result := PostMessage(AButton, BM_CLICK, 0, 0);
    if Result then Inc(FDialogCloseAttempts);
  end;

  function HasActiveReloadPolicy: Boolean;
  begin
    FBlockLock.Enter;
    try
      Result := (FReloadJobId <> '') and (FReloadToken <> '') and
        (FReloadExpiryTick <> 0) and
        (Integer(GetTickCount - FReloadExpiryTick) < 0) and
        (Length(FAllowedReloadFiles) > 0);
    finally
      FBlockLock.Leave;
    end;
  end;

begin
  if not IsWindowVisible(AWnd) then Exit;
  GetWindowThreadProcessId(AWnd, ProcessID);
  if ProcessID <> GetCurrentProcessId then Exit;
  if (AWnd = Application.Handle) or
     (Assigned(Application.MainForm) and (AWnd = Application.MainForm.Handle)) then
    Exit;

  ClassBuf[0] := #0;
  if GetClassName(AWnd, ClassBuf, Length(ClassBuf)) = 0 then Exit;
  WindowClass := string(ClassBuf);
  if SameText(WindowClass, 'TDelphiCompileGateSettingsForm') then
    Exit;
  if SameText(WindowClass, 'TAppBuilder') then Exit;
  // Delphi 13 uses one form class for two states: transient progress with a
  // Cancel button, then a terminal build summary with only OK. Most summary
  // labels are non-windowed VCL controls and therefore cannot be collected by
  // GetWindowText. Never cancel progress; acknowledge only the exact class
  // after it has transitioned to a sole visible, enabled, exact OK button.
  if ((FPolicy = dapProtocolV2) or
      ((FPolicy = dapReloadOnly) and HasActiveReloadPolicy)) and
     SameText(WindowClass, 'TProgressForm') then
  begin
    ReloadText := '';
    CollectBoundedText(AWnd, 0, ReloadText);
    ButtonText := '';
    ButtonWnd := FindButtonRecursive(AWnd, 0, ['ok'], ButtonText);
    if (ButtonWnd <> 0) and HasOnlyExactOkButton then
    begin
      if GetProp(AWnd, 'DelphiCompileGate.ProtocolV2.ResultPosted') =
         THandle(NativeUInt(Self)) then Exit;
      if PostVerifiedButtonClick(ButtonWnd, ['ok'], ButtonText) then
      begin
        SetProp(AWnd, 'DelphiCompileGate.ProtocolV2.ResultPosted',
          THandle(NativeUInt(Self)));
        Inc(FDialogHits);
        Inc(FKnownTechnicalDialogHits);
        Trace('[v2] Acknowledged terminal IDE build result via sole exact OK button');
      end
      else if GetProp(AWnd, 'DelphiCompileGate.ProtocolV2.ResultPostFailed') <>
              THandle(NativeUInt(Self)) then
      begin
        SetProp(AWnd, 'DelphiCompileGate.ProtocolV2.ResultPostFailed',
          THandle(NativeUInt(Self)));
        Trace('[v2] Terminal IDE build result OK post failed; retrying');
      end;
    end
    else if IsBuildResultText(ReloadText) and (ButtonWnd <> 0) then
    begin
      if GetProp(AWnd, 'DelphiCompileGate.ProtocolV2.ResultUnsafe') <>
         THandle(NativeUInt(Self)) then
      begin
        SetProp(AWnd, 'DelphiCompileGate.ProtocolV2.ResultUnsafe',
          THandle(NativeUInt(Self)));
        Inc(FDialogHits);
        FUnknownDialogDetected := True;
        SetBlockReason('unexpected_build_result_controls');
        Trace('[v2] Terminal IDE build result left open; expected only exact OK');
      end;
    end
    else if GetProp(AWnd, 'DelphiCompileGate.ProtocolV2.Seen') <>
            THandle(NativeUInt(Self)) then
    begin
      SetProp(AWnd, 'DelphiCompileGate.ProtocolV2.Seen',
        THandle(NativeUInt(Self)));
      Trace('[v2] Ignoring active IDE progress form without interaction');
    end;
    Exit;
  end;

  OwnerWnd := GetWindow(AWnd, GW_OWNER);
  OwnerProcessID := 0;
  if OwnerWnd <> 0 then
    GetWindowThreadProcessId(OwnerWnd, OwnerProcessID);
  HasModalOwner := (OwnerWnd <> 0) and
    (OwnerProcessID = GetCurrentProcessId) and not IsWindowEnabled(OwnerWnd);
  // The persistent reload worker may inspect all visible same-process windows;
  // it acts only after strict text, path, token, revision and button evidence.
  // Do not couple this narrowly authorized action to a RAD Studio form class.
  if FPolicy = dapReloadOnly then
    IsDialogCandidate := True
  else
    IsDialogCandidate := SameText(WindowClass, '#32770') or
      (Pos('tmessageform', LowerCase(WindowClass)) > 0) or
      (Pos('tapplication', LowerCase(WindowClass)) > 0) or
      ((Pos('dialog', LowerCase(WindowClass)) > 0) and HasModalOwner) or
      ((Pos('form', LowerCase(WindowClass)) > 0) and HasModalOwner);
  if not IsDialogCandidate then Exit;
  if FPolicy = dapReloadOnly then
  begin
    ReloadPolicyActive := HasActiveReloadPolicy;
    if not ReloadPolicyActive then
      Exit;
  end;
  // A reload dialog can be enumerated before its body text and buttons are
  // populated. Keep polling it until the strict reload fingerprint is ready;
  // otherwise an early empty observation would permanently suppress handling.
  if FPolicy <> dapReloadOnly then
  begin
    if GetProp(AWnd, 'DelphiCompileGate.ProtocolV2.Seen') =
       THandle(NativeUInt(Self)) then Exit;
    SetProp(AWnd, 'DelphiCompileGate.ProtocolV2.Seen',
      THandle(NativeUInt(Self)));
  end;

  // The persistent watcher worker has exclusive reload ownership. It never
  // falls through to CE, legal, or unknown-dialog automation.
  ReloadText := '';
  CollectBoundedText(AWnd, 0, ReloadText);
  if FPolicy = dapReloadOnly then
  begin
    // The strict text, exact-path policy and exact button-set checks are the
    // authorization; the visible same-process window class is not trusted.
    // The German phrase is a localized Delphi 13 input fingerprint only.
    if ((Pos('reload', LowerCase(ReloadText)) > 0) or
        (Pos('neu laden', LowerCase(ReloadText)) > 0)) then
    begin
      Inc(FDialogHits);
      if IsStrictReloadPromptText(ReloadText) and
         ResolveAllowedReloadPath(ReloadText, ReloadPath, ReloadJobId,
           ReloadToken, ReloadRevision) and
         HasExactReloadButtonSet then
      begin
        ButtonText := '';
        ButtonWnd := FindButtonRecursive(AWnd, 0,
          ['yes', 'ja', 'reload', 'neu laden'], ButtonText);
        // Clearing or replacing a policy waits until this non-blocking post has
        // been bound to the exact revision, job, token, and canonical path.
        FBlockLock.Enter;
        try
          if ReloadPolicyMatchesLocked(ReloadPath, ReloadJobId, ReloadToken,
            ReloadRevision) then
            ReloadPolicyActive := PostVerifiedButtonClick(ButtonWnd,
              ['yes', 'ja', 'reload', 'neu laden'], ButtonText)
          else
            ReloadPolicyActive := False;
        finally
          FBlockLock.Leave;
        end;
        if ReloadPolicyActive then
        begin
          Inc(FKnownTechnicalDialogHits);
          Trace('[reload-worker] reload_prompt_confirmed job_id=' + ReloadJobId +
            ' reload_authorization_sha256=' + ReloadAuthorizationSHA256(
              ReloadJobId, ReloadToken, ReloadPath, ReloadRevision));
        end
        else
          Trace('[reload-worker] manual-required reload_click_failed_or_policy_stale');
      end
      else
      begin
        // Keep retrying a dialog that is still populating, but report the
        // fail-closed decision only once.
        if GetProp(AWnd, 'DelphiCompileGate.ReloadFailureTraced') <>
           THandle(NativeUInt(Self)) then
        begin
          SetProp(AWnd, 'DelphiCompileGate.ReloadFailureTraced',
            THandle(NativeUInt(Self)));
          Trace('[reload-worker] manual-required reload prompt not strictly authorized');
        end;
      end;
    end;
    Exit;
  end;

  // Reload prompts are deliberately not handled by the per-job v2 worker.
  // The watch-lifetime reload-only worker owns this policy after job completion.
  // The German phrase is a localized Delphi 13 input fingerprint only.
  if SameText(WindowClass, 'TMessageForm') and HasModalOwner and
     ((Pos('reload', LowerCase(ReloadText)) > 0) or
      (Pos('neu laden', LowerCase(ReloadText)) > 0)) then
  begin
    Inc(FDialogHits);
    FUnknownDialogDetected := True;
    Trace('[v2] reload prompt deferred to reload-only watcher worker');
    Exit;
  end;

  // Delphi Community Edition emits an informational TCENotificationDialog
  // during project builds. When its only actionable control is a plain OK/
  // Close button and no acceptance/continue control exists, acknowledging it
  // is not a license acceptance. Handle this exact fingerprint before scanning
  // the informational text for legal keywords.
  ButtonText := '';
  // German labels below are localized Delphi 13 button fingerprints only.
  ButtonWnd := FindButtonRecursive(AWnd, 0,
    ['ok', 'close', 'schlie' + #$00DF + 'en'], ButtonText);
  UnsafeButtonText := '';
  UnsafeButtonWnd := FindButtonRecursive(AWnd, 0,
    ['accept', 'akzeptieren', 'i agree', 'ich stimme zu', 'continue', 'weiter'],
    UnsafeButtonText);
  if SameText(WindowClass, 'TCENotificationDialog') and HasModalOwner and
     (ButtonWnd <> 0) and (UnsafeButtonWnd = 0) and HasOnlyExactOkButton and
     not HasUnsafeAcceptanceControl(AWnd, 0) then
  begin
    NoticeCaptionLength := GetWindowTextLength(AWnd);
    SetLength(NoticeCaption, NoticeCaptionLength);
    if NoticeCaptionLength > 0 then
      GetWindowText(AWnd, PChar(NoticeCaption), NoticeCaptionLength + 1);
    FLegalNoticeEvidence.Detected := True;
    FLegalNoticeEvidence.Classification :=
      'community_edition_usage_notice';
    FLegalNoticeEvidence.WindowClass := WindowClass;
    FLegalNoticeEvidence.Title := NoticeCaption;
    // The visible body is a non-windowed VCL control and is not observable via
    // Win32 text APIs. Do not substitute aggregate caption/button text.
    FLegalNoticeEvidence.TextAvailable := False;
    FLegalNoticeEvidence.Action := 'left_open';
    FLegalNoticeEvidence.Button := ButtonText;
    FLegalNoticeEvidence.AcceptedTerms := False;
    Inc(FDialogHits);
    if PostVerifiedButtonClick(ButtonWnd, ['ok'], ButtonText) then
    begin
      Inc(FKnownTechnicalDialogHits);
      FLegalNoticeEvidence.Action := 'acknowledged';
      Trace(Format('[v2] Acknowledged CE informational notification via "%s" hwnd=%d',
        [ButtonText, AWnd]));
    end
    else
    begin
      FUnknownDialogDetected := True;
      Trace(Format('[v2] CE notification button verification/post failed hwnd=%d',
        [AWnd]));
    end;
    Exit;
  end;

  IsLegal := WindowTreeMatches(AWnd, 0, True);

  Inc(FDialogHits);
  if IsLegal then
  begin
    FLicenseOrEulaDetected := True;
    Trace(Format('[v2] Legal/license dialog detected: class="%s" hwnd=%d',
      [WindowClass, AWnd]));
    ButtonText := '';
    // German labels are localized Delphi 13 button fingerprints only.
    ButtonWnd := FindButtonRecursive(AWnd, 0,
      ['decline', 'reject', 'ablehnen', 'nicht akzeptieren'], ButtonText);
    if PostVerifiedButtonClick(ButtonWnd,
      ['decline', 'reject', 'ablehnen', 'nicht akzeptieren'], ButtonText) then
      Trace(Format('[v2] Posted explicit legal rejection button "%s" hwnd=%d',
        [ButtonText, ButtonWnd]))
    else
    begin
      SetBlockReason('legal_no_safe_reject');
      Trace('[v2] Legal dialog left untouched; no verified reject button');
    end;
    Exit;
  end;

  ButtonText := '';
  ButtonWnd := FindButtonRecursive(AWnd, 0,
    ['ok', 'close', 'schlie' + #$00DF + 'en', 'ignore', 'ignore all'],
    ButtonText);
  IsKnownTechnical :=
    not SameText(WindowClass, 'TCENotificationDialog') and
    WindowTreeMatches(AWnd, 0, False) and (ButtonWnd <> 0);

  if IsKnownTechnical then
  begin
    Inc(FKnownTechnicalDialogHits);
    if PostVerifiedButtonClick(ButtonWnd,
      ['ok', 'close', 'schlie' + #$00DF + 'en', 'ignore', 'ignore all'],
      ButtonText) then
      Trace(Format('[v2] Posted safe technical button "%s": class="%s" hwnd=%d',
        [ButtonText, WindowClass, AWnd]))
    else
      Trace(Format('[v2] Technical dialog click verification/post failed: class="%s" hwnd=%d',
        [WindowClass, AWnd]));
    Exit;
  end;

  FUnknownDialogDetected := True;
  ButtonText := '';
  // The German label is a localized Delphi 13 button fingerprint only.
  ButtonWnd := FindButtonRecursive(AWnd, 0, ['cancel', 'abbrechen'], ButtonText);
  if PostVerifiedButtonClick(ButtonWnd, ['cancel', 'abbrechen'], ButtonText) then
    Trace(Format('[v2] Posted unknown-dialog cancel button "%s": class="%s" hwnd=%d',
      [ButtonText, WindowClass, AWnd]))
  else
  begin
    SetBlockReason('unknown_no_safe_cancel');
    Trace(Format('[v2] Unknown same-process modal/dialog left untouched: class="%s" hwnd=%d',
      [WindowClass, AWnd]));
  end;
end;

procedure TCompileDialogCloser.TryDismissDialogs;
begin
  EnumWindows(@EnumWindowsProc, LPARAM(Self));
end;

procedure TCompileDialogCloser.UpdateReloadPolicy(const AJobId, AToken: string;
  const AAllowedReloadFiles: TArray<string>; const AExpiryTick: Cardinal);
begin
  FBlockLock.Enter;
  try
    Inc(FReloadPolicyRevision);
    FAllowedReloadFiles := Copy(AAllowedReloadFiles);
    FReloadJobId := AJobId;
    FReloadToken := AToken;
    FReloadExpiryTick := AExpiryTick;
  finally
    FBlockLock.Leave;
  end;
end;

procedure TCompileDialogCloser.ClearReloadPolicy;
begin
  UpdateReloadPolicy('', '', nil, 0);
end;

function TCompileDialogCloser.StopAndWait(const ATimeoutMs: Cardinal): Boolean;
var
  WaitResult: DWORD;
begin
  Terminate;
  // TThread.WaitFor pumps messages when called from the IDE main thread. Under
  // modal compiler load Delphi 13 can then raise "Unexpected wait result 4".
  // This worker never Synchronize()s, so a direct kernel wait is sufficient.
  WaitResult := WaitForSingleObject(Handle, ATimeoutMs);
  Result := WaitResult = WAIT_OBJECT_0;
  if not Result then
    Trace(Format('Dialog closer kernel wait failed: result=%d timeout_ms=%d',
      [WaitResult, ATimeoutMs]));
end;

procedure TCompileDialogCloser.Execute;
begin
  while not Terminated do
  begin
    TryDismissDialogs;
    if (FPolicy = dapProtocolV2) and (GetBlockReason <> '') and
       not BlockDeadlineExceeded and
       (Integer(GetTickCount - FBlockDeadlineTick) >= 0) then
    begin
      MarkBlockDeadlineExceeded;
      Trace('[v2] dialog blocker exceeded evidence deadline; IDE call remains blocked because no unsafe UI action is permitted');
    end;
    // Poll every 20 ms to handle cascaded DFM-reader dialogs in real time.
    // EnumWindows is inexpensive here because the IDE has few top-level windows.
    Sleep(20);
  end;
end;

constructor TCompileWaitNotifier.Create(const ADprFile: string);
begin
  inherited Create;
  FDprFile := ExpandFileName(ADprFile);
  FDprojFile := ChangeFileExt(FDprFile, '.dproj');
  FHasResult := False;
  FCompileResult := crOTAFailed;
  FActive := True;
end;

procedure TCompileWaitNotifier.Deactivate;
begin
  FActive := False;
end;

function TCompileWaitNotifier.MatchesProject(const AProject: IOTAProject): Boolean;
var
  ProjFile: string;
begin
  Result := False;
  if not FActive then
    Exit;
  try
    if not Assigned(AProject) then
      Exit;

    ProjFile := ExpandFileName(AProject.FileName);
    Result := SameFileName(ProjFile, FDprFile) or SameFileName(ProjFile, FDprojFile);
  except
    Result := False;
  end;
end;

procedure TCompileWaitNotifier.ProjectCompileStarted(const Project: IOTAProject;
  Mode: TOTACompileMode);
begin
  // Intentionally empty, but exception-safe.
  try
  except
  end;
end;

procedure TCompileWaitNotifier.ProjectCompileFinished(const Project: IOTAProject;
  Result: TOTACompileResult);
begin
  try
    if FActive and MatchesProject(Project) then
    begin
      FCompileResult := Result;
      FHasResult := True;
    end;
  except
    // Never propagate an exception through the BDS callback chain.
  end;
end;

procedure TCompileWaitNotifier.ProjectGroupCompileStarted(Mode: TOTACompileMode);
begin
  try
  except
  end;
end;

procedure TCompileWaitNotifier.ProjectGroupCompileFinished(Result: TOTACompileResult);
begin
  try
    if FActive and not FHasResult then
    begin
      FCompileResult := Result;
      FHasResult := True;
    end;
  except
  end;
end;

{ TProjectCompileEvidenceNotifier }

constructor TProjectCompileEvidenceNotifier.Create;
begin
  inherited Create;
  FActive := True;
end;

procedure TProjectCompileEvidenceNotifier.Deactivate;
begin
  FActive := False;
end;

procedure TProjectCompileEvidenceNotifier.BeforeCompile(
  var CompileInfo: TOTAProjectCompileInfo);
begin
  if not FActive then
    Exit;
  FAfterSeen := False;
  FPlatform := CompileInfo.Platform;
  FConfiguration := CompileInfo.Configuration;
  FResult := False;
end;

procedure TProjectCompileEvidenceNotifier.AfterCompile(
  var CompileInfo: TOTAProjectCompileInfo);
begin
  if not FActive then
    Exit;
  FPlatform := CompileInfo.Platform;
  FConfiguration := CompileInfo.Configuration;
  FResult := CompileInfo.Result;
  FAfterSeen := True;
end;

procedure TProjectCompileEvidenceNotifier.Destroyed;
begin
  FActive := False;
  // The builder owns notifier registration; retained evidence remains readable.
end;

function TCompileError.ToJSON: string;
var
  EscapedCode, EscapedText, EscapedSource, EscapedKind, EscapedCanonicalCode: string;
  EscapedCanonicalEn, EscapedRawText, EscapedLocale: string;

  function EscapeJSON(const S: string): string;
  begin
    Result := S;
    Result := StringReplace(Result, '\', '\\', [rfReplaceAll]);
    Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
    Result := StringReplace(Result, #13#10, '\n', [rfReplaceAll]);
    Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
    Result := StringReplace(Result, #13, '\n', [rfReplaceAll]);
  end;
begin
  EscapedCode := EscapeJSON(ErrorCode);
  EscapedText := EscapeJSON(ErrorText);
  EscapedSource := EscapeJSON(Source);
  EscapedKind := EscapeJSON(Kind);
  EscapedCanonicalCode := EscapeJSON(CanonicalCode);
  EscapedCanonicalEn := EscapeJSON(CanonicalMessageEn);
  EscapedRawText := EscapeJSON(RawText);
  EscapedLocale := EscapeJSON(Locale);

  Result := Format(
    '{"file":"%s","line":%d,"column":%d,"code":"%s","text":"%s","warning":%s,' +
    '"source":"%s","kind":"%s","canonical_code":"%s","canonical_message_en":"%s",' +
    '"raw_text":"%s","locale":"%s"}',
    [ExtractFileName(FileName), Line, Column, EscapedCode, EscapedText,
     BoolToStr(IsWarning, True).ToLower,
     EscapedSource, EscapedKind, EscapedCanonicalCode, EscapedCanonicalEn,
     EscapedRawText, EscapedLocale]);
end;

procedure TDelphiCompileGateCompiler.Trace(const AMsg: string);
begin
  if Assigned(FOnTrace) then
    FOnTrace(AMsg);
end;

function TDelphiCompileGateCompiler.CurrentLocaleTag: string;
var
  LangID: Cardinal;
  PrimaryLang: Cardinal;
  SubLang: Cardinal;
begin
  Result := 'unknown';
  try
    LangID := GetUserDefaultUILanguage;
    PrimaryLang := LangID and $03FF;
    SubLang := (LangID shr 10) and $003F;
    Result := Format('lang-%d-%d', [PrimaryLang, SubLang]);
  except
    Result := 'unknown';
  end;
end;

procedure TDelphiCompileGateCompiler.PopulateDiagnosticMetadata(var AError: TCompileError);
var
  LRaw, LCode, LRawCode, LExtractedCode, LLower: string;

  function IsCompilerCode(const ACode: string): Boolean;
  begin
    Result :=
      (Length(ACode) = 5) and
      CharInSet(ACode[1], ['E', 'W', 'F', 'H']) and
      CharInSet(ACode[2], ['0'..'9']) and
      CharInSet(ACode[3], ['0'..'9']) and
      CharInSet(ACode[4], ['0'..'9']) and
      CharInSet(ACode[5], ['0'..'9']);
  end;

  function ExtractCompilerCodeFromText(const AText: string): string;
  var
    I, J: Integer;
    U: string;
  begin
    Result := '';
    U := UpperCase(AText);
    for I := 1 to Length(U) - 4 do
    begin
      if CharInSet(U[I], ['E', 'W', 'F', 'H']) and
         ((I = 1) or not CharInSet(U[I - 1], ['A'..'Z', '0'..'9'])) then
      begin
        J := I + 1;
        while (J <= Length(U)) and (J < I + 5) and CharInSet(U[J], ['0'..'9']) do
          Inc(J);
        if (J - I = 5) then
          Exit(Copy(U, I, 5));
      end;
    end;
  end;
begin
  LRaw := AError.ErrorText;
  LRawCode := UpperCase(Trim(AError.ErrorCode));
  if LRawCode = '' then
    LRawCode := 'UNSPECIFIED';
  LCode := LRawCode;
  LLower := LowerCase(LRaw);

  if not IsCompilerCode(LCode) then
  begin
    LExtractedCode := ExtractCompilerCodeFromText(LRaw);
    if LExtractedCode <> '' then
      LCode := LExtractedCode;
  end;

  AError.RawText := LRaw;
  AError.Locale := CurrentLocaleTag;

  if SameText(LRawCode, 'DFM') then
    AError.Source := 'dfm_reader'
  else if SameText(LRawCode, 'EXCEPTION') or SameText(LRawCode, 'FILENOTFOUND') then
    AError.Source := 'watcher'
  else if SameText(LRawCode, 'DCC32') or
          SameText(LRawCode, 'DCC') or
          IsCompilerCode(LCode) then
    AError.Source := 'compiler'
  else
    AError.Source := 'unknown';

  AError.Kind := 'unknown';
  AError.CanonicalCode := LCode;
  AError.CanonicalMessageEn := LRaw;

  // German terms are localized Delphi diagnostic input fingerprints. Keep
  // them alongside English fingerprints; canonical output remains English.
  if (Pos('ungueltiger eigenschaftswert', LLower) > 0) or
     (Pos('eigenschaftswert', LLower) > 0) or
     (Pos('invalid property value', LLower) > 0) then
  begin
    AError.Kind := 'invalid_property_value';
    AError.CanonicalCode := 'DFM_INVALID_PROPERTY';
    AError.CanonicalMessageEn := 'Invalid property value in DFM stream.';
    Exit;
  end;

  if (Pos('komponente mit der bezeichnung', LLower) > 0) or
     (Pos('component named', LLower) > 0) or
     (Pos('already exists', LLower) > 0) then
  begin
    AError.Kind := 'duplicate_component';
    AError.CanonicalCode := 'DFM_DUP_COMPONENT';
    AError.CanonicalMessageEn := 'Duplicate component name in DFM.';
    Exit;
  end;

  if ((Pos('klasse ', LLower) > 0) and (Pos('nicht gefunden', LLower) > 0)) or
     ((Pos('class ', LLower) > 0) and (Pos('not found', LLower) > 0)) then
  begin
    AError.Kind := 'class_not_found';
    AError.CanonicalCode := 'DFM_CLASS_NOT_FOUND';
    AError.CanonicalMessageEn := 'Component class not found while reading DFM.';
    Exit;
  end;

  // Compiler patterns
  if SameText(LCode, 'E2003') then
  begin
    AError.Kind := 'undeclared_identifier';
    AError.CanonicalCode := 'E2003';
    AError.CanonicalMessageEn := 'Undeclared identifier.';
    Exit;
  end;

  if SameText(LCode, 'F2063') then
  begin
    AError.Kind := 'unit_not_found';
    AError.CanonicalCode := 'F2063';
    AError.CanonicalMessageEn := 'Unit file not found.';
    Exit;
  end;

  if SameText(LCode, 'EXCEPTION') then
  begin
    AError.Kind := 'runtime_exception';
    AError.CanonicalCode := 'RUNTIME_EXCEPTION';
    AError.CanonicalMessageEn := 'Compile gate runtime exception.';
    Exit;
  end;

  if SameText(LCode, 'FILENOTFOUND') then
  begin
    AError.Kind := 'input_file_not_found';
    AError.CanonicalCode := 'INPUT_FILE_NOT_FOUND';
    AError.CanonicalMessageEn := 'Input source file not found.';
    Exit;
  end;

  if AError.IsWarning then
    AError.Kind := 'warning';
end;

{ TDelphiCompileGateCompiler }

function TDelphiCompileGateCompiler.MakeDprReferencesAbsolute(const ADprText,
  ASourceDir: string): string;
var
  QuoteStart: Integer;
  QuoteEnd: Integer;
  CheckPos: Integer;
  RelPath: string;
  AbsPath: string;

  function IsIdentChar(const C: Char): Boolean;
  begin
    Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
  end;
begin
  Result := ADprText;
  QuoteStart := Pos('''', Result);
  while QuoteStart > 0 do
  begin
    QuoteEnd := PosEx('''', Result, QuoteStart + 1);
    if QuoteEnd = 0 then
      Break;

    CheckPos := QuoteStart - 1;
    while (CheckPos > 0) and (Result[CheckPos] <= ' ') do
      Dec(CheckPos);

    if (CheckPos >= 2) and SameText(Copy(Result, CheckPos - 1, 2), 'in') and
       ((CheckPos <= 2) or (not IsIdentChar(Result[CheckPos - 2]))) then
    begin
      RelPath := Copy(Result, QuoteStart + 1, QuoteEnd - QuoteStart - 1);
      if (RelPath <> '') and (not TPath.IsPathRooted(RelPath)) then
      begin
        AbsPath := TPath.GetFullPath(TPath.Combine(ASourceDir, RelPath));
        AbsPath := StringReplace(AbsPath, '''', '''''', [rfReplaceAll]);
        Delete(Result, QuoteStart + 1, QuoteEnd - QuoteStart - 1);
        Insert(AbsPath, Result, QuoteStart + 1);
        QuoteEnd := QuoteStart + Length(AbsPath) + 1;
      end;
    end;

    QuoteStart := PosEx('''', Result, QuoteEnd + 1);
  end;
end;

function TDelphiCompileGateCompiler.DeriveWrapperCaptureSourceRoot(
  const AProjectFile, AOriginalDpr, AWrapperDpr: string): string;
var
  Candidate: string;
  MaximumRoot: string;
  WrapperText: string;
  QuoteStart: Integer;
  QuoteEnd: Integer;
  CheckPos: Integer;
  ReferencedPath: string;

  function IsIdentChar(const C: Char): Boolean;
  begin
    Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
  end;

  function CanonicalDirectory(const APath: string): string;
  begin
    Result := '';
    if APath = '' then
      Exit;
    try
      Result := IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(APath)));
    except
      Result := '';
    end;
  end;

  function IsUnderDirectory(const APath, ADirectory: string): Boolean;
  begin
    Result := (ADirectory <> '') and
      SameText(Copy(APath, 1, Length(ADirectory)), ADirectory);
  end;

  function IsVolumeRoot(const ADirectory: string): Boolean;
  begin
    Result := SameText(ADirectory,
      IncludeTrailingPathDelimiter(ExtractFileDrive(ADirectory)));
  end;

  procedure IncludeDirectory(const ADirectory: string);
  begin
    if ADirectory = '' then
      Exit;
    // Do not widen capture beyond the original DPR's project parent. If a
    // referenced unit is outside that bounded tree, fail closed for it.
    while (Candidate <> '') and not IsUnderDirectory(ADirectory, Candidate) do
    begin
      Candidate := IncludeTrailingPathDelimiter(
        ExtractFilePath(ExcludeTrailingPathDelimiter(Candidate)));
      if IsVolumeRoot(Candidate) or not IsUnderDirectory(Candidate, MaximumRoot) then
      begin
        Candidate := '';
        Exit;
      end;
    end;
  end;

begin
  // The original DPR directory is the minimum safe scope. Wrapper paths are
  // deliberately allowed separately by TMessageHook.
  Candidate := CanonicalDirectory(AOriginalDpr);
  if Candidate = '' then
    Exit;
  MaximumRoot := IncludeTrailingPathDelimiter(
    ExtractFilePath(ExcludeTrailingPathDelimiter(Candidate)));
  if MaximumRoot = '' then
    Exit;
  if IsVolumeRoot(MaximumRoot) then
    MaximumRoot := Candidate;
  IncludeDirectory(CanonicalDirectory(AProjectFile));
  if Candidate = '' then
    Exit;

  try
    WrapperText := TFile.ReadAllText(AWrapperDpr, TEncoding.UTF8);
  except
    Exit;
  end;
  QuoteStart := Pos('''', WrapperText);
  while QuoteStart > 0 do
  begin
    QuoteEnd := PosEx('''', WrapperText, QuoteStart + 1);
    if QuoteEnd = 0 then
      Break;
    CheckPos := QuoteStart - 1;
    while (CheckPos > 0) and (WrapperText[CheckPos] <= ' ') do
      Dec(CheckPos);
    if (CheckPos >= 2) and SameText(Copy(WrapperText, CheckPos - 1, 2), 'in') and
      ((CheckPos <= 2) or (not IsIdentChar(WrapperText[CheckPos - 2]))) then
    begin
      ReferencedPath := StringReplace(Copy(WrapperText, QuoteStart + 1,
        QuoteEnd - QuoteStart - 1), '''''', '''', [rfReplaceAll]);
      if TPath.IsPathRooted(ReferencedPath) then
      begin
        IncludeDirectory(CanonicalDirectory(ReferencedPath));
        if Candidate = '' then
          Exit;
      end;
    end;
    QuoteStart := PosEx('''', WrapperText, QuoteEnd + 1);
  end;
  Result := Candidate;
end;

function TDelphiCompileGateCompiler.CollectWrapperCaptureSourceFiles(
  const AOriginalDpr, AWrapperDpr: string): TArray<string>;
const
  MAX_CAPTURE_SOURCE_FILES = 4096;
var
  Basenames: TStringList;
  WrapperText: string;
  WrapperDproj: string;
  WrapperDprojDir: string;
  Doc: IXMLDocument;
  Root: IXMLNode;
  QuoteStart: Integer;
  QuoteEnd: Integer;
  CheckPos: Integer;
  ReferencedPath: string;

  function IsIdentChar(const C: Char): Boolean;
  begin
    Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
  end;

  function IsPascalSourceFile(const APath: string): Boolean;
  var
    Ext: string;
  begin
    Ext := LowerCase(ExtractFileExt(Trim(APath)));
    Result := (Ext = '.pas') or (Ext = '.pp') or (Ext = '.dpr') or
      (Ext = '.dpk');
  end;

  function IsElementName(const ANode: IXMLNode; const AName: string): Boolean;
  begin
    Result := Assigned(ANode) and
      (SameText(ANode.LocalName, AName) or SameText(ANode.NodeName, AName));
  end;

  function IsCompileItem(const ANode: IXMLNode): Boolean;
  begin
    Result := IsElementName(ANode, 'Compile') or
      IsElementName(ANode, 'DelphiCompile') or
      IsElementName(ANode, 'DCCReference');
  end;

  function IsExplicitlyLinkedItem(const ANode: IXMLNode): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := 0 to ANode.ChildNodes.Count - 1 do
      if IsElementName(ANode.ChildNodes[I], 'Link') then
        Exit(True);
  end;

  procedure AddSourceFile(const APath, ABaseDirectory: string);
  var
    SourceFile: string;
    Candidate: string;
  begin
    Candidate := Trim(APath);
    // MSBuild item lists and wildcard expressions do not identify one source.
    if (Candidate = '') or (Pos(';', Candidate) > 0) or
       (Pos('*', Candidate) > 0) or (Pos('?', Candidate) > 0) or
       (Pos('$(', Candidate) > 0) or (Pos('%(', Candidate) > 0) then
      Exit;
    if not IsPascalSourceFile(Candidate) then
      Exit;
    if not TPath.IsPathRooted(Candidate) then
      Candidate := TPath.Combine(ABaseDirectory, Candidate);
    SourceFile := ExpandFileName(Candidate);
    if TPath.IsPathRooted(SourceFile) and
       (Basenames.Count < MAX_CAPTURE_SOURCE_FILES) then
      Basenames.Add(SourceFile);
  end;

  procedure CollectDprojSourceItems;
  var
    I: Integer;
    J: Integer;
    ItemGroup: IXMLNode;
    Item: IXMLNode;
    IncludePath: string;
  begin
    WrapperDproj := ChangeFileExt(AWrapperDpr, '.dproj');
    if not FileExists(WrapperDproj) then
      Exit;
    try
      Doc := TXMLDocument.Create(nil);
      Doc.LoadFromFile(WrapperDproj);
      Root := Doc.DocumentElement;
      if not Assigned(Root) then
        Exit;
      WrapperDprojDir := ExtractFilePath(WrapperDproj);
      for I := 0 to Root.ChildNodes.Count - 1 do
      begin
        ItemGroup := Root.ChildNodes[I];
        if not IsElementName(ItemGroup, 'ItemGroup') then
          Continue;
        for J := 0 to ItemGroup.ChildNodes.Count - 1 do
        begin
          Item := ItemGroup.ChildNodes[J];
          if not (IsCompileItem(Item) or IsExplicitlyLinkedItem(Item)) or
             not Item.HasAttribute('Include') then
            Continue;
          IncludePath := VarToStr(Item.Attributes['Include']);
          AddSourceFile(IncludePath, WrapperDprojDir);
        end;
      end;
    except
      // A malformed wrapper project is not authorization.
    end;
  end;
begin
  Basenames := TStringList.Create;
  try
    Basenames.CaseSensitive := False;
    Basenames.Sorted := True;
    Basenames.Duplicates := dupIgnore;
    AddSourceFile(AOriginalDpr, ExtractFilePath(AOriginalDpr));
    try
      WrapperText := TFile.ReadAllText(AWrapperDpr, TEncoding.UTF8);
    except
      WrapperText := '';
    end;
    QuoteStart := Pos('''', WrapperText);
    while QuoteStart > 0 do
    begin
      QuoteEnd := PosEx('''', WrapperText, QuoteStart + 1);
      if QuoteEnd = 0 then
        Break;
      CheckPos := QuoteStart - 1;
      while (CheckPos > 0) and (WrapperText[CheckPos] <= ' ') do
        Dec(CheckPos);
      if (CheckPos >= 2) and SameText(Copy(WrapperText, CheckPos - 1, 2), 'in') and
         ((CheckPos <= 2) or (not IsIdentChar(WrapperText[CheckPos - 2]))) then
      begin
        ReferencedPath := StringReplace(Copy(WrapperText, QuoteStart + 1,
          QuoteEnd - QuoteStart - 1), '''''', '''', [rfReplaceAll]);
        if TPath.IsPathRooted(ReferencedPath) then
          AddSourceFile(ReferencedPath, ExtractFilePath(AWrapperDpr));
      end;
      QuoteStart := PosEx('''', WrapperText, QuoteEnd + 1);
    end;
    CollectDprojSourceItems;
    Result := Basenames.ToStringArray;
  finally
    Basenames.Free;
  end;
end;

function TDelphiCompileGateCompiler.CollectWrapperReloadAllowedFiles(
  const AOriginalDpr, AWrapperDpr: string): TArray<string>;
var
  Files: TStringList;
  WrapperText: string;
  QuoteStart, QuoteEnd, CheckPos: Integer;
  ReferencedPath: string;

  function IsIdentChar(const C: Char): Boolean;
  begin
    Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
  end;

  procedure AddCanonical(const APath: string);
  var
    Canonical: string;
  begin
    if APath = '' then Exit;
    try
      Canonical := ExpandFileName(APath);
      if TPath.IsPathRooted(Canonical) then
        Files.Add(Canonical);
    except
      // A malformed wrapper reference is not authorization.
    end;
  end;
begin
  Files := TStringList.Create;
  try
    Files.CaseSensitive := False;
    Files.Sorted := True;
    Files.Duplicates := dupIgnore;
    AddCanonical(AOriginalDpr);
    try
      WrapperText := TFile.ReadAllText(AWrapperDpr, TEncoding.UTF8);
    except
      Result := Files.ToStringArray;
      Exit;
    end;
    QuoteStart := Pos('''', WrapperText);
    while QuoteStart > 0 do
    begin
      QuoteEnd := PosEx('''', WrapperText, QuoteStart + 1);
      if QuoteEnd = 0 then Break;
      CheckPos := QuoteStart - 1;
      while (CheckPos > 0) and (WrapperText[CheckPos] <= ' ') do Dec(CheckPos);
      if (CheckPos >= 2) and SameText(Copy(WrapperText, CheckPos - 1, 2), 'in') and
         ((CheckPos <= 2) or not IsIdentChar(WrapperText[CheckPos - 2])) then
      begin
        ReferencedPath := StringReplace(Copy(WrapperText, QuoteStart + 1,
          QuoteEnd - QuoteStart - 1), '''''', '''', [rfReplaceAll]);
        if TPath.IsPathRooted(ReferencedPath) then AddCanonical(ReferencedPath);
      end;
      QuoteStart := PosEx('''', WrapperText, QuoteEnd + 1);
    end;
    Result := Files.ToStringArray;
  finally
    Files.Free;
  end;
end;

function TDelphiCompileGateCompiler.MakeDprResourceReferencesAbsolute(
  const ADprText, ASourceDpr: string): string;
var
  SourceDir: string;
  SourceBase: string;
  ResPath: string;
  DresPath: string;
begin
  Result := ADprText;
  SourceDir := ExtractFilePath(ASourceDpr);
  SourceBase := ChangeFileExt(ExtractFileName(ASourceDpr), '');

  ResPath := TPath.Combine(SourceDir, SourceBase + '.res');
  ResPath := StringReplace(ResPath, '''', '''''', [rfReplaceAll]);
  DresPath := TPath.Combine(SourceDir, SourceBase + '.dres');
  DresPath := StringReplace(DresPath, '''', '''''', [rfReplaceAll]);

  Result := StringReplace(Result, '{$R *.res}', '{$R ''' + ResPath + '''}',
    [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{$RESOURCE *.res}', '{$RESOURCE ''' + ResPath + '''}',
    [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{$R *.dres}', '{$R ''' + DresPath + '''}',
    [rfReplaceAll, rfIgnoreCase]);
end;

function TDelphiCompileGateCompiler.MakeDprojReferencesAbsolute(const ADprojText,
  ASourceDir, AWrapperDir: string): string;
var
  PosStart: Integer;
  PosEnd: Integer;
  ValueStart: Integer;
  ValueEnd: Integer;
  Value: string;
  AbsValue: string;
  TagStart: Integer;
  TagEnd: Integer;
  PathList: string;
  NewPathList: string;
  Part: string;
  P: Integer;
  ProjectEnd: Integer;
  HasExeOutput: Boolean;

  function ShouldAbsolutize(const AValue: string): Boolean;
  begin
    Result := (AValue <> '') and
      (Pos('$(', AValue) = 0) and
      (Pos('%', AValue) = 0) and
      (not TPath.IsPathRooted(AValue));
  end;

  function AbsolutePath(const AValue: string): string;
  begin
    if ShouldAbsolutize(AValue) then
      Result := TPath.GetFullPath(TPath.Combine(ASourceDir, AValue))
    else
      Result := AValue;
  end;

  function RewritePathList(const AValue: string): string;
  begin
    Result := '';
    PathList := AValue;
    while PathList <> '' do
    begin
      P := Pos(';', PathList);
      if P > 0 then
      begin
        Part := Copy(PathList, 1, P - 1);
        Delete(PathList, 1, P);
      end
      else
      begin
        Part := PathList;
        PathList := '';
      end;

      Part := Trim(Part);
      if Part <> '' then
      begin
        if Result <> '' then
          Result := Result + ';';
        Result := Result + AbsolutePath(Part);
      end;
    end;
  end;

  function RewriteExeOutputPath(const AValue: string): string;
  begin
    Result := ExcludeTrailingPathDelimiter(ExpandFileName(AWrapperDir));
  end;
begin
  Result := ADprojText;
  HasExeOutput := Pos('<DCC_ExeOutput>', Result) > 0;

  PosStart := Pos('Include="', Result);
  while PosStart > 0 do
  begin
    ValueStart := PosStart + Length('Include="');
    ValueEnd := PosEx('"', Result, ValueStart);
    if ValueEnd = 0 then
      Break;

    Value := Copy(Result, ValueStart, ValueEnd - ValueStart);
    if ShouldAbsolutize(Value) and SameText(ExtractFileExt(Value), '.pas') then
    begin
      AbsValue := AbsolutePath(Value);
      Delete(Result, ValueStart, ValueEnd - ValueStart);
      Insert(AbsValue, Result, ValueStart);
      ValueEnd := ValueStart + Length(AbsValue);
    end;

    PosStart := PosEx('Include="', Result, ValueEnd + 1);
  end;

  TagStart := Pos('<DCC_UnitSearchPath>', Result);
  while TagStart > 0 do
  begin
    ValueStart := TagStart + Length('<DCC_UnitSearchPath>');
    TagEnd := PosEx('</DCC_UnitSearchPath>', Result, ValueStart);
    if TagEnd = 0 then
      Break;

    PathList := Copy(Result, ValueStart, TagEnd - ValueStart);
    NewPathList := RewritePathList(PathList);
    Delete(Result, ValueStart, TagEnd - ValueStart);
    Insert(NewPathList, Result, ValueStart);
    TagStart := PosEx('<DCC_UnitSearchPath>', Result, ValueStart + Length(NewPathList));
  end;

  TagStart := Pos('<DCC_ExeOutput>', Result);
  while TagStart > 0 do
  begin
    ValueStart := TagStart + Length('<DCC_ExeOutput>');
    TagEnd := PosEx('</DCC_ExeOutput>', Result, ValueStart);
    if TagEnd = 0 then
      Break;

    Value := Copy(Result, ValueStart, TagEnd - ValueStart);
    AbsValue := RewriteExeOutputPath(Value);
    Delete(Result, ValueStart, TagEnd - ValueStart);
    Insert(AbsValue, Result, ValueStart);
    TagStart := PosEx('<DCC_ExeOutput>', Result, ValueStart + Length(AbsValue));
  end;

  if not HasExeOutput then
  begin
    ProjectEnd := Pos('</Project>', Result);
    if ProjectEnd > 0 then
      Insert('  <PropertyGroup>'#13#10 +
        '    <DCC_ExeOutput>' +
        ExcludeTrailingPathDelimiter(ExpandFileName(AWrapperDir)) +
        '</DCC_ExeOutput>'#13#10 +
        '  </PropertyGroup>'#13#10, Result, ProjectEnd);
  end;
end;

function TDelphiCompileGateCompiler.SanitizeWrapperDprojSources(
  const ADprojText, AWrapperMainSource: string): string;
var
  Doc: IXMLDocument;
  Root: IXMLNode;
  WrapperCompileCount: Integer;
  ItemGroup: IXMLNode;
  DelphiCompile: IXMLNode;
  function IsSourceFile(const APath: string): Boolean;
  var
    Ext: string;
  begin
    Ext := LowerCase(ExtractFileExt(Trim(APath)));
    Result := (Ext = '.pas') or (Ext = '.pp') or (Ext = '.dfm') or
      (Ext = '.fmx') or (Ext = '.dpr') or (Ext = '.dpk');
  end;

  procedure SanitizeXml;
    function IsElementName(const ANode: IXMLNode; const AName: string): Boolean;
    begin
      Result := SameText(ANode.LocalName, AName) or SameText(ANode.NodeName, AName);
    end;
    function IncludeValue(const ANode: IXMLNode): string;
    begin
      if ANode.HasAttribute('Include') then
        Result := VarToStr(ANode.Attributes['Include'])
      else
        Result := '';
    end;

    function TryGetDirectScalarText(const ANode: IXMLNode;
      out AText: string): Boolean;
    var
      ScalarNode: IXMLNode;
    begin
      AText := '';
      Result := Assigned(ANode) and (ANode.ChildNodes.Count = 1);
      if not Result then
        Exit;
      ScalarNode := ANode.ChildNodes[0];
      Result := ScalarNode.NodeType in [ntText, ntCData];
      if Result then
        AText := VarToStr(ScalarNode.NodeValue);
    end;

    procedure ProcessItemGroup(const AParent: IXMLNode);
    var
      I: Integer;
      Node: IXMLNode;
      IncludeName: string;
    begin
      for I := AParent.ChildNodes.Count - 1 downto 0 do
      begin
        Node := AParent.ChildNodes[I];
        // DCCReference items carry Delphi project compile semantics, including
        // the original DPR and unit references. Retain them verbatim; only the
        // DelphiCompile main-source item is redirected to the wrapper DPR.
        if SameText(Node.NodeName, 'DelphiCompile') then
        begin
          IncludeName := IncludeValue(Node);
          if SameText(Node.NodeName, 'DelphiCompile') and
             SameText(IncludeName, '$(MainSource)') then
          begin
            Node.Attributes['Include'] := AWrapperMainSource;
            IncludeName := AWrapperMainSource;
          end;
          if IsSourceFile(IncludeName) then
          begin
            if SameText(Node.NodeName, 'DelphiCompile') and
               SameText(ExtractFileName(IncludeName), AWrapperMainSource) and
               (WrapperCompileCount = 0) then
              Inc(WrapperCompileCount)
            else
            begin
              AParent.ChildNodes.Delete(I);
              Continue;
            end;
          end;
        end;
      end;
    end;
    procedure CleanupSourceMetadata(const AParent: IXMLNode);
    var
      I: Integer;
      Node: IXMLNode;
      SourceText: string;
    begin
      for I := AParent.ChildNodes.Count - 1 downto 0 do
      begin
        Node := AParent.ChildNodes[I];
        if IsElementName(Node, 'Source') then
        begin
          // Nested Source metadata is opaque and must be preserved verbatim.
          if TryGetDirectScalarText(Node, SourceText) and IsSourceFile(SourceText) and
             not SameText(ExtractFileName(SourceText), AWrapperMainSource) then
            AParent.ChildNodes.Delete(I);
          Continue;
        end;
        if Node.NodeType = ntElement then
          CleanupSourceMetadata(Node);
      end;
    end;
    procedure ProcessProjectChildren;
    var
      I: Integer;
      Node: IXMLNode;
    begin
      for I := Root.ChildNodes.Count - 1 downto 0 do
      begin
        Node := Root.ChildNodes[I];
        if IsElementName(Node, 'PropertyGroup') then
        begin
          // Only the project-level PropertyGroup property selects the main DPR.
          // DelphiCompile child metadata named MainSource must remain literal.
          if Assigned(Node.ChildNodes.FindNode('MainSource')) then
            Node.ChildNodes.FindNode('MainSource').Text := AWrapperMainSource;
        end
        else if IsElementName(Node, 'ItemGroup') then
          ProcessItemGroup(Node)
        else if IsElementName(Node, 'ProjectExtensions') then
        begin
          // Source metadata is not an MSBuild item; remove only source entries.
          // Do not recurse into retained DelphiCompile metadata.
          CleanupSourceMetadata(Node);
        end;
      end;
    end;
  begin
    Doc := TXMLDocument.Create(nil);
    Doc.LoadFromXML(ADprojText);
    Root := Doc.DocumentElement;
    if not Assigned(Root) then
      raise Exception.Create('wrapper_project_invalid');
    WrapperCompileCount := 0;
    ProcessProjectChildren;
    if WrapperCompileCount = 0 then
    begin
      ItemGroup := Root.AddChild('ItemGroup');
      DelphiCompile := ItemGroup.AddChild('DelphiCompile');
      DelphiCompile.Attributes['Include'] := AWrapperMainSource;
      DelphiCompile.AddChild('MainSource').Text := 'MainSource';
    end;
    Result := Doc.XML.Text;
  end;
begin
  // DOM traversal handles quote, whitespace and tag-case variations without
  // touching unrelated MSBuild property and item nodes.
  SanitizeXml;
end;

procedure TDelphiCompileGateCompiler.ValidateWrapperDproj(const AWrapperDproj,
  AWrapperMainSource: string);
var
  Doc: IXMLDocument;
  Root: IXMLNode;
  I: Integer;
  J: Integer;
  Node: IXMLNode;
  Item: IXMLNode;
  MainSource: IXMLNode;
  IncludeName: string;
  WrapperCompileCount: Integer;

  function IsElementName(const ANode: IXMLNode; const AName: string): Boolean;
  begin
    Result := Assigned(ANode) and
      (SameText(ANode.LocalName, AName) or SameText(ANode.NodeName, AName));
  end;
begin
  try
    Doc := TXMLDocument.Create(nil);
    Doc.LoadFromFile(AWrapperDproj);
    Root := Doc.DocumentElement;
    if not IsElementName(Root, 'Project') then
      raise Exception.Create('wrapper_project_invalid');
    WrapperCompileCount := 0;
    for I := 0 to Root.ChildNodes.Count - 1 do
    begin
      Node := Root.ChildNodes[I];
      if IsElementName(Node, 'PropertyGroup') then
      begin
        MainSource := Node.ChildNodes.FindNode('MainSource');
        if Assigned(MainSource) and not SameText(Trim(MainSource.Text), AWrapperMainSource) then
          raise Exception.Create('wrapper_project_invalid');
      end
      else if IsElementName(Node, 'ItemGroup') then
        for J := 0 to Node.ChildNodes.Count - 1 do
        begin
          Item := Node.ChildNodes[J];
          if not IsElementName(Item, 'DelphiCompile') then
            Continue;
          if not Item.HasAttribute('Include') then
            raise Exception.Create('wrapper_project_invalid');
          IncludeName := VarToStr(Item.Attributes['Include']);
          if not SameText(ExtractFileName(IncludeName), AWrapperMainSource) then
            raise Exception.Create('wrapper_project_invalid');
          Inc(WrapperCompileCount);
        end;
    end;
    if WrapperCompileCount <> 1 then
      raise Exception.Create('wrapper_project_invalid');
  except
    on E: Exception do
      if E.Message = 'wrapper_project_invalid' then
        raise
      else
        raise Exception.Create('wrapper_project_invalid');
  end;
end;

procedure TDelphiCompileGateCompiler.EnsureSourceBuffersMatchDisk(
  const AModuleServices: IOTAModuleServices;
  const ASourceFiles: TArray<string>);
const
  MAX_SOURCE_BUFFER_BYTES = 32 * 1024 * 1024;
var
  SourceFile: string;
  Module: IOTAModule;
  Editor: IOTAEditor;

  function EditorBufferMatchesDisk(const AEditor: IOTAEditor;
    const AFileName: string; out AVerifiable: Boolean): Boolean;
  var
    Content: IOTAEditorContent;
    ContentStream: IStream;
    Stat: TStatStg;
    DiskBytes: TBytes;
    EditorBytes: TBytes;
    Offset: Integer;
    ReadCount: Longint;
    ChunkSize: Longint;
    BufferSize: Int64;
  begin
    Result := False;
    AVerifiable := False;
    if not Supports(AEditor, IOTAEditorContent, Content) then
      Exit;
    ContentStream := Content.Content;
    if not Assigned(ContentStream) then
      Exit;
    ContentStream.Stat(Stat, STATFLAG_NONAME);
    BufferSize := Stat.cbSize;
    if (BufferSize < 0) or (BufferSize > MAX_SOURCE_BUFFER_BYTES) then
      Exit;
    DiskBytes := TFile.ReadAllBytes(AFileName);
    if Length(DiskBytes) <> BufferSize then
    begin
      AVerifiable := True;
      Exit;
    end;
    SetLength(EditorBytes, BufferSize);
    Offset := 0;
    while Offset < Length(EditorBytes) do
    begin
      ChunkSize := Length(EditorBytes) - Offset;
      ReadCount := 0;
      if ContentStream.Read(@EditorBytes[Offset], ChunkSize, @ReadCount) <> S_OK then
        Exit;
      if ReadCount <= 0 then
        Exit;
      Inc(Offset, ReadCount);
    end;
    AVerifiable := True;
    Result := (Length(EditorBytes) = 0) or
      CompareMem(@EditorBytes[0], @DiskBytes[0], Length(EditorBytes));
  end;

  procedure EnsureOne(const AFileName: string);
  var
    Canonical: string;
    Verifiable: Boolean;
    EditorIndex: Integer;
  begin
    Canonical := ExpandFileName(AFileName);
    Module := AModuleServices.FindModule(Canonical);
    if not Assigned(Module) then
      Exit; // Unopened source files compile from disk.
    for EditorIndex := 0 to Module.ModuleFileCount - 1 do
    begin
      Editor := Module.ModuleFileEditors[EditorIndex];
      if not Assigned(Editor) or not SameText(ExpandFileName(Editor.FileName), Canonical) then
        Continue;
      // The dedicated build worker never edits source in the IDE. An
      // unmodified editor therefore cannot override the requested disk source.
      if not Editor.Modified then
        Continue;
      if not EditorBufferMatchesDisk(Editor, Canonical, Verifiable) then
      begin
        if Verifiable then
          raise Exception.Create('source_buffer_mismatch')
        else
          raise Exception.Create('source_buffer_unverified');
      end;
    end;
  end;
begin
  for SourceFile in ASourceFiles do
    try
      EnsureOne(SourceFile);
    except
      on E: Exception do
      begin
        Trace('Source buffer preflight failed for ' + SourceFile + ': ' + E.Message);
        if (E.Message = 'source_buffer_mismatch') or
           (E.Message = 'source_buffer_unverified') then
          raise
        else
          raise Exception.Create('source_buffer_unverified');
      end;
    end;
end;

function TDelphiCompileGateCompiler.FindWrapperOutputEXE(const ASourceDpr,
  AWrapperProject, AJobId: string): string;
var
  SourceDir: string;
  WrapperName: string;
  Candidate: string;
  Candidates: TStringList;
  ProjectText: string;
  TagStart: Integer;
  ValueStart: Integer;
  TagEnd: Integer;
  OutputDir: string;
  LatestWriteTime: TDateTime;

  procedure AddOutputDirectory(const ADirectory: string);
  var
    DirectoryPath: string;
  begin
    DirectoryPath := Trim(ADirectory);
    DirectoryPath := StringReplace(DirectoryPath, '&amp;', '&',
      [rfReplaceAll, rfIgnoreCase]);
    if (DirectoryPath = '') or (Pos('$(', DirectoryPath) > 0) or
       not TPath.IsPathRooted(DirectoryPath) then
      Exit;
    Candidates.Add(TPath.Combine(DirectoryPath, WrapperName + '.exe'));
  end;
begin
  Result := '';
  SourceDir := ExtractFilePath(ASourceDpr);
  if not DirectoryExists(SourceDir) then
    Exit;

  WrapperName := 'DCG_' + AJobId;
  WrapperName := StringReplace(WrapperName, '-', '_', [rfReplaceAll]);
  WrapperName := StringReplace(WrapperName, '.', '_', [rfReplaceAll]);
  WrapperName := StringReplace(WrapperName, ' ', '_', [rfReplaceAll]);
  LatestWriteTime := 0;
  Candidates := TStringList.Create;
  try
    Candidates.CaseSensitive := False;
    Candidates.Sorted := True;
    Candidates.Duplicates := dupIgnore;
    AddOutputDirectory(SourceDir);
    AddOutputDirectory(ExtractFilePath(AWrapperProject));
    if SameText(ExtractFileExt(AWrapperProject), '.dproj') and
       FileExists(AWrapperProject) then
    begin
      ProjectText := TFile.ReadAllText(AWrapperProject, TEncoding.UTF8);
      TagStart := Pos('<DCC_ExeOutput>', ProjectText);
      while TagStart > 0 do
      begin
        ValueStart := TagStart + Length('<DCC_ExeOutput>');
        TagEnd := PosEx('</DCC_ExeOutput>', ProjectText, ValueStart);
        if TagEnd = 0 then
          Break;
        OutputDir := Copy(ProjectText, ValueStart, TagEnd - ValueStart);
        AddOutputDirectory(OutputDir);
        TagStart := PosEx('<DCC_ExeOutput>', ProjectText,
          TagEnd + Length('</DCC_ExeOutput>'));
      end;
    end;
    for Candidate in Candidates do
      if FileExists(Candidate) and
         ((Result = '') or
          (TFile.GetLastWriteTime(Candidate) > LatestWriteTime)) then
      begin
        Result := Candidate;
        LatestWriteTime := TFile.GetLastWriteTime(Candidate);
      end;
  finally
    Candidates.Free;
  end;
end;

function TDelphiCompileGateCompiler.IsIDEQuiescentForProjectClose: Boolean;
var
  CompileServices: IOTACompileServices;
  Window: HWND;
  ProcessID: DWORD;
  ClassBuf: array[0..127] of Char;
  Popup: HWND;
  MainWindow: HWND;
begin
  Result := False;
  if not Supports(BorlandIDEServices, IOTACompileServices, CompileServices) or
     CompileServices.IsBackgroundCompileActive then
    Exit;
  MainWindow := Application.Handle;
  if Assigned(Application.MainForm) then
    MainWindow := Application.MainForm.Handle;
  if (MainWindow = 0) or not IsWindowEnabled(MainWindow) then
    Exit;
  Popup := GetLastActivePopup(MainWindow);
  if (Popup <> 0) and (Popup <> MainWindow) and IsWindowVisible(Popup) then
    Exit;
  Window := FindWindowEx(0, 0, nil, nil);
  while Window <> 0 do
  begin
    GetWindowThreadProcessId(Window, ProcessID);
    if (ProcessID = GetCurrentProcessId) and IsWindowVisible(Window) then
    begin
      ClassBuf[0] := #0;
      if (GetClassName(Window, ClassBuf, Length(ClassBuf)) > 0) and
         SameText(string(ClassBuf), 'TProgressForm') then
        Exit;
    end;
    Window := FindWindowEx(0, Window, nil, nil);
  end;
  Result := True;
end;

function TDelphiCompileGateCompiler.TryCloseGeneratedModule(
  const AProjectFile: string): TGeneratedModuleCloseResult;
var
  CanonicalProject: string;
  WrapperRoot: string;
  CanonicalRoot: string;
  ModuleServices: IOTAModuleServices;
  CompileServices: IOTACompileServices;
  Module: IOTAModule;

  function HasReparsePointInControlledPath(const AFileName,
    ARoot: string): Boolean;
  var
    CurrentPath: string;
    RootPath: string;
    ParentPath: string;
    Attr: DWORD;
  begin
    Result := True;
    RootPath := ExcludeTrailingPathDelimiter(ExpandFileName(ARoot));
    CurrentPath := ExpandFileName(AFileName);
    Attr := GetFileAttributes(PChar(CurrentPath));
    if (Attr = INVALID_FILE_ATTRIBUTES) or
       ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
      Exit;
    CurrentPath := ExtractFileDir(CurrentPath);
    while CurrentPath <> '' do
    begin
      if not SameText(CurrentPath, RootPath) and
         not StartsText(IncludeTrailingPathDelimiter(RootPath),
           IncludeTrailingPathDelimiter(CurrentPath)) then
        Exit;
      Attr := GetFileAttributes(PChar(CurrentPath));
      if (Attr = INVALID_FILE_ATTRIBUTES) or
         ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
        Exit;
      if SameText(CurrentPath, RootPath) then
        Exit(False);
      ParentPath := ExtractFileDir(CurrentPath);
      if SameText(ParentPath, CurrentPath) then
        Exit;
      CurrentPath := ParentPath;
    end;
  end;
begin
  Result := gmcrDeferred;
  if Trim(AProjectFile) = '' then
    Exit(gmcrAlreadyAbsent);

  CanonicalProject := ExpandFileName(AProjectFile);
  WrapperRoot := TPath.Combine(ResolveDelphiCompileGateBaseDir, 'Projects');
  CanonicalRoot := IncludeTrailingPathDelimiter(ExpandFileName(WrapperRoot));
  if not StartsText(CanonicalRoot, CanonicalProject) then
  begin
    Trace('Generated hidden module close rejected outside wrapper root: ' +
      CanonicalProject);
    Exit;
  end;
  if HasReparsePointInControlledPath(CanonicalProject, CanonicalRoot) then
  begin
    Trace('Generated hidden module close rejected for reparse/unresolved path: ' +
      CanonicalProject);
    Exit;
  end;
  if not SameText(ExtractFileExt(CanonicalProject), '.dproj') and
     not SameText(ExtractFileExt(CanonicalProject), '.dpr') and
     not SameText(ExtractFileExt(CanonicalProject), '.dpk') then
  begin
    Trace('Generated hidden module close rejected for unsupported extension: ' +
      CanonicalProject);
    Exit;
  end;

  if not Supports(BorlandIDEServices, IOTACompileServices, CompileServices) then
  begin
    Trace('Generated hidden module close deferred: compile services unavailable');
    Exit;
  end;
  if CompileServices.IsBackgroundCompileActive then
  begin
    Trace('Generated hidden module close deferred: background compile active');
    Exit;
  end;
  if not Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
  begin
    Trace('Generated hidden module close deferred: module services unavailable');
    Exit;
  end;

  Module := ModuleServices.FindModule(CanonicalProject);
  if not Assigned(Module) then
  begin
    Trace('Generated hidden module already closed: ' + CanonicalProject);
    Exit(gmcrAlreadyAbsent);
  end;
  if not SameText(ExpandFileName(Module.FileName), CanonicalProject) then
  begin
    Trace('Generated hidden module close rejected unexpected module: ' +
      Module.FileName);
    Module := nil;
    Exit;
  end;

  try
    // The v2 wrapper was loaded through OpenModule and never shown. Close that
    // exact module directly; never combine this with project-group/file close APIs
    // and never retry after the mutation has been invoked.
    Trace('Closing exact hidden wrapper via forced IOTAModule.CloseModule: ' +
      CanonicalProject);
    if Module.CloseModule(True) then
      Result := gmcrCloseRequested
    else
      Result := gmcrAttemptFailed;
  except
    on E: Exception do
    begin
      Result := gmcrAttemptFailed;
      Trace('Generated hidden module close exception (not retried): ' + E.ClassName + ': ' +
        E.Message);
    end;
  end;
  Module := nil;
end;

function TDelphiCompileGateCompiler.IsGeneratedModuleOpen(
  const AProjectFile: string): Boolean;
var
  ModuleServices: IOTAModuleServices;
  Module: IOTAModule;
begin
  // Fail closed: inability to prove absence is treated as still open.
  Result := True;
  try
    if not Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
      Exit;
    Module := ModuleServices.FindModule(ExpandFileName(AProjectFile));
    Result := Assigned(Module);
    Module := nil;
  except
    on E: Exception do
      Trace('Generated hidden module absence verification failed: ' +
        E.ClassName + ': ' + E.Message);
  end;
end;

procedure TDelphiCompileGateCompiler.CreateMinimalWrapperDproj(
  const AWrapperDproj, AWrapperMainSource, AOriginalSourceDir, APlatform,
  AConfiguration: string; const AIsPackage: Boolean);
var
  ProjectGuid: TGUID;
  ProjectName: string;
  AppType: string;
  ProjectType: string;
  PackageProperties: string;
  XML: string;

  function XMLText(const AValue: string): string;
  begin
    Result := StringReplace(AValue, '&', '&amp;', [rfReplaceAll]);
    Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
    Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
    Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
    Result := StringReplace(Result, '''', '&apos;', [rfReplaceAll]);
  end;

  function L(const AValue: string): string;
  begin
    Result := AValue + sLineBreak;
  end;
begin
  CreateGUID(ProjectGuid);
  ProjectName := ChangeFileExt(ExtractFileName(AWrapperMainSource), '');
  if AIsPackage then
  begin
    AppType := 'Package';
    ProjectType := 'Package';
    PackageProperties :=
      L('    <GenPackage>true</GenPackage>') +
      L('    <GenDll>true</GenDll>') +
      L('    <DCC_BplOutput>.\</DCC_BplOutput>') +
      L('    <DCC_DcpOutput>.\</DCC_DcpOutput>');
  end
  else
  begin
    AppType := 'Console';
    ProjectType := '';
    PackageProperties := '';
  end;

  XML :=
    L('<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">') +
    L('  <PropertyGroup>') +
    L('    <ProjectGuid>' + GUIDToString(ProjectGuid) + '</ProjectGuid>') +
    L('    <ProjectVersion>20.1</ProjectVersion>') +
    L('    <FrameworkType>None</FrameworkType>') +
    L('    <Base>True</Base>') +
    L('    <Config Condition="''$(Config)''==''''">' + XMLText(AConfiguration) + '</Config>') +
    L('    <Platform Condition="''$(Platform)''==''''">' + XMLText(APlatform) + '</Platform>') +
    L('    <TargetedPlatforms>3</TargetedPlatforms>') +
    L('    <AppType>' + AppType + '</AppType>') +
    L('    <MainSource>' + XMLText(ExtractFileName(AWrapperMainSource)) + '</MainSource>') +
    L('    <ProjectName Condition="''$(ProjectName)''==''''">' + XMLText(ProjectName) + '</ProjectName>') +
    L('  </PropertyGroup>') +
    L('  <PropertyGroup Condition="''$(Config)''==''Base'' or ''$(Base)''!=''''">') +
    L('    <Base>true</Base>') +
    L('  </PropertyGroup>') +
    L('  <PropertyGroup Condition="(''$(Platform)''==''Win32'' and ''$(Base)''==''true'') or ''$(Base_Win32)''!=''''">') +
    L('    <Base_Win32>true</Base_Win32><CfgParent>Base</CfgParent><Base>true</Base>') +
    L('  </PropertyGroup>') +
    L('  <PropertyGroup Condition="(''$(Platform)''==''Win64'' and ''$(Base)''==''true'') or ''$(Base_Win64)''!=''''">') +
    L('    <Base_Win64>true</Base_Win64><CfgParent>Base</CfgParent><Base>true</Base>') +
    L('  </PropertyGroup>') +
    L('  <PropertyGroup Condition="''$(Config)''==''Debug'' or ''$(Cfg_1)''!=''''">') +
    L('    <Cfg_1>true</Cfg_1><CfgParent>Base</CfgParent><Base>true</Base>') +
    L('    <DCC_Define>DEBUG;$(DCC_Define)</DCC_Define><DCC_Optimize>false</DCC_Optimize>') +
    L('    <DCC_GenerateStackFrames>true</DCC_GenerateStackFrames><DCC_DebugInfoInExe>true</DCC_DebugInfoInExe>') +
    L('  </PropertyGroup>') +
    L('  <PropertyGroup Condition="''$(Config)''==''Release'' or ''$(Cfg_2)''!=''''">') +
    L('    <Cfg_2>true</Cfg_2><CfgParent>Base</CfgParent><Base>true</Base>') +
    L('    <DCC_Define>RELEASE;$(DCC_Define)</DCC_Define><DCC_Optimize>true</DCC_Optimize>') +
    L('    <DCC_LocalDebugSymbols>false</DCC_LocalDebugSymbols><DCC_SymbolReferenceInfo>0</DCC_SymbolReferenceInfo>') +
    L('  </PropertyGroup>') +
    L('  <PropertyGroup Condition="''$(Base)''!=''''">') +
    L('    <DCC_UnitSearchPath>' + XMLText(ExcludeTrailingPathDelimiter(AOriginalSourceDir)) + ';$(DCC_UnitSearchPath)</DCC_UnitSearchPath>') +
    L('    <DCC_DcuOutput>.\$(Platform)\$(Config)\dcu</DCC_DcuOutput>') +
    L('    <DCC_ExeOutput>.\</DCC_ExeOutput>') +
    L('    <SanitizedProjectName>' + XMLText(ProjectName) + '</SanitizedProjectName>') +
    PackageProperties +
    L('  </PropertyGroup>') +
    L('  <ItemGroup>') +
    L('    <DelphiCompile Include="' + XMLText(ExtractFileName(AWrapperMainSource)) + '"><MainSource>MainSource</MainSource></DelphiCompile>') +
    L('    <BuildConfiguration Include="Base"><Key>Base</Key></BuildConfiguration>') +
    L('    <BuildConfiguration Include="Debug"><Key>Cfg_1</Key><CfgParent>Base</CfgParent></BuildConfiguration>') +
    L('    <BuildConfiguration Include="Release"><Key>Cfg_2</Key><CfgParent>Base</CfgParent></BuildConfiguration>') +
    L('  </ItemGroup>') +
    L('  <ProjectExtensions>') +
    L('    <Borland.Personality>Delphi.Personality.12</Borland.Personality>') +
    L('    <Borland.ProjectType>' + ProjectType + '</Borland.ProjectType>') +
    L('    <BorlandProject><Delphi.Personality><Source><Source Name="MainSource">' +
      XMLText(ExtractFileName(AWrapperMainSource)) + '</Source></Source></Delphi.Personality>') +
    L('      <Platforms><Platform value="Win32">True</Platform><Platform value="Win64">True</Platform></Platforms>') +
    L('    </BorlandProject><ProjectFileVersion>12</ProjectFileVersion>') +
    L('  </ProjectExtensions>') +
    L('  <Import Project="$(BDS)\Bin\CodeGear.Delphi.Targets" Condition="Exists(''$(BDS)\Bin\CodeGear.Delphi.Targets'')" />') +
    L('</Project>');
  TFile.WriteAllText(AWrapperDproj, XML, TEncoding.UTF8);
end;

function TDelphiCompileGateCompiler.BuildProjectWrapper(const AProjectFile,
  ADprFile, AJobId: string; const APlatform, AConfiguration: string): string;
const
  // Wrapper cleanup runs on the IDE thread. Bound it so a large stale backlog
  // never delays a newly queued Gate job for minutes.
  MAX_STALE_WRAPPERS_PER_BUILD = 4;
var
  SourceDpr: string;
  SourceDir: string;
  SourceBase: string;
  WrapperRoot: string;
  WrapperDir: string;
  WrapperName: string;
  WrapperDpr: string;
  WrapperDproj: string;
  DprText: string;
  DprojText: string;
  SourceExt: string;
  ProgramPos: Integer;
  PackagePos: Integer;
  SemiPos: Integer;
  GuidStart: Integer;
  GuidEnd: Integer;
  NewGuid: TGUID;
  OldDir: string;
  MaxAgeDays: Integer;
  EnvValue: string;
  DeletedWrappers: Integer;
begin
  SourceDpr := ADprFile;
  if SourceDpr = '' then
    SourceDpr := ChangeFileExt(AProjectFile, '.dpr');
  if (SourceDpr <> '') and (not FileExists(SourceDpr)) and
     (AProjectFile <> '') then
    SourceDpr := ChangeFileExt(AProjectFile, '.dpk');
  if not FileExists(SourceDpr) then
    raise Exception.Create('Project wrapper main source not found: ' + SourceDpr);

  WrapperRoot := TPath.Combine(ResolveDelphiCompileGateBaseDir, 'Projects');
  ForceDirectories(WrapperRoot);

  MaxAgeDays := DEFAULT_WRAPPER_MAX_AGE_DAYS;
  EnvValue := Trim(GetEnvironmentVariable('DELPHI_COMPILE_GATE_TEMP_MAX_AGE_DAYS'));
  if EnvValue <> '' then
    MaxAgeDays := StrToIntDef(EnvValue, MaxAgeDays);
  if MaxAgeDays < 1 then
    MaxAgeDays := 1;

  DeletedWrappers := 0;
  for OldDir in TDirectory.GetDirectories(WrapperRoot, '*', TSearchOption.soTopDirectoryOnly) do
  begin
    if DeletedWrappers >= MAX_STALE_WRAPPERS_PER_BUILD then
      Break;
    try
      if TDirectory.GetLastWriteTime(OldDir) < (Now - MaxAgeDays) then
      begin
        Trace('BuildProjectWrapper: deleting stale wrapper dir ' + OldDir);
        TDirectory.Delete(OldDir, True);
        Inc(DeletedWrappers);
      end;
    except
      on E: Exception do
        Trace('BuildProjectWrapper: cleanup failed for ' + OldDir + ': ' + E.ClassName + ': ' + E.Message);
    end;
  end;

  WrapperDir := TPath.Combine(WrapperRoot, AJobId);
  if DirectoryExists(WrapperDir) then
    raise Exception.Create('preexisting_wrapper_directory');
  ForceDirectories(WrapperDir);

  SourceDir := ExtractFilePath(SourceDpr);
  SourceBase := ChangeFileExt(ExtractFileName(SourceDpr), '');
  SourceExt := ExtractFileExt(SourceDpr);
  WrapperName := 'DCG_' + AJobId;
  WrapperName := StringReplace(WrapperName, '-', '_', [rfReplaceAll]);
  WrapperName := StringReplace(WrapperName, '.', '_', [rfReplaceAll]);
  WrapperName := StringReplace(WrapperName, ' ', '_', [rfReplaceAll]);

  DprText := TFile.ReadAllText(SourceDpr, TEncoding.UTF8);
  DprText := MakeDprReferencesAbsolute(DprText, SourceDir);
  DprText := MakeDprResourceReferencesAbsolute(DprText, SourceDpr);

  ProgramPos := Pos('program ', LowerCase(DprText));
  if (AProjectFile = '') and SameText(SourceExt, '.dpr') and
     (ProgramPos = 0) then
    raise Exception.Create('source_only_main_kind_unsupported');
  if ProgramPos > 0 then
  begin
    SemiPos := PosEx(';', DprText, ProgramPos);
    if SemiPos > ProgramPos then
    begin
      Delete(DprText, ProgramPos, SemiPos - ProgramPos + 1);
      Insert('program ' + WrapperName + ';', DprText, ProgramPos);
    end;
  end
  else
  begin
    PackagePos := Pos('package ', LowerCase(DprText));
    if PackagePos > 0 then
    begin
      SemiPos := PosEx(';', DprText, PackagePos);
      if SemiPos > PackagePos then
      begin
        Delete(DprText, PackagePos, SemiPos - PackagePos + 1);
        Insert('package ' + WrapperName + ';', DprText, PackagePos);
      end;
    end;
  end;

  WrapperDpr := TPath.Combine(WrapperDir, WrapperName + SourceExt);
  TFile.WriteAllText(WrapperDpr, DprText, TEncoding.UTF8);

  if (AProjectFile <> '') and FileExists(AProjectFile) then
  begin
    DprojText := TFile.ReadAllText(AProjectFile, TEncoding.UTF8);
    DprojText := MakeDprojReferencesAbsolute(DprojText,
      ExtractFilePath(AProjectFile), WrapperDir);
    if Pos('</Project>', DprojText) = 0 then
      raise Exception.Create('wrapper_project_invalid');
    GuidStart := Pos('<ProjectGuid>', DprojText);
    if GuidStart > 0 then
    begin
      GuidStart := GuidStart + Length('<ProjectGuid>');
      GuidEnd := PosEx('</ProjectGuid>', DprojText, GuidStart);
      if GuidEnd > GuidStart then
      begin
        CreateGUID(NewGuid);
        Delete(DprojText, GuidStart, GuidEnd - GuidStart);
        Insert(GUIDToString(NewGuid), DprojText, GuidStart);
      end;
    end;
    DprojText := StringReplace(DprojText, '<MainSource>' + ExtractFileName(SourceDpr) + '</MainSource>',
      '<MainSource>' + ExtractFileName(WrapperDpr) + '</MainSource>', [rfReplaceAll, rfIgnoreCase]);
    DprojText := StringReplace(DprojText, '<Source Name="MainSource">' + ExtractFileName(SourceDpr) + '</Source>',
      '<Source Name="MainSource">' + ExtractFileName(WrapperDpr) + '</Source>', [rfReplaceAll, rfIgnoreCase]);
    DprojText := StringReplace(DprojText, '<DelphiCompile Include="$(MainSource)">',
      '<DelphiCompile Include="' + ExtractFileName(WrapperDpr) + '">', [rfReplaceAll, rfIgnoreCase]);
    DprojText := SanitizeWrapperDprojSources(DprojText, ExtractFileName(WrapperDpr));
    DprojText := StringReplace(DprojText, '<ProjectName Condition="''$(ProjectName)''==''''">' + SourceBase + '</ProjectName>',
      '<ProjectName Condition="''$(ProjectName)''==''''">' + WrapperName + '</ProjectName>', [rfReplaceAll, rfIgnoreCase]);
    DprojText := StringReplace(DprojText, '<SanitizedProjectName>' + SourceBase + '</SanitizedProjectName>',
      '<SanitizedProjectName>' + WrapperName + '</SanitizedProjectName>', [rfReplaceAll, rfIgnoreCase]);
    WrapperDproj := ChangeFileExt(WrapperDpr, '.dproj');
    TFile.WriteAllText(WrapperDproj, DprojText, TEncoding.UTF8);
    ValidateWrapperDproj(WrapperDproj, ExtractFileName(WrapperDpr));
    Result := WrapperDproj;
  end
  else
  begin
    WrapperDproj := ChangeFileExt(WrapperDpr, '.dproj');
    CreateMinimalWrapperDproj(WrapperDproj, WrapperDpr, SourceDir,
      APlatform, AConfiguration, SameText(SourceExt, '.dpk'));
    ValidateWrapperDproj(WrapperDproj, ExtractFileName(WrapperDpr));
    Result := WrapperDproj;
  end;
end;

function TDelphiCompileGateCompiler.ValidateDprProject(const ADprFile,
  ASourceName, AOriginalDprFile: string; const APlatform,
  AConfiguration: string;
  out ASelectedPlatform, ASelectedConfiguration, ACompilePlatform,
  ACompileConfiguration: string; out ACompileEvidenceAvailable,
  ACompileSucceeded: Boolean;
  out ADialogHits, ADialogCloseAttempts, AKnownTechnicalDialogHits,
  AExceptionsSwallowed: Integer; out ALicenseOrEulaDetected,
  AUnknownDialogDetected: Boolean;
  out ALegalNoticeEvidence: TLegalNoticeEvidence): TCompileResult;
var
  ModuleServices: IOTAModuleServices;
  CompileServices: IOTACompileServices;
  OpenedModule: IOTAModule;
  Project: IOTAProject;
  StartTime: TDateTime;
  CompileResult: TOTACompileResult;
  WaitOK: Boolean;
  CompileNotifier: IOTACompileNotifier;
  CompileWait: TCompileWaitNotifier;
  CompileNotifierIndex: Integer;
  DialogCloser: TCompileDialogCloser;
  MessageHookInstalledByJob: Boolean;
  ProjectBuilder: IOTAProjectBuilder;
  ProjectCompileNotifier: IOTAProjectCompileNotifier;
  ProjectCompileEvidence: TProjectCompileEvidenceNotifier;
  ProjectCompileNotifierIndex: Integer;
  CaptureOnlyStarted: Boolean;
  CaptureSourceFiles: TArray<string>;
  NotifierCleanupFailed: Boolean;

  procedure SetRuntimeError(const AMessage: string);
  begin
    SetLength(Result.Errors, 1);
    Result.Errors[0].FileName := ASourceName;
    Result.Errors[0].Line := 0;
    Result.Errors[0].Column := 0;
    Result.Errors[0].ErrorCode := 'EXCEPTION';
    Result.Errors[0].ErrorText := AMessage;
    Result.Errors[0].IsWarning := False;
    Result.Errors[0].Source := '';
    Result.Errors[0].Kind := '';
    Result.Errors[0].CanonicalCode := '';
    Result.Errors[0].CanonicalMessageEn := '';
    Result.Errors[0].RawText := '';
    Result.Errors[0].Locale := '';
    PopulateDiagnosticMetadata(Result.Errors[0]);
  end;
  function HasActionableNonWarningDiagnostic(
    const AErrors: TArray<TCompileError>): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := 0 to High(AErrors) do
      if not AErrors[I].IsWarning and
         (Trim(AErrors[I].ErrorText) <> '') then
        Exit(True);
  end;
  function HasPreexistingModal: Boolean;
  var
    Popup: HWND;
    MainWindow: HWND;
  begin
    MainWindow := Application.Handle;
    if Assigned(Application.MainForm) then
      MainWindow := Application.MainForm.Handle;
    Popup := GetLastActivePopup(MainWindow);
    Result := (Popup <> 0) and (Popup <> MainWindow) and
      IsWindowVisible(Popup) and not IsWindowEnabled(MainWindow);
  end;
  procedure EnsureNoDialogBlock(const ABoundary: string);
  var
    BlockReason: string;
  begin
    if not Assigned(DialogCloser) then
      Exit;
    BlockReason := DialogCloser.BlockReason;
    if (BlockReason <> '') or DialogCloser.BlockDeadlineExceeded then
    begin
      if BlockReason = '' then
        BlockReason := 'dialog_block_deadline';
      Trace('V2 dialog block at ' + ABoundary + ': ' + BlockReason);
      raise Exception.Create('dialog_blocked');
    end;
  end;
  procedure StopDialogCloserAndCapture;
  var
    Stopped: Boolean;
  begin
    if not Assigned(DialogCloser) then
      Exit;
    try
      Stopped := DialogCloser.StopAndWait(5000);
    except
      Stopped := False;
    end;
    if not Stopped then
    begin
      Trace('Dialog closer stop timeout; evidence not read');
      DialogCloser.Terminate;
      DialogCloser.FreeOnTerminate := True;
      DialogCloser := nil;
      AUnknownDialogDetected := True;
      raise Exception.Create('dialog_closer_stop_timeout');
    end;
    ADialogHits := DialogCloser.DialogHits;
    ADialogCloseAttempts := DialogCloser.DialogCloseAttempts;
    AKnownTechnicalDialogHits := DialogCloser.KnownTechnicalDialogHits;
    ALicenseOrEulaDetected := DialogCloser.LicenseOrEulaDetected;
    AUnknownDialogDetected := DialogCloser.UnknownDialogDetected;
    ALegalNoticeEvidence := DialogCloser.LegalNoticeEvidence;
    FreeAndNil(DialogCloser);
  end;
begin
  Result.Success := False;
  SetLength(Result.Errors, 0);
  Result.OutputEXE := '';
  Result.CompileTimeMs := 0;
  ASelectedPlatform := '';
  ASelectedConfiguration := '';
  ACompilePlatform := '';
  ACompileConfiguration := '';
  ACompileEvidenceAvailable := False;
  ACompileSucceeded := False;
  ADialogHits := 0;
  ADialogCloseAttempts := 0;
  AKnownTechnicalDialogHits := 0;
  AExceptionsSwallowed := 0;
  ALicenseOrEulaDetected := False;
  AUnknownDialogDetected := False;
  ALegalNoticeEvidence := Default(TLegalNoticeEvidence);

  if FNotifierLifetimeCompromised then
    raise Exception.Create('notifier_lifetime_compromised');

  CompileNotifierIndex := -1;
  DialogCloser := nil;
  CompileNotifier := nil;
  CompileWait := nil;
  ProjectBuilder := nil;
  ProjectCompileNotifier := nil;
  ProjectCompileEvidence := nil;
  ProjectCompileNotifierIndex := -1;
  CaptureOnlyStarted := False;
  MessageHookInstalledByJob := False;
  NotifierCleanupFailed := False;
  SetLength(CaptureSourceFiles, 0);

  try
    Trace('ValidateDprProject: start ' + ADprFile);

    DrainPendingNotifiers;

    if not Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
      raise Exception.Create('IOTAModuleServices not available');

    CompileServices := GetCompileServices;
    if CompileServices.IsBackgroundCompileActive then
      CompileServices.CancelBackgroundCompile(False);

    try
      MessageHook.OnTrace := Trace;
      if not MessageHook.Installed then
      begin
        if MessageHook.Install then
        begin
          MessageHookInstalledByJob := True;
          Trace('MessageHook: VMT hook installed successfully');
        end;
      end;
      if not MessageHook.Installed or not MessageHook.CompleteCoverage then
        raise Exception.Create('message_capture_unavailable');
      MessageHook.ClearMessages;
    except
      on E: Exception do
      begin
        Trace('MessageHook setup failed: ' + E.ClassName + ': ' + E.Message);
        raise Exception.Create('message_capture_unavailable');
      end;
    end;

    CaptureSourceFiles := CollectWrapperCaptureSourceFiles(AOriginalDprFile,
      ADprFile);
    EnsureSourceBuffersMatchDisk(ModuleServices, CaptureSourceFiles);
    if not MessageHook.BeginCaptureOnly(ADprFile,
      DeriveWrapperCaptureSourceRoot(ASourceName, AOriginalDprFile, ADprFile),
      CaptureSourceFiles) then
      raise Exception.Create('message_capture_unavailable');
    CaptureOnlyStarted := True;
    if HasPreexistingModal then
      raise Exception.Create('dialog_blocked');

    DialogCloser := TCompileDialogCloser.Create(Trace, dapProtocolV2);
    Trace('Dialog closer thread started (pre-OpenProject)');

    OpenedModule := ModuleServices.OpenModule(ADprFile);
    EnsureNoDialogBlock('OpenModule');
    if not Assigned(OpenedModule) then
      raise Exception.Create('OpenModule failed: ' + ADprFile);
    if not SameText(ExpandFileName(OpenedModule.FileName),
       ExpandFileName(ADprFile)) then
      raise Exception.Create('OpenModule returned unexpected module: ' +
        OpenedModule.FileName);
    if not Supports(OpenedModule, IOTAProject, Project) then
      raise Exception.Create('Opened hidden module is not an IOTAProject: ' +
        ADprFile);
    Trace('Opened v2 wrapper as hidden IOTAProject via OpenModule: ' +
      ADprFile);

    if (APlatform <> '') and not SameText(Project.CurrentPlatform, APlatform) then
      Project.CurrentPlatform := APlatform;
    // Delphi can reset configuration when platform changes. Apply the requested
    // configuration after platform selection, then verify both immediately.
    if (AConfiguration <> '') and not SameText(Project.CurrentConfiguration, AConfiguration) then
      Project.CurrentConfiguration := AConfiguration;
    ASelectedPlatform := Project.CurrentPlatform;
    ASelectedConfiguration := Project.CurrentConfiguration;
    Trace(Format('Project target selection requested=%s/%s selected=%s/%s',
      [APlatform, AConfiguration, ASelectedPlatform, ASelectedConfiguration]));
    if ((APlatform <> '') and not SameText(ASelectedPlatform, APlatform)) or
       ((AConfiguration <> '') and
        not SameText(ASelectedConfiguration, AConfiguration)) then
      raise Exception.Create('target_selection_unavailable');

    ProjectBuilder := Project.ProjectBuilder;
    if not Assigned(ProjectBuilder) then
      raise Exception.Create('project_builder_unavailable');
    ProjectCompileEvidence := TProjectCompileEvidenceNotifier.Create;
    ProjectCompileNotifier := ProjectCompileEvidence;
    ProjectCompileNotifierIndex := ProjectBuilder.AddCompileNotifier(
      ProjectCompileNotifier);
    if ProjectCompileNotifierIndex < 0 then
      raise Exception.Create('compile_notifier_unavailable');

    StartTime := Now;
    CompileWait := TCompileWaitNotifier.Create(ADprFile);
    CompileNotifier := CompileWait;
    CompileNotifierIndex := CompileServices.AddNotifier(CompileNotifier);
    try
      if CompileNotifierIndex < 0 then
        raise Exception.Create('compile_notifier_unavailable');
      CompileResult := CompileServices.CompileProjects([Project], cmOTABuild,
        False, True);
      WaitOK := WaitForBackgroundCompile(CompileServices,
        FBackgroundCompileTimeoutMs);
      if not WaitOK then
      begin
        CompileResult := crOTAFailed;
        SetRuntimeError('Compile timeout waiting for background compile to finish.');
      end;
      EnsureNoDialogBlock('CompileProjects');

      if Assigned(DialogCloser) then
        // The v2 worker is already polling. Avoid a concurrent enumeration
        // from the caller so its evidence counters remain coherent.
        Sleep(120);
      // Give the V2 worker one final polling interval, then consume any
      // blocker it observed before classifying or promoting this job result.
      EnsureNoDialogBlock('CompileProjectsSettled');

      if CompileWait.HasResult then
      begin
        CompileResult := CompileWait.CompileResult;
        Trace('Compile notifier result captured: ' + IntToStr(Integer(CompileResult)));
      end;
    finally
      if Assigned(ProjectCompileEvidence) then
      begin
        ACompileEvidenceAvailable := ProjectCompileEvidence.AfterSeen;
        ACompilePlatform := ProjectCompileEvidence.Platform;
        ACompileConfiguration := ProjectCompileEvidence.Configuration;
        ACompileSucceeded := ProjectCompileEvidence.CompileSucceeded;
        ProjectCompileEvidence.Deactivate;
      end;
      if (ProjectCompileNotifierIndex >= 0) and Assigned(ProjectBuilder) then
      begin
        try
          ProjectBuilder.RemoveCompileNotifier(ProjectCompileNotifierIndex);
        except
          on E: Exception do
          begin
            NotifierCleanupFailed := True;
            FNotifierLifetimeCompromised := True;
            Trace('RemoveCompileNotifier exception: ' + E.ClassName + ': ' + E.Message);
          end;
        end;
        ProjectCompileNotifierIndex := -1;
      end;
      if Assigned(ProjectCompileNotifier) and
         Assigned(FPendingProjectCompileNotifiers) then
        FPendingProjectCompileNotifiers.Add(ProjectCompileNotifier);
      ProjectCompileEvidence := nil;
      ProjectCompileNotifier := nil;
      ProjectBuilder := nil;

      StopDialogCloserAndCapture;

      if Assigned(CompileWait) then
        CompileWait.Deactivate;
      if CompileNotifierIndex >= 0 then
      begin
        try
          CompileServices.RemoveNotifier(CompileNotifierIndex);
        except
          on E: Exception do
          begin
            NotifierCleanupFailed := True;
            FNotifierLifetimeCompromised := True;
            Trace('RemoveNotifier exception: ' + E.ClassName + ': ' + E.Message);
          end;
        end;
      end;

      if Assigned(CompileNotifier) and Assigned(FPendingNotifiers) then
        FPendingNotifiers.Add(CompileNotifier);
      CompileWait := nil;
      CompileNotifier := nil;
    end;

    if NotifierCleanupFailed then
      raise Exception.Create('notifier_cleanup_failed');
    Result.CompileTimeMs := MilliSecondsBetween(Now, StartTime);
    if MessageHook.CaptureFailed then
      raise Exception.Create('message_capture_unavailable');
    CollectErrorsFromIDE(Result.Errors);

    // The target-specific project notifier is authoritative for v2. The
    // aggregate CompileProjects result can be failed by informational IDE
    // output even though this wrapper project compiled successfully.
    Result.Success := ACompileEvidenceAvailable and ACompileSucceeded;
    for var Error in Result.Errors do
      if not Error.IsWarning then
      begin
        Result.Success := False;
        Break;
      end;

    if not Result.Success then
      Sleep(80);

    // A target notifier failure is a completed compiler outcome, but without
    // an actionable captured error it must not be disguised as an exception.
    if ACompileEvidenceAvailable and
       (not ACompileSucceeded) and not HasActionableNonWarningDiagnostic(Result.Errors) then
      raise Exception.Create('compile_error_details_unavailable');

    if Result.Success then
    begin
      Result.OutputEXE := ChangeFileExt(ADprFile, '.exe');
      if not FileExists(Result.OutputEXE) then
        Result.OutputEXE := '';
    end;

    Trace(Format('ValidateDprProject result: success=%s compile_ms=%d errors=%d',
      [BoolToStr(Result.Success, True), Result.CompileTimeMs, Length(Result.Errors)]));
  finally
    StopDialogCloserAndCapture;

    if Assigned(ProjectCompileEvidence) then
      ProjectCompileEvidence.Deactivate;
    if (ProjectCompileNotifierIndex >= 0) and Assigned(ProjectBuilder) then
    begin
      try
        ProjectBuilder.RemoveCompileNotifier(ProjectCompileNotifierIndex);
      except
        on E: Exception do
        begin
          FNotifierLifetimeCompromised := True;
          Trace('Outer RemoveCompileNotifier exception: ' +
            E.ClassName + ': ' + E.Message);
        end;
      end;
    end;
    if Assigned(ProjectCompileNotifier) and
       Assigned(FPendingProjectCompileNotifiers) then
      FPendingProjectCompileNotifiers.Add(ProjectCompileNotifier);
    ProjectCompileEvidence := nil;
    ProjectCompileNotifier := nil;
    ProjectBuilder := nil;
    if CaptureOnlyStarted then
    begin
      try
        MessageHook.EndCaptureOnly;
      except
        on E: Exception do
          Trace('MessageHook capture-only cleanup failed: ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    if MessageHookInstalledByJob then
    begin
      try
        if not MessageHook.Uninstall then
          raise Exception.Create('message_hook_uninstall_failed');
      except
        on E: Exception do
        begin
          Trace('MessageHook job cleanup failed: ' + E.ClassName + ': ' + E.Message);
          raise;
        end;
      end;
    end;
  end;
end;

function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(
  const AProjectFile, ADprFile, AJobId, APlatform, AConfiguration: string;
  out AWrapperProject, AWrapperMainSource, ASelectedPlatform,
  ASelectedConfiguration, ACompilePlatform, ACompileConfiguration: string;
  out ACompileEvidenceAvailable, ACompileSucceeded: Boolean;
  const AExpectedProjectSize, AExpectedMainSourceSize: Int64;
  const AExpectedProjectHash, AExpectedMainSourceHash: string;
  out ADialogHits, ADialogCloseAttempts, AKnownTechnicalDialogHits,
  AExceptionsSwallowed: Integer; out ALicenseOrEulaDetected,
  AUnknownDialogDetected: Boolean;
  out ALegalNoticeEvidence: TLegalNoticeEvidence): TCompileResult;
var
  SourceDpr: string;
  SourceName: string;
  ArtifactExt: string;
  CompiledOutput: string;

  function FileMatches(const APath: string; const AExpectedSize: Int64;
    const AExpectedHash: string): Boolean;
  var
    Bytes: TBytes;
    Stream: TBytesStream;
    ActualHash: string;
    Attr: DWORD;
  begin
    Result := False;
    if not FileExists(APath) then Exit;
    Attr := GetFileAttributes(PChar(APath));
    if (Attr = INVALID_FILE_ATTRIBUTES) or
       ((Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
      Exit;
    Bytes := TFile.ReadAllBytes(APath);
    if Length(Bytes) <> AExpectedSize then Exit;
    Stream := TBytesStream.Create(Bytes);
    try
      ActualHash := LowerCase(THashSHA2.GetHashString(Stream));
    finally
      Stream.Free;
    end;
    Result := ActualHash = AExpectedHash;
  end;

  procedure VerifyInputs(const AFailureCode: string);
  begin
    if ((AProjectFile <> '') and
        not FileMatches(AProjectFile, AExpectedProjectSize, AExpectedProjectHash)) or
       not FileMatches(ADprFile, AExpectedMainSourceSize,
         AExpectedMainSourceHash) then
      raise Exception.Create(AFailureCode);
  end;
begin
  VerifyInputs('input_hash_mismatch');
  SourceDpr := ADprFile;
  if SourceDpr = '' then
    SourceDpr := ChangeFileExt(AProjectFile, '.dpr');
  AWrapperProject := BuildProjectWrapper(AProjectFile, ADprFile, AJobId,
    APlatform, AConfiguration);
  AWrapperMainSource := ChangeFileExt(AWrapperProject, ExtractFileExt(ADprFile));
  if not FileExists(AWrapperMainSource) then
  begin
    if not FileExists(SourceDpr) then
      SourceDpr := ChangeFileExt(AProjectFile, '.dpk');
    AWrapperMainSource := ChangeFileExt(AWrapperProject, ExtractFileExt(SourceDpr));
  end;

  VerifyInputs('input_hash_changed');

  if AProjectFile <> '' then
    SourceName := AProjectFile
  else
    SourceName := SourceDpr;
  if SameText(ExtractFileExt(AWrapperMainSource), '.dpk') then
    ArtifactExt := '.bpl'
  else
    ArtifactExt := '.exe';
  Result := ValidateDprProject(AWrapperProject, SourceName, SourceDpr,
    APlatform, AConfiguration,
    ASelectedPlatform, ASelectedConfiguration,
    ACompilePlatform, ACompileConfiguration, ACompileEvidenceAvailable,
    ACompileSucceeded, ADialogHits, ADialogCloseAttempts,
    AKnownTechnicalDialogHits, AExceptionsSwallowed, ALicenseOrEulaDetected,
    AUnknownDialogDetected, ALegalNoticeEvidence);
  Result.OutputEXE := TPath.Combine(ExtractFilePath(AWrapperProject),
    ChangeFileExt(ExtractFileName(AWrapperMainSource), ArtifactExt));
  if Result.Success and SameText(ArtifactExt, '.exe') then
  begin
    CompiledOutput := FindWrapperOutputEXE(SourceDpr, AWrapperProject, AJobId);
    if (CompiledOutput <> '') and
       not SameText(ExpandFileName(CompiledOutput),
         ExpandFileName(Result.OutputEXE)) then
      TFile.Copy(CompiledOutput, Result.OutputEXE, True);
  end;
  if not FileExists(Result.OutputEXE) then
    Result.OutputEXE := '';
end;

constructor TDelphiCompileGateCompiler.Create;
begin
  inherited;
  FBackgroundCompileTimeoutMs := DEFAULT_COMPILE_TIMEOUT_MS;
  FPendingNotifiers := TList<IOTACompileNotifier>.Create;
  FPendingProjectCompileNotifiers := TList<IOTAProjectCompileNotifier>.Create;
  FNotifierLifetimeCompromised := False;
end;

procedure TDelphiCompileGateCompiler.SetBackgroundCompileTimeoutMs(
  const AValue: Cardinal);
begin
  if (AValue < MIN_COMPILE_TIMEOUT_MS) or
     (AValue > MAX_COMPILE_TIMEOUT_MS) then
    raise EArgumentOutOfRangeException.CreateFmt(
      'Compile timeout must be between %d and %d ms.',
      [MIN_COMPILE_TIMEOUT_MS, MAX_COMPILE_TIMEOUT_MS]);
  FBackgroundCompileTimeoutMs := AValue;
end;

destructor TDelphiCompileGateCompiler.Destroy;
begin
  try
    if Assigned(FPendingNotifiers) then
    begin
      FPendingNotifiers.Clear;
      FPendingNotifiers.Free;
      FPendingNotifiers := nil;
    end;
    if Assigned(FPendingProjectCompileNotifiers) then
    begin
      FPendingProjectCompileNotifiers.Clear;
      FPendingProjectCompileNotifiers.Free;
      FPendingProjectCompileNotifiers := nil;
    end;
  except
    // ignore
  end;
  inherited;
end;

procedure TDelphiCompileGateCompiler.DrainPendingNotifiers;
begin
  // Called at the start of each compile job. By this point all callbacks from
  // the previous job have completed, so retained interface references are safe
  // to release.
  try
    if FNotifierLifetimeCompromised then
    begin
      Trace('Pending notifier refs retained: notifier lifetime is compromised');
      Exit;
    end;
    if Assigned(FPendingNotifiers) and (FPendingNotifiers.Count > 0) then
    begin
      Trace(Format('Draining %d pending notifier ref(s)', [FPendingNotifiers.Count]));
      FPendingNotifiers.Clear;
    end;
    if Assigned(FPendingProjectCompileNotifiers) and
       (FPendingProjectCompileNotifiers.Count > 0) then
    begin
      Trace(Format('Draining %d pending project notifier ref(s)',
        [FPendingProjectCompileNotifiers.Count]));
      FPendingProjectCompileNotifiers.Clear;
    end;
  except
    // ignore
  end;
end;

procedure TDelphiCompileGateCompiler.ReleasePendingNotifiers;
begin
  DrainPendingNotifiers;
end;

function TDelphiCompileGateCompiler.GetCompileServices: IOTACompileServices;
begin
  if not Supports(BorlandIDEServices, IOTACompileServices, Result) then
    raise Exception.Create('IOTACompileServices not available');
end;

function TDelphiCompileGateCompiler.WaitForBackgroundCompile(
  const ACompileServices: IOTACompileServices; const ATimeoutMs: Cardinal): Boolean;
var
  StartTick: Cardinal;
  TimedOut: Boolean;
begin
  Result := True;
  if not Assigned(ACompileServices) then
    Exit;

  StartTick := GetTickCount;
  TimedOut := False;
  while ACompileServices.IsBackgroundCompileActive do
  begin
    Sleep(100);
    if not TimedOut and ((GetTickCount - StartTick) >= ATimeoutMs) then
    begin
      Result := False;
      TimedOut := True;
      // Never finalize a v2 result or tear down its evidence monitors while
      // the IDE compiler is still active. The threshold marks failure, but the
      // worker remains fail-closed until the compiler has actually settled.
      Trace('Background compile timeout reached; waiting for compiler to settle');
    end;
  end;
end;

procedure TDelphiCompileGateCompiler.CollectErrorsFromIDE(
  out AErrors: TArray<TCompileError>);
var
  HookedMsgs: TArray<TCapturedMessage>;
  N: Integer;
  Sev: TMessageSeverity;
begin
  SetLength(AErrors, 0);
  try
    HookedMsgs := MessageHook.GetMessages;
  except
    on E: Exception do
    begin
      Trace('CollectErrorsFromIDE: MessageHook.GetMessages failed: ' + E.Message);
      SetLength(HookedMsgs, 0);
    end;
  end;

  if Length(HookedMsgs) > 0 then
  begin
    Trace(Format('CollectErrorsFromIDE: VMT-hook captured %d message(s)',
      [Length(HookedMsgs)]));
    for N := 0 to High(HookedMsgs) do
    begin
      if (HookedMsgs[N].GroupName <> '') and
         (Pos('compil', LowerCase(HookedMsgs[N].GroupName)) = 0) and
         (Pos('build', LowerCase(HookedMsgs[N].GroupName)) = 0) and
         (Pos('output', LowerCase(HookedMsgs[N].GroupName)) = 0) then
        Continue;

      SetLength(AErrors, Length(AErrors) + 1);
      AErrors[High(AErrors)].FileName := HookedMsgs[N].FileName;
      AErrors[High(AErrors)].Line := HookedMsgs[N].LineNumber;
      AErrors[High(AErrors)].Column := HookedMsgs[N].ColumnNumber;
      AErrors[High(AErrors)].ErrorCode := HookedMsgs[N].ToolName;
      AErrors[High(AErrors)].ErrorText := HookedMsgs[N].MessageText;
      Sev := HookedMsgs[N].Severity;
      AErrors[High(AErrors)].IsWarning := (Sev = msHint) or
        (Sev = msWarning) or (Sev = msInfo);
      AErrors[High(AErrors)].Source := '';
      AErrors[High(AErrors)].Kind := '';
      AErrors[High(AErrors)].CanonicalCode := '';
      AErrors[High(AErrors)].CanonicalMessageEn := '';
      AErrors[High(AErrors)].RawText := '';
      AErrors[High(AErrors)].Locale := '';
      PopulateDiagnosticMetadata(AErrors[High(AErrors)]);
    end;
    if Length(AErrors) > 0 then
    begin
      Trace(Format('CollectErrorsFromIDE: using %d hook messages, skipping RTTI-scan',
        [Length(AErrors)]));
      Exit;
    end;
  end;
  Trace('CollectErrorsFromIDE: capture-only job has no hook diagnostics');
end;

end.
