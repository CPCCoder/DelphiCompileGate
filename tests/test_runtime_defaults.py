import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
CLIENT_SOURCE = (ROOT / "delphi_compile_gate.py").read_text(encoding="utf-8")
COMPILER = (ROOT / "Src" / "DelphiCompileGate.Compiler.pas").read_text(encoding="utf-8")
WATCH = (ROOT / "Src" / "DelphiCompileGate.Watch.pas").read_text(encoding="utf-8")


class RuntimeDefaultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import sys

        sys.path.insert(0, str(ROOT))
        from delphi_compile_gate import DelphiCompileGateClient

        cls.client_type = DelphiCompileGateClient

    def test_explicit_gate_environment_precedes_local_app_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            override = root / "override"
            local_app_data = root / "local"
            with patch.dict(os.environ, {
                "DELPHI_COMPILE_GATE_BASE_DIR": str(override),
                "LOCALAPPDATA": str(local_app_data),
            }):
                client = self.client_type()

            self.assertEqual(client.BASE_DIR, override)
            self.assertTrue((override / "Input").is_dir())
            self.assertFalse((local_app_data / "DelphiCompileGate").exists())

    def test_local_app_data_is_the_default_runtime_root(self):
        with tempfile.TemporaryDirectory() as directory:
            local_app_data = Path(directory) / "local"
            expected = local_app_data / "DelphiCompileGate" / "Run"
            with patch.dict(os.environ, {
                "DELPHI_COMPILE_GATE_BASE_DIR": "",
                "LOCALAPPDATA": str(local_app_data),
            }):
                client = self.client_type()

            self.assertEqual(client.BASE_DIR, expected)
            for child in ("Input", "Output", "Processed", "Failed", "Logs"):
                self.assertTrue((expected / child).is_dir())

    def test_missing_local_app_data_falls_back_under_user_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            user_profile = Path(directory) / "profile"
            expected = user_profile / "AppData" / "Local" / "DelphiCompileGate" / "Run"
            with patch.dict(os.environ, {
                "DELPHI_COMPILE_GATE_BASE_DIR": "",
                "LOCALAPPDATA": "",
                "USERPROFILE": str(user_profile),
            }):
                client = self.client_type()

            self.assertEqual(client.BASE_DIR, expected)
            self.assertTrue((expected / "Input").is_dir())

    def test_unavailable_user_profile_falls_back_to_os_temp(self):
        with tempfile.TemporaryDirectory() as directory:
            temp_root = Path(directory) / "temp"
            expected = temp_root / "DelphiCompileGate" / "Run"
            with patch.dict(os.environ, {
                "DELPHI_COMPILE_GATE_BASE_DIR": "",
                "LOCALAPPDATA": "",
                "USERPROFILE": "",
            }), patch(
                "delphi_compile_gate.tempfile.gettempdir", return_value=str(temp_root)
            ):
                client = self.client_type()

            self.assertEqual(client.BASE_DIR, expected)
            self.assertTrue((expected / "Logs").is_dir())

    def test_plugin_uses_one_resolver_for_watch_and_wrapper_roots(self):
        implementation = COMPILER.index("implementation")
        resolver_start = COMPILER.index(
            "function ResolveDelphiCompileGateBaseDir: string;", implementation
        )
        resolver_end = COMPILER.index("\n{ TCompileError }", resolver_start)
        resolver = COMPILER[resolver_start:resolver_end]

        override_at = resolver.index("DELPHI_COMPILE_GATE_BASE_DIR")
        local_at = resolver.index("LOCALAPPDATA")
        profile_at = resolver.index("GetEnvironmentVariable('USERPROFILE')")
        temp_at = resolver.index("GetEnvironmentVariable('TEMP')")
        self.assertLess(override_at, local_at)
        self.assertLess(local_at, profile_at)
        self.assertLess(profile_at, temp_at)
        self.assertNotIn("TPath.GetHomePath", resolver)
        self.assertIn("'DelphiCompileGate'), 'Run'", resolver)

        python_local_at = CLIENT_SOURCE.index('os.getenv("LOCALAPPDATA"')
        python_profile_at = CLIENT_SOURCE.index('os.getenv("USERPROFILE"')
        python_temp_at = CLIENT_SOURCE.index("tempfile.gettempdir()")
        self.assertLess(python_local_at, python_profile_at)
        self.assertLess(python_profile_at, python_temp_at)

        watch_constructor = WATCH[
            WATCH.index("constructor TDelphiCompileGateWatch.Create;"):
            WATCH.index("function TDelphiCompileGateWatch.GetPollIntervalMs")
        ]
        self.assertIn("BaseDir := ResolveDelphiCompileGateBaseDir;", watch_constructor)
        self.assertNotIn("GetEnvironmentVariable", watch_constructor)

        for routine_name, next_name in (
            ("function TDelphiCompileGateCompiler.TryCloseGeneratedModule(",
             "function TDelphiCompileGateCompiler.IsGeneratedModuleOpen("),
            ("function TDelphiCompileGateCompiler.BuildProjectWrapper(",
             "function TDelphiCompileGateCompiler.ValidateDprProject("),
        ):
            routine = COMPILER[COMPILER.index(routine_name):COMPILER.index(
                next_name, COMPILER.index(routine_name)
            )]
            self.assertIn(
                "TPath.Combine(ResolveDelphiCompileGateBaseDir, 'Projects')", routine
            )
            self.assertNotIn("GetEnvironmentVariable('DELPHI_COMPILE_GATE_BASE_DIR')", routine)

    def test_executable_sources_have_no_checkout_specific_default(self):
        for source in (CLIENT_SOURCE, COMPILER, WATCH):
            self.assertNotIn("F:\\Programming", source)

    def test_client_documents_manual_watcher_start(self):
        self.assertNotIn("starts automatically", CLIENT_SOURCE)
        self.assertIn("selected Start Watch and then OK", CLIENT_SOURCE)


if __name__ == "__main__":
    unittest.main()
