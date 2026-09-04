{$IF CompilerVersion = 37.0}
  {$DEFINE DCG_IDE13}
  {$DEFINE DCG_MESSAGE_SERVICES_LAYOUT_13}
{$ELSE}
  {$MESSAGE FATAL 'DelphiCompileGate supports only Delphi 13 (CompilerVersion 37.0).'}
{$IFEND}
