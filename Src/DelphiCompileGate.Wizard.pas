unit DelphiCompileGate.Wizard;

interface

uses
  System.SysUtils,
  ToolsAPI,
  DelphiCompileGate.Watch, DelphiCompileGate.Settings;

type
  TDelphiCompileGateWizard = class(TNotifierObject, IOTAWizard, IOTAMenuWizard)
  private
    FWatch: TDelphiCompileGateWatch;
    FSettings: TDelphiCompileGateSettings;
    FSettingsLoaded: Boolean;
    FSettingsLoadError: string;
    procedure EnsureInitialized;
  protected
    { IOTAWizard }
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
    { IOTAMenuWizard }
    function GetMenuText: string;
  public
    constructor Create;
    destructor Destroy; override;
    class var LastInstance: TDelphiCompileGateWizard;
  end;

implementation

uses
  Winapi.Windows, Vcl.Forms,
  DelphiCompileGate.Consts, DelphiCompileGate.SettingsDialog;

{ TDelphiCompileGateWizard }

constructor TDelphiCompileGateWizard.Create;
begin
  inherited;
  // Keep constructor side-effect free; initialize lazily on first use.
  FWatch := nil;
  FSettings := TDelphiCompileGateSettings.Defaults;
  FSettingsLoaded := False;
  FSettingsLoadError := '';
  LastInstance := Self;
end;

destructor TDelphiCompileGateWizard.Destroy;
begin
  if LastInstance = Self then
    LastInstance := nil;
  FreeAndNil(FWatch);
  inherited;
end;

procedure TDelphiCompileGateWizard.EnsureInitialized;
begin
  OutputDebugString(PChar('[DelphiCompileGate] EnsureInitialized enter'));
  if not FSettingsLoaded then
  begin
    LoadDelphiCompileGateSettings(FSettings, FSettingsLoadError);
    FSettingsLoaded := True;
  end;
  if not Assigned(FWatch) then
  begin
    OutputDebugString(PChar('[DelphiCompileGate] Creating watch instance'));
    FWatch := TDelphiCompileGateWatch.Create;
  end;
  FWatch.ApplyRuntimeSettings(FSettings.WatchIntervalMs,
    FSettings.CompileTimeoutMs, FSettings.ExperimentalHiddenModuleClose);
  OutputDebugString(PChar('[DelphiCompileGate] EnsureInitialized done'));
end;

function TDelphiCompileGateWizard.GetIDString: string;
begin
  Result := PLUGIN_NAME + '.Wizard';
end;

function TDelphiCompileGateWizard.GetName: string;
begin
  Result := PLUGIN_NAME + ' Wizard';
end;

function TDelphiCompileGateWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

function TDelphiCompileGateWizard.GetMenuText: string;
begin
  Result := PLUGIN_MENU_CAPTION + ' Settings / Status...';
end;

procedure TDelphiCompileGateWizard.Execute;
begin
  EnsureInitialized;
  ShowDelphiCompileGateSettingsDialog(Application, FWatch, FSettings,
    FSettingsLoadError);
end;

end.
