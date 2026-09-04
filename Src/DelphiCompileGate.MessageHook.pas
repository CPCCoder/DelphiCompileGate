unit DelphiCompileGate.MessageHook;

{$I DelphiCompileGate.IdeCompat.inc}

// VMT hooks for the running Delphi IDE's IOTAMessageServices instance.
//
// ToolsAPI exposes methods for publishing compiler messages but no supported
// API for reading messages already added to the Build/Message view. This unit
// therefore intercepts the Delphi 13 message-service methods, captures their
// original arguments in a thread-safe list, and forwards unsuppressed calls.
// This avoids locale-dependent UI scraping and preserves message severity and
// help metadata. VMT patching is process-wide, so installation verifies both
// the Delphi 13 slot layout and each slot owner before making any change.

interface

uses
  Winapi.Windows,
  System.SysUtils, System.Classes, System.IOUtils, System.SyncObjs, System.Generics.Collections,
  ToolsAPI;

type
  TAddToolMessage40Proc = procedure(ASelf: Pointer;
    const AFileName, AMessageStr, APrefixStr: string;
    ALineNumber, AColumnNumber: Integer);
  TAddToolMessage50Proc = procedure(ASelf: Pointer;
    const AFileName, AMessageStr, APrefixStr: string;
    ALineNumber, AColumnNumber: Integer; AParent: Pointer; out ALineRef: Pointer);
  TMessageSeverity = (msHint, msWarning, msError, msFatal, msInfo, msUnknown);

  TCapturedMessage = record
    FileName: string;
    MessageText: string;
    ToolName: string;
    PrefixStr: string;
    LineNumber: Integer;
    ColumnNumber: Integer;
    Severity: TMessageSeverity;
    HelpKeyword: string;
    GroupName: string;
  end;

  TMessageHookTraceProc = procedure(const AMsg: string) of object;

  /// <summary>
  /// Thread-safe collector for intercepted compiler messages. The plugin owns
  /// one singleton; hook procedures write here and the compiler reads after
  /// compilation finishes.
  /// </summary>
  TMessageHook = class
  private
    FLock: TCriticalSection;
    FMessages: TList<TCapturedMessage>;
    FInstalled: Boolean;
    FCaptureOnlyDepth: Integer;
    FCaptureWrapperRoot: string;
    FCaptureSourceRoot: string;
    FCaptureSourceFiles: TStringList;
    FCaptureSourceBasenames: TStringList;
    FOnTrace: TMessageHookTraceProc;
    FMessageServicesIntf: IOTAMessageServices;
    FOriginalAddToolMessage40: Pointer;
    FOriginalAddToolMessage50: Pointer;
    FOriginalAddToolMessage60: Pointer;
    FOriginalAddCompilerMessage70: Pointer;
    FOriginalAddCompilerMessage80a: Pointer;
    FOriginalAddCompilerMessage80b: Pointer;
    FOriginalAddWideCompilerMessage: Pointer;
    FOriginalAddWideCompilerMessageHK: Pointer;
    FOriginalAddWideCompilerMessageHC: Pointer;
    FOriginalAddWideToolMessage40: Pointer;
    FOriginalAddWideToolMessage50: Pointer;
    FOriginalAddWideToolMessage60: Pointer;
    FVTableAddress: PPointer;
    FToolMessageSlotIndex40: Integer;
    FToolMessageSlotIndex50: Integer;
    FToolMessageSlotIndex: Integer;
    FCompilerMessageSlotIndex70: Integer;
    FCompilerMessageSlotIndex80a: Integer;
    FCompilerMessageSlotIndex80b: Integer;
    FWideCompilerMessageSlotIndex: Integer;
    FWideCompilerMessageSlotIndexHK: Integer;
    FWideCompilerMessageSlotIndexHC: Integer;
    FWideToolMessageSlotIndex40: Integer;
    FWideToolMessageSlotIndex50: Integer;
    FWideToolMessageSlotIndex60: Integer;
    FOldProtectToolMessage40: DWORD;
    FOldProtectToolMessage50: DWORD;
    FOldProtectToolMessage: DWORD;
    FOldProtectCompilerMessage70: DWORD;
    FOldProtectCompilerMessage80a: DWORD;
    FOldProtectCompilerMessage80b: DWORD;
    FOldProtectWideCompilerMessage: DWORD;
    FOldProtectWideCompilerMessageHK: DWORD;
    FOldProtectWideCompilerMessageHC: DWORD;
    FOldProtectWideToolMessage40: DWORD;
    FOldProtectWideToolMessage50: DWORD;
    FOldProtectWideToolMessage60: DWORD;
    FCompleteCoverage: Boolean;
    FCaptureFailed: Boolean;
    procedure Trace(const AMsg: string);
    function SeverityFromKind(AKind: TOTAMessageKind): TMessageSeverity;
    function PatchVTableSlot(const ASlotIndex: Integer; ANewPointer: Pointer;
      out AOldPointer: Pointer; out AOldProtect: DWORD): Boolean;
    function IsTrustedIDESlotPointer(const ASlotPointer: Pointer): Boolean;
    function RestoreVTableSlot(const ASlotIndex: Integer; AOldPointer: Pointer;
      AExpectedPointer: Pointer; AOldProtect: DWORD): Boolean;
    function VerifyVTableSlot(const ASlotIndex: Integer;
      AExpectedPointer: Pointer): Boolean;
    function FindVTableForInterface(const AIntf: IInterface): PPointer;
    function DetectSlotIndices: Boolean;
    function GetCaptureFailed: Boolean;
    function IsInCaptureScope(const AFileName: string): Boolean;
    procedure MarkCaptureFailure;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    /// Installs the VMT hooks in the current BorlandIDEServices message-service
    /// instance. Returns True on success.
    /// </summary>
    function Install: Boolean;

    /// <summary>
    /// Removes the hooks and restores the original VMT entries.
    /// </summary>
    function Uninstall: Boolean;

    /// <summary>
    /// Clears all captured messages. Call before each compilation.
    /// </summary>
    procedure ClearMessages;

    /// <summary>
    /// Captures compiler messages without publishing them to IDE message
    /// services. Calls are depth-counted for nested wrapper jobs.
    /// </summary>
    function BeginCaptureOnly(const AWrapperProject, ASourceRoot: string;
      const ASourceBasenames: TArray<string>): Boolean;
    procedure EndCaptureOnly;

    /// <summary>
    /// Returns a snapshot of the messages captured so far.
    /// </summary>
    function GetMessages: TArray<TCapturedMessage>;

    /// <summary>
    /// Called by hook procedures to register a message. Public because the
    /// procedures are outside the class.
    /// </summary>
    function CaptureToolMessageAndShouldSuppress(const AFileName, AMessage,
      APrefix, AGroupName: string; ALine, ACol: Integer): Boolean;
    function CaptureCompilerMessageAndShouldSuppress(const AFileName, AMessage,
      AToolName: string; AKind: TOTAMessageKind; ALine, ACol: Integer;
      const AHelpKeyword: string): Boolean;

    property Installed: Boolean read FInstalled;
    property CompleteCoverage: Boolean read FCompleteCoverage;
    property CaptureFailed: Boolean read GetCaptureFailed;
    property OnTrace: TMessageHookTraceProc read FOnTrace write FOnTrace;
  end;

/// <summary>Global singleton, initialized lazily.</summary>
function MessageHook: TMessageHook;

/// <summary>Shuts down during plugin unload.</summary>
procedure FinalizeMessageHook;

