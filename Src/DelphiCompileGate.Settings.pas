unit DelphiCompileGate.Settings;

interface

type
  TDelphiCompileGateSettings = record
    WatchIntervalMs: Integer;
    CompileTimeoutMs: Integer;
    ExperimentalHiddenModuleClose: Boolean;
    class function Defaults: TDelphiCompileGateSettings; static;
    function Validate(out AError: string): Boolean;
  end;

function DelphiCompileGateSettingsFileName: string;
function LoadDelphiCompileGateSettings(out ASettings: TDelphiCompileGateSettings;
  out AError: string): Boolean;
procedure SaveDelphiCompileGateSettings(
  const ASettings: TDelphiCompileGateSettings);

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IniFiles,
  System.IOUtils, DelphiCompileGate.Consts;

class function TDelphiCompileGateSettings.Defaults: TDelphiCompileGateSettings;
begin
  Result.WatchIntervalMs := DEFAULT_WATCH_INTERVAL_MS;
  Result.CompileTimeoutMs := DEFAULT_COMPILE_TIMEOUT_MS;
  Result.ExperimentalHiddenModuleClose :=
    DEFAULT_EXPERIMENTAL_HIDDEN_MODULE_CLOSE;
end;

function TDelphiCompileGateSettings.Validate(out AError: string): Boolean;
begin
  AError := '';
  if (WatchIntervalMs < MIN_WATCH_INTERVAL_MS) or
     (WatchIntervalMs > MAX_WATCH_INTERVAL_MS) then
    AError := Format('Watch interval must be between %d and %d ms.',
      [MIN_WATCH_INTERVAL_MS, MAX_WATCH_INTERVAL_MS])
  else if (CompileTimeoutMs < MIN_COMPILE_TIMEOUT_MS) or
          (CompileTimeoutMs > MAX_COMPILE_TIMEOUT_MS) then
    AError := Format('Compile timeout must be between %d and %d ms.',
      [MIN_COMPILE_TIMEOUT_MS, MAX_COMPILE_TIMEOUT_MS]);
  Result := AError = '';
end;

function DelphiCompileGateSettingsFileName: string;
var
  AppData: string;
begin
  AppData := Trim(GetEnvironmentVariable('APPDATA'));
  if (AppData = '') or not TPath.IsPathRooted(AppData) then
    raise Exception.Create('APPDATA is unavailable; settings cannot be stored safely.');
  Result := TPath.Combine(TPath.Combine(AppData, 'DelphiCompileGate'),
    'DelphiCompileGate.ini');
end;

function ParseIntegerSetting(const AValue, AName: string;
  const ADefault: Integer; out AResult: Integer; out AError: string): Boolean;
begin
  AError := '';
  if Trim(AValue) = '' then
  begin
    AResult := ADefault;
    Exit(True);
  end;
  Result := TryStrToInt(Trim(AValue), AResult);
  if not Result then
    AError := AName + ' is not a valid integer.';
end;

function ParseBooleanSetting(const AValue, AName: string;
  const ADefault: Boolean; out AResult: Boolean; out AError: string): Boolean;
var
  Value: string;
begin
  AError := '';
  Value := LowerCase(Trim(AValue));
  if Value = '' then
  begin
    AResult := ADefault;
    Exit(True);
  end;
  if (Value = 'true') or (Value = '1') then
    AResult := True
  else if (Value = 'false') or (Value = '0') then
    AResult := False
  else
  begin
    AError := AName + ' is not a valid boolean.';
    Exit(False);
  end;
  Result := True;
end;

function LoadDelphiCompileGateSettings(out ASettings: TDelphiCompileGateSettings;
  out AError: string): Boolean;
var
  FileName: string;
  Ini: TMemIniFile;
  Value: string;
  SchemaVersion: Integer;
begin
  ASettings := TDelphiCompileGateSettings.Defaults;
  AError := '';
  try
    FileName := DelphiCompileGateSettingsFileName;
    if FileExists(FileName) then
    begin
      Ini := TMemIniFile.Create(FileName, TEncoding.UTF8);
      try
        Value := Ini.ReadString('Meta', 'SchemaVersion', '');
        if not TryStrToInt(Trim(Value), SchemaVersion) or
           (SchemaVersion <> SETTINGS_SCHEMA_VERSION) then
        begin
          AError := 'Unsupported or missing settings schema version.';
          Exit(False);
        end;
        if not ParseIntegerSetting(
          Ini.ReadString('Watch', 'PollIntervalMs', ''), 'PollIntervalMs',
          DEFAULT_WATCH_INTERVAL_MS, ASettings.WatchIntervalMs, AError) then
          Exit(False);
        if not ParseIntegerSetting(
          Ini.ReadString('Compiler', 'BackgroundTimeoutMs', ''),
          'BackgroundTimeoutMs', DEFAULT_COMPILE_TIMEOUT_MS,
          ASettings.CompileTimeoutMs, AError) then
          Exit(False);
        if not ParseBooleanSetting(
          Ini.ReadString('Projects', 'ExperimentalHiddenModuleClose', ''),
          'ExperimentalHiddenModuleClose',
          DEFAULT_EXPERIMENTAL_HIDDEN_MODULE_CLOSE,
          ASettings.ExperimentalHiddenModuleClose, AError) then
          Exit(False);
      finally
        Ini.Free;
      end;
    end;
    Result := ASettings.Validate(AError);
  except
    on E: Exception do
    begin
      ASettings := TDelphiCompileGateSettings.Defaults;
      AError := E.Message;
      Result := False;
    end;
  end;
end;

procedure SaveDelphiCompileGateSettings(
  const ASettings: TDelphiCompileGateSettings);
var
  Error: string;
  FileName: string;
  TempFile: string;
  Ini: TMemIniFile;
  LastError: Integer;
begin
  if not ASettings.Validate(Error) then
    raise Exception.Create(Error);
  FileName := DelphiCompileGateSettingsFileName;
  ForceDirectories(ExtractFileDir(FileName));
  // Use a unique same-directory file so concurrent IDE instances cannot move
  // or delete each other's completed settings payload.
  TempFile := TPath.Combine(ExtractFileDir(FileName),
    TPath.GetRandomFileName + '.tmp');
  try
    Ini := TMemIniFile.Create(TempFile, TEncoding.UTF8);
    try
      Ini.WriteInteger('Meta', 'SchemaVersion', SETTINGS_SCHEMA_VERSION);
      Ini.WriteInteger('Watch', 'PollIntervalMs', ASettings.WatchIntervalMs);
      Ini.WriteInteger('Compiler', 'BackgroundTimeoutMs',
        ASettings.CompileTimeoutMs);
      Ini.WriteBool('Projects', 'ExperimentalHiddenModuleClose',
        ASettings.ExperimentalHiddenModuleClose);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
    if not MoveFileEx(PChar(TempFile), PChar(FileName),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    begin
      LastError := GetLastError;
      raise EOSError.CreateFmt('Atomic settings replace failed (error %d).',
        [LastError]);
    end;
  except
    if FileExists(TempFile) then
      DeleteFile(TempFile);
    raise;
  end;
end;

end.
