import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPILER = (ROOT / "Src" / "DelphiCompileGate.Compiler.pas").read_text(encoding="utf-8")
HOOK = (ROOT / "Src" / "DelphiCompileGate.MessageHook.pas").read_text(encoding="utf-8")
WATCH = (ROOT / "Src" / "DelphiCompileGate.Watch.pas").read_text(encoding="utf-8")
PROTOCOL_V2 = (ROOT / "Src" / "DelphiCompileGate.ProtocolV2.pas").read_text(encoding="utf-8")
NESTED_SOURCE_FIXTURE = ROOT / "tests" / "fixtures" / "nested_source_metadata.xml"
CAPTURE_SCOPE_FIXTURE = ROOT / "tests" / "fixtures" / "capture_scope_sibling_paths.json"
BARE_CAPTURE_SCOPE_FIXTURE = ROOT / "tests" / "fixtures" / "capture_scope_bare_filenames.json"
COMPILE_ITEMS_FIXTURE = ROOT / "tests" / "fixtures" / "wrapper_capture_compile_items.dproj"
SEARCH_PATH_DOM_FIXTURE = ROOT / "tests" / "fixtures" / "SearchPathDom" / "SearchPathDom.dproj"
SEARCH_PATH_MACRO_FIXTURE = ROOT / "tests" / "fixtures" / "SearchPathDom" / "MacroRejected.dproj"


def pascal_routine(source, name, next_name):
    implementation = source.index("implementation")
    start = source.index(name, implementation)
    end = source.index(next_name, start)
    return source[start:end]