implementation

uses
  System.Rtti, System.TypInfo;

const
  DCG_GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = $00000004;

function DCGGetModuleHandleExW(dwFlags: DWORD; lpModuleName: PWideChar;
  var phModule: HMODULE): BOOL; stdcall; external 'kernel32.dll' name 'GetModuleHandleExW';

var
  GMessageHook: TMessageHook;
  GMessageHookModuleHold: HMODULE;

function MessageHook: TMessageHook;
begin
  if GMessageHook = nil then
    GMessageHook := TMessageHook.Create;
  Result := GMessageHook;
end;

procedure FinalizeMessageHook;
begin
  if Assigned(GMessageHook) then
  begin
    // The compiler/watch owner has already been destroyed during package
    // finalization, so no restore diagnostic may call its stale trace method.
    GMessageHook.OnTrace := nil;
    GMessageHookModuleHold := 0;
    if not DCGGetModuleHandleExW(DCG_GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
      PWideChar(@FinalizeMessageHook), GMessageHookModuleHold) then
      RaiseLastOSError;
    if not GMessageHook.Uninstall then
      // Keep both forwarding state and one module reference alive. The IDE
      // must restart before this package image can be reclaimed safely.
      Exit;
    GMessageHook.Free;
    GMessageHook := nil;
    FreeLibrary(GMessageHookModuleHold);
    GMessageHookModuleHold := 0;
  end;
end;

// --- Hook procedure infrastructure ------------------------------------------
//
// Each hook procedure exactly matches its interface method signature, including
// the hidden interface-implementation Self argument. It captures the call and
// then invokes the original method through the saved VMT slot pointer.

type
  // AddToolMessage signature with MessageGroup (IOTAMessageServices60).
  //   procedure AddToolMessage(const FileName, MessageStr, PrefixStr: string;
  //     LineNumber, ColumnNumber: Integer; Parent: Pointer; out LineRef: Pointer;
  //     const MessageGroupIntf: IOTAMessageGroup);
  TAddToolMessage60Proc = procedure(ASelf: Pointer;
    const AFileName, AMessageStr, APrefixStr: string;
    ALineNumber, AColumnNumber: Integer; AParent: Pointer; out ALineRef: Pointer;
    const AMessageGroupIntf: IOTAMessageGroup);

  // AddCompilerMessage signature from IOTAMessageServices70.
  TAddCompilerMessage70Proc = procedure(ASelf: Pointer;
    const AFileName, AMessageStr, AToolName: string;
    AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
    AParent: Pointer; out ALineRef: Pointer);

  // AddCompilerMessage signature with HelpKeyword (IOTAMessageServices80).
  TAddCompilerMessage80aProc = procedure(ASelf: Pointer;
    const AFileName, AMessageStr, AToolName: string;
    AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
    AParent: Pointer; out ALineRef: Pointer; AHelpKeyword: string);

  // AddCompilerMessage signature with HelpContext (IOTAMessageServices80).
  TAddCompilerMessage80bProc = procedure(ASelf: Pointer;
    const AFileName, AMessageStr, AToolName: string;
    AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
    AParent: Pointer; out ALineRef: Pointer; AHelpContext: Integer);

  TAddWideCompilerMessageProc = procedure(ASelf: Pointer;
    AFileName, AMessageStr, AToolName: WideString;
    AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
    AParent: Pointer; out ALineRef: Pointer);
  TAddWideCompilerMessageHKProc = procedure(ASelf: Pointer;
    AFileName, AMessageStr, AToolName: WideString;
    AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
    AParent: Pointer; out ALineRef: Pointer; AHelpKeyword: WideString);
  TAddWideCompilerMessageHCProc = procedure(ASelf: Pointer;
    AFileName, AMessageStr, AToolName: WideString;
    AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
    AParent: Pointer; out ALineRef: Pointer; AHelpContext: Integer);
  TAddWideToolMessage40Proc = procedure(ASelf: Pointer;
    AFileName, AMessageStr, APrefixStr: WideString;
    ALineNumber, AColumnNumber: Integer);
  TAddWideToolMessage50Proc = procedure(ASelf: Pointer;
    AFileName, AMessageStr, APrefixStr: WideString;
    ALineNumber, AColumnNumber: Integer; AParent: Pointer;
    out ALineRef: Pointer);
  TAddWideToolMessage60Proc = procedure(ASelf: Pointer;
    AFileName, AMessageStr, APrefixStr: WideString;
    ALineNumber, AColumnNumber: Integer; AParent: Pointer;
    out ALineRef: Pointer; const AMessageGroupIntf: IOTAMessageGroup);

procedure HookedAddToolMessage40(ASelf: Pointer;
  const AFileName, AMessageStr, APrefixStr: string;
  ALineNumber, AColumnNumber: Integer);
var
  Orig: TAddToolMessage40Proc;
begin
  Orig := nil;
  if Assigned(GMessageHook) then
  begin
    if GMessageHook.CaptureToolMessageAndShouldSuppress(AFileName, AMessageStr,
      APrefixStr, '', ALineNumber, AColumnNumber) then
      Exit;
    Orig := TAddToolMessage40Proc(GMessageHook.FOriginalAddToolMessage40);
  end;
  if Assigned(Orig) then Orig(ASelf, AFileName, AMessageStr, APrefixStr,
    ALineNumber, AColumnNumber);
end;

procedure HookedAddToolMessage50(ASelf: Pointer;
  const AFileName, AMessageStr, APrefixStr: string;
  ALineNumber, AColumnNumber: Integer; AParent: Pointer; out ALineRef: Pointer);
var
  Orig: TAddToolMessage50Proc;
begin
  Orig := nil;
  if Assigned(GMessageHook) then
  begin
    if GMessageHook.CaptureToolMessageAndShouldSuppress(AFileName, AMessageStr,
      APrefixStr, '', ALineNumber, AColumnNumber) then
    begin ALineRef := nil; Exit; end;
    Orig := TAddToolMessage50Proc(GMessageHook.FOriginalAddToolMessage50);
  end;
  if Assigned(Orig) then Orig(ASelf, AFileName, AMessageStr, APrefixStr,
    ALineNumber, AColumnNumber, AParent, ALineRef) else ALineRef := nil;
end;

procedure HookedAddToolMessage60(ASelf: Pointer;
  const AFileName, AMessageStr, APrefixStr: string;
  ALineNumber, AColumnNumber: Integer; AParent: Pointer; out ALineRef: Pointer;
  const AMessageGroupIntf: IOTAMessageGroup);
var
  GrpName: string;
  Orig: TAddToolMessage60Proc;
  Hook: TMessageHook;
begin
  GrpName := '';
  try
    if Assigned(AMessageGroupIntf) then
      GrpName := AMessageGroupIntf.GetGroupName;
  except
  end;

  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureToolMessageAndShouldSuppress(AFileName,
    AMessageStr, APrefixStr, GrpName, ALineNumber, AColumnNumber) then
  begin
    ALineRef := nil;
    Exit;
  end;

  // Forward to the original method.
  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddToolMessage60Proc(Hook.FOriginalAddToolMessage60);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, APrefixStr, ALineNumber, AColumnNumber,
      AParent, ALineRef, AMessageGroupIntf)
  else
    ALineRef := nil;
end;

procedure HookedAddCompilerMessage70(ASelf: Pointer;
  const AFileName, AMessageStr, AToolName: string;
  AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
  AParent: Pointer; out ALineRef: Pointer);
