import hashlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPILER = (ROOT / "Src" / "DelphiCompileGate.Compiler.pas").read_text(encoding="utf-8")
WATCH = (ROOT / "Src" / "DelphiCompileGate.Watch.pas").read_text(encoding="utf-8")


def strict_reload_text(text):
    value = text.casefold()
    denied = ("license", "eula", "save", "speichern", "delete", "löschen", "overwrite")
    return not any(word in value for word in denied) and (
        "changed outside the source editor" in value and "reload" in value
        or "bei modul " in value and "wurden änderungen festgestellt" in value and "neu laden" in value
        or "bei modul " in value and "wurden änderungen auf der festplatte festgestellt" in value
        and "auch im hauptspeicher wurde dieses modul geändert" in value and "erneut laden" in value
        or "ausserhalb des quelltexteditors geändert" in value and "neu laden" in value
    )


def normalize_path_token(value):
    return value.strip().replace("/", "\\").casefold()


def has_bounded_token(text, token):
    value = normalize_path_token(text)
    token = normalize_path_token(token)
    allowed_boundaries = set("\"'()[]{};,=")

    def is_allowed_boundary(char):
        return char.isspace() or char in allowed_boundaries

    start = 0
    while True:
        start = value.find(token, start)
        if start < 0:
            return False
        end = start + len(token)
        if (start == 0 or is_allowed_boundary(value[start - 1])) and (
            end == len(value) or is_allowed_boundary(value[end])
        ):
            return True
        start += 1


def resolve_exact_canonical_path(text, allowed):
    exact = [path for path in allowed if has_bounded_token(text, path)]
    return exact[0] if len(exact) == 1 else None


def policy_allows_click(policy, captured_revision, captured_job, captured_token, path, now):
    return (
        policy["revision"] == captured_revision
        and policy["job"] == captured_job
        and policy["token"] == captured_token
        and captured_token
        and policy["expires"] > now
        and path in policy["paths"]
    )


def reload_authorization_sha256(job, token, revision, path):
    payload = f"{job}\0{token}\0{revision}\0{path}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def can_commit_reload_policy(status, failure_code, policy_compliant=True, authenticated=True):
    return authenticated and policy_compliant and (
        (status == "ok" and failure_code is None)
        or (status == "failed" and failure_code in (
            "compile_failed", "compile_error_details_unavailable"
        ))
    )


