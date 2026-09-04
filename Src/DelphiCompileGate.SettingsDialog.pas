unit DelphiCompileGate.SettingsDialog;

interface

uses
  System.Classes, DelphiCompileGate.Settings, DelphiCompileGate.Watch;

function ShowDelphiCompileGateSettingsDialog(AOwner: TComponent;
  const AWatch: TDelphiCompileGateWatch;
  var ASettings: TDelphiCompileGateSettings;
  var ALoadError: string): Boolean;

implementation

uses
  Winapi.Windows, System.SysUtils, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls,
  Vcl.Dialogs,
  DelphiCompileGate.Consts, DelphiCompileGate.BuildInfo;

type
  TDelphiCompileGateSettingsForm = class(TForm)
  private
    FWatch: TDelphiCompileGateWatch;
    FStartPending: Boolean;
    FDisplayedWatchRunning: Boolean;
    FDisplayedWatchDraining: Boolean;
    FSettings: TDelphiCompileGateSettings;
    FLoadError: string;
    FConfigPathLabel: TLabel;
    FPollEdit: TEdit;
    FCompileTimeoutEdit: TEdit;
    FAutoCloseCheck: TCheckBox;
    FStatusMemo: TMemo;
    FWatchButton: TButton;
    FRefreshButton: TButton;
    FOKButton: TButton;
    FCancelButton: TButton;
    procedure RefreshStatus;
    function ApplyEdits: Boolean;
    procedure WatchClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure OKClick(Sender: TObject);
  public
    constructor CreateDialog(AOwner: TComponent;
      const AWatch: TDelphiCompileGateWatch;
      const ASettings: TDelphiCompileGateSettings;
      const ALoadError: string);
    property Settings: TDelphiCompileGateSettings read FSettings;
    property LoadError: string read FLoadError;
  end;

constructor TDelphiCompileGateSettingsForm.CreateDialog(AOwner: TComponent;
  const AWatch: TDelphiCompileGateWatch;
  const ASettings: TDelphiCompileGateSettings; const ALoadError: string);
var
  LabelControl: TLabel;