var
  Orig: TAddCompilerMessage70Proc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureCompilerMessageAndShouldSuppress(AFileName,
    AMessageStr, AToolName, AKind, ALineNumber, AColumnNumber, '') then
  begin
    ALineRef := nil;
    Exit;
  end;

  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddCompilerMessage70Proc(Hook.FOriginalAddCompilerMessage70);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, AToolName, AKind, ALineNumber,
      AColumnNumber, AParent, ALineRef)
  else
    ALineRef := nil;
end;

procedure HookedAddCompilerMessage80a(ASelf: Pointer;
  const AFileName, AMessageStr, AToolName: string;
  AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
  AParent: Pointer; out ALineRef: Pointer; AHelpKeyword: string);
var
  Orig: TAddCompilerMessage80aProc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureCompilerMessageAndShouldSuppress(AFileName,
    AMessageStr, AToolName, AKind, ALineNumber, AColumnNumber, AHelpKeyword) then
  begin
    ALineRef := nil;
    Exit;
  end;

  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddCompilerMessage80aProc(Hook.FOriginalAddCompilerMessage80a);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, AToolName, AKind, ALineNumber,
      AColumnNumber, AParent, ALineRef, AHelpKeyword)
  else
    ALineRef := nil;
end;

procedure HookedAddCompilerMessage80b(ASelf: Pointer;
  const AFileName, AMessageStr, AToolName: string;
  AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
  AParent: Pointer; out ALineRef: Pointer; AHelpContext: Integer);
var
  Orig: TAddCompilerMessage80bProc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureCompilerMessageAndShouldSuppress(AFileName,
    AMessageStr, AToolName, AKind, ALineNumber, AColumnNumber, '') then
  begin
    ALineRef := nil;
    Exit;
  end;

  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddCompilerMessage80bProc(Hook.FOriginalAddCompilerMessage80b);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, AToolName, AKind, ALineNumber,
      AColumnNumber, AParent, ALineRef, AHelpContext)
  else
    ALineRef := nil;
end;

procedure HookedAddWideCompilerMessage(ASelf: Pointer;
  AFileName, AMessageStr, AToolName: WideString;
  AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
  AParent: Pointer; out ALineRef: Pointer);
var
  Orig: TAddWideCompilerMessageProc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureCompilerMessageAndShouldSuppress(
    string(AFileName), string(AMessageStr), string(AToolName), AKind,
    ALineNumber, AColumnNumber, '') then
  begin
    ALineRef := nil;
    Exit;
  end;
  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddWideCompilerMessageProc(Hook.FOriginalAddWideCompilerMessage);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, AToolName, AKind, ALineNumber,
      AColumnNumber, AParent, ALineRef)
  else
    ALineRef := nil;
end;

procedure HookedAddWideCompilerMessageHK(ASelf: Pointer;
  AFileName, AMessageStr, AToolName: WideString;
  AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
  AParent: Pointer; out ALineRef: Pointer; AHelpKeyword: WideString);
var
  Orig: TAddWideCompilerMessageHKProc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureCompilerMessageAndShouldSuppress(
    string(AFileName), string(AMessageStr), string(AToolName), AKind,
    ALineNumber, AColumnNumber, string(AHelpKeyword)) then
  begin
    ALineRef := nil;
    Exit;
  end;
  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddWideCompilerMessageHKProc(Hook.FOriginalAddWideCompilerMessageHK);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, AToolName, AKind, ALineNumber,
      AColumnNumber, AParent, ALineRef, AHelpKeyword)
  else
    ALineRef := nil;
end;

procedure HookedAddWideCompilerMessageHC(ASelf: Pointer;
  AFileName, AMessageStr, AToolName: WideString;
  AKind: TOTAMessageKind; ALineNumber, AColumnNumber: Integer;
  AParent: Pointer; out ALineRef: Pointer; AHelpContext: Integer);
var
  Orig: TAddWideCompilerMessageHCProc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureCompilerMessageAndShouldSuppress(
    string(AFileName), string(AMessageStr), string(AToolName), AKind,
    ALineNumber, AColumnNumber, '') then
  begin
    ALineRef := nil;
    Exit;
  end;
  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddWideCompilerMessageHCProc(Hook.FOriginalAddWideCompilerMessageHC);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, AToolName, AKind, ALineNumber,
      AColumnNumber, AParent, ALineRef, AHelpContext)
  else
    ALineRef := nil;
end;

procedure HookedAddWideToolMessage40(ASelf: Pointer;
  AFileName, AMessageStr, APrefixStr: WideString;
  ALineNumber, AColumnNumber: Integer);
var
  Orig: TAddWideToolMessage40Proc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureToolMessageAndShouldSuppress(
    string(AFileName), string(AMessageStr), string(APrefixStr), '',
    ALineNumber, AColumnNumber) then
    Exit;
  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddWideToolMessage40Proc(Hook.FOriginalAddWideToolMessage40);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, APrefixStr, ALineNumber, AColumnNumber);
end;

procedure HookedAddWideToolMessage50(ASelf: Pointer;
  AFileName, AMessageStr, APrefixStr: WideString;
  ALineNumber, AColumnNumber: Integer; AParent: Pointer;
  out ALineRef: Pointer);
var
  Orig: TAddWideToolMessage50Proc;
  Hook: TMessageHook;
begin
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureToolMessageAndShouldSuppress(
    string(AFileName), string(AMessageStr), string(APrefixStr), '',
    ALineNumber, AColumnNumber) then
  begin
    ALineRef := nil;
    Exit;
  end;
  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddWideToolMessage50Proc(Hook.FOriginalAddWideToolMessage50);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, APrefixStr, ALineNumber,
      AColumnNumber, AParent, ALineRef)
  else
    ALineRef := nil;
end;

procedure HookedAddWideToolMessage60(ASelf: Pointer;
  AFileName, AMessageStr, APrefixStr: WideString;
  ALineNumber, AColumnNumber: Integer; AParent: Pointer;
  out ALineRef: Pointer; const AMessageGroupIntf: IOTAMessageGroup);
var
  GroupName: string;
  Orig: TAddWideToolMessage60Proc;
  Hook: TMessageHook;
begin
  GroupName := '';
  try
    if Assigned(AMessageGroupIntf) then
      GroupName := AMessageGroupIntf.GetGroupName;
  except
  end;
  Hook := GMessageHook;
  if Assigned(Hook) and Hook.CaptureToolMessageAndShouldSuppress(
    string(AFileName), string(AMessageStr), string(APrefixStr), GroupName,
    ALineNumber, AColumnNumber) then
  begin
    ALineRef := nil;
    Exit;
  end;
  Orig := nil;
  if Assigned(Hook) then
    Orig := TAddWideToolMessage60Proc(Hook.FOriginalAddWideToolMessage60);
  if Assigned(Orig) then
    Orig(ASelf, AFileName, AMessageStr, APrefixStr, ALineNumber,
      AColumnNumber, AParent, ALineRef, AMessageGroupIntf)
  else
    ALineRef := nil;
end;

{ TMessageHook }

