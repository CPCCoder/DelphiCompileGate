unit DelphiCompileGate.ProtocolV2;

interface

uses
  System.SysUtils, System.JSON,
  DelphiCompileGate.Compiler;

type
  TV2FileEvidence = record
    Path: string;
    Size: Int64;
    SHA256: string;
  end;

  TV2Request = class
  public
    JobId: string;
    Nonce: string;
    RequestHash: string;
    Platform: string;
    Configuration: string;
    HasProject: Boolean;
    Project: TV2FileEvidence;
    MainSource: TV2FileEvidence;
  end;

function TryLoadV2Request(const AJobFile: string;
  out ARequest: TV2Request; out AFailureCode: string): Boolean;
function VerifyV2InputEvidence(const ARequest: TV2Request): Boolean;
function BuildV2Result(const ARequest: TV2Request; const ACompileResult: TCompileResult;
  const AWrapperProject, AWrapperMainSource, ASelectedPlatform,
  ASelectedConfiguration, ACompilePlatform, ACompileConfiguration: string;
  const ACompileEvidenceAvailable, ACompileSucceeded: Boolean;
  const ADialogHits, ADialogCloseAttempts, AKnownTechnicalDialogHits,
  AExceptionsSwallowed: Integer; const ALicenseOrEulaDetected,
  AUnknownDialogDetected: Boolean;
  const ALegalNoticeEvidence: TLegalNoticeEvidence;
  const AFailureCode: string): TJSONObject;
function BuildV2Failure(const ARequest: TV2Request; const AFailureCode: string): TJSONObject;

implementation

uses
  Winapi.Windows, System.Classes, System.IOUtils, System.Hash, System.StrUtils,
  DelphiCompileGate.BuildInfo;

const
  HASH_ZERO = '0000000000000000000000000000000000000000000000000000000000000000';

  DCG_GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = $00000002;
  DCG_GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = $00000004;

function DCGGetModuleHandleExW(dwFlags: DWORD; lpModuleName: PWideChar;
  var phModule: HMODULE): BOOL; stdcall; external 'kernel32.dll' name 'GetModuleHandleExW';

function IsAllowedV2Target(const APlatform, AConfiguration: string): Boolean;
begin
  Result := ((APlatform = 'Win32') or (APlatform = 'Win64')) and
    ((AConfiguration = 'Debug') or (AConfiguration = 'Release'));
end;

function IsLowerHex(const S: string; const ALen: Integer): Boolean;
var
  C: Char;