begin
  inherited CreateNew(AOwner);
  FWatch := AWatch;
  FSettings := ASettings;
  FLoadError := ALoadError;
  FStartPending := False;

  Caption := 'Delphi Compile Gate - Settings / Status';
  Position := poScreenCenter;
  BorderStyle := bsSizeable;
  Scaled := True;
  AutoScroll := True;
  ClientWidth := 780;
  ClientHeight := 560;
  Constraints.MinWidth := 680;
  Constraints.MinHeight := 480;

  LabelControl := TLabel.Create(Self);
  LabelControl.Parent := Self;
  LabelControl.Caption := 'Configuration file:';
  LabelControl.SetBounds(16, 18, 130, 20);

  FConfigPathLabel := TLabel.Create(Self);
  FConfigPathLabel.Parent := Self;
  FConfigPathLabel.AutoSize := False;
  FConfigPathLabel.SetBounds(150, 18, ClientWidth - 166, 36);
  FConfigPathLabel.Anchors := [akLeft, akTop, akRight];
  try
    FConfigPathLabel.Caption := DelphiCompileGateSettingsFileName;
  except
    on E: Exception do
      FConfigPathLabel.Caption := E.Message;
  end;

  LabelControl := TLabel.Create(Self);
  LabelControl.Parent := Self;
  LabelControl.Caption := Format('Watch interval (%d-%d ms):',
    [MIN_WATCH_INTERVAL_MS, MAX_WATCH_INTERVAL_MS]);
  LabelControl.SetBounds(16, 62, 225, 20);

  FPollEdit := TEdit.Create(Self);
  FPollEdit.Parent := Self;
  FPollEdit.SetBounds(250, 58, 110, 24);
  FPollEdit.Text := IntToStr(FSettings.WatchIntervalMs);

  LabelControl := TLabel.Create(Self);
  LabelControl.Parent := Self;
  LabelControl.Caption := Format('Compile timeout threshold (%d-%d ms):',
    [MIN_COMPILE_TIMEOUT_MS, MAX_COMPILE_TIMEOUT_MS]);
  LabelControl.SetBounds(390, 62, 235, 20);

  FCompileTimeoutEdit := TEdit.Create(Self);
  FCompileTimeoutEdit.Parent := Self;
  FCompileTimeoutEdit.SetBounds(635, 58, 125, 24);
  FCompileTimeoutEdit.Anchors := [akTop, akRight];
  FCompileTimeoutEdit.Text := IntToStr(FSettings.CompileTimeoutMs);

  FAutoCloseCheck := TCheckBox.Create(Self);
  FAutoCloseCheck.Parent := Self;
  FAutoCloseCheck.Caption :=
    'Experimentally close completed hidden Protocol-v2 modules';
  FAutoCloseCheck.SetBounds(16, 96, 430, 24);
  FAutoCloseCheck.Checked := FSettings.ExperimentalHiddenModuleClose;

  LabelControl := TLabel.Create(Self);
  LabelControl.Parent := Self;
  LabelControl.Caption :=
    'Compile success/failure closes; runtime or evidence failures remain open.';
  LabelControl.SetBounds(36, 122, 700, 20);

  FStatusMemo := TMemo.Create(Self);
  FStatusMemo.Parent := Self;
  FStatusMemo.ReadOnly := True;
  FStatusMemo.WordWrap := False;
  FStatusMemo.ScrollBars := ssBoth;
  FStatusMemo.SetBounds(16, 152, ClientWidth - 32, ClientHeight - 220);
  FStatusMemo.Anchors := [akLeft, akTop, akRight, akBottom];

  FWatchButton := TButton.Create(Self);
  FWatchButton.Parent := Self;
  FWatchButton.SetBounds(16, ClientHeight - 52, 120, 30);
  FWatchButton.Anchors := [akLeft, akBottom];
  FWatchButton.OnClick := WatchClick;

  FRefreshButton := TButton.Create(Self);
  FRefreshButton.Parent := Self;
  FRefreshButton.Caption := 'Refresh';
  FRefreshButton.SetBounds(144, ClientHeight - 52, 90, 30);
  FRefreshButton.Anchors := [akLeft, akBottom];
  FRefreshButton.OnClick := RefreshClick;

  FOKButton := TButton.Create(Self);
  FOKButton.Parent := Self;
  FOKButton.Caption := 'OK';
  FOKButton.Default := True;
  FOKButton.SetBounds(ClientWidth - 212, ClientHeight - 52, 90, 30);
  FOKButton.Anchors := [akRight, akBottom];
  FOKButton.OnClick := OKClick;

  FCancelButton := TButton.Create(Self);
  FCancelButton.Parent := Self;
  FCancelButton.Caption := 'Cancel';
  FCancelButton.Cancel := True;
  FCancelButton.ModalResult := mrCancel;
  FCancelButton.SetBounds(ClientWidth - 114, ClientHeight - 52, 90, 30);
  FCancelButton.Anchors := [akRight, akBottom];

  RefreshStatus;
end;

procedure TDelphiCompileGateSettingsForm.RefreshStatus;
var
  WatchState: string;
  PackagePath: array[0..MAX_PATH - 1] of Char;
begin
  if FWatch.IsDraining then
    WatchState := 'Draining'
  else if FWatch.IsBusy then
    WatchState := 'Busy'
  else if FWatch.IsRunning then
    WatchState := 'Running'
  else if FStartPending then
    WatchState := 'Start pending (press OK)'
  else
    WatchState := 'Stopped';
  if FWatch.IsRunning then
    FWatchButton.Caption := 'Stop Watch'
  else if FStartPending then
    FWatchButton.Caption := 'Cancel Start'
  else
    FWatchButton.Caption := 'Start Watch';
  FDisplayedWatchRunning := FWatch.IsRunning;
  FDisplayedWatchDraining := FWatch.IsDraining;

  FStatusMemo.Lines.BeginUpdate;
  try
    FStatusMemo.Clear;
    FStatusMemo.Lines.Add(Format('Plugin: %s', [PLUGIN_VERSION]));
    FStatusMemo.Lines.Add(Format('Build ID: %s', [DCG_PACKAGE_BUILD_ID]));
    FStatusMemo.Lines.Add(Format('Protocol: %d', [DCG_PROTOCOL_VERSION]));
    FStatusMemo.Lines.Add(Format('Compiler: %.1f', [CompilerVersion]));
    if GetModuleFileName(HInstance, PackagePath, Length(PackagePath)) > 0 then
      FStatusMemo.Lines.Add('Package: ' + string(PackagePath));
    FStatusMemo.Lines.Add('');
    FStatusMemo.Lines.Add('Watch state: ' + WatchState);
    FStatusMemo.Lines.Add(Format('Effective poll interval: %d ms',
      [FWatch.PollIntervalMs]));
    FStatusMemo.Lines.Add(Format('Effective compile timeout threshold: %d ms',
      [FWatch.CompileTimeoutMs]));
    FStatusMemo.Lines.Add(Format('Pending experimental hidden-module closes: %d',
      [FWatch.PendingProjectCloseCount]));
    FStatusMemo.Lines.Add('');
    FStatusMemo.Lines.Add('Input: ' + FWatch.InputDir);
    FStatusMemo.Lines.Add('Output: ' + FWatch.OutputDir);
    FStatusMemo.Lines.Add('Processed: ' + FWatch.ProcessedDir);
    FStatusMemo.Lines.Add('Failed: ' + FWatch.FailedDir);
    FStatusMemo.Lines.Add('Logs: ' + FWatch.LogDir);
    if FLoadError <> '' then
    begin
      FStatusMemo.Lines.Add('');
      FStatusMemo.Lines.Add('Settings load warning: ' + FLoadError);
      FStatusMemo.Lines.Add('Review this warning before starting the watcher.');
    end;
  finally
    FStatusMemo.Lines.EndUpdate;
  end;