constructor TMessageHook.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FMessages := TList<TCapturedMessage>.Create;
  FCaptureSourceFiles := TStringList.Create;
  FCaptureSourceFiles.CaseSensitive := False;
  FCaptureSourceFiles.Sorted := True;
  FCaptureSourceFiles.Duplicates := dupIgnore;
  FCaptureSourceBasenames := TStringList.Create;
  FCaptureSourceBasenames.CaseSensitive := False;
  FCaptureSourceBasenames.Sorted := True;
  // Preserve multiplicity so a bare compiler filename is accepted only when
  // exactly one referenced source owns that basename.
  FCaptureSourceBasenames.Duplicates := dupAccept;
  FInstalled := False;
  FCaptureOnlyDepth := 0;
  FToolMessageSlotIndex40 := -1;
  FToolMessageSlotIndex50 := -1;
  FToolMessageSlotIndex := -1;
  FCompilerMessageSlotIndex70 := -1;
  FCompilerMessageSlotIndex80a := -1;
  FCompilerMessageSlotIndex80b := -1;
  FWideCompilerMessageSlotIndex := -1;
  FWideCompilerMessageSlotIndexHK := -1;
  FWideCompilerMessageSlotIndexHC := -1;
  FWideToolMessageSlotIndex40 := -1;
  FWideToolMessageSlotIndex50 := -1;
  FWideToolMessageSlotIndex60 := -1;
  FCompleteCoverage := False;
  FCaptureFailed := False;
end;

destructor TMessageHook.Destroy;
begin
  // The unit-owned singleton is freed only by FinalizeMessageHook after every
  // slot has been restored. Uninstall failures retain the singleton instead.
  FMessages.Free;
  FCaptureSourceFiles.Free;
  FCaptureSourceBasenames.Free;
  FLock.Free;
  inherited;
end;

procedure TMessageHook.Trace(const AMsg: string);
begin
  if Assigned(FOnTrace) then
    FOnTrace('[MessageHook] ' + AMsg);
end;

function TMessageHook.SeverityFromKind(AKind: TOTAMessageKind): TMessageSeverity;
begin
  case AKind of
    otamkHint:  Result := msHint;
    otamkWarn:  Result := msWarning;
    otamkError: Result := msError;
    otamkFatal: Result := msFatal;
    otamkInfo:  Result := msInfo;
  else
    Result := msUnknown;
  end;
end;

function TMessageHook.CaptureToolMessageAndShouldSuppress(const AFileName,
  AMessage, APrefix, AGroupName: string; ALine, ACol: Integer): Boolean;
var
  Msg: TCapturedMessage;
  CaptureOnly: Boolean;
begin
  Result := False;
  try
  Msg.FileName := AFileName;
  Msg.MessageText := AMessage;
  Msg.PrefixStr := APrefix;
  Msg.ToolName := APrefix; // PrefixStr is commonly the tool or error code.
  Msg.LineNumber := ALine;
  Msg.ColumnNumber := ACol;
  Msg.HelpKeyword := '';
  Msg.GroupName := AGroupName;
  // AddToolMessage does not carry TOTAMessageKind. An unprefixed entry is
  // informational output; compiler errors/warnings provide an E/F/W/H prefix.
  Msg.Severity := msInfo;

  // Infer severity from the prefix.
  if (APrefix <> '') then
  begin
    case UpCase(APrefix[1]) of
      'E': Msg.Severity := msError;
      'F': Msg.Severity := msFatal;
      'W': Msg.Severity := msWarning;
      'H': Msg.Severity := msHint;
    end;
  end;

  FLock.Enter;
  try
    CaptureOnly := FCaptureOnlyDepth > 0;
    Result := CaptureOnly and IsInCaptureScope(AFileName);
    if not CaptureOnly or Result then
      FMessages.Add(Msg);
  finally
    FLock.Leave;
  end;
  except
    MarkCaptureFailure;
    Result := False;
  end;
end;

function TMessageHook.CaptureCompilerMessageAndShouldSuppress(const AFileName,
  AMessage, AToolName: string; AKind: TOTAMessageKind; ALine, ACol: Integer;
  const AHelpKeyword: string): Boolean;
var
  Msg: TCapturedMessage;
  CaptureOnly: Boolean;
begin
  Result := False;
  try
  Msg.FileName := AFileName;
  Msg.MessageText := AMessage;
  Msg.ToolName := AToolName;
  Msg.PrefixStr := '';
  Msg.LineNumber := ALine;
  Msg.ColumnNumber := ACol;
  Msg.Severity := SeverityFromKind(AKind);
  Msg.HelpKeyword := AHelpKeyword;
  Msg.GroupName := '';

  FLock.Enter;
  try
    CaptureOnly := FCaptureOnlyDepth > 0;
    Result := CaptureOnly and IsInCaptureScope(AFileName);
    if not CaptureOnly or Result then
      FMessages.Add(Msg);
  finally
    FLock.Leave;
  end;
  except
    MarkCaptureFailure;
    Result := False;
  end;
end;

procedure TMessageHook.MarkCaptureFailure;
begin
  try
    FLock.Enter;
    try
      FCaptureFailed := True;
    finally
      FLock.Leave;
    end;
  except
    // Never propagate an instrumentation failure into an IDE callback.
  end;
end;

procedure TMessageHook.ClearMessages;
begin
  FLock.Enter;
  try
    FMessages.Clear;
  finally
    FLock.Leave;
  end;
end;

function TMessageHook.IsInCaptureScope(const AFileName: string): Boolean;
var
  FullName: string;
  I: Integer;
  MatchCount: Integer;
begin
  Result := False;
  // A filename is the only reliable attribution available in message-service
  // callbacks. Never suppress unattributed messages: they may belong to IDE work.
  if (AFileName = '') or (FCaptureWrapperRoot = '') or (FCaptureSourceRoot = '') then
    Exit;
  // The compiler may report a wrapper unit by basename only. Bare names are
  // accepted only when the wrapper explicitly referenced that source file.
  if ExtractFileName(AFileName) = AFileName then
  begin
    MatchCount := 0;
    for I := 0 to FCaptureSourceBasenames.Count - 1 do
      if SameText(FCaptureSourceBasenames[I], AFileName) then
        Inc(MatchCount);
    Result := MatchCount = 1;
    if MatchCount > 1 then
      Trace('Capture scope=False reason=ambiguous_bare_source file="' +
        AFileName + '"');
    Exit;
  end;
  try
    FullName := ExpandFileName(AFileName);
    Result := SameText(Copy(FullName, 1, Length(FCaptureWrapperRoot)), FCaptureWrapperRoot) or
      SameText(Copy(FullName, 1, Length(FCaptureSourceRoot)), FCaptureSourceRoot) or
      (FCaptureSourceFiles.IndexOf(FullName) >= 0);
  except
    Result := False;
  end;
end;

function TMessageHook.BeginCaptureOnly(const AWrapperProject, ASourceRoot: string;
  const ASourceBasenames: TArray<string>): Boolean;
const
  MAX_CAPTURE_SOURCE_BASENAMES = 4096;
var
  WrapperRoot: string;
  SourceRoot: string;
  Basename: string;
  I: Integer;
begin
  Result := False;
  WrapperRoot := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(AWrapperProject)));
  SourceRoot := IncludeTrailingPathDelimiter(ExpandFileName(ASourceRoot));
  if (not DirectoryExists(WrapperRoot)) or (not DirectoryExists(SourceRoot)) then
    Exit;
  FLock.Enter;
  try
    if (FCaptureOnlyDepth > 0) and ((not SameText(FCaptureWrapperRoot, WrapperRoot)) or
      (not SameText(FCaptureSourceRoot, SourceRoot))) then
      Exit;
    if FCaptureOnlyDepth = 0 then
    begin
      FCaptureWrapperRoot := WrapperRoot;
      FCaptureSourceRoot := SourceRoot;
      FCaptureSourceFiles.Clear;
      FCaptureSourceBasenames.Clear;
      for I := 0 to High(ASourceBasenames) do
      begin
        Basename := ExtractFileName(ASourceBasenames[I]);
        if (Basename <> '') and
           (FCaptureSourceBasenames.Count < MAX_CAPTURE_SOURCE_BASENAMES) then
          FCaptureSourceBasenames.Add(Basename);
        if TPath.IsPathRooted(ASourceBasenames[I]) and
           (FCaptureSourceFiles.Count < MAX_CAPTURE_SOURCE_BASENAMES) then
          FCaptureSourceFiles.Add(ExpandFileName(ASourceBasenames[I]));
      end;
      FCaptureFailed := False;
    end;
    Inc(FCaptureOnlyDepth);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMessageHook.EndCaptureOnly;
