import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples"
HELLO = EXAMPLES / "HelloGate"
COMPILE_ERROR = EXAMPLES / "CompileError" / "CompileError.dpr"


class ExamplesContractTests(unittest.TestCase):
    def test_hello_gate_is_source_only_ready_with_an_explicit_unit_path(self):
        source = (HELLO / "HelloGate.dpr").read_text(encoding="utf-8")
        unit = (HELLO / "src" / "HelloGate.Greeting.pas").read_text(encoding="utf-8")

        self.assertIn("program HelloGate;", source)
        self.assertIn("HelloGate.Greeting in 'src\\HelloGate.Greeting.pas'", source)
        self.assertIn("Writeln(GreetingText);", source)
        self.assertIn("unit HelloGate.Greeting;", unit)
        self.assertIn("function GreetingText: string;", unit)

    def test_optional_project_targets_delphi_13_win32_debug(self):
        project_path = HELLO / "HelloGate.dproj"
        namespace = {"msb": "http://schemas.microsoft.com/developer/msbuild/2003"}
        project = ET.parse(project_path).getroot()

        def property_text(name):
            node = project.find(f".//msb:{name}", namespace)
            self.assertIsNotNone(node, name)
            return node.text

        self.assertEqual("20.1", property_text("ProjectVersion"))
        self.assertEqual("HelloGate.dpr", property_text("MainSource"))
        self.assertEqual("Debug", property_text("Config"))
        self.assertEqual("Win32", property_text("Platform"))
        self.assertEqual("1", property_text("TargetedPlatforms"))
        references = {
            item.attrib["Include"]
            for item in project.findall(".//msb:DCCReference", namespace)
        }
        self.assertEqual({"src\\HelloGate.Greeting.pas"}, references)
        configurations = {
            item.attrib["Include"]
            for item in project.findall(".//msb:BuildConfiguration", namespace)
        }
        self.assertEqual({"Base", "Debug"}, configurations)

    def test_compile_error_has_one_intentional_e2003(self):
        source = COMPILE_ERROR.read_text(encoding="utf-8")

        self.assertIn("Intentional E2003: Undeclared identifier.", source)
        self.assertEqual(1, source.count("UndefinedExampleValue"))
        self.assertIn("Writeln(UndefinedExampleValue);", source)

    def test_examples_do_not_contain_absolute_windows_paths(self):
        for path in EXAMPLES.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in {
                ".dpr", ".dproj", ".pas"
            }:
                continue
            source = path.read_text(encoding="utf-8")
            self.assertIsNone(
                re.search(r"(?<![A-Za-z0-9+.-])[A-Za-z]:[\\/]", source),
                path,
            )

    def test_public_documentation_references_compile_project(self):
        for name in ("README.md", "INSTALLATION.md", "AGENTS.md", "ASSISTANT_GUIDE.md"):
            documentation = (ROOT / name).read_text(encoding="utf-8")
            self.assertIn("DelphiCompileGateClient.compile_project()", documentation, name)
            self.assertIn("client.compile_project(", documentation, name)
            self.assertIn("project_path", documentation, name)
            self.assertIn("source-only", documentation.casefold(), name)

    def test_public_instructions_document_manual_start_and_trust_boundary(self):
        for name in ("README.md", "INSTALLATION.md", "AGENTS.md", "ASSISTANT_GUIDE.md"):
            documentation = (ROOT / name).read_text(encoding="utf-8")
            folded = documentation.casefold()
            self.assertIn("start watch", folded, name)
            self.assertIn("settings / status", folded, name)
            self.assertIn("does not start with the ide", folded, name)
            self.assertIn("local windows account", folded, name)
            self.assertIn("trust boundary", folded, name)
            self.assertRegex(folded, r"custom\s+build\s+steps", name)

    def test_public_installation_documents_the_exact_ide_menu_path(self):
        for name in ("README.md", "INSTALLATION.md"):
            documentation = (ROOT / name).read_text(encoding="utf-8")
            self.assertIn("Help > Help Wizards > Delphi Compile Gate Settings / Status...",
                          documentation, name)
            self.assertIn("Hilfe > Hilfe-Experten > Delphi Compile Gate Settings / Status...",
                          documentation, name)

    def test_public_repository_url_has_no_placeholder(self):
        installation = (ROOT / "INSTALLATION.md").read_text(encoding="utf-8")
        metadata = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
        repository = "https://github.com/CPCCoder/DelphiCompileGate"
        self.assertNotIn("<repository-url>", installation)
        self.assertIn(repository + ".git", installation)
        self.assertIn(repository, metadata)

    def test_agent_instructions_make_dproj_decision_deterministic(self):
        instructions = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        decision = instructions[
            instructions.index("## Simple Decision Rule"):
            instructions.index("## Required State")
        ]
        self.assertIn("If the `.dproj` exists, pass both files", decision)
        self.assertIn("If no `.dproj` exists, pass only the `.dpr` or `.dpk`", decision)
        self.assertIn("creates a managed temporary `.dproj` automatically", decision)
        self.assertIn("Never create, guess, or edit a `.dproj`", decision)
        self.assertIn('arguments["project_path"] = str(project.resolve())', decision)
        self.assertIn("compile_project(**arguments)", decision)
        self.assertIn("Do not call any other compile function", decision)

    def test_readme_contains_a_self_contained_ai_assistant_prompt(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        prompt = readme[
            readme.index("## Prompt for AI Coding Assistants"):
            readme.index("## Runtime Directories")
        ]
        self.assertIn("Read AGENTS.md", prompt)
        self.assertIn("Use only DelphiCompileGateClient.compile_project()", prompt)
        self.assertIn("Never invoke dcc32", prompt)
        self.assertIn("If a same-directory, same-stem\n.dproj already exists", prompt)
        self.assertIn("If no matching\n.dproj exists, pass only the .dpr or .dpk", prompt)
        self.assertIn("Never create, guess, or edit a .dproj", prompt)
        self.assertIn('status is "ok"', prompt)
        self.assertIn("compile.release_eligible is true", prompt)
        self.assertIn("watcher must show Running", prompt)


if __name__ == "__main__":
    unittest.main()