end;

function TDelphiCompileGateSettingsForm.ApplyEdits: Boolean;
var
  NewSettings: TDelphiCompileGateSettings;
  Error: string;
begin
  Result := False;
  Error := '';
  NewSettings := FSettings;
  if not TryStrToInt(Trim(FPollEdit.Text), NewSettings.WatchIntervalMs) then
    Error := 'Watch interval is not a valid integer.'
  else if not TryStrToInt(Trim(FCompileTimeoutEdit.Text),
    NewSettings.CompileTimeoutMs) then
    Error := 'Compile timeout is not a valid integer.'
  else
  begin
    NewSettings.ExperimentalHiddenModuleClose := FAutoCloseCheck.Checked;
    NewSettings.Validate(Error);
  end;
  if Error <> '' then
  begin
    MessageDlg(Error, mtError, [mbOK], 0);
    Exit;
  end;
  try
    // Persist first. Runtime objects change only after the atomic INI replace.
    SaveDelphiCompileGateSettings(NewSettings);
    FWatch.ApplyRuntimeSettings(NewSettings.WatchIntervalMs,
      NewSettings.CompileTimeoutMs,
      NewSettings.ExperimentalHiddenModuleClose);
    FSettings := NewSettings;
    FLoadError := '';
    Result := True;
  except
    on E: Exception do
      MessageDlg('Could not save settings: ' + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TDelphiCompileGateSettingsForm.WatchClick(Sender: TObject);
begin
  if (FDisplayedWatchRunning <> FWatch.IsRunning) or
     (FDisplayedWatchDraining <> FWatch.IsDraining) then
  begin
    RefreshStatus;
    Exit;
  end;
  if FWatch.IsDraining then
    Exit;
  if FWatch.IsRunning then
  begin
    FStartPending := False;
    if (GetKeyState(VK_SHIFT) and $8000) <> 0 then
      FWatch.Stop
    else
      FWatch.StopGraceful;
  end
  else
    FStartPending := not FStartPending;
  RefreshStatus;
end;

procedure TDelphiCompileGateSettingsForm.RefreshClick(Sender: TObject);
begin
  RefreshStatus;
end;

procedure TDelphiCompileGateSettingsForm.OKClick(Sender: TObject);
begin
  if ApplyEdits then
  begin
    if FStartPending and not FWatch.IsRunning then
      FWatch.Start;
    FStartPending := False;
    ModalResult := mrOk;
  end;
end;

function ShowDelphiCompileGateSettingsDialog(AOwner: TComponent;
  const AWatch: TDelphiCompileGateWatch;
  var ASettings: TDelphiCompileGateSettings;
  var ALoadError: string): Boolean;
var
  Dialog: TDelphiCompileGateSettingsForm;
begin
  Dialog := TDelphiCompileGateSettingsForm.CreateDialog(AOwner, AWatch,
    ASettings, ALoadError);
  try
    Result := Dialog.ShowModal = mrOk;
    if Result then
    begin
      ASettings := Dialog.Settings;
      ALoadError := Dialog.LoadError;
    end;
  finally
    Dialog.Free;
  end;
end;

end.