begin
  FLock.Enter;
  try
    if FCaptureOnlyDepth > 0 then
    begin
      Dec(FCaptureOnlyDepth);
      if FCaptureOnlyDepth = 0 then
      begin
        FCaptureWrapperRoot := '';
        FCaptureSourceRoot := '';
        FCaptureSourceFiles.Clear;
        FCaptureSourceBasenames.Clear;
      end;
    end
    else
      Trace('EndCaptureOnly without matching BeginCaptureOnly');
  finally
    FLock.Leave;
  end;
end;

function TMessageHook.GetCaptureFailed: Boolean;
begin
  FLock.Enter;
  try
    Result := FCaptureFailed;
  finally
    FLock.Leave;
  end;
end;

function TMessageHook.GetMessages: TArray<TCapturedMessage>;
begin
  FLock.Enter;
  try
    Result := FMessages.ToArray;
  finally
    FLock.Leave;
  end;
end;

function TMessageHook.FindVTableForInterface(const AIntf: IInterface): PPointer;
// A Delphi interface points to a structure whose first field is the VMT pointer:
//
//   IInterface variable = Pointer -> [VTable pointer, ...]
//                                 |
//                                 v
//                              [QueryInterface, _AddRef, _Release, ...]
begin
  Result := nil;
  if AIntf = nil then
    Exit;
  Result := PPointer(AIntf)^;
end;

function TMessageHook.DetectSlotIndices: Boolean;
// Prefer interface RTTI when available. Delphi 13 normally omits the required
// extended interface RTTI, so the verified Delphi 13 indices below remain the
// authoritative fallback.
var
  Ctx: TRttiContext;
  IntfType: TRttiInterfaceType;
  Method: TRttiMethod;
  SlotIndex: Integer;

  function MatchIntfMethodByName(const AIntfGuid: TGUID; const AMethodName: string;
    AParamCount: Integer; out ASlotIndex: Integer): Boolean;
  var
    T: TRttiType;
    IT: TRttiInterfaceType;
    M: TRttiMethod;
  begin
    Result := False;
    ASlotIndex := -1;
    for T in Ctx.GetTypes do
    begin
      if not (T is TRttiInterfaceType) then Continue;
      IT := TRttiInterfaceType(T);
      if IT.GUID <> AIntfGuid then Continue;
      for M in IT.GetDeclaredMethods do
      begin
        if SameText(M.Name, AMethodName) and
           (Length(M.GetParameters) = AParamCount) then
        begin
          ASlotIndex := M.VirtualIndex;
          Result := True;
          Exit;
        end;
      end;
    end;
  end;

// Verified slot indices from the exact Delphi 13 ToolsAPI.pas method order.
// These are used when interface method RTTI is unavailable.
//
// Method layout (ToolsAPI.pas lines 6334-6580):
//   IUnknown                         Slots 0..2
//   IOTAMessageServices40 (7 methods) Slots 3..9
//     3: AddCustomMessage
//     4: AddTitleMessage
//     5: AddToolMessage                (5 params)
//     6: ClearAllMessages
//     7: ClearCompilerMessages
//     8: ClearSearchMessages
//     9: ClearToolMessages
//   IOTAMessageServices50 (1 method) Slot 10
//    10: AddToolMessage                (7 params - with Parent/LineRef)
//   IOTAMessageServices60 (13 methods) Slots 11..23
//    11: AddNotifier
//    12: RemoveNotifier
//    13: AddMessageGroup
//    14: AddCustomMessage              (with Group)
//    15: AddTitleMessage               (with Group)
//    16: AddToolMessage                (8 params)  <-- TARGET 1
//    17: ClearMessageGroup
//    18: ClearToolMessages             (with Group)
//    19: GetMessageGroupCount
//    20: GetMessageGroup
//    21: GetGroup
//    22: ShowMessageView
//    23: RemoveMessageGroup
//   IOTAMessageServices70 (1 method) Slot 24
//    24: AddCompilerMessage            (8 params)  <-- TARGET 2
//   IOTAMessageServices80 (4 methods) Slots 25..28
//    25: NextMessage
//    26: NextErrorMessage
//    27: AddCompilerMessage            (9 params - HelpKeyword)  <-- TARGET 3
//    28: AddCompilerMessage            (9 params - HelpContext)  <-- TARGET 4
//   IOTAMessageServices (11 methods) Slots 29..39
//    31: AddWideCompilerMessage         (8 params)
//    32: AddWideCompilerMessage         (9 params - HelpKeyword)
//    33: AddWideCompilerMessage         (9 params - HelpContext)
//    37: AddWideToolMessage             (5 params)
//    38: AddWideToolMessage             (7 params - Parent/LineRef)
//    39: AddWideToolMessage             (8 params - MessageGroup)
const
  HARDCODED_SLOT_ADD_TOOL_MESSAGE60        = 16;
  HARDCODED_SLOT_ADD_TOOL_MESSAGE40        = 5;
  HARDCODED_SLOT_ADD_TOOL_MESSAGE50        = 10;
  HARDCODED_SLOT_ADD_COMPILER_MESSAGE70    = 24;
  HARDCODED_SLOT_ADD_COMPILER_MESSAGE80_HK = 27;
  HARDCODED_SLOT_ADD_COMPILER_MESSAGE80_HC = 28;
  HARDCODED_SLOT_ADD_WIDE_COMPILER_MESSAGE = 31;
  HARDCODED_SLOT_ADD_WIDE_COMPILER_MESSAGE_HK = 32;
  HARDCODED_SLOT_ADD_WIDE_COMPILER_MESSAGE_HC = 33;
  HARDCODED_SLOT_ADD_WIDE_TOOL_MESSAGE40 = 37;
  HARDCODED_SLOT_ADD_WIDE_TOOL_MESSAGE50 = 38;
  HARDCODED_SLOT_ADD_WIDE_TOOL_MESSAGE60 = 39;