class WrapperIsolationContractTests(unittest.TestCase):

    def test_search_path_facade_fixture_requires_transitive_project_path(self):
        fixture = ROOT / "tests" / "fixtures" / "SearchPathFacade"
        dpr = (fixture / "SearchPathFacade.dpr").read_text(encoding="utf-8")
        dproj = (fixture / "SearchPathFacade.dproj").read_text(encoding="utf-8")
        facade = (fixture / "src" / "Facade.pas").read_text(encoding="utf-8")
        self.assertIn("Facade in 'src\\Facade.pas'", dpr)
        self.assertNotIn("Dependency", dpr)
        self.assertIn("Dependency", facade)
        self.assertIn("<DCC_UnitSearchPath>lib;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>",
                      dproj)
        self.assertNotIn("lib\\Dependency.pas", dproj)
        self.assertTrue((fixture / "lib" / "Dependency.pas").is_file())

    def test_unit_search_path_diagnostics_use_official_ota_key_read_only(self):
        validate = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        start = validate.index("function TraceUnitSearchPathState")
        diagnostics = validate[start:validate.index("end;\nbegin", start)]
        self.assertIn("DCCStrs.sUnitSearchPath", diagnostics)
        self.assertIn("Options.Values['UnitSearchPath']", diagnostics)
        self.assertIn("IOTAProjectOptionsConfigurations", diagnostics)
        self.assertIn("PlatformConfiguration[APlatform]", diagnostics)
        self.assertIn("GetValue(DCCStrs.sUnitSearchPath, False)", diagnostics)
        self.assertIn("GetValue(DCCStrs.sUnitSearchPath, True)", diagnostics)
        self.assertIn("InheritedValue(DCCStrs.sUnitSearchPath)", diagnostics)
        self.assertIn("Merged[DCCStrs.sUnitSearchPath]", diagnostics)
        self.assertIn("function WrapperDeclaresUnitSearchPath", diagnostics)
        self.assertIn("Doc.LoadFromFile(ADprFile)", diagnostics)
        self.assertIn("SameText(ANode.LocalName, 'DCC_UnitSearchPath')", diagnostics)
        self.assertNotIn("SetValue", diagnostics)
        self.assertNotIn("SetValues", diagnostics)
        self.assertLess(validate.index("UseProjectBuilderForCompile := TraceUnitSearchPathState;"),
                        validate.index("CompileServices.CompileProjects"))
        self.assertIn("SuppliedProject := SameText(ExtractFileExt(ASourceName), '.dproj')",
                      diagnostics)
        self.assertIn("unit_search_path_unavailable", diagnostics)
        self.assertIn("ProjectBuilder.BuildProject(cmOTABuild, False, True)",
                      validate)
        self.assertIn("Compile entry=IOTAProjectBuilder.BuildProject", validate)
        self.assertNotIn("Options.Values[DCCStrs.sUnitSearchPath] :=", validate)

    def test_derived_unit_search_path_read_failure_is_fail_closed(self):
        validate = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        start = validate.index("function TraceUnitSearchPathState")
        diagnostics = validate[start:validate.index("end;\nbegin", start)]
        self.assertIn("EffectiveOptionAvailable := False", diagnostics)
        self.assertIn("EffectiveOptionAvailable := True", diagnostics)
        self.assertIn("(not EffectiveOptionAvailable)", diagnostics)
        self.assertLess(
            diagnostics.index("EffectiveOptionValue := '<error:' + E.ClassName + '>'"),
            diagnostics.index("(not EffectiveOptionAvailable)"),
        )
        self.assertLess(
            diagnostics.index("(not EffectiveOptionAvailable)"),
            diagnostics.index("Result := DeclaresUnitSearchPath"),
        )

    def test_search_path_dom_fixture_covers_conditional_ampersand_and_import_order(self):
        root = ET.parse(SEARCH_PATH_DOM_FIXTURE).getroot()
        local_name = lambda node: node.tag.rsplit("}", 1)[-1]
        search_paths = [node for node in root.iter()
                        if local_name(node) == "DCC_UnitSearchPath"]
        self.assertEqual(1, len(search_paths))
        self.assertEqual("lib&shared;$(DCC_UnitSearchPath)", search_paths[0].text)
        self.assertEqual("'$(Platform)'=='Win32'", search_paths[0].attrib["Condition"])
        references = [node for node in root.iter() if local_name(node) == "DCCReference"]
        self.assertEqual("lib&shared\\AmpDependency.pas", references[0].attrib["Include"])
        imports = [node.attrib["Project"] for node in root
                   if local_name(node) == "Import"]
        self.assertEqual(["common.props", "$(BDS)\\Bin\\CodeGear.Delphi.Targets"], imports)
        self.assertFalse(any(local_name(node) == "DCC_ExeOutput" for node in root.iter()))
        self.assertTrue((SEARCH_PATH_DOM_FIXTURE.parent / "lib&shared" /
                         "AmpDependency.pas").is_file())

    def test_search_path_macro_fixture_requires_fail_closed_rejection(self):
        root = ET.parse(SEARCH_PATH_MACRO_FIXTURE).getroot()
        search_path = next(node for node in root.iter()
                           if node.tag.rsplit("}", 1)[-1] == "DCC_UnitSearchPath")
        self.assertEqual("lib\\$(Platform);$(DCC_UnitSearchPath)", search_path.text)

    def test_unit_search_path_dom_rewrite_is_canonical_and_fail_closed(self):
        rewriter = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.MakeDprojReferencesAbsolute(",
            "function TDelphiCompileGateCompiler.SanitizeWrapperDprojSources(",
        )
        self.assertIn("function RewritePathList", rewriter)
        self.assertIn("TXMLDocument.Create", rewriter)
        self.assertIn("Doc.LoadFromXML(ADprojText)", rewriter)
        self.assertIn("Result := Doc.XML.Text", rewriter)
        self.assertIn("SameText(ANode.LocalName, AName)", rewriter)
        self.assertIn("ANode.Text := RewritePathList(ANode.Text)", rewriter)
        self.assertIn("ANode.Attributes['Include'] := AbsolutePath(IncludeValue)", rewriter)
        self.assertNotIn("DecodeXMLText", rewriter)
        self.assertNotIn("EncodeXMLText", rewriter)
        self.assertIn("TPath.IsPathRooted(APath)", rewriter)
        self.assertIn("TPath.Combine(ASourceDir, APath)", rewriter)
        self.assertIn("TPath.GetFullPath", rewriter)
        self.assertIn("DirectoryExists(Result)", rewriter)
        self.assertIn("FILE_ATTRIBUTE_REPARSE_POINT", rewriter)
        self.assertIn("unit_search_path_invalid", rewriter)
        self.assertIn("if APath = '$(DCC_UnitSearchPath)' then", rewriter)
        self.assertIn("Pos('$(', APath)", rewriter)
        self.assertIn("(Pos('%', APath) > 0)", rewriter)
        macro_check = rewriter[rewriter.index("if APath = '$(DCC_UnitSearchPath)' then"):
                               rewriter.index("try", rewriter.index("if APath = '$(DCC_UnitSearchPath)' then"))]
        self.assertIn("raise Exception.Create('unit_search_path_invalid')", macro_check)
        self.assertIn("Result := Result + ';'", rewriter)
        self.assertIn("function IsDelphiTargetsImport", rewriter)
        self.assertIn("ExtractFileName(ProjectName)", rewriter)
        self.assertIn("'CodeGear.Delphi.Targets'", rewriter)
        self.assertIn("OutputGroup := Root.AddChild('PropertyGroup', ImportIndex)", rewriter)
        self.assertIn("raise Exception.Create('wrapper_project_invalid')", rewriter)
        self.assertNotIn("ImportStart := Pos(", rewriter)

    def test_wrapper_sanitizer_preserves_dccreference_compile_items(self):
        sanitizer = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.SanitizeWrapperDprojSources(",
            "procedure TDelphiCompileGateCompiler.ValidateWrapperDproj",
        )
        self.assertIn("TXMLDocument.Create", sanitizer)
        self.assertIn("Doc.LoadFromXML", sanitizer)
        self.assertIn("Result := Doc.XML.Text;", sanitizer)
        self.assertIn("AParent.ChildNodes.Delete", sanitizer)
        self.assertIn("WrapperCompileCount", sanitizer)
        self.assertIn("IsElementName(Node, 'PropertyGroup')", sanitizer)
        self.assertIn("Node.ChildNodes.FindNode('MainSource').Text := AWrapperMainSource", sanitizer)
        self.assertNotIn("ProcessItemGroup(Node);\n        else if IsElementName(Node, 'ProjectExtensions')", sanitizer)
        self.assertIn("if SameText(Node.NodeName, 'DelphiCompile') then", sanitizer)
        self.assertNotIn("SameText(Node.NodeName, 'DCCReference')", sanitizer)
        self.assertIn("AWrapperMainSource", sanitizer)
        for extension in (".pas", ".dfm", ".dpr"):
            self.assertIn(extension, sanitizer)

    def test_capture_only_hooks_capture_before_suppressing_forwarding(self):
        self.assertIn("FCaptureOnlyDepth", HOOK)
        self.assertIn("function BeginCaptureOnly", HOOK)
        self.assertIn("procedure EndCaptureOnly", HOOK)
        for name in (
            "HookedAddToolMessage40",
            "HookedAddToolMessage50",
            "HookedAddToolMessage60",
            "HookedAddCompilerMessage70",
            "HookedAddCompilerMessage80a",
            "HookedAddCompilerMessage80b",
            "HookedAddWideCompilerMessage",
            "HookedAddWideCompilerMessageHK",
            "HookedAddWideCompilerMessageHC",
            "HookedAddWideToolMessage40",
            "HookedAddWideToolMessage50",
            "HookedAddWideToolMessage60",
        ):
            next_name = {
                "HookedAddToolMessage40": "procedure HookedAddToolMessage50",
                "HookedAddToolMessage50": "procedure HookedAddToolMessage60",
                "HookedAddToolMessage60": "procedure HookedAddCompilerMessage70",
                "HookedAddCompilerMessage70": "procedure HookedAddCompilerMessage80a",
                "HookedAddCompilerMessage80a": "procedure HookedAddCompilerMessage80b",
                "HookedAddCompilerMessage80b": "procedure HookedAddWideCompilerMessage",
                "HookedAddWideCompilerMessage": "procedure HookedAddWideCompilerMessageHK",
                "HookedAddWideCompilerMessageHK": "procedure HookedAddWideCompilerMessageHC",
                "HookedAddWideCompilerMessageHC": "procedure HookedAddWideToolMessage40",
                "HookedAddWideToolMessage40": "procedure HookedAddWideToolMessage50",
                "HookedAddWideToolMessage50": "procedure HookedAddWideToolMessage60",
                "HookedAddWideToolMessage60": "{ TMessageHook }",
            }[name]
            routine = pascal_routine(HOOK, name, next_name)
            capture_at = routine.index("Capture")
            forward_at = routine.index("if Assigned(Orig) then")
            self.assertLess(capture_at, forward_at)
            self.assertIn("AndShouldSuppress", routine)
            self.assertIn("Exit;", routine[capture_at:forward_at])

    def test_capture_only_does_not_emit_per_callback_telemetry(self):
        self.assertNotIn("TraceCaptureCallback", HOOK)
        self.assertNotIn("Callback slot=", HOOK)
        self.assertNotIn("Capture scope=%s", HOOK)

    def test_all_documented_narrow_and_wide_vmt_slots_are_used(self):
        for slot in ("= 5", "= 10", "= 16", "= 24", "= 27", "= 28",
                     "= 31", "= 32", "= 33", "= 37", "= 38", "= 39"):
            self.assertIn(slot, HOOK)

    def test_wide_trampolines_match_delphi_12_toolsapi_signatures(self):
        signatures = (
            "AFileName, AMessageStr, AToolName: WideString;",
            "AParent: Pointer; out ALineRef: Pointer; AHelpKeyword: WideString",
            "AParent: Pointer; out ALineRef: Pointer; AHelpContext: Integer",
            "AFileName, AMessageStr, APrefixStr: WideString;",
            "out ALineRef: Pointer; const AMessageGroupIntf: IOTAMessageGroup",
        )
        for signature in signatures:
            self.assertIn(signature, HOOK)
        self.assertNotIn("stdcall;\n\nprocedure HookedAddWide", HOOK)
        for value in ("string(AFileName)", "string(AMessageStr)", "string(AToolName)",
                      "string(APrefixStr)", "string(AHelpKeyword)"):
            self.assertIn(value, HOOK)
        self.assertNotIn("const AFileName, AMessageStr, AToolName: WideString", HOOK)
        self.assertNotIn("const AFileName, AMessageStr, APrefixStr: WideString", HOOK)

    def test_v2_target_selection_reapplies_configuration_after_platform(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        platform_set = routine.index("Project.CurrentPlatform := APlatform")
        configuration_set = routine.index("Project.CurrentConfiguration := AConfiguration")
        self.assertLess(platform_set, configuration_set)
        self.assertIn("Project target selection requested=%s/%s selected=%s/%s", routine)
        self.assertIn("target_selection_unavailable", routine)
        protocol = (ROOT / "Src" / "DelphiCompileGate.ProtocolV2.pas").read_text(encoding="utf-8")
        compat = (ROOT / "Src" / "DelphiCompileGate.IdeCompat.inc").read_text(encoding="utf-8")
        build_info = (ROOT / "Src" / "DelphiCompileGate.BuildInfo.pas").read_text(encoding="utf-8")
        normalized_protocol = " ".join(protocol.split())
        self.assertIn(
            "Result := ((APlatform = 'Win32') or (APlatform = 'Win64')) and "
            "((AConfiguration = 'Debug') or (AConfiguration = 'Release'));",
            normalized_protocol,
        )
        self.assertIn("not IsAllowedV2Target(ARequest.Platform, ARequest.Configuration)", protocol)
        self.assertIn("target_selection_unavailable", WATCH)
        self.assertIn("CompilerVersion = 37.0", compat)
        self.assertNotIn("CompilerVersion = 36.0", compat)
        self.assertIn("DCG_MESSAGE_SERVICES_LAYOUT_13", compat)
        self.assertIn("{$MESSAGE FATAL", compat)
        self.assertIn("dcg-v2-20260905-searchpathfix-03", build_info)
        self.assertIn("DCG_IDE_VERSION", protocol)

    def test_package_outputs_are_isolated_by_active_bds_installation(self):
        project = (ROOT / "Package" / "DelphiCompileGate.dproj").read_text(encoding="utf-8")
        self.assertIn("DCGIDEOutputRoot", project)
        self.assertIn("$(BDSCOMMONDIR)\\DelphiCompileGate\\$(Platform)\\$(Config)", project)
        self.assertNotIn("$([System.IO.Path]::", project)
        self.assertIn("<DCC_DcuOutput>", project)
        self.assertIn("<DCC_BplOutput>", project)
        self.assertIn("<DCC_DcpOutput>", project)

    def test_compile_error_example_has_valid_config_graph_and_one_intentional_error(self):
        fixture = ROOT / "tests" / "fixtures" / "DcgCompileErrorExample.dproj"
        project = ET.parse(fixture).getroot()
        namespace = {"msb": "http://schemas.microsoft.com/developer/msbuild/2003"}
        configurations = {
            item.attrib["Include"]
            for item in project.findall(".//msb:BuildConfiguration", namespace)
        }
        self.assertEqual(configurations, {"Base", "Debug", "Release"})
        source = fixture.with_suffix(".dpr").read_text(encoding="utf-8")
        self.assertEqual(source.count("UndefinedGateExampleValue"), 1)
        self.assertIn("Writeln(UndefinedGateExampleValue);", source)

    def test_hook_install_is_transactional_verified_and_ownership_aware(self):
        install = pascal_routine(
            HOOK, "function TMessageHook.Install: Boolean;",
            "function TMessageHook.Uninstall: Boolean;",
        )
        self.assertIn("if not Patch(", install)
        self.assertIn("PatchVTableSlot(ASlotIndex", install)
        self.assertIn("Result := VerifyVTableSlot(ASlotIndex, AHook);", install)
        self.assertIn("rolling back transaction", install)
        self.assertIn("procedure Rollback", install)
        self.assertIn("Reverse installation order", install)
        # One immediate verification plus all twelve final coverage checks.
        self.assertEqual(13, install.count("VerifyVTableSlot("))
        self.assertIn("FCompleteCoverage :=", install)
        restore = pascal_routine(
            HOOK, "function TMessageHook.RestoreVTableSlot(",
            "function TMessageHook.Install: Boolean;",
        )
        self.assertIn("if Slot^ <> AExpectedPointer then", restore)
        self.assertIn("ownership conflict", restore)
        self.assertIn("not restoring", restore)
        patch = pascal_routine(
            HOOK, "function TMessageHook.PatchVTableSlot(",
            "function TMessageHook.RestoreVTableSlot(",
        )
        self.assertIn("IsTrustedIDESlotPointer(AOldPointer)", patch)
        self.assertIn("refusing untrusted slot", patch)
        trusted_owner = pascal_routine(
            HOOK, "function TMessageHook.IsTrustedIDESlotPointer(",
            "function TMessageHook.PatchVTableSlot(",
        )
        self.assertIn("VirtualQuery(ASlotPointer, MemoryInfo", trusted_owner)
        self.assertIn("Module := HMODULE(MemoryInfo.AllocationBase);", trusted_owner)
        self.assertNotIn("GetModuleHandleEx", trusted_owner)
        self.assertIn("FCompleteCoverage := False", HOOK)

    def test_complete_coverage_requires_all_twelve_hooks(self):
        install = pascal_routine(
            HOOK, "function TMessageHook.Install: Boolean;",
            "function TMessageHook.Uninstall: Boolean;",
        )
        hook_names = (
            "HookedAddToolMessage40", "HookedAddToolMessage50", "HookedAddToolMessage60",
            "HookedAddCompilerMessage70", "HookedAddCompilerMessage80a",
            "HookedAddCompilerMessage80b", "HookedAddWideCompilerMessage",
            "HookedAddWideCompilerMessageHK", "HookedAddWideCompilerMessageHC",
            "HookedAddWideToolMessage40", "HookedAddWideToolMessage50",
            "HookedAddWideToolMessage60",
        )
        for hook_name in hook_names:
            self.assertIn(f"VerifyVTableSlot", install)
            self.assertIn(f"@{hook_name}", install)

    def test_callbacks_contain_capture_failure_handling(self):
        self.assertIn("FCaptureFailed", HOOK)
        self.assertIn("procedure TMessageHook.MarkCaptureFailure", HOOK)
        self.assertIn("except\n    MarkCaptureFailure", HOOK)
        self.assertIn("MessageHook.CaptureFailed", COMPILER)

    def test_message_hook_is_scoped_to_each_compile_job(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertIn("MessageHookInstalledByJob: Boolean", routine)
        self.assertIn("MessageHookInstalledByJob := False", routine)
        self.assertIn("MessageHookInstalledByJob := True", routine)
        self.assertIn("if MessageHookInstalledByJob then", routine)
        self.assertIn("MessageHook.Uninstall", routine)
        self.assertIn("message_hook_uninstall_failed", routine)
        self.assertLess(routine.rindex("CollectErrorsFromIDE"),
                        routine.rindex("MessageHook.Uninstall"))

    def test_partial_message_hook_restore_blocks_followup_capture_and_unload(self):
        wrapper = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        coverage_check = (
            "if not MessageHook.Installed or not MessageHook.CompleteCoverage then"
        )
        self.assertIn(coverage_check, wrapper)
        self.assertGreater(wrapper.index(coverage_check),
                           wrapper.index("if not MessageHook.Installed then"))
        finalizer = pascal_routine(
            HOOK,
            "procedure FinalizeMessageHook;",
            "// --- Hook procedure infrastructure",
        )
        self.assertIn("GMessageHook.OnTrace := nil", finalizer)
        self.assertIn("DCGGetModuleHandleExW", finalizer)
        self.assertIn("if not GMessageHook.Uninstall then", finalizer)
        self.assertIn("Exit;", finalizer)
        self.assertIn("FreeLibrary(GMessageHookModuleHold)", finalizer)
        self.assertNotIn("FreeAndNil", finalizer)
        destructor = pascal_routine(
            HOOK,
            "destructor TMessageHook.Destroy;",
            "procedure TMessageHook.Trace(",
        )
        self.assertNotIn("if FInstalled", destructor)
        self.assertEqual(1, HOOK.count("GMessageHook.Free"))

    def test_wrapper_capture_starts_before_open_and_ends_in_outer_finally(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertLess(routine.index("MessageHook.BeginCaptureOnly"),
                        routine.index("ModuleServices.OpenModule"))
        self.assertIn("if CaptureOnlyStarted then", routine)
        self.assertLess(routine.rindex("CollectErrorsFromIDE"),
                        routine.rindex("MessageHook.EndCaptureOnly"))

    def test_v2_opens_wrapper_as_hidden_project_module(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertIn("OpenedModule := ModuleServices.OpenModule(ADprFile)", routine)
        self.assertIn("EnsureNoDialogBlock('OpenModule')", routine)
        self.assertIn("OpenedModule.FileName", routine)
        self.assertIn("Supports(OpenedModule, IOTAProject, Project)", routine)
        self.assertNotIn(".Show", routine)
        self.assertNotIn("ActionServices.OpenProject", routine)
        self.assertNotIn("IOTAActionServices", routine)

    def test_capture_only_diagnostics_do_not_scan_message_view(self):
        collector = pascal_routine(
            COMPILER,
            "procedure TDelphiCompileGateCompiler.CollectErrorsFromIDE(",
            "end.",
        )
        self.assertIn("HookedMsgs := MessageHook.GetMessages", collector)
        self.assertIn("capture-only job has no hook diagnostics", collector)
        self.assertNotIn("TryClipboardCopy", collector)
        self.assertNotIn("TRttiContext", collector)
        self.assertNotIn("IOTAMessageServices", collector)

    def test_v2_notifier_success_ignores_informational_diagnostics(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        collector = pascal_routine(
            COMPILER,
            "procedure TDelphiCompileGateCompiler.CollectErrorsFromIDE(",
            "end.",
        )
        self.assertIn("CollectErrorsFromIDE(Result.Errors);", routine)
        self.assertIn("Result.Success := ACompileEvidenceAvailable and ACompileSucceeded;", routine)
        self.assertIn("if not Error.IsWarning then", routine)
        self.assertIn(
            "AErrors[High(AErrors)].IsWarning := (Sev = msHint) or",
            collector,
        )
        self.assertIn("(Sev = msInfo);", collector)
        self.assertIn("Msg.Severity := msInfo;", HOOK)

    def test_v2_capture_failure_has_stable_protocol_code(self):
        self.assertIn("raise Exception.Create('message_capture_unavailable')", COMPILER)
        self.assertIn("FailureCode := 'message_capture_unavailable'", WATCH)
        self.assertIn("FailureCode := 'dialog_blocked'", WATCH)
        self.assertIn("source_buffer_mismatch", WATCH)
        self.assertIn("source_buffer_unverified", WATCH)
        self.assertIn("wrapper_project_invalid", WATCH)

    def test_notifier_failure_without_actionable_error_has_distinct_code(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertIn("HasActionableNonWarningDiagnostic(Result.Errors)", routine)
        self.assertIn("(not ACompileSucceeded)", routine)
        self.assertIn("raise Exception.Create('compile_error_details_unavailable')", routine)
        self.assertNotIn("Compilation failed without captured diagnostic messages", routine)
        self.assertIn("FailureCode := 'compile_error_details_unavailable'", WATCH)

    def test_wrapper_modal_policy_is_fail_closed(self):
        self.assertIn("V2_DIALOG_BLOCK_TIMEOUT_MS", COMPILER)
        self.assertIn("HasPreexistingModal", COMPILER)
        self.assertIn("raise Exception.Create('dialog_blocked')", COMPILER)
        self.assertIn("legal_no_safe_reject", COMPILER)
        self.assertIn("unknown_no_safe_cancel", COMPILER)
        self.assertIn("dapProtocolV2", COMPILER)
        self.assertIn("dapReloadOnly", COMPILER)
        self.assertNotIn("dapLegacy", COMPILER)

    def test_protocol_parser_accepts_exactly_protocol_and_schema_version_two(self):
        number_parser = pascal_routine(
            PROTOCOL_V2,
            "function NumberIsTwo(",
            "function ParseEvidence(",
        )
        self.assertIn("Value is TJSONNumber", number_parser)
        self.assertIn("Value.Value = '2'", number_parser)

        request_parser = pascal_routine(
            PROTOCOL_V2,
            "function TryLoadV2Request(",
            "function NullValue:",
        )
        self.assertIn(
            "if not NumberIsTwo(Root, 'schema_version') or not NumberIsTwo(Root, 'protocol') then Exit;",
            request_parser,
        )
        self.assertIn(
            "if not StringField(Root, 'kind', Kind) or (Kind <> 'project_wrapper_build') then Exit;",
            request_parser,
        )
        self.assertIn(
            "if not HasExactFields(Root, ['input', 'job_id', 'kind', 'nonce', 'protocol',",
            request_parser,
        )
        self.assertNotIn("LooksLikeV2Request", PROTOCOL_V2)

    def test_v2_accepts_canonical_regular_inputs_from_any_workspace(self):
        self.assertIn("const AJobFile: string", PROTOCOL_V2)
        self.assertIn("function IsRegularAbsoluteFile", PROTOCOL_V2)
        self.assertIn("FILE_ATTRIBUTE_REPARSE_POINT", PROTOCOL_V2)
        self.assertIn("CanonicalMain := CanonicalFinalPath", PROTOCOL_V2)
        self.assertIn("not SameText(ARequest.MainSource.Path, CanonicalMain)", PROTOCOL_V2)
        self.assertIn("not SameText(ARequest.Project.Path, CanonicalProject)", PROTOCOL_V2)
        self.assertIn("TryLoadV2Request(AJobFile, Request, FailureCode)", WATCH)

    def test_v2_source_only_mode_generates_managed_minimal_project(self):
        self.assertIn("function ParseNullableEvidence", PROTOCOL_V2)
        self.assertIn("ARequest.HasProject", PROTOCOL_V2)
        self.assertIn("if Result and ARequest.HasProject then", PROTOCOL_V2)
        generator = pascal_routine(
            COMPILER,
            "procedure TDelphiCompileGateCompiler.CreateMinimalWrapperDproj(",
            "function TDelphiCompileGateCompiler.BuildProjectWrapper(",
        )
        for marker in (
            "<TargetedPlatforms>3</TargetedPlatforms>",
            "$(Platform)''==''Win32",
            "$(Platform)''==''Win64",
            "$(Config)''==''Debug",
            "$(Config)''==''Release",
            "<DelphiCompile Include=",
            "CodeGear.Delphi.Targets",
            "<DCC_UnitSearchPath>",
            "<DCC_DcuOutput>",
            "<DCC_ExeOutput>",
            "<GenPackage>true</GenPackage>",
        ):
            self.assertIn(marker, generator)
        builder = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.BuildProjectWrapper(",
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
        )
        self.assertIn("CreateMinimalWrapperDproj", builder)
        self.assertIn("ValidateWrapperDproj", builder)
        v2 = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
            "constructor TDelphiCompileGateCompiler.Create",
        )
        self.assertIn("(AProjectFile <> '') and", v2)
        self.assertIn("BuildProjectWrapper(AProjectFile, ADprFile, AJobId,", v2)
        self.assertIn("APlatform, AConfiguration)", v2)

    def test_reload_only_worker_uses_v2_safe_dispatch(self):
        dispatch = pascal_routine(
            COMPILER,
            "procedure TCompileDialogCloser.TryDismissWindow(",
            "procedure TCompileDialogCloser.TryDismissWindowV2(",
        )
        self.assertIn("TryDismissWindowV2(AWnd)", dispatch)

    def test_v2_never_automates_gate_settings_dialog(self):
        handler = pascal_routine(
            COMPILER,
            "procedure TCompileDialogCloser.TryDismissWindowV2(",
            "procedure TCompileDialogCloser.TryDismissDialogs;",
        )
        exclusion = "SameText(WindowClass, 'TDelphiCompileGateSettingsForm')"
        self.assertIn(exclusion, handler)
        self.assertLess(handler.index(exclusion), handler.index("OwnerWnd :="))
        validate = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertIn("MainWindow := Application.MainForm.Handle", validate)
        self.assertIn("GetLastActivePopup(MainWindow)", validate)
        self.assertIn("not IsWindowEnabled(MainWindow)", validate)
        stop_helper = validate[
            validate.index("procedure StopDialogCloserAndCapture"):
            validate.index("end;\nbegin", validate.index("procedure StopDialogCloserAndCapture"))
        ]
        self.assertIn("Stopped := DialogCloser.StopAndWait(5000)", stop_helper)
        self.assertIn("if not Stopped then", stop_helper)
        self.assertLess(stop_helper.index("if not Stopped then"),
                        stop_helper.index("ALegalNoticeEvidence :="))
        self.assertIn("dialog_closer_stop_timeout", stop_helper)

    def test_ce_notice_is_acknowledged_without_accepting_terms_and_reported(self):
        handler = pascal_routine(
            COMPILER,
            "procedure TCompileDialogCloser.TryDismissWindowV2(",
            "procedure TCompileDialogCloser.TryDismissDialogs;",
        )
        ce_start = handler.index("SameText(WindowClass, 'TCENotificationDialog')")
        ce_end = handler.index("IsLegal := WindowTreeMatches", ce_start)
        ce = handler[ce_start:ce_end]
        self.assertIn("HasOnlyExactOkButton", ce)
        self.assertIn("not HasUnsafeAcceptanceControl(AWnd, 0)", ce)
        self.assertIn("UnsafeButtonWnd = 0", ce)
        self.assertIn("community_edition_usage_notice", ce)
        self.assertIn("FLegalNoticeEvidence.AcceptedTerms := False", ce)
        self.assertIn("FLegalNoticeEvidence.Action := 'acknowledged'", ce)
        self.assertIn("PostVerifiedButtonClick(ButtonWnd, ['ok']", ce)
        self.assertNotIn("['accept'", ce)
        self.assertIn("Result.AddPair('legal_notice', LegalNoticeJSON", PROTOCOL_V2)
        self.assertIn("Result.AddPair('accepted_terms', TJSONBool.Create(False))",
                      PROTOCOL_V2)
        self.assertIn("text_available", PROTOCOL_V2)
        self.assertIn("function HasUnsafeAcceptanceControl", handler)
        unsafe = handler[
            handler.index("function HasUnsafeAcceptanceControl"):
            handler.index("function HasExactReloadButtonSet")
        ]
        self.assertIn("SameText(ControlText, 'agree')", unsafe)
        self.assertIn("SameText(ControlText, 'zustimmen')", unsafe)
        self.assertNotIn("IsWindowEnabled(Child)", unsafe)

    def test_open_source_buffers_are_verified_before_capture_and_compile(self):
        verifier = pascal_routine(
            COMPILER,
            "procedure TDelphiCompileGateCompiler.EnsureSourceBuffersMatchDisk(",
            "function TDelphiCompileGateCompiler.FindWrapperOutputEXE",
        )
        self.assertIn("AModuleServices.FindModule", verifier)
        self.assertIn("IOTAEditorContent", verifier)
        self.assertIn("TFile.ReadAllBytes", verifier)
        self.assertIn("if not Editor.Modified then", verifier)
        self.assertNotIn("if AEditor.Modified or not Supports", verifier)
        self.assertIn("source_buffer_mismatch", verifier)
        self.assertIn("source_buffer_unverified", verifier)
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertLess(routine.index("EnsureSourceBuffersMatchDisk"),
                        routine.index("MessageHook.BeginCaptureOnly"))

    def test_wrapper_exe_lookup_is_bounded_and_never_recursive(self):
        finder = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.FindWrapperOutputEXE(",
            "function TDelphiCompileGateCompiler.IsIDEQuiescentForProjectClose",
        )
        self.assertNotIn("TDirectory.GetFiles", finder)
        self.assertNotIn("soAllDirectories", finder)
        self.assertIn("AddOutputDirectory(SourceDir)", finder)
        self.assertIn("AddOutputDirectory(ExtractFilePath(AWrapperProject))", finder)
        self.assertIn("<DCC_ExeOutput>", finder)
        self.assertIn("Candidates.Duplicates := dupIgnore", finder)
        self.assertIn("FileExists(Candidate)", finder)

    def test_wrapper_xml_is_reparsed_and_semantically_validated(self):
        validator = pascal_routine(
            COMPILER,
            "procedure TDelphiCompileGateCompiler.ValidateWrapperDproj(",
            "procedure TDelphiCompileGateCompiler.EnsureSourceBuffersMatchDisk(",
        )
        self.assertIn("Doc.LoadFromFile(AWrapperDproj)", validator)
        self.assertIn("IsElementName(Root, 'Project')", validator)
        self.assertIn("WrapperCompileCount <> 1", validator)
        self.assertIn("wrapper_project_invalid", validator)
        wrapper = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.BuildProjectWrapper(",
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
        )
        self.assertIn("ValidateWrapperDproj(WrapperDproj", wrapper)

    def test_hidden_module_close_is_quiescent_path_only_and_once(self):
        interface = COMPILER[COMPILER.index("TDelphiCompileGateCompiler = class"):COMPILER.index("implementation")]
        self.assertIn("TGeneratedModuleCloseResult", COMPILER)
        self.assertIn("function IsIDEQuiescentForProjectClose: Boolean;", interface)
        self.assertIn("function IsGeneratedModuleOpen(const AProjectFile: string): Boolean;", interface)
        self.assertIn("TGeneratedModuleCloseResult;", interface)
        closer = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.TryCloseGeneratedModule(",
            "function TDelphiCompileGateCompiler.IsGeneratedModuleOpen(",
        )
        self.assertIn("IsBackgroundCompileActive", closer)
        self.assertNotIn("DrainPendingNotifiers;", closer)
        self.assertIn("ModuleServices.FindModule(CanonicalProject)", closer)
        self.assertEqual(1, closer.count("Module.CloseModule(True)"))
        self.assertNotIn("RemoveProject", closer)
        self.assertNotIn("CloseFile", closer)
        self.assertIn("gmcrAttemptFailed", closer)
        self.assertIn("not retried", closer)
        self.assertIn("Module := nil", closer)
        self.assertIn("StartsText(CanonicalRoot, CanonicalProject)", closer)
        self.assertNotIn("SaveFile", closer)
        self.assertNotIn("Sleep(", closer)

        watch_interface = WATCH[WATCH.index("interface"):WATCH.index("implementation")]
        self.assertIn("TPendingProjectClose = record", watch_interface)
        pending_record = watch_interface[watch_interface.index("TPendingProjectClose = record"):watch_interface.index("TDelphiCompileGateWatch = class")]
        self.assertIn("ProjectFile: string", pending_record)
        self.assertIn("StableTicks: Integer", pending_record)
        self.assertIn("CloseAttempted: Boolean", pending_record)
        self.assertIn("SettleTicks: Integer", pending_record)
        self.assertNotIn("IOTAProject", pending_record)
        self.assertNotIn("IOTAModule", pending_record)
        process_v2 = pascal_routine(
            WATCH,
            "procedure TDelphiCompileGateWatch.ProcessV2Job(",
            "procedure TDelphiCompileGateWatch.ProcessInputQueue;",
        )
        self.assertIn("QueueGeneratedProjectClose(WrapperProject)", process_v2)
        self.assertIn("JobPublished := False", process_v2)
        self.assertIn("JobPublished := True", process_v2)
        self.assertIn("if JobPublished and Assigned(ResultObject)", process_v2)
        self.assertLess(process_v2.index("TFile.Move(AJobFile, Destination)"),
                        process_v2.index("JobPublished := True"))
        self.assertIn("ResultObject.GetStringDef('status', ''), 'ok'", process_v2)
        self.assertIn("ResultObject.GetBoolDef('success', False)", process_v2)
        self.assertIn("IsCompileFailureResult(ResultObject)", process_v2)
        compile_failure = WATCH[
            WATCH.index("function IsCompileFailureResult("):
            WATCH.index("function TDelphiCompileGateWatch.QueueGeneratedProjectClose(")
        ]
        self.assertIn("SameText(FailureCode.Value, 'compile_failed')", compile_failure)
        self.assertNotIn("compile_error_details_unavailable", compile_failure)
        exception_result = process_v2[
            process_v2.index("on E: Exception do"):
            process_v2.index("WriteJSONAtomic(Request.JobId", process_v2.index("on E: Exception do"))
        ]
        self.assertIn("BuildV2Result(Request, ResultJSON", exception_result)
        self.assertIn("LegalNoticeEvidence", exception_result)
        self.assertIn("close skipped for non-compile result", process_v2)
        timer = WATCH[WATCH.index("procedure TDelphiCompileGateWatch.OnTimer("):]
        self.assertLess(timer.index("ProcessPendingProjectCloses"), timer.index("ProcessPending;"))
        close_queue = pascal_routine(
            WATCH,
            "function TDelphiCompileGateWatch.ProcessPendingProjectCloses:",
            "procedure TDelphiCompileGateWatch.ClearPendingProjectCloses",
        )
        self.assertIn("Item := FPendingProjectCloses[0]", close_queue)
        self.assertNotIn("while I >= 0", close_queue)
        self.assertIn("AUTO_CLOSE_STABLE_TICKS", close_queue)
        self.assertIn("AUTO_CLOSE_SETTLE_TICKS", close_queue)
        self.assertIn("if Item.CloseAttempted then", close_queue)
        self.assertIn("FCompiler.ReleasePendingNotifiers", close_queue)
        self.assertIn("FCompiler.IsGeneratedModuleOpen(Item.ProjectFile)", close_queue)
        self.assertNotIn("CloseFile", close_queue)
        self.assertIn("gmcrCloseRequested, gmcrAttemptFailed", close_queue)
        self.assertIn("close invoked once", close_queue)
        self.assertGreaterEqual(close_queue.count("DisableExperimentalHiddenModuleClose"), 3)
        self.assertIn("close preparation exception (not retried)", close_queue)
        self.assertIn("Item.CloseAttempted := True", close_queue)
        queue_close = pascal_routine(
            WATCH,
            "function TDelphiCompileGateWatch.QueueGeneratedProjectClose(",
            "procedure TDelphiCompileGateWatch.DisableExperimentalHiddenModuleClose(",
        )
        self.assertIn("if FDrainRequested", queue_close)
        disable = pascal_routine(
            WATCH,
            "procedure TDelphiCompileGateWatch.DisableExperimentalHiddenModuleClose(",
            "function TDelphiCompileGateWatch.ProcessPendingProjectCloses:",
        )
        self.assertIn("FHiddenModuleCloseFailed := True", disable)
        self.assertIn("FExperimentalHiddenModuleClose := False", disable)
        self.assertGreaterEqual(WATCH.count("ClearPendingProjectCloses;"), 3)
        self.assertNotIn("CloseTempProjectInIDE", COMPILER)
        self.assertNotIn("CloseFile(", COMPILER)
        self.assertEqual(1, COMPILER.count("Module.CloseModule(True)"))
        hard_stop = pascal_routine(
            WATCH,
            "procedure TDelphiCompileGateWatch.Stop;",
            "procedure TDelphiCompileGateWatch.StopGraceful;",
        )
        self.assertIn("SettleAttemptedModuleCloseBeforeStop", hard_stop)
        settle = pascal_routine(
            WATCH,
            "procedure TDelphiCompileGateWatch.SettleAttemptedModuleCloseBeforeStop;",
            "procedure TDelphiCompileGateWatch.CancelUnattemptedPendingModuleCloses;",
        )
        self.assertIn("Application.ProcessMessages", settle)
        self.assertIn("ProcessPendingProjectCloses", settle)
        self.assertIn("AUTO_CLOSE_SETTLE_TICKS + 2", settle)
        stop_graceful = pascal_routine(
            WATCH,
            "procedure TDelphiCompileGateWatch.StopGraceful;",
            "procedure TDelphiCompileGateWatch.WriteLog(",
        )
        self.assertIn("CancelUnattemptedPendingModuleCloses", stop_graceful)
        self.assertIn("GetPendingProjectCloseCount > 0", stop_graceful)
        timer = pascal_routine(
            WATCH,
            "procedure TDelphiCompileGateWatch.OnTimer(",
            "end.",
        )
        drain_start = timer.index("if FDrainRequested then")
        drain = timer[drain_start:timer.index("FIsBusy := True", drain_start)]
        self.assertIn("ProcessPendingProjectCloses", drain)
        self.assertLess(drain.index("GetPendingProjectCloseCount > 0"),
                        drain.index("FIsRunning := False"))

    def test_input_queue_dispatches_only_v2_job_manifests(self):
        queue = pascal_routine(
            WATCH,
            "procedure TDelphiCompileGateWatch.ProcessInputQueue;",
            "function TDelphiCompileGateWatch.CanProcessNow",
        )
        self.assertEqual(1, queue.count("TDirectory.GetFiles(FInputDir, '*.job.json')"))
        self.assertEqual(1, queue.count("ProcessV2Job(Jobs[0])"))
        self.assertIn("if not FileExists(Jobs[0]) then", queue)
        self.assertIn("MoveToFailed(Jobs[0], E.Message)", queue)
        self.assertIn("cannot starve the complete queue", queue)
        self.assertIn("if IsGateSettingsDialogOpen then", queue)
        self.assertIn("FQueueDeferredBySettings", queue)
        self.assertIn("Input queue resumed after Gate settings dialog closed", queue)
        self.assertLess(queue.index("if IsGateSettingsDialogOpen then"),
                        queue.index("TDirectory.GetFiles(FInputDir, '*.job.json')"))
        for removed in (
            "*.pas", "ProcessFile", "ProcessOneFile", "ProcessJobManifest",
            "TryLoadJobManifest", "TryLoadProjectWrapperJob", "ValidateUnits",
            "ArchiveLegacyInputs", "multi-unit", "multi_unit",
            "'project_wrapper'", '"project_wrapper"',
        ):
            self.assertNotIn(removed, WATCH)
        modal_probe = pascal_routine(
            WATCH,
            "function TDelphiCompileGateWatch.IsGateSettingsDialogOpen:",
            "function TDelphiCompileGateWatch.HasAttemptedPendingModuleClose:",
        )
        self.assertIn("TDelphiCompileGateSettingsForm", modal_probe)
        self.assertIn("ProcessID = GetCurrentProcessId", modal_probe)
        self.assertIn("IsWindowVisible(Window)", modal_probe)

        closer = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.TryCloseGeneratedModule(",
            "function TDelphiCompileGateCompiler.IsGeneratedModuleOpen(",
        )
        self.assertNotIn("CanonicalTempRoot", closer)
        self.assertIn("HasReparsePointInControlledPath", closer)
        self.assertIn("FILE_ATTRIBUTE_REPARSE_POINT", closer)
        self.assertIn("reparse/unresolved path", closer)

    def test_compile_notifiers_are_inert_before_removal(self):
        self.assertIn("procedure Deactivate;", COMPILER)
        self.assertIn("if not FActive then", COMPILER)
        self.assertEqual(1, COMPILER.count("CompileWait.Deactivate;"))
        for marker in (
            "CompileWait.Deactivate;\n      if CompileNotifierIndex >= 0 then",
        ):
            self.assertIn(marker, COMPILER)
        self.assertIn("FPendingProjectCompileNotifiers", COMPILER)
        self.assertIn("FPendingProjectCompileNotifiers.Add(ProjectCompileNotifier)", COMPILER)
        self.assertIn("ProjectCompileEvidence.Deactivate", COMPILER)
        self.assertIn("NotifierCleanupFailed := True", COMPILER)
        self.assertIn("FNotifierLifetimeCompromised := True", COMPILER)
        self.assertIn("raise Exception.Create('notifier_lifetime_compromised')", COMPILER)
        self.assertIn("raise Exception.Create('notifier_cleanup_failed')", COMPILER)
        outer_cleanup = COMPILER[
            COMPILER.index("if Assigned(ProjectCompileEvidence) then\n      ProjectCompileEvidence.Deactivate"):
            COMPILER.index("if CaptureOnlyStarted then", COMPILER.index("if Assigned(ProjectCompileEvidence) then\n      ProjectCompileEvidence.Deactivate"))
        ]
        self.assertIn("Outer RemoveCompileNotifier exception", outer_cleanup)
        self.assertIn("FPendingProjectCompileNotifiers.Add(ProjectCompileNotifier)", outer_cleanup)

    def test_message_hook_retains_forwarding_state_if_restore_is_incomplete(self):
        uninstall = pascal_routine(
            HOOK,
            "function TMessageHook.Uninstall: Boolean;",
            "initialization",
        )
        self.assertIn("if RestoreVTableSlot", uninstall)
        self.assertIn("AOriginal := nil", uninstall)
        self.assertIn("AllRestored := False", uninstall)
        self.assertIn("if AllRestored then", uninstall)
        self.assertIn("FInstalled := True", uninstall)
        self.assertIn("forwarding state retained", uninstall)

    def test_v2_consumes_dialog_block_evidence_at_both_boundaries(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertIn("procedure EnsureNoDialogBlock", routine)
        self.assertLess(routine.index("EnsureNoDialogBlock('OpenModule')"),
                        routine.index("ProjectBuilder := Project.ProjectBuilder"))
        self.assertLess(routine.index("EnsureNoDialogBlock('CompileProjects')"),
                        routine.rindex("Result.Success :="))
        settling_section = routine[routine.index("The v2 worker is already polling"):]
        settle_at = settling_section.index("Sleep(120);")
        settled_check_at = settling_section.index("EnsureNoDialogBlock('CompileProjectsSettled')")
        self.assertLess(settle_at, settled_check_at)
        self.assertLess(settled_check_at, settling_section.index("if CompileWait.HasResult"))
        self.assertIn("raise Exception.Create('dialog_blocked')", routine)
        self.assertIn("FailureCode := 'dialog_blocked'", WATCH)
        self.assertIn("function GetBlockDeadlineExceeded", COMPILER)
        self.assertIn("property BlockDeadlineExceeded: Boolean read GetBlockDeadlineExceeded", COMPILER)

    def test_capture_scope_filters_and_clears_atomically(self):
        self.assertIn("FCaptureWrapperRoot", HOOK)
        self.assertIn("FCaptureSourceRoot", HOOK)
        self.assertIn("IsInCaptureScope", HOOK)
        self.assertIn("CaptureCompilerMessageAndShouldSuppress", HOOK)
        self.assertIn("FCaptureWrapperRoot := '';", HOOK)
        self.assertIn("FCaptureSourceRoot := '';", HOOK)
        self.assertIn("function TMessageHook.GetCaptureFailed", HOOK)
        self.assertIn("if FCaptureOnlyDepth = 0 then", HOOK)

    def test_wrapper_capture_source_root_includes_sibling_units_but_not_unrelated_sibling(self):
        fixture = __import__("json").loads(CAPTURE_SCOPE_FIXTURE.read_text(encoding="utf-8"))
        root = (ROOT / fixture["source_root"]).resolve()
        unit_tests_message = (ROOT / fixture["unit_tests_message"]).resolve()
        src_message = (ROOT / fixture["src_message"]).resolve()
        unrelated_sibling_message = (ROOT / fixture["unrelated_sibling_message"]).resolve()
        self.assertTrue(root.is_dir())
        for path in (unit_tests_message, src_message, unrelated_sibling_message):
            self.assertTrue(path.is_file(), path)

        def is_in_source_root(path):
            try:
                path.relative_to(root)
                return True
            except ValueError:
                return False

        self.assertTrue(is_in_source_root(unit_tests_message))
        self.assertTrue(is_in_source_root(src_message))
        self.assertFalse(is_in_source_root(unrelated_sibling_message))
        derivation = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.DeriveWrapperCaptureSourceRoot(",
            "function TDelphiCompileGateCompiler.MakeDprResourceReferencesAbsolute(",
        )
        self.assertIn("AOriginalDpr", derivation)
        self.assertIn("AProjectFile", derivation)
        self.assertIn("TPath.IsPathRooted(ReferencedPath)", derivation)
        self.assertIn("IsVolumeRoot", derivation)
        self.assertIn("MaximumRoot", derivation)
        self.assertIn("Candidate := '';", derivation)

    def test_capture_scope_allows_only_known_bare_wrapper_source_basenames(self):
        fixture = __import__("json").loads(BARE_CAPTURE_SCOPE_FIXTURE.read_text(encoding="utf-8"))
        original_dpr = ROOT / fixture["original_dpr"]
        references = [ROOT / reference for reference in fixture["wrapper_references"]]
        unrelated_bare_source = ROOT / fixture["unrelated_bare_source"]
        for path in (original_dpr, unrelated_bare_source, *references):
            self.assertTrue(path.is_file(), path)
        self.assertEqual(unrelated_bare_source.name, fixture["unrelated_bare_diagnostic"])

        allowlist = {original_dpr.name.casefold()}
        allowlist.update(reference.name.casefold() for reference in references)
        self.assertEqual(4, len(allowlist))
        self.assertIn(fixture["known_bare_diagnostic"].casefold(), allowlist)
        self.assertNotIn(fixture["unrelated_bare_diagnostic"].casefold(), allowlist)

        collector = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.CollectWrapperCaptureSourceFiles(",
            "function TDelphiCompileGateCompiler.MakeDprResourceReferencesAbsolute(",
        )
        self.assertIn("TPath.IsPathRooted(ReferencedPath)", collector)
        self.assertIn("Basenames.Sorted := True", collector)
        self.assertIn("Basenames.Duplicates := dupIgnore", collector)
        self.assertIn("MAX_CAPTURE_SOURCE_FILES", collector)
        scope = pascal_routine(HOOK, "function TMessageHook.IsInCaptureScope(",
                               "function TMessageHook.BeginCaptureOnly(")
        self.assertIn("ExtractFileName(AFileName) = AFileName", scope)
        self.assertIn("MatchCount = 1", scope)
        self.assertIn("ambiguous_bare_source", scope)
        self.assertIn("FCaptureSourceBasenames.Duplicates := dupAccept", HOOK)

    def test_capture_scope_allows_only_exact_full_wrapper_source_paths(self):
        fixture = __import__("json").loads(BARE_CAPTURE_SCOPE_FIXTURE.read_text(encoding="utf-8"))
        original_dpr = (ROOT / fixture["original_dpr"]).resolve()
        references = [(ROOT / reference).resolve()
                      for reference in fixture["wrapper_references"]]
        known_full_diagnostic = (ROOT / fixture["known_full_diagnostic"]).resolve()
        unrelated_full_diagnostic = (ROOT / fixture["unrelated_full_diagnostic"]).resolve()
        for path in (original_dpr, known_full_diagnostic,
                     unrelated_full_diagnostic, *references):
            self.assertTrue(path.is_file(), path)

        allowlist = {original_dpr.as_posix().casefold()}
        allowlist.update(reference.as_posix().casefold() for reference in references)
        self.assertIn(known_full_diagnostic.as_posix().casefold(), allowlist)
        self.assertNotIn(unrelated_full_diagnostic.as_posix().casefold(), allowlist)

        collector = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.CollectWrapperCaptureSourceFiles(",
            "function TDelphiCompileGateCompiler.MakeDprResourceReferencesAbsolute(",
        )
        self.assertIn("procedure AddSourceFile", collector)
        self.assertIn("SourceFile := ExpandFileName(Candidate);", collector)
        self.assertIn("Basenames.Add(SourceFile);", collector)
        scope = pascal_routine(HOOK, "function TMessageHook.IsInCaptureScope(",
                               "function TMessageHook.BeginCaptureOnly(")
        self.assertIn("FCaptureSourceFiles.IndexOf(FullName) >= 0", scope)
        self.assertNotIn("FCaptureSourceBasenames.IndexOf(ExtractFileName(FullName))", scope)

    def test_capture_scope_collects_exact_dproj_compile_item_paths(self):
        root = ET.parse(COMPILE_ITEMS_FIXTURE).getroot()
        namespace = {"msb": "http://schemas.microsoft.com/developer/msbuild/2003"}
        includes = [item.attrib["Include"] for item in root.findall(".//msb:Compile", namespace)]
        allowed = {
            (COMPILE_ITEMS_FIXTURE.parent / include.replace("\\", "/")).resolve()
            for include in includes
            if ";" not in include and "*" not in include and "?" not in include
        }
        linked = root.find(".//msb:None[msb:Link]", namespace)
        self.assertIsNotNone(linked)
        linked_path = (COMPILE_ITEMS_FIXTURE.parent /
                       linked.attrib["Include"].replace("\\", "/")).resolve()
        allowed.add(linked_path)
        expected = (COMPILE_ITEMS_FIXTURE.parent / "wrapper_capture_project" /
                    "source" / "ModuleLoader.pas").resolve()
        rejected_multi_item = (COMPILE_ITEMS_FIXTURE.parent /
                               "wrapper_capture_project" / "source" /
                               "OtherUnit.pas").resolve()
        unrelated = (COMPILE_ITEMS_FIXTURE.parent / "wrapper_capture_project" /
                     "unrelated" / "ModuleLoader.pas").resolve()
        for path in (*allowed, expected, rejected_multi_item, unrelated):
            self.assertTrue(path.is_file(), path)
        self.assertIn(expected, allowed)
        self.assertNotIn(rejected_multi_item, allowed)
        self.assertNotIn(unrelated, allowed)

        collector = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.CollectWrapperCaptureSourceFiles(",
            "function TDelphiCompileGateCompiler.CollectWrapperReloadAllowedFiles(",
        )
        self.assertIn("Doc.LoadFromFile(WrapperDproj)", collector)
        self.assertIn("ChangeFileExt(AWrapperDpr, '.dproj')", collector)
        self.assertIn("IsCompileItem(Item) or IsExplicitlyLinkedItem(Item)", collector)
        self.assertIn("TPath.Combine(ABaseDirectory, Candidate)", collector)
        self.assertIn("Pos(';', Candidate) > 0", collector)
        self.assertIn("Pos('*', Candidate) > 0", collector)

    def test_v2_source_has_no_removed_compile_or_dialog_paths(self):
        routine = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.ValidateDprProject(",
            "function TDelphiCompileGateCompiler.ValidateProjectWrapperV2(",
        )
        self.assertIn("TCompileDialogCloser.Create(Trace, dapProtocolV2)", routine)
        for removed in (
            "dapLegacy", "TScopedExceptionSink", "ExceptionSink",
            "ValidatePasDfmPair", "ValidateUnits", "ValidatePasFile",
            "DismissActiveDialog", "IsLikelyCompileDialog", "ACaptureOnly",
            "AAllowInterventions", "keybd_event", "SendInput", "WM_KEYDOWN",
            "WM_KEYUP", "VK_RETURN", "VK_ESCAPE",
        ):
            self.assertNotIn(removed, COMPILER)

    def test_v2_separates_active_progress_from_terminal_build_result(self):
        handler = pascal_routine(
            COMPILER,
            "procedure TCompileDialogCloser.TryDismissWindowV2(",
            "procedure TCompileDialogCloser.TryDismissDialogs;",
        )
        branch_start = handler.index("if ((FPolicy = dapProtocolV2) or")
        branch_end = handler.index("OwnerWnd :=", branch_start)
        progress_branch = handler[branch_start:branch_end]
        self.assertIn("(FPolicy = dapReloadOnly) and HasActiveReloadPolicy", progress_branch)
        self.assertIn("IsBuildResultText(ReloadText)", progress_branch)
        self.assertIn("['ok']", progress_branch)
        self.assertIn("HasOnlyExactOkButton", progress_branch)
        self.assertIn("if (ButtonWnd <> 0) and HasOnlyExactOkButton then", progress_branch)
        self.assertLess(progress_branch.index("if (ButtonWnd <> 0) and HasOnlyExactOkButton then"),
                        progress_branch.index("else if IsBuildResultText(ReloadText)"))
        self.assertIn("VisibleEnabledButtons = 1", handler)
        self.assertIn("Acknowledged terminal IDE build result via sole exact OK button", progress_branch)
        self.assertIn("unexpected_build_result_controls", progress_branch)
        self.assertIn("Ignoring active IDE progress form without interaction", progress_branch)
        self.assertIn("Exit", progress_branch)
        self.assertIn("DelphiCompileGate.ProtocolV2.Seen", progress_branch)
        self.assertNotIn("PostVerifiedButtonClick(ButtonWnd, ['cancel'", progress_branch)
        post_call = progress_branch.index("PostVerifiedButtonClick(ButtonWnd, ['ok']")
        posted_prop = progress_branch.index(
            "SetProp(AWnd, 'DelphiCompileGate.ProtocolV2.ResultPosted'"
        )
        self.assertLess(post_call, posted_prop)

    def test_dialog_closer_cleanup_uses_kernel_wait_without_ui_message_pump(self):
        compiler = COMPILER
        stop_wait = pascal_routine(
            COMPILER,
            "function TCompileDialogCloser.StopAndWait(",
            "constructor TCompileWaitNotifier.Create(",
        )
        self.assertIn("WaitForSingleObject(Handle, ATimeoutMs)", stop_wait)
        self.assertIn("WAIT_OBJECT_0", stop_wait)
        self.assertNotIn("DialogCloser.WaitFor", compiler)

    def test_persistent_worker_closes_manual_terminal_build_results(self):
        handler = pascal_routine(
            COMPILER,
            "procedure TCompileDialogCloser.TryDismissWindowV2(",
            "procedure TCompileDialogCloser.TryDismissDialogs;",
        )
        branch_start = handler.index("if ((FPolicy = dapProtocolV2) or")
        progress_branch = handler[
            branch_start:handler.index("OwnerWnd :=", branch_start)
        ]
        self.assertIn("SameText(WindowClass, 'TProgressForm')", progress_branch)
        self.assertIn("if (ButtonWnd <> 0) and HasOnlyExactOkButton then", progress_branch)
        self.assertIn("PostVerifiedButtonClick(ButtonWnd, ['ok']", progress_branch)
        self.assertNotIn("['cancel'", progress_branch)
        self.assertIn("(FPolicy = dapReloadOnly) and HasActiveReloadPolicy", progress_branch)

    def test_persistent_worker_does_not_race_active_gate_job_result(self):
        handler = pascal_routine(
            COMPILER,
            "procedure TCompileDialogCloser.TryDismissWindowV2(",
            "procedure TCompileDialogCloser.TryDismissDialogs;",
        )
        self.assertIn("function HasActiveReloadPolicy: Boolean;", handler)
        self.assertIn("ReloadPolicyActive := HasActiveReloadPolicy;", handler)
        branch_start = handler.index("if ((FPolicy = dapProtocolV2) or")
        progress_branch = handler[
            branch_start:handler.index("OwnerWnd :=", branch_start)
        ]
        self.assertIn("(FPolicy = dapReloadOnly) and HasActiveReloadPolicy", progress_branch)

    def test_fixture_variants_preserve_dccreference_items_and_rewrite_only_main_source(self):
        xml = """<Project><PropertyGroup><MainSource>Old.dpr</MainSource></PropertyGroup>
        <ItemGroup><DCCReference Include = 'Old.pas'><Meta/></DCCReference>
        <DCCReference Include=\"rtl.dcp\"/><DelphiCompile Include = \"Old.dpr\"><MainSource>MainSource</MainSource></DelphiCompile>
        <DelphiCompile Include='Keep.txt'/></ItemGroup>
        <ProjectExtensions><Source Name='Unit'>Old.dfm</Source></ProjectExtensions></Project>"""
        root = ET.fromstring(xml)
        property_main = root.find("./PropertyGroup/MainSource")
        compile_main = root.find("./ItemGroup/DelphiCompile/MainSource")
        self.assertEqual("Old.dpr", property_main.text)
        self.assertEqual("MainSource", compile_main.text)
        dcc_references = root.findall("./ItemGroup/DCCReference")
        self.assertEqual(2, len(dcc_references))
        self.assertEqual("Old.pas", dcc_references[0].attrib["Include"])
        self.assertEqual("rtl.dcp", dcc_references[1].attrib["Include"])
        sanitizer = pascal_routine(COMPILER, "function TDelphiCompileGateCompiler.SanitizeWrapperDprojSources(", "procedure TDelphiCompileGateCompiler.ValidateWrapperDproj")
        self.assertIn("PropertyGroup", sanitizer)
        self.assertIn("FindNode('MainSource').Text := AWrapperMainSource", sanitizer)
        self.assertNotIn("Node.Text := AWrapperMainSource", sanitizer)
        item_cleanup = sanitizer[sanitizer.index("procedure ProcessItemGroup"):sanitizer.index("procedure CleanupSourceMetadata")]
        self.assertIn("SameText(Node.NodeName, 'DelphiCompile')", item_cleanup)
        self.assertNotIn("DCCReference') or", item_cleanup)

    def test_nested_source_metadata_is_preserved_without_reading_element_text(self):
        root = ET.parse(NESTED_SOURCE_FIXTURE).getroot()
        source = root.find("./ProjectExtensions/Source")
        self.assertEqual(
            b'<Source Name="NestedMetadata">\n      <Metadata>\n        <FileName>Original.dpr</FileName>\n      </Metadata>\n    </Source>\n  ',
            ET.tostring(source),
        )

        sanitizer = pascal_routine(
            COMPILER,
            "function TDelphiCompileGateCompiler.SanitizeWrapperDprojSources(",
            "procedure TDelphiCompileGateCompiler.ValidateWrapperDproj",
        )
        cleanup = sanitizer[sanitizer.index("procedure CleanupSourceMetadata"):]
        self.assertIn("function TryGetDirectScalarText", sanitizer)
        self.assertIn("ScalarNode.NodeType in [ntText, ntCData]", sanitizer)
        self.assertIn("TryGetDirectScalarText(Node, SourceText)", cleanup)
        self.assertIn("Continue;", cleanup)
        self.assertNotIn("Node.Text", cleanup)


if __name__ == "__main__":
    unittest.main()
