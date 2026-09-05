unit DelphiCompileGate.Consts;

interface

const
  PLUGIN_NAME = 'DelphiCompileGate';
  PLUGIN_VERSION = '2.0.1';
  PLUGIN_MENU_CAPTION = 'Delphi Compile Gate';
  SETTINGS_SCHEMA_VERSION = 1;
  DEFAULT_WATCH_INTERVAL_MS = 1000;
  MIN_WATCH_INTERVAL_MS = 250;
  MAX_WATCH_INTERVAL_MS = 60000;
  DEFAULT_COMPILE_TIMEOUT_MS = 60000;
  // The existing v2 evidence window is 60 seconds. Settings may extend it but
  // must never shorten it and finalize while the compiler is still active.
  MIN_COMPILE_TIMEOUT_MS = 60000;
  MAX_COMPILE_TIMEOUT_MS = 600000;
  // Closing a project is opt-in. The IDE remains stable with the setting off,
  // and only the v2 wrapper path has passed repeated close stress tests.
  DEFAULT_EXPERIMENTAL_HIDDEN_MODULE_CLOSE = False;

implementation

end.