begin
  Result := False;
  Ctx := TRttiContext.Create;
  try
    // Try RTTI first. It is usually unavailable because ToolsAPI.pas is not
    // compiled with {$M+}, but it can detect a future method-order change.
    if MatchIntfMethodByName(IOTAMessageServices60, 'AddToolMessage', 8,
      SlotIndex) then
    begin
      FToolMessageSlotIndex := SlotIndex;
      Trace(Format('DetectSlotIndices: AddToolMessage60 slot=%d (RTTI)', [SlotIndex]));
    end;

    if MatchIntfMethodByName(IOTAMessageServices70, 'AddCompilerMessage', 8,
      SlotIndex) then
    begin
      FCompilerMessageSlotIndex70 := SlotIndex;
      Trace(Format('DetectSlotIndices: AddCompilerMessage70 slot=%d (RTTI)', [SlotIndex]));
    end;

    if MatchIntfMethodByName(IOTAMessageServices80, 'AddCompilerMessage', 9,
      SlotIndex) then
    begin
      FCompilerMessageSlotIndex80a := SlotIndex;
      Trace(Format('DetectSlotIndices: AddCompilerMessage80 first slot=%d (RTTI)',
        [SlotIndex]));

      IntfType := Ctx.GetType(TypeInfo(IOTAMessageServices80)) as TRttiInterfaceType;
      if Assigned(IntfType) then
      begin
        for Method in IntfType.GetDeclaredMethods do
        begin
          if SameText(Method.Name, 'AddCompilerMessage') and
             (Length(Method.GetParameters) = 9) and
             (Method.VirtualIndex <> FCompilerMessageSlotIndex80a) then
          begin
            FCompilerMessageSlotIndex80b := Method.VirtualIndex;
            Trace(Format('DetectSlotIndices: AddCompilerMessage80 second slot=%d (RTTI)',
              [Method.VirtualIndex]));
            Break;
          end;
        end;
      end;
    end;

    // Use the locally verified Delphi 13 slots when RTTI is unavailable.
    FToolMessageSlotIndex40 := HARDCODED_SLOT_ADD_TOOL_MESSAGE40;
    FToolMessageSlotIndex50 := HARDCODED_SLOT_ADD_TOOL_MESSAGE50;
    if FToolMessageSlotIndex < 0 then
    begin
      FToolMessageSlotIndex := HARDCODED_SLOT_ADD_TOOL_MESSAGE60;
      Trace(Format('DetectSlotIndices: AddToolMessage60 slot=%d (hardcoded)',
        [FToolMessageSlotIndex]));
    end;
    if FCompilerMessageSlotIndex70 < 0 then
    begin
      FCompilerMessageSlotIndex70 := HARDCODED_SLOT_ADD_COMPILER_MESSAGE70;
      Trace(Format('DetectSlotIndices: AddCompilerMessage70 slot=%d (hardcoded)',
        [FCompilerMessageSlotIndex70]));
    end;
    if FCompilerMessageSlotIndex80a < 0 then
    begin
      FCompilerMessageSlotIndex80a := HARDCODED_SLOT_ADD_COMPILER_MESSAGE80_HK;
      Trace(Format('DetectSlotIndices: AddCompilerMessage80 HK slot=%d (hardcoded)',
        [FCompilerMessageSlotIndex80a]));
    end;
    if FCompilerMessageSlotIndex80b < 0 then
    begin
      FCompilerMessageSlotIndex80b := HARDCODED_SLOT_ADD_COMPILER_MESSAGE80_HC;
      Trace(Format('DetectSlotIndices: AddCompilerMessage80 HC slot=%d (hardcoded)',
        [FCompilerMessageSlotIndex80b]));
    end;

{$IFNDEF DCG_MESSAGE_SERVICES_LAYOUT_13}
    {$MESSAGE FATAL 'Unverified IOTAMessageServices VMT layout.'}
{$ENDIF}
    // These slots are declared directly on the Delphi 13
    // IOTAMessageServices interface and are fixed by its documented order.
    FWideCompilerMessageSlotIndex := HARDCODED_SLOT_ADD_WIDE_COMPILER_MESSAGE;
    FWideCompilerMessageSlotIndexHK := HARDCODED_SLOT_ADD_WIDE_COMPILER_MESSAGE_HK;
    FWideCompilerMessageSlotIndexHC := HARDCODED_SLOT_ADD_WIDE_COMPILER_MESSAGE_HC;
    FWideToolMessageSlotIndex40 := HARDCODED_SLOT_ADD_WIDE_TOOL_MESSAGE40;
    FWideToolMessageSlotIndex50 := HARDCODED_SLOT_ADD_WIDE_TOOL_MESSAGE50;
    FWideToolMessageSlotIndex60 := HARDCODED_SLOT_ADD_WIDE_TOOL_MESSAGE60;

    Result := True;
  finally
    Ctx.Free;
  end;
end;

function TMessageHook.VerifyVTableSlot(const ASlotIndex: Integer;
  AExpectedPointer: Pointer): Boolean;
var
  Slot: PPointer;
begin
  Result := False;
  if (ASlotIndex < 0) or (FVTableAddress = nil) or
     (AExpectedPointer = nil) then
    Exit;
  Slot := PPointer(PByte(FVTableAddress) + ASlotIndex * SizeOf(Pointer));
  Result := Slot^ = AExpectedPointer;
  if not Result then
    Trace(Format('VerifyVTableSlot: slot=%d expected=%p actual=%p',
      [ASlotIndex, AExpectedPointer, Slot^]));
end;

function TMessageHook.IsTrustedIDESlotPointer(const ASlotPointer: Pointer): Boolean;
var
  Module: HMODULE;
  MemoryInfo: MEMORY_BASIC_INFORMATION;
  ModuleName: array[0..MAX_PATH - 1] of Char;
  FileName: string;
begin
  Result := False;
  if ASlotPointer = nil then
    Exit;
  if VirtualQuery(ASlotPointer, MemoryInfo, SizeOf(MemoryInfo)) = 0 then
    Exit;
  Module := HMODULE(MemoryInfo.AllocationBase);
  if Module = 0 then
    Exit;
  if GetModuleFileName(Module, ModuleName, Length(ModuleName)) = 0 then
    Exit;
  FileName := LowerCase(ExtractFileName(string(ModuleName)));
  // The documented IOTAMessageServices implementation is provided by
  // coreide*.bpl. Refuse unknown owners instead of replacing another plugin's
  // VMT chain, even though that leaves capture unavailable for this job.
  Result := Pos('coreide', FileName) = 1;
  if not Result then
    Trace(Format('PatchVTableSlot: ownership/hook-chain conflict pointer=%p module=%s',
      [ASlotPointer, FileName]));
end;

function TMessageHook.PatchVTableSlot(const ASlotIndex: Integer;
  ANewPointer: Pointer; out AOldPointer: Pointer;
  out AOldProtect: DWORD): Boolean;
var
  Slot: PPointer;
begin
  Result := False;
  AOldPointer := nil;
  AOldProtect := 0;

  if (ASlotIndex < 0) or (FVTableAddress = nil) then
    Exit;

  // Slot address = VMT base + index * SizeOf(Pointer).
  Slot := PPointer(PByte(FVTableAddress) + ASlotIndex * SizeOf(Pointer));
  AOldPointer := Slot^;
  if AOldPointer = ANewPointer then
  begin
    Trace(Format('PatchVTableSlot: ownership/hook-chain conflict on slot %d; already ours',
      [ASlotIndex]));
    Exit;
  end;
  if not IsTrustedIDESlotPointer(AOldPointer) then
  begin
    Trace(Format('PatchVTableSlot: refusing untrusted slot %d pointer=%p',
      [ASlotIndex, AOldPointer]));
    Exit;
  end;

  if not VirtualProtect(Slot, SizeOf(Pointer), PAGE_READWRITE, AOldProtect) then
  begin
    Trace(Format('PatchVTableSlot: VirtualProtect RW failed on slot %d, err=%d',
      [ASlotIndex, GetLastError]));
    Exit;
  end;

  try
    Slot^ := ANewPointer;
    Result := True;
    Trace(Format('PatchVTableSlot: slot=%d old=%p new=%p ok',
      [ASlotIndex, AOldPointer, ANewPointer]));
  finally
    // Restore original protection (best effort)
    if not VirtualProtect(Slot, SizeOf(Pointer), AOldProtect, @AOldProtect) then
      Trace(Format('PatchVTableSlot: VirtualProtect restore failed on slot %d, err=%d',
        [ASlotIndex, GetLastError]));
  end;