class ReloadPolicyContractTests(unittest.TestCase):
    def test_english_and_german_reload_patterns_are_strict(self):
        self.assertTrue(strict_reload_text("Unit1.pas changed outside the source editor. Reload?"))
        self.assertTrue(strict_reload_text("Unit1.pas wurde außerhalb des Quelltexteditors geändert. Neu laden?"))
        self.assertTrue(strict_reload_text("Bei Modul F:\\Gate\\One\\Unit1.pas wurden Änderungen festgestellt. Neu laden?"))
        self.assertTrue(strict_reload_text("Bei Modul F:\\Gate\\One\\Unit1.pas wurden Änderungen auf der Festplatte festgestellt. Auch im Hauptspeicher wurde dieses Modul geändert. Wenn Sie das Modul jetzt laden, werden die Änderungen im Hauptspeicher verworfen. Erneut laden?"))
        self.assertFalse(strict_reload_text("Unit1.pas changed. Reload?"))
        self.assertFalse(strict_reload_text("License changed outside the source editor. Reload?"))
        self.assertFalse(strict_reload_text("Save changes before reload?"))
        self.assertFalse(strict_reload_text("Delete file and reload?"))

    def test_exact_canonical_path_only_no_basename_fallback(self):
        allowed = [r"F:\Gate\One\Unit1.pas", r"F:\Gate\Two\Unit2.pas"]
        self.assertEqual(allowed[0], resolve_exact_canonical_path(r"F:\Gate\One\Unit1.pas", allowed))
        self.assertIsNone(resolve_exact_canonical_path("Unit2.pas", allowed))
        self.assertIsNone(resolve_exact_canonical_path("Unit1.pas", [allowed[0], r"F:\Other\Unit1.pas"]))

    def test_path_tokens_require_explicit_display_boundaries(self):
        allowed = [r"F:\Gate\One\Unit1.pas"]
        canonical = allowed[0]
        self.assertEqual(allowed[0], resolve_exact_canonical_path('"F:/Gate/One/Unit1.pas"', allowed))
        for suffix_or_prefix in (
            canonical + "-backup",
            canonical + ".bak",
            canonical + r"\another-segment",
            "x" + canonical,
            canonical + "x",
            canonical + ":suffix",
            canonical + "_copy",
            canonical + "+copy",
            canonical + "@copy",
            canonical + "~copy",
            "x" + canonical + "y",
        ):
            self.assertIsNone(resolve_exact_canonical_path(suffix_or_prefix, allowed), suffix_or_prefix)
        for delimited in (
            canonical,
            " " + canonical + " ",
            '"' + canonical + '",',
            '"' + canonical + '": display path',
            "(" + canonical + ")",
            "[" + canonical + "]",
            "{" + canonical + "}",
            canonical + ";",
            canonical + "=",
        ):
            self.assertEqual(allowed[0], resolve_exact_canonical_path(delimited, allowed), delimited)

    def test_stale_revision_or_token_does_not_click(self):
        path = r"F:\Gate\One\Unit1.pas"
        policy = {"revision": 8, "job": "job_a", "token": "token_a", "expires": 100, "paths": [path]}
        self.assertTrue(policy_allows_click(policy, 8, "job_a", "token_a", path, 50))
        self.assertFalse(policy_allows_click(policy, 7, "job_a", "token_a", path, 50))
        self.assertFalse(policy_allows_click(policy, 8, "job_a", "token_b", path, 50))
        self.assertFalse(policy_allows_click(policy, 8, "job_a", "", path, 50))

    def test_reload_authorization_hash_binds_job_token_revision_and_path(self):
        baseline = reload_authorization_sha256("job_a", "token_a", 8, r"F:\Gate\One\Unit1.pas")
        self.assertNotEqual(baseline, reload_authorization_sha256("job_b", "token_a", 8, r"F:\Gate\One\Unit1.pas"))
        self.assertNotEqual(baseline, reload_authorization_sha256("job_a", "token_b", 8, r"F:\Gate\One\Unit1.pas"))
        self.assertNotEqual(baseline, reload_authorization_sha256("job_a", "token_a", 9, r"F:\Gate\One\Unit1.pas"))
        self.assertNotEqual(baseline, reload_authorization_sha256("job_a", "token_a", 8, r"F:\Gate\Two\Unit1.pas"))

    def test_reload_only_worker_uses_verified_click_and_no_legacy_policy(self):
        self.assertIn("CollectWrapperReloadAllowedFiles", COMPILER)
        self.assertIn("FAllowedReloadFiles: TArray<string>", COMPILER)
        self.assertIn("dapReloadOnly", COMPILER)
        self.assertIn("reload_prompt_confirmed", COMPILER)
        self.assertIn("FReloadPolicyRevision", COMPILER)
        self.assertIn("FReloadPolicyRevision: Cardinal", COMPILER)
        self.assertIn("FReloadPolicyRevision := 0", COMPILER)
        self.assertIn("ReloadPolicyMatchesLocked", COMPILER)
        self.assertIn("reload_authorization_sha256", COMPILER)
        self.assertIn("'alle nein', 'all yes', 'alle ja'", COMPILER)
        self.assertIn("function FindButtonRecursive(const AParent: HWND; const ADepth: Integer;\n"
                      "    const AValues: array of string; out AText: string): HWND; forward;", COMPILER)
        self.assertNotIn("source_sha256=", COMPILER)
        resolver = COMPILER[COMPILER.index("function ResolveAllowedReloadPath"):COMPILER.index("function ReloadPolicyMatchesLocked")]
        self.assertNotIn("ExtractFileName(Candidate)", resolver)
        self.assertIn("TPath.IsPathRooted(AllowedFiles[I])", resolver)
        closer = COMPILER[COMPILER.index("procedure TCompileDialogCloser.TryDismissWindowV2"):]
        self.assertIn("if FPolicy = dapReloadOnly", closer)
        self.assertIn("SameText(WindowClass, 'TMessageForm') and HasModalOwner", closer)
        self.assertIn("PostVerifiedButtonClick(ButtonWnd", closer)
        reload_only = closer[closer.index("if FPolicy = dapReloadOnly"):closer.index("Reload prompts are deliberately")]
        self.assertNotIn("IsLegal :=", reload_only)
        self.assertNotIn("TCENotificationDialog", reload_only)
        self.assertNotIn("SetBlockReason", reload_only)
        deferred = closer[closer.index("Reload prompts are deliberately"):closer.index("TCENotificationDialog")]
        self.assertIn("reload prompt deferred", deferred)

    def test_reload_only_worker_retries_initially_empty_dialogs(self):
        handler = COMPILER[COMPILER.index("procedure TCompileDialogCloser.TryDismissWindowV2("):]
        reload_branch = handler[handler.index("if FPolicy = dapReloadOnly then"):handler.index("// Reload prompts are deliberately")]
        self.assertIn("if FPolicy <> dapReloadOnly then", handler)
        self.assertIn("Keep polling it until the strict reload fingerprint is ready", handler)
        seen_guard = handler[handler.index("if FPolicy <> dapReloadOnly then"):handler.index("// The persistent watcher worker")]
        self.assertIn("DelphiCompileGate.ProtocolV2.Seen", seen_guard)
        self.assertNotIn("if FPolicy = dapReloadOnly then\n  begin\n    if GetProp", reload_branch)

    def test_reload_only_authorizes_by_strict_evidence_not_owner_state(self):
        handler = COMPILER[COMPILER.index("procedure TCompileDialogCloser.TryDismissWindowV2("):]
        reload_branch = handler[handler.index("if FPolicy = dapReloadOnly then"):handler.index("// Reload prompts are deliberately")]
        self.assertIn("exact-path policy and exact button-set checks", reload_branch)
        self.assertIn("IsStrictReloadPromptText(ReloadText)", reload_branch)
        self.assertIn("ResolveAllowedReloadPath", reload_branch)
        self.assertIn("HasExactReloadButtonSet", reload_branch)
        self.assertNotIn("SameText(WindowClass, 'TMessageForm') and HasModalOwner", reload_branch)

    def test_reload_only_does_not_depend_on_rad_studio_dialog_class(self):
        handler = COMPILER[COMPILER.index("procedure TCompileDialogCloser.TryDismissWindowV2("):]
        self.assertIn("if FPolicy = dapReloadOnly then\n    IsDialogCandidate := True", handler)
        reload_branch = handler[handler.index("if FPolicy = dapReloadOnly then"):handler.index("// Reload prompts are deliberately")]
        self.assertNotIn("SameText(WindowClass, 'TMessageForm')", reload_branch)
        self.assertIn("visible same-process window class is not trusted", reload_branch)

    def test_watcher_commits_and_clears_reload_policy_by_lifecycle(self):
        interface = WATCH[WATCH.index("interface"):WATCH.index("implementation")]
        self.assertIn("System.JSON", interface)
        self.assertIn("DelphiCompileGate.ProtocolV2", interface)
        self.assertIn("TCompileDialogCloser.Create(OnCompilerTrace, dapReloadOnly)", WATCH)
        self.assertIn("procedure TDelphiCompileGateWatch.CommitReloadPromptPolicy", WATCH)
        self.assertIn("UpdateReloadPolicy(AJobId, AToken, AllowedFiles", WATCH)
        self.assertIn("ClearReloadPromptPolicy;", WATCH)
        v2 = WATCH[WATCH.index("procedure TDelphiCompileGateWatch.ProcessV2Job"):]
        self.assertLess(v2.index("ClearReloadPromptPolicy;"), v2.index("TryLoadV2Request"))
        self.assertIn("CommitReloadPromptPolicy(Request.JobId, Request.Nonce", v2)
        self.assertLess(v2.index("WriteJSONAtomic(Request.JobId, ResultObject.ToJSON)"),
                        v2.index("CommitReloadPromptPolicy(Request.JobId, Request.Nonce"))
        self.assertLess(v2.index("TFile.Move(AJobFile, Destination)"),
                        v2.index("CommitReloadPromptPolicy(Request.JobId, Request.Nonce"))
        self.assertIn("if not ReloadPolicyCommitted then", v2)
        self.assertNotIn("ProcessJobManifest", WATCH)

    def test_only_success_and_completed_compile_failures_commit_reload_policy(self):
        self.assertTrue(can_commit_reload_policy("ok", None))
        self.assertTrue(can_commit_reload_policy("failed", "compile_failed"))
        self.assertTrue(can_commit_reload_policy(
            "failed", "compile_error_details_unavailable"
        ))
        for code in (
            "runtime_failure", "message_capture_unavailable", "dialog_blocked",
            "source_buffer_mismatch", "source_buffer_unverified",
            "wrapper_project_invalid",
            "malformed_request", "protocol_failure", "timeout", "target_mismatch",
            "artifact_missing", "package_identity_unavailable", "intervention_detected",
        ):
            self.assertFalse(can_commit_reload_policy("failed", code), code)
        self.assertFalse(can_commit_reload_policy("failed", "compile_failed", policy_compliant=False))
        self.assertFalse(can_commit_reload_policy("failed", "compile_failed", authenticated=False))
        self.assertIn("CanCommitReloadPromptPolicy", WATCH)
        self.assertIn("FailureCode.Value, 'compile_failed'", WATCH)
        self.assertIn("FailureCode.Value, 'compile_error_details_unavailable'", WATCH)
        self.assertIn("SchemaVersion.Value <> '2'", WATCH)
        self.assertIn("PolicyCompliant.Value, 'true'", WATCH)


if __name__ == "__main__":
    unittest.main()
