unit DelphiCompileGate.Register;

interface

uses
  System.SysUtils, System.Classes,
  ToolsAPI,
  DelphiCompileGate.Wizard;

procedure Register;

implementation

uses
  Winapi.Windows;

var
  WizardIndex: Integer = -1;

procedure Register;
begin
  OutputDebugString(PChar('[DelphiCompileGate] Register called'));
  WizardIndex := (BorlandIDEServices as IOTAWizardServices)
    .AddWizard(TDelphiCompileGateWizard.Create);
  OutputDebugString(PChar('[DelphiCompileGate] Wizard registered index=' + IntToStr(WizardIndex)));
end;

initialization

finalization
  if WizardIndex >= 0 then
  begin
    (BorlandIDEServices as IOTAWizardServices).RemoveWizard(WizardIndex);
    WizardIndex := -1;
  end;

end.