end;

function TMessageHook.RestoreVTableSlot(const ASlotIndex: Integer;
  AOldPointer: Pointer; AExpectedPointer: Pointer; AOldProtect: DWORD): Boolean;
var
  Slot: PPointer;
  Dummy: DWORD;
begin
  Result := False;
  if (ASlotIndex < 0) or (FVTableAddress = nil) or (AOldPointer = nil) then
    Exit;

  Slot := PPointer(PByte(FVTableAddress) + ASlotIndex * SizeOf(Pointer));
  if Slot^ <> AExpectedPointer then
  begin
    Trace(Format('RestoreVTableSlot: ownership conflict on slot %d expected=%p actual=%p; not restoring',
      [ASlotIndex, AExpectedPointer, Slot^]));
    Exit;
  end;

  if not VirtualProtect(Slot, SizeOf(Pointer), PAGE_READWRITE, @Dummy) then
  begin
    Trace(Format('RestoreVTableSlot: VirtualProtect RW failed on slot %d, err=%d',
      [ASlotIndex, GetLastError]));
    Exit;
  end;

  try
    Slot^ := AOldPointer;
    Result := True;
    Trace(Format('RestoreVTableSlot: slot=%d restored=%p ok',
      [ASlotIndex, AOldPointer]));
  finally
    VirtualProtect(Slot, SizeOf(Pointer), Dummy, @Dummy);
  end;
end;

function TMessageHook.Install: Boolean;
var
  Svc: IOTAMessageServices;
  PatchedCount: Integer;

  function Patch(const ASlotIndex: Integer; AHook: Pointer;
    out AOriginal: Pointer; out AOldProtect: DWORD): Boolean;
  begin
    Result := PatchVTableSlot(ASlotIndex, AHook, AOriginal, AOldProtect);
    if Result then
    begin
      Inc(PatchedCount);
      Result := VerifyVTableSlot(ASlotIndex, AHook);
      if not Result then
        Trace(Format('Install: post-patch verification failed for slot %d',
          [ASlotIndex]));
    end;
  end;

  procedure Rollback;
  begin
    // Reverse installation order preserves every predecessor chain.
    if PatchedCount >= 12 then RestoreVTableSlot(FWideToolMessageSlotIndex60,
      FOriginalAddWideToolMessage60, @HookedAddWideToolMessage60, FOldProtectWideToolMessage60);
    if PatchedCount >= 11 then RestoreVTableSlot(FWideToolMessageSlotIndex50,
      FOriginalAddWideToolMessage50, @HookedAddWideToolMessage50, FOldProtectWideToolMessage50);
    if PatchedCount >= 10 then RestoreVTableSlot(FWideToolMessageSlotIndex40,
      FOriginalAddWideToolMessage40, @HookedAddWideToolMessage40, FOldProtectWideToolMessage40);
    if PatchedCount >= 9 then RestoreVTableSlot(FWideCompilerMessageSlotIndexHC,
      FOriginalAddWideCompilerMessageHC, @HookedAddWideCompilerMessageHC, FOldProtectWideCompilerMessageHC);
    if PatchedCount >= 8 then RestoreVTableSlot(FWideCompilerMessageSlotIndexHK,
      FOriginalAddWideCompilerMessageHK, @HookedAddWideCompilerMessageHK, FOldProtectWideCompilerMessageHK);
    if PatchedCount >= 7 then RestoreVTableSlot(FWideCompilerMessageSlotIndex,
      FOriginalAddWideCompilerMessage, @HookedAddWideCompilerMessage, FOldProtectWideCompilerMessage);
    if PatchedCount >= 6 then RestoreVTableSlot(FCompilerMessageSlotIndex80b,
      FOriginalAddCompilerMessage80b, @HookedAddCompilerMessage80b, FOldProtectCompilerMessage80b);
    if PatchedCount >= 5 then RestoreVTableSlot(FCompilerMessageSlotIndex80a,
      FOriginalAddCompilerMessage80a, @HookedAddCompilerMessage80a, FOldProtectCompilerMessage80a);
    if PatchedCount >= 4 then RestoreVTableSlot(FCompilerMessageSlotIndex70,
      FOriginalAddCompilerMessage70, @HookedAddCompilerMessage70, FOldProtectCompilerMessage70);
    if PatchedCount >= 3 then RestoreVTableSlot(FToolMessageSlotIndex,
      FOriginalAddToolMessage60, @HookedAddToolMessage60, FOldProtectToolMessage);
    if PatchedCount >= 2 then RestoreVTableSlot(FToolMessageSlotIndex50,
      FOriginalAddToolMessage50, @HookedAddToolMessage50, FOldProtectToolMessage50);
    if PatchedCount >= 1 then RestoreVTableSlot(FToolMessageSlotIndex40,
      FOriginalAddToolMessage40, @HookedAddToolMessage40, FOldProtectToolMessage40);
  end;

  procedure ClearHookState;
  begin
    FOriginalAddToolMessage40 := nil;
    FOriginalAddToolMessage50 := nil;
    FOriginalAddToolMessage60 := nil;
    FOriginalAddCompilerMessage70 := nil;
    FOriginalAddCompilerMessage80a := nil;
    FOriginalAddCompilerMessage80b := nil;
    FOriginalAddWideCompilerMessage := nil;
    FOriginalAddWideCompilerMessageHK := nil;
    FOriginalAddWideCompilerMessageHC := nil;
    FOriginalAddWideToolMessage40 := nil;
    FOriginalAddWideToolMessage50 := nil;
    FOriginalAddWideToolMessage60 := nil;
  end;