begin
  Result := Length(S) = ALen;
  if not Result then Exit;
  for C in S do
    if not (C in ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

function IsJobId(const S: string): Boolean;
var
  C: Char;
begin
  Result := (Length(S) >= 1) and (Length(S) <= 64) and
    (S[1] in ['a'..'z', '0'..'9']);
  if not Result then Exit;
  for C in S do
    if not (C in ['a'..'z', '0'..'9', '_', '-']) then
      Exit(False);
end;

function HashBytes(const ABytes: TBytes): string;
var
  Stream: TBytesStream;
begin
  Stream := TBytesStream.Create(ABytes);
  try
    Result := LowerCase(THashSHA2.GetHashString(Stream));
  finally
    Stream.Free;
  end;
end;

function FileEvidence(const APath: string): TV2FileEvidence;
var
  Bytes: TBytes;
  Attempt: Integer;
begin
  Result.Path := APath;
  SetLength(Bytes, 0);
  for Attempt := 0 to 99 do
    try
      Bytes := TFile.ReadAllBytes(APath);
      Break;
    except
      on E: EInOutError do
      begin
        if Attempt = 99 then
          raise;
        Sleep(50);
      end;
    end;
  Result.Size := Length(Bytes);
  Result.SHA256 := HashBytes(Bytes);
end;

function IsRegularAbsoluteFile(const APath: string; const AExtensions: array of string): Boolean;
var
  Attr: DWORD;
  Ext: string;
  I: Integer;
begin
  Result := False;
  if (APath = '') or not TPath.IsPathRooted(APath) then Exit;
  Attr := GetFileAttributes(PChar(APath));
  if (Attr = INVALID_FILE_ATTRIBUTES) or ((Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0) or
     ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then Exit;
  Ext := ExtractFileExt(APath);
  for I := Low(AExtensions) to High(AExtensions) do
    if SameText(Ext, AExtensions[I]) then Exit(True);
end;

function CanonicalFinalPath(const APath: string; const ADirectory: Boolean): string;
var
  Handle: THandle;
  Flags: DWORD;
  Needed: DWORD;
  Buffer: TArray<Char>;
begin
  Result := '';
  Flags := FILE_ATTRIBUTE_NORMAL;
  if ADirectory then Flags := Flags or FILE_FLAG_BACKUP_SEMANTICS;
  Handle := CreateFile(PChar(APath), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or
    FILE_SHARE_DELETE, nil, OPEN_EXISTING, Flags, 0);
  if Handle = INVALID_HANDLE_VALUE then Exit;
  try
    Needed := GetFinalPathNameByHandle(Handle, nil, 0, FILE_NAME_NORMALIZED);
    if Needed = 0 then Exit;
    SetLength(Buffer, Needed + 1);
    Needed := GetFinalPathNameByHandle(Handle, PChar(@Buffer[0]), Length(Buffer),
      FILE_NAME_NORMALIZED);
    if (Needed = 0) or (Needed >= DWORD(Length(Buffer))) then Exit;
    SetString(Result, PChar(@Buffer[0]), Needed);
    if StartsText('\\?\UNC\', Result) then
      Result := '\\' + Copy(Result, 9, MaxInt)
    else if StartsText('\\?\', Result) then
      Delete(Result, 1, 4);
  finally
    CloseHandle(Handle);
  end;
end;

function HasExactFields(const AObject: TJSONObject; const ANames: array of string): Boolean;
var
  Pair: TJSONPair;
  I: Integer;
  Found: Boolean;
begin
  Result := Assigned(AObject) and (AObject.Count = Length(ANames));
  if not Result then Exit;
  for Pair in AObject do
  begin
    Found := False;
    for I := Low(ANames) to High(ANames) do
      if Pair.JsonString.Value = ANames[I] then
      begin
        Found := True;
        Break;
      end;
    if not Found then Exit(False);
  end;
end;

function StringField(const AObject: TJSONObject; const AName: string; out AValue: string): Boolean;
var
  Value: TJSONValue;
begin
  Value := AObject.GetValue(AName);
  Result := Value is TJSONString;
  if Result then AValue := Value.Value else AValue := '';
end;

function NumberIsTwo(const AObject: TJSONObject; const AName: string): Boolean;
var
  Value: TJSONValue;
begin
  Value := AObject.GetValue(AName);
  Result := (Value is TJSONNumber) and (Value.Value = '2');
end;

function ParseEvidence(const AObject: TJSONObject; out AEvidence: TV2FileEvidence): Boolean;
var
  SizeValue: TJSONValue;
  Parsed: TV2FileEvidence;
begin
  Result := False;
  if not HasExactFields(AObject, ['path', 'size', 'sha256']) then Exit;
  if not StringField(AObject, 'path', Parsed.Path) then Exit;
  if not StringField(AObject, 'sha256', Parsed.SHA256) or not IsLowerHex(Parsed.SHA256, 64) then Exit;
  SizeValue := AObject.GetValue('size');
  if not (SizeValue is TJSONNumber) or not TryStrToInt64(SizeValue.Value, Parsed.Size) or
     (Parsed.Size < 0) then Exit;
  AEvidence := Parsed;
  Result := True;
end;

function ParseNullableEvidence(const AObject: TJSONObject;
  out AEvidence: TV2FileEvidence; out AHasEvidence: Boolean): Boolean;
var
  PathValue: TJSONValue;
  SizeValue: TJSONValue;
  HashValue: TJSONValue;
begin
  Result := False;
  AHasEvidence := False;
  AEvidence.Path := '';
  AEvidence.Size := -1;
  AEvidence.SHA256 := '';
  if not HasExactFields(AObject, ['path', 'size', 'sha256']) then
    Exit;
  PathValue := AObject.GetValue('path');
  SizeValue := AObject.GetValue('size');
  HashValue := AObject.GetValue('sha256');
  if (PathValue is TJSONNull) and (SizeValue is TJSONNull) and
     (HashValue is TJSONNull) then
    Exit(True);
  if not ParseEvidence(AObject, AEvidence) then
    Exit;
  AHasEvidence := True;
  Result := True;
end;

function VerifyV2InputEvidence(const ARequest: TV2Request): Boolean;
var
  ActualProject, ActualMain: TV2FileEvidence;
begin
  Result := False;
  if not Assigned(ARequest) then Exit;
  try
    ActualMain := FileEvidence(ARequest.MainSource.Path);
    Result := (ActualMain.Size = ARequest.MainSource.Size) and
      (ActualMain.SHA256 = ARequest.MainSource.SHA256);
    if Result and ARequest.HasProject then
    begin
      ActualProject := FileEvidence(ARequest.Project.Path);
      Result := (ActualProject.Size = ARequest.Project.Size) and
        (ActualProject.SHA256 = ARequest.Project.SHA256);
    end;
  except
    Result := False;
  end;
end;

function TryLoadV2Request(const AJobFile: string;
  out ARequest: TV2Request; out AFailureCode: string): Boolean;
var
  Bytes: TBytes;
  RoundTrip: TBytes;
  Text: string;
  Root, InputObject, TargetObject: TJSONObject;
  HashMarker, ZeroText, Kind: string;
  ExpectedJobId: string;
  CanonicalProject, CanonicalMain: string;
begin
  Result := False;
  ARequest := TV2Request.Create;
  ExpectedJobId := ChangeFileExt(ChangeFileExt(ExtractFileName(AJobFile), ''), '');
  ARequest.JobId := ExpectedJobId;
  AFailureCode := 'invalid_request';
  Root := nil;
  try
    try
      Bytes := TFile.ReadAllBytes(AJobFile);
    if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
      Exit;
    Text := TEncoding.UTF8.GetString(Bytes);
    RoundTrip := TEncoding.UTF8.GetBytes(Text);
    if (Length(RoundTrip) <> Length(Bytes)) or
       ((Length(Bytes) > 0) and not CompareMem(@Bytes[0], @RoundTrip[0], Length(Bytes))) then
      Exit;
    Root := TJSONObject.ParseJSONValue(Text) as TJSONObject;
    if Assigned(Root) then
    begin
      StringField(Root, 'job_id', ARequest.JobId);
      StringField(Root, 'nonce', ARequest.Nonce);
      StringField(Root, 'request_hash', ARequest.RequestHash);
      TargetObject := Root.GetValue('target') as TJSONObject;
      if Assigned(TargetObject) then
      begin
        StringField(TargetObject, 'platform', ARequest.Platform);
        StringField(TargetObject, 'configuration', ARequest.Configuration);
      end;
    end;
    if not HasExactFields(Root, ['input', 'job_id', 'kind', 'nonce', 'protocol',
      'request_hash', 'schema_version', 'target']) then Exit;
    if not NumberIsTwo(Root, 'schema_version') or not NumberIsTwo(Root, 'protocol') then Exit;
    if not StringField(Root, 'job_id', ARequest.JobId) or not IsJobId(ARequest.JobId) then Exit;
    if ARequest.JobId <> ExpectedJobId then
    begin
      AFailureCode := 'job_id_mismatch';
      Exit;
    end;
    if not StringField(Root, 'nonce', ARequest.Nonce) or not IsLowerHex(ARequest.Nonce, 32) then Exit;
    if not StringField(Root, 'request_hash', ARequest.RequestHash) or
       not IsLowerHex(ARequest.RequestHash, 64) then Exit;
    if not StringField(Root, 'kind', Kind) or (Kind <> 'project_wrapper_build') then Exit;

    TargetObject := Root.GetValue('target') as TJSONObject;
    if not HasExactFields(TargetObject, ['configuration', 'platform']) then Exit;
    if not StringField(TargetObject, 'platform', ARequest.Platform) or
       not StringField(TargetObject, 'configuration', ARequest.Configuration) or
       not IsAllowedV2Target(ARequest.Platform, ARequest.Configuration) then Exit;

    InputObject := Root.GetValue('input') as TJSONObject;
    if not HasExactFields(InputObject, ['main_source', 'project']) then Exit;
    if not ParseNullableEvidence(InputObject.GetValue('project') as TJSONObject,
      ARequest.Project, ARequest.HasProject) then Exit;
    if not ParseEvidence(InputObject.GetValue('main_source') as TJSONObject, ARequest.MainSource) then Exit;
    if not IsRegularAbsoluteFile(ARequest.MainSource.Path, ['.dpr', '.dpk']) then Exit;
    if ARequest.HasProject and
       not IsRegularAbsoluteFile(ARequest.Project.Path, ['.dproj']) then Exit;
    CanonicalMain := CanonicalFinalPath(ARequest.MainSource.Path, False);
    if (CanonicalMain = '') or
       not SameText(ARequest.MainSource.Path, CanonicalMain) then Exit;
    if ARequest.HasProject then
    begin
      CanonicalProject := CanonicalFinalPath(ARequest.Project.Path, False);
      if (CanonicalProject = '') or
         not SameText(ARequest.Project.Path, CanonicalProject) or
         not SameText(ExcludeTrailingPathDelimiter(ExtractFilePath(CanonicalProject)),
           ExcludeTrailingPathDelimiter(ExtractFilePath(CanonicalMain))) or
         not SameText(ChangeFileExt(ExtractFileName(CanonicalProject), ''),
           ChangeFileExt(ExtractFileName(CanonicalMain), '')) then
      begin
        AFailureCode := 'project_main_mismatch';
        Exit;
      end;
    end;
    HashMarker := '"request_hash":"' + ARequest.RequestHash + '"';
    if Pos(HashMarker, Text) = 0 then Exit;
    ZeroText := StringReplace(Text, HashMarker, '"request_hash":"' + HASH_ZERO + '"', []);
    if HashBytes(TEncoding.UTF8.GetBytes(ZeroText)) <> ARequest.RequestHash then
    begin
      AFailureCode := 'request_hash_mismatch';
      Exit;
    end;

    if not VerifyV2InputEvidence(ARequest) then
    begin
      AFailureCode := 'input_hash_mismatch';
      Exit;
    end;
      Result := True;
    except
      on E: Exception do
        AFailureCode := 'invalid_request';
    end;
  finally
    Root.Free;
    if not Result then
      ARequest.JobId := ExpectedJobId;
    if not IsJobId(ARequest.JobId) then
      ARequest.JobId := '';
  end;
end;

function NullValue: TJSONValue;
begin
  Result := TJSONNull.Create;
end;

function EvidenceJSON(const AEvidence: TV2FileEvidence): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('path', AEvidence.Path);
  Result.AddPair('size', TJSONNumber.Create(IntToStr(AEvidence.Size)));
  Result.AddPair('sha256', AEvidence.SHA256);
end;

function NullableEvidenceJSON(const APath: string): TJSONObject;
var
  Evidence: TV2FileEvidence;
  Attr: DWORD;
begin
  if (APath <> '') and FileExists(APath) then
  begin
    Attr := GetFileAttributes(PChar(APath));
    if (Attr <> INVALID_FILE_ATTRIBUTES) and
       ((Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) = 0) then
      Exit(EvidenceJSON(FileEvidence(APath)));
  end;
  Result := TJSONObject.Create;
  Result.AddPair('path', NullValue);
  Result.AddPair('size', NullValue);
  Result.AddPair('sha256', NullValue);
end;

function RequestEvidenceJSON(const AEvidence: TV2FileEvidence): TJSONObject;
begin
  if (AEvidence.Path <> '') and (AEvidence.Size >= 0) and
     IsLowerHex(AEvidence.SHA256, 64) then
    Exit(EvidenceJSON(AEvidence));
  Result := NullableEvidenceJSON('');
end;

function LoadedPackagePath: string;
var
  Module: HMODULE;
  Buffer: TArray<Char>;
  BufferSize: Integer;
  Written: DWORD;
begin
  Result := '';
  Module := 0;
  if not DCGGetModuleHandleExW(DCG_GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or
    DCG_GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    PWideChar(@LoadedPackagePath), Module) then
    Exit;
  BufferSize := 512;
  while BufferSize <= 32768 do
  begin
    SetLength(Buffer, BufferSize);
    Written := GetModuleFileName(Module, PChar(@Buffer[0]), BufferSize);
    if Written = 0 then Exit;
    if Written < DWORD(BufferSize - 1) then
    begin
      SetString(Result, PChar(@Buffer[0]), Written);
      Exit;
    end;
    BufferSize := BufferSize * 2;
  end;
end;

function IdentityJSON(out AAvailable: Boolean): TJSONObject;
var
  PackagePath: string;
  PackageHash: string;
  IdePath: string;
begin
  PackagePath := LoadedPackagePath;
  IdePath := ParamStr(0);
  AAvailable := False;
  PackageHash := '';
  if (PackagePath <> '') and SameText(ExtractFileExt(PackagePath), '.bpl') and
     FileExists(PackagePath) then
    try
      PackageHash := FileEvidence(PackagePath).SHA256;
      AAvailable := PackageHash <> '';
    except
      AAvailable := False;
    end;
  Result := TJSONObject.Create;
  Result.AddPair('protocol', TJSONNumber.Create(DCG_PROTOCOL_VERSION));
  Result.AddPair('plugin_version', DCG_PLUGIN_VERSION);
  Result.AddPair('package_build_id', DCG_PACKAGE_BUILD_ID);
  if AAvailable then
  begin
    Result.AddPair('loaded_package_path', PackagePath);
    Result.AddPair('loaded_package_sha256', PackageHash);
  end
  else
  begin
    Result.AddPair('loaded_package_path', NullValue);
    Result.AddPair('loaded_package_sha256', NullValue);
  end;
  if IdePath <> '' then Result.AddPair('ide_path', IdePath)
  else Result.AddPair('ide_path', NullValue);
  Result.AddPair('ide_version', DCG_IDE_VERSION);
  Result.AddPair('compiler_version', TJSONNumber.Create(CompilerVersion));
end;

function LegalNoticeJSON(
  const AEvidence: TLegalNoticeEvidence): TJSONObject;
var
  Buttons: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('detected', TJSONBool.Create(AEvidence.Detected));
  if AEvidence.Detected then
  begin
    Result.AddPair('classification', AEvidence.Classification);
    Result.AddPair('window_class', AEvidence.WindowClass);
    if AEvidence.Title <> '' then Result.AddPair('title', AEvidence.Title)
    else Result.AddPair('title', NullValue);
    Result.AddPair('text_available', TJSONBool.Create(AEvidence.TextAvailable));
    if AEvidence.TextAvailable then
    begin
      Result.AddPair('text', AEvidence.Text);
      Result.AddPair('text_sha256', AEvidence.TextSHA256);
    end
    else
    begin
      Result.AddPair('text', NullValue);
      Result.AddPair('text_sha256', NullValue);
    end;
    Result.AddPair('text_length', TJSONNumber.Create(AEvidence.TextLength));
    Buttons := TJSONArray.Create;
    if AEvidence.Button <> '' then
      Buttons.Add(AEvidence.Button);
    Result.AddPair('available_buttons', Buttons);
    Result.AddPair('action', AEvidence.Action);
    Result.AddPair('accepted_terms', TJSONBool.Create(False));
  end
  else
  begin
    Result.AddPair('classification', NullValue);
    Result.AddPair('window_class', NullValue);
    Result.AddPair('title', NullValue);
    Result.AddPair('text_available', TJSONBool.Create(False));
    Result.AddPair('text', NullValue);
    Result.AddPair('text_length', TJSONNumber.Create(0));
    Result.AddPair('text_sha256', NullValue);
    Result.AddPair('available_buttons', TJSONArray.Create);
    Result.AddPair('action', NullValue);
    Result.AddPair('accepted_terms', TJSONBool.Create(False));
  end;
end;

function BuildV2Result(const ARequest: TV2Request; const ACompileResult: TCompileResult;
  const AWrapperProject, AWrapperMainSource, ASelectedPlatform,
  ASelectedConfiguration, ACompilePlatform, ACompileConfiguration: string;
  const ACompileEvidenceAvailable, ACompileSucceeded: Boolean;
  const ADialogHits, ADialogCloseAttempts, AKnownTechnicalDialogHits,
  AExceptionsSwallowed: Integer; const ALicenseOrEulaDetected,
  AUnknownDialogDetected: Boolean;
  const ALegalNoticeEvidence: TLegalNoticeEvidence;
  const AFailureCode: string): TJSONObject;
var
  RequestedTarget, EffectiveTarget, InputObject, WrapperObject: TJSONObject;
  CompileObject, InterventionsObject, IdentityObject: TJSONObject;
  Errors: TJSONArray;
  I: Integer;
  FailureCode: string;
  TargetMatched: Boolean;
  WrapperEvidenceAvailable: Boolean;
  ArtifactAvailable: Boolean;
  PackageIdentityAvailable: Boolean;
  InterventionFree: Boolean;
  PolicyCompliant: Boolean;
  Success: Boolean;
begin
  FailureCode := AFailureCode;
  TargetMatched := ACompileEvidenceAvailable and
    (ARequest.Platform = ASelectedPlatform) and
    (ARequest.Configuration = ASelectedConfiguration) and
    (ARequest.Platform = ACompilePlatform) and
    (ARequest.Configuration = ACompileConfiguration);
  WrapperEvidenceAvailable := (AWrapperProject <> '') and FileExists(AWrapperProject) and
    (AWrapperMainSource <> '') and FileExists(AWrapperMainSource);
  ArtifactAvailable := (ACompileResult.OutputEXE <> '') and
    FileExists(ACompileResult.OutputEXE);
  IdentityObject := IdentityJSON(PackageIdentityAvailable);
  InterventionFree := (ADialogHits = 0) and
    (ADialogCloseAttempts = 0) and (AExceptionsSwallowed = 0) and
    not ALicenseOrEulaDetected and not AUnknownDialogDetected;
  PolicyCompliant := (AExceptionsSwallowed = 0) and not ALicenseOrEulaDetected and
    not AUnknownDialogDetected and
    (AKnownTechnicalDialogHits = ADialogHits) and
    (ADialogCloseAttempts = ADialogHits);

  if FailureCode = '' then
  begin
    if not ACompileEvidenceAvailable then
      FailureCode := 'target_evidence_unavailable'
    else if not TargetMatched then
      FailureCode := 'target_mismatch'
    else if not ACompileSucceeded or not ACompileResult.Success then
      FailureCode := 'compile_failed'
    else if not WrapperEvidenceAvailable or not ArtifactAvailable then
      FailureCode := 'artifact_missing'
    else if not PackageIdentityAvailable then
      FailureCode := 'package_identity_unavailable'
    else if not PolicyCompliant then
      FailureCode := 'intervention_detected';
  end;
  Success := FailureCode = '';

  Result := TJSONObject.Create;
  Result.AddPair('schema_version', TJSONNumber.Create(2));
  Result.AddPair('protocol', TJSONNumber.Create(2));
  Result.AddPair('job_id', ARequest.JobId);
  Result.AddPair('nonce', ARequest.Nonce);
  Result.AddPair('request_hash', ARequest.RequestHash);
  if Success then Result.AddPair('status', 'ok')
  else Result.AddPair('status', 'failed');
  Result.AddPair('success', TJSONBool.Create(Success));
  if FailureCode = '' then Result.AddPair('failure_code', NullValue)
  else Result.AddPair('failure_code', FailureCode);

  RequestedTarget := TJSONObject.Create;
  RequestedTarget.AddPair('platform', ARequest.Platform);
  RequestedTarget.AddPair('configuration', ARequest.Configuration);
  Result.AddPair('requested_target', RequestedTarget);
  EffectiveTarget := TJSONObject.Create;
  if ASelectedPlatform <> '' then EffectiveTarget.AddPair('platform', ASelectedPlatform)
  else EffectiveTarget.AddPair('platform', NullValue);
  if ASelectedConfiguration <> '' then EffectiveTarget.AddPair('configuration', ASelectedConfiguration)
  else EffectiveTarget.AddPair('configuration', NullValue);
  Result.AddPair('effective_target', EffectiveTarget);

  InputObject := TJSONObject.Create;
  InputObject.AddPair('project', RequestEvidenceJSON(ARequest.Project));
  InputObject.AddPair('main_source', RequestEvidenceJSON(ARequest.MainSource));
  Result.AddPair('input', InputObject);
  WrapperObject := TJSONObject.Create;
  if AWrapperProject <> '' then WrapperObject.AddPair('directory', ExtractFilePath(AWrapperProject))
  else WrapperObject.AddPair('directory', NullValue);
  WrapperObject.AddPair('project', NullableEvidenceJSON(AWrapperProject));
  WrapperObject.AddPair('main_source', NullableEvidenceJSON(AWrapperMainSource));
  Result.AddPair('wrapper', WrapperObject);
  Result.AddPair('artifact', NullableEvidenceJSON(ACompileResult.OutputEXE));
  Result.AddPair('identity', IdentityObject);
  Result.AddPair('legal_notice', LegalNoticeJSON(ALegalNoticeEvidence));

  Errors := TJSONArray.Create;
  for I := 0 to High(ACompileResult.Errors) do
    Errors.AddElement(TJSONObject.ParseJSONValue(ACompileResult.Errors[I].ToJSON));
  CompileObject := TJSONObject.Create;
  CompileObject.AddPair('succeeded', TJSONBool.Create(ACompileSucceeded));
  CompileObject.AddPair('compile_time_ms', TJSONNumber.Create(ACompileResult.CompileTimeMs));
  if ASelectedPlatform <> '' then CompileObject.AddPair('selected_platform', ASelectedPlatform)
  else CompileObject.AddPair('selected_platform', NullValue);
  if ASelectedConfiguration <> '' then CompileObject.AddPair('selected_configuration', ASelectedConfiguration)
  else CompileObject.AddPair('selected_configuration', NullValue);
  if ACompileEvidenceAvailable then
  begin
    CompileObject.AddPair('compile_platform', ACompilePlatform);
    CompileObject.AddPair('compile_configuration', ACompileConfiguration);
  end
  else
  begin
    CompileObject.AddPair('compile_platform', NullValue);
    CompileObject.AddPair('compile_configuration', NullValue);
  end;
  CompileObject.AddPair('target_matched', TJSONBool.Create(TargetMatched));
  CompileObject.AddPair('release_eligible', TJSONBool.Create(Success));
  CompileObject.AddPair('errors', Errors);
  Result.AddPair('compile', CompileObject);

  InterventionsObject := TJSONObject.Create;
  InterventionsObject.AddPair('dialog_hits', TJSONNumber.Create(ADialogHits));
  InterventionsObject.AddPair('dialog_close_attempts', TJSONNumber.Create(ADialogCloseAttempts));
  InterventionsObject.AddPair('known_technical_dialog_hits',
    TJSONNumber.Create(AKnownTechnicalDialogHits));
  InterventionsObject.AddPair('exceptions_swallowed', TJSONNumber.Create(AExceptionsSwallowed));
  InterventionsObject.AddPair('license_or_eula_detected',
    TJSONBool.Create(ALicenseOrEulaDetected));
  InterventionsObject.AddPair('unknown_dialog_detected',
    TJSONBool.Create(AUnknownDialogDetected));
  InterventionsObject.AddPair('intervention_free', TJSONBool.Create(InterventionFree));
  InterventionsObject.AddPair('policy_compliant', TJSONBool.Create(PolicyCompliant));
  Result.AddPair('interventions', InterventionsObject);
end;

function BuildV2Failure(const ARequest: TV2Request; const AFailureCode: string): TJSONObject;
var
  EmptyResult: TCompileResult;
  EmptyNotice: TLegalNoticeEvidence;
begin
  EmptyResult := Default(TCompileResult);
  EmptyNotice := Default(TLegalNoticeEvidence);
  Result := BuildV2Result(ARequest, EmptyResult, '', '', '', '', '', '', False,
    False, 0, 0, 0, 0, False, False, EmptyNotice, AFailureCode);
end;

end.
