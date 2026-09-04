import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "Src" / "DelphiCompileGate.Settings.pas").read_text(encoding="utf-8")
DIALOG = (ROOT / "Src" / "DelphiCompileGate.SettingsDialog.pas").read_text(encoding="utf-8")
CONSTS = (ROOT / "Src" / "DelphiCompileGate.Consts.pas").read_text(encoding="utf-8")
COMPILER = (ROOT / "Src" / "DelphiCompileGate.Compiler.pas").read_text(encoding="utf-8")
WATCH = (ROOT / "Src" / "DelphiCompileGate.Watch.pas").read_text(encoding="utf-8")
WIZARD = (ROOT / "Src" / "DelphiCompileGate.Wizard.pas").read_text(encoding="utf-8")
DPK = (ROOT / "Package" / "DelphiCompileGate.dpk").read_text(encoding="utf-8")
DPROJ = (ROOT / "Package" / "DelphiCompileGate.dproj").read_text(encoding="utf-8")


class SettingsContractTests(unittest.TestCase):
    def test_ini_uses_appdata_validated_schema_and_atomic_replace(self):
        self.assertIn("GetEnvironmentVariable('APPDATA')", SETTINGS)
        self.assertIn("DelphiCompileGate.ini", SETTINGS)
        self.assertIn("SETTINGS_SCHEMA_VERSION = 1", CONSTS)
        self.assertIn("TryStrToInt", SETTINGS)
        self.assertIn("ParseBooleanSetting", SETTINGS)
        self.assertIn("MoveFileEx", SETTINGS)
        self.assertIn("MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH", SETTINGS)
        self.assertLess(SETTINGS.index("Ini.UpdateFile"), SETTINGS.index("MoveFileEx"))

    def test_only_safe_runtime_values_are_persisted(self):
        for key in (
            "PollIntervalMs", "BackgroundTimeoutMs", "ExperimentalHiddenModuleClose",
        ):
            self.assertIn(f"'{key}'", SETTINGS)
        for forbidden in (
            "ReloadPolicy", "DialogAutomation", "HookSlot",
            "AutoCloseFailed", "License", "EULA", "CleanupRetries",
        ):
            self.assertNotIn(f"'{forbidden}'", SETTINGS)

    def test_settings_ranges_and_defaults_are_shared(self):
        expected = (
            "DEFAULT_WATCH_INTERVAL_MS = 1000",
            "MIN_WATCH_INTERVAL_MS = 250",
            "MAX_WATCH_INTERVAL_MS = 60000",
            "DEFAULT_COMPILE_TIMEOUT_MS = 60000",
            "MIN_COMPILE_TIMEOUT_MS = 60000",
            "MAX_COMPILE_TIMEOUT_MS = 600000",
            "DEFAULT_EXPERIMENTAL_HIDDEN_MODULE_CLOSE = False",
        )
        for value in expected:
            self.assertIn(value, CONSTS)
        self.assertIn("function Validate(out AError: string): Boolean", SETTINGS)

    def test_compile_timeout_is_runtime_configurable_in_the_v2_compile_path(self):
        self.assertIn("property BackgroundCompileTimeoutMs: Cardinal", COMPILER)
        self.assertNotIn("COMPILE_BACKGROUND_TIMEOUT_MS", COMPILER)
        waits = re.findall(
            r"WaitForBackgroundCompile\(CompileServices,\s*FBackgroundCompileTimeoutMs\)",
            COMPILER,
        )
        self.assertEqual(1, len(waits))
        wait_routine = COMPILER[COMPILER.index("function TDelphiCompileGateCompiler.WaitForBackgroundCompile("):]
        wait_routine = wait_routine[:wait_routine.index("procedure TDelphiCompileGateCompiler.CollectErrorsFromIDE(")]
        self.assertIn("waiting for compiler to settle", wait_routine)
        self.assertNotIn("Result := False;\n      Exit;", wait_routine)

    def test_watcher_applies_settings_without_restarting(self):
        self.assertIn("procedure ApplyRuntimeSettings", WATCH)
        self.assertIn("FTimer.Interval := APollIntervalMs", WATCH)
        self.assertIn("FCompiler.BackgroundCompileTimeoutMs := ACompileTimeoutMs", WATCH)
        self.assertIn("FExperimentalHiddenModuleClose := AExperimentalHiddenModuleClose and", WATCH)
        self.assertIn("not FHiddenModuleCloseFailed", WATCH)
        self.assertIn("remains disabled after session failure", WATCH)
        self.assertIn("if not FExperimentalHiddenModuleClose then", WATCH)
        self.assertNotIn("Ini.ReadString('Projects', 'AutoCloseSuccessful'", SETTINGS)
        self.assertNotIn("AUTO_CLOSE_GENERATED_PROJECTS", WATCH)
        self.assertGreaterEqual(WATCH.count("FDrainRequested := False;"), 5)

    def test_wizard_opens_settings_instead_of_obsolete_rebuild_message(self):
        self.assertIn("ShowDelphiCompileGateSettingsDialog", WIZARD)
        self.assertIn("Settings / Status...", WIZARD)
        self.assertNotIn("Triggered RebuildAll for one queued Input file tick", WIZARD)
        execute = WIZARD[WIZARD.index("procedure TDelphiCompileGateWizard.Execute;"):]
        execute = execute[:execute.index("end.")]
        self.assertNotIn("RebuildAll", execute)

    def test_dialog_is_dfm_free_and_exposes_status_and_safe_controls(self):
        self.assertIn("inherited CreateNew(AOwner)", DIALOG)
        self.assertIn("Start Watch", DIALOG)
        self.assertIn("Pending experimental hidden-module closes", DIALOG)
        self.assertIn("Compile success/failure closes", DIALOG)
        self.assertIn("SaveDelphiCompileGateSettings(NewSettings)", DIALOG)
        self.assertLess(
            DIALOG.index("SaveDelphiCompileGateSettings(NewSettings)"),
            DIALOG.index("FWatch.ApplyRuntimeSettings"),
        )
        self.assertNotIn("FApplyButton", DIALOG)
        self.assertNotIn("ApplyClick", DIALOG)
        self.assertNotIn("Caption := 'Apply'", DIALOG)

    def test_dialog_defers_start_until_ok_but_stops_immediately(self):
        watch_click = DIALOG[
            DIALOG.index("procedure TDelphiCompileGateSettingsForm.WatchClick"):
            DIALOG.index("procedure TDelphiCompileGateSettingsForm.RefreshClick")
        ]
        self.assertIn("if FWatch.IsRunning then", watch_click)
        self.assertIn("FWatch.StopGraceful", watch_click)
        self.assertIn("FStartPending := not FStartPending", watch_click)
        self.assertNotIn("FWatch.Start", watch_click)
        self.assertIn("FDisplayedWatchRunning <> FWatch.IsRunning", watch_click)
        self.assertIn("FDisplayedWatchDraining <> FWatch.IsDraining", watch_click)
        self.assertLess(watch_click.index("FDisplayedWatchRunning"),
                        watch_click.index("if FWatch.IsRunning then"))
        ok_start = DIALOG.index("procedure TDelphiCompileGateSettingsForm.OKClick")
        ok_click = DIALOG[
            ok_start:DIALOG.index("function ShowDelphiCompileGateSettingsDialog", ok_start)
        ]
        self.assertLess(ok_click.index("ApplyEdits"), ok_click.index("FWatch.Start"))
        self.assertIn("FStartPending and not FWatch.IsRunning", ok_click)
        self.assertIn("Start pending (press OK)", DIALOG)
        self.assertIn("Cancel Start", DIALOG)

    def test_package_includes_both_settings_units(self):
        for unit_name in (
            "DelphiCompileGate.Settings.pas",
            "DelphiCompileGate.SettingsDialog.pas",
        ):
            self.assertIn(unit_name, DPK)
        self.assertIn(unit_name, DPROJ)

    def test_removed_rebuild_path_cannot_bypass_the_close_queue(self):
        self.assertNotIn("FWatch.RebuildAll", DIALOG)
        self.assertNotIn("Process One", DIALOG)
        self.assertNotIn("procedure RebuildAll", WATCH)
        self.assertNotIn("procedure TDelphiCompileGateWatch.RebuildAll", WATCH)
        timer = WATCH[WATCH.index("procedure TDelphiCompileGateWatch.OnTimer("):]
        self.assertLess(timer.index("ProcessPendingProjectCloses"),
                        timer.index("ProcessPending;"))

    def test_atomic_temp_file_is_unique_per_save(self):
        self.assertIn("TPath.GetRandomFileName", SETTINGS)
        self.assertNotIn("TempFile := FileName + '.tmp'", SETTINGS)


if __name__ == "__main__":
    unittest.main()