begin
  Result := False;
  PatchedCount := 0;
  FCompleteCoverage := False;

  if FInstalled then
  begin
    Trace('Install: already installed');
    Exit(True);
  end;

  if not Supports(BorlandIDEServices, IOTAMessageServices, Svc) then
  begin
    Trace('Install: IOTAMessageServices not available');
    Exit;
  end;

  // Retain the reference so the IDE cannot release this interface instance and
  // create a replacement with the original VMT.
  FMessageServicesIntf := Svc;

  FVTableAddress := FindVTableForInterface(FMessageServicesIntf);
  if FVTableAddress = nil then
  begin
    Trace('Install: cannot resolve VTable pointer');
    Exit;
  end;
  Trace(Format('Install: VTable addr=%p', [Pointer(FVTableAddress)]));

  if not DetectSlotIndices then
  begin
    Trace('Install: could not detect any slot index via RTTI');
    Exit;
  end;

  if not Patch(FToolMessageSlotIndex40, @HookedAddToolMessage40,
    FOriginalAddToolMessage40, FOldProtectToolMessage40) or
     not Patch(FToolMessageSlotIndex50, @HookedAddToolMessage50,
    FOriginalAddToolMessage50, FOldProtectToolMessage50) or
     not Patch(FToolMessageSlotIndex, @HookedAddToolMessage60,
    FOriginalAddToolMessage60, FOldProtectToolMessage) or
     not Patch(FCompilerMessageSlotIndex70, @HookedAddCompilerMessage70,
    FOriginalAddCompilerMessage70, FOldProtectCompilerMessage70) or
     not Patch(FCompilerMessageSlotIndex80a, @HookedAddCompilerMessage80a,
    FOriginalAddCompilerMessage80a, FOldProtectCompilerMessage80a) or
     not Patch(FCompilerMessageSlotIndex80b, @HookedAddCompilerMessage80b,
    FOriginalAddCompilerMessage80b, FOldProtectCompilerMessage80b) or
     not Patch(FWideCompilerMessageSlotIndex, @HookedAddWideCompilerMessage,
    FOriginalAddWideCompilerMessage, FOldProtectWideCompilerMessage) or
     not Patch(FWideCompilerMessageSlotIndexHK, @HookedAddWideCompilerMessageHK,
    FOriginalAddWideCompilerMessageHK, FOldProtectWideCompilerMessageHK) or
     not Patch(FWideCompilerMessageSlotIndexHC, @HookedAddWideCompilerMessageHC,
    FOriginalAddWideCompilerMessageHC, FOldProtectWideCompilerMessageHC) or
     not Patch(FWideToolMessageSlotIndex40, @HookedAddWideToolMessage40,
    FOriginalAddWideToolMessage40, FOldProtectWideToolMessage40) or
     not Patch(FWideToolMessageSlotIndex50, @HookedAddWideToolMessage50,
    FOriginalAddWideToolMessage50, FOldProtectWideToolMessage50) or
     not Patch(FWideToolMessageSlotIndex60, @HookedAddWideToolMessage60,
    FOriginalAddWideToolMessage60, FOldProtectWideToolMessage60) then
  begin
    Trace('Install: patch failed; rolling back transaction');
    Rollback;
    ClearHookState;
    FMessageServicesIntf := nil;
    FVTableAddress := nil;
    Exit;
  end;

  FCompleteCoverage :=
    VerifyVTableSlot(FToolMessageSlotIndex40, @HookedAddToolMessage40) and
    VerifyVTableSlot(FToolMessageSlotIndex50, @HookedAddToolMessage50) and
    VerifyVTableSlot(FToolMessageSlotIndex, @HookedAddToolMessage60) and
    VerifyVTableSlot(FCompilerMessageSlotIndex70, @HookedAddCompilerMessage70) and
    VerifyVTableSlot(FCompilerMessageSlotIndex80a, @HookedAddCompilerMessage80a) and
    VerifyVTableSlot(FCompilerMessageSlotIndex80b, @HookedAddCompilerMessage80b) and
    VerifyVTableSlot(FWideCompilerMessageSlotIndex, @HookedAddWideCompilerMessage) and
    VerifyVTableSlot(FWideCompilerMessageSlotIndexHK, @HookedAddWideCompilerMessageHK) and
    VerifyVTableSlot(FWideCompilerMessageSlotIndexHC, @HookedAddWideCompilerMessageHC) and
    VerifyVTableSlot(FWideToolMessageSlotIndex40, @HookedAddWideToolMessage40) and
    VerifyVTableSlot(FWideToolMessageSlotIndex50, @HookedAddWideToolMessage50) and
    VerifyVTableSlot(FWideToolMessageSlotIndex60, @HookedAddWideToolMessage60);
  if not FCompleteCoverage then
  begin
    Trace('Install: verification failed; rolling back transaction');
    Rollback;
    ClearHookState;
    FMessageServicesIntf := nil;
    FVTableAddress := nil;
    Exit;
  end;

  FInstalled := True;
  Result := True;
  Trace('Install: success with complete narrow and wide coverage');
end;

function TMessageHook.Uninstall: Boolean;
var
  AllRestored: Boolean;

  procedure RestoreAndClear(const ASlotIndex: Integer; var AOriginal: Pointer;
    AHook: Pointer; const AOldProtect: DWORD);
  begin
    if not Assigned(AOriginal) then
      Exit;
    if RestoreVTableSlot(ASlotIndex, AOriginal, AHook, AOldProtect) then
      AOriginal := nil
    else
      AllRestored := False;
  end;
begin
  Result := True;
  if not FInstalled and not Assigned(FOriginalAddToolMessage40) and
     not Assigned(FOriginalAddToolMessage50) and not Assigned(FOriginalAddToolMessage60) and
     not Assigned(FOriginalAddCompilerMessage70) and not Assigned(FOriginalAddCompilerMessage80a) and
     not Assigned(FOriginalAddCompilerMessage80b) and
     not Assigned(FOriginalAddWideCompilerMessage) and
     not Assigned(FOriginalAddWideCompilerMessageHK) and
     not Assigned(FOriginalAddWideCompilerMessageHC) and
     not Assigned(FOriginalAddWideToolMessage40) and
     not Assigned(FOriginalAddWideToolMessage50) and
     not Assigned(FOriginalAddWideToolMessage60) then
    Exit;

  AllRestored := True;
  try
    // Restore in reverse installation order and only while each slot is still
    // ours. Overwriting a later hook would destroy its predecessor chain.
    RestoreAndClear(FWideToolMessageSlotIndex60, FOriginalAddWideToolMessage60,
      @HookedAddWideToolMessage60, FOldProtectWideToolMessage60);
    RestoreAndClear(FWideToolMessageSlotIndex50, FOriginalAddWideToolMessage50,
      @HookedAddWideToolMessage50, FOldProtectWideToolMessage50);
    RestoreAndClear(FWideToolMessageSlotIndex40, FOriginalAddWideToolMessage40,
      @HookedAddWideToolMessage40, FOldProtectWideToolMessage40);
    RestoreAndClear(FWideCompilerMessageSlotIndexHC, FOriginalAddWideCompilerMessageHC,
      @HookedAddWideCompilerMessageHC, FOldProtectWideCompilerMessageHC);
    RestoreAndClear(FWideCompilerMessageSlotIndexHK, FOriginalAddWideCompilerMessageHK,
      @HookedAddWideCompilerMessageHK, FOldProtectWideCompilerMessageHK);
    RestoreAndClear(FWideCompilerMessageSlotIndex, FOriginalAddWideCompilerMessage,
      @HookedAddWideCompilerMessage, FOldProtectWideCompilerMessage);
    RestoreAndClear(FCompilerMessageSlotIndex80b, FOriginalAddCompilerMessage80b,
      @HookedAddCompilerMessage80b, FOldProtectCompilerMessage80b);
    RestoreAndClear(FCompilerMessageSlotIndex80a, FOriginalAddCompilerMessage80a,
      @HookedAddCompilerMessage80a, FOldProtectCompilerMessage80a);
    RestoreAndClear(FCompilerMessageSlotIndex70, FOriginalAddCompilerMessage70,
      @HookedAddCompilerMessage70, FOldProtectCompilerMessage70);
    RestoreAndClear(FToolMessageSlotIndex, FOriginalAddToolMessage60,
      @HookedAddToolMessage60, FOldProtectToolMessage);
    RestoreAndClear(FToolMessageSlotIndex50, FOriginalAddToolMessage50,
      @HookedAddToolMessage50, FOldProtectToolMessage50);
    RestoreAndClear(FToolMessageSlotIndex40, FOriginalAddToolMessage40,
      @HookedAddToolMessage40, FOldProtectToolMessage40);
  finally
    FCompleteCoverage := False;
    Result := AllRestored;
    if AllRestored then
    begin
      FInstalled := False;
      FMessageServicesIntf := nil;
      FVTableAddress := nil;
      Trace('Uninstall: done');
    end
    else
    begin
      FInstalled := True;
      Trace('Uninstall: incomplete; forwarding state retained');
    end;
  end;
end;

initialization
  GMessageHook := nil;

finalization
  FinalizeMessageHook;

end.
