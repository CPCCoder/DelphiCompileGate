import hashlib
import inspect
import json
import copy
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from delphi_compile_gate import DelphiCompileGateClient


class ProtocolV2Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.project = self.root / "Demo.dproj"
        self.source = self.root / "Demo.dpr"
        self.project.write_bytes(b"<Project/>\r\n")
        self.source.write_bytes(b"program Demo;\r\nbegin end.\r\n")
        self.wrapper_dir = self.root / "wrapper"
        self.wrapper_dir.mkdir()
        self.wrapper_project = self.wrapper_dir / "DCG_demo_01.dproj"
        self.wrapper_source = self.wrapper_dir / "DCG_demo_01.dpr"
        self.artifact = self.wrapper_dir / "DCG_demo_01.exe"
        self.package = self.root / "DelphiCompileGate.bpl"
        self.wrapper_project.write_bytes(b"<Project/>\r\n")
        self.wrapper_source.write_bytes(b"program DCG_demo; begin end.\r\n")
        self.artifact.write_bytes(b"MZ-artifact")
        self.package.write_bytes(b"MZ-package")
        self.client = DelphiCompileGateClient(timeout=0.4, base_dir=str(self.root / "Run"))

    def tearDown(self):
        self.temp.cleanup()

    def manifest(self, platform="Win32", configuration="Debug"):
        return self.client._make_v2_manifest(
            self.project.resolve(), self.source.resolve(), "demo_01", "a" * 32,
            platform, configuration
        )

    def result(self, request):
        evidence = lambda p: {"path": str(p), "size": p.stat().st_size,
                               "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
        target = request["target"]
        return {
            "schema_version": 2, "protocol": 2, "job_id": request["job_id"],
            "nonce": request["nonce"], "request_hash": request["request_hash"],
            "status": "ok", "success": True, "failure_code": None,
            "requested_target": dict(request["target"]),
            "effective_target": dict(target),
            "input": copy.deepcopy(request["input"]),
            "wrapper": {"directory": str(self.wrapper_dir),
                        "project": evidence(self.wrapper_project), "main_source": evidence(self.wrapper_source)},
            "artifact": evidence(self.artifact),
            "identity": {"protocol": 2, "plugin_version": "2.0.0", "package_build_id": "dcg-v2-20260904-releaseprep-02",
                         "loaded_package_path": str(self.package),
                         "loaded_package_sha256": hashlib.sha256(self.package.read_bytes()).hexdigest(),
                          "ide_path": None, "ide_version": "Delphi 13 Community Edition", "compiler_version": 37.0},
            "compile": {"succeeded": True, "compile_time_ms": 1, "selected_platform": target["platform"],
                        "selected_configuration": target["configuration"], "compile_platform": target["platform"],
                        "compile_configuration": target["configuration"], "target_matched": True,
                        "release_eligible": True, "errors": []},
            "interventions": {"dialog_hits": 1, "dialog_close_attempts": 1,
                              "known_technical_dialog_hits": 1, "exceptions_swallowed": 0,
                              "license_or_eula_detected": False,
                               "unknown_dialog_detected": False, "intervention_free": False,
                               "policy_compliant": True},
            "legal_notice": {"detected": False, "classification": None,
                             "window_class": None, "title": None,
                             "text_available": False, "text": None,
                             "text_length": 0, "text_sha256": None,
                             "available_buttons": [], "action": None,
                             "accepted_terms": False},
        }

    def test_request_hash_is_deterministic_and_exact_bytes_verify(self):
        first, first_bytes = self.manifest()
        second, second_bytes = self.manifest()
        self.assertEqual(first, second)
        self.assertEqual(first_bytes, second_bytes)
        zeroed = first_bytes.replace(first["request_hash"].encode(), b"0" * 64, 1)
        self.assertEqual(hashlib.sha256(zeroed).hexdigest(), first["request_hash"])
        self.assertNotEqual(hashlib.sha256(first_bytes + b" ").hexdigest(), first["request_hash"])

    def test_tampered_manifest_does_not_match_hash(self):
        request, raw = self.manifest()
        tampered = raw.replace(b'"Debug"', b'"Other"')
        zeroed = tampered.replace(request["request_hash"].encode(), b"0" * 64, 1)
        self.assertNotEqual(hashlib.sha256(zeroed).hexdigest(), request["request_hash"])

    def test_win32_and_win64_debug_release_targets_are_explicitly_allowed(self):
        for platform in ("Win32", "Win64"):
            for configuration in ("Debug", "Release"):
                project, main_source, job_id = self.client._validate_v2_request(
                    str(self.project), str(self.source), "demo_01", platform, configuration
                )
                self.assertEqual((project, main_source, job_id),
                                 (self.project.resolve(), self.source.resolve(), "demo_01"))
                request, _ = self.manifest(platform, configuration)
                self.client._validate_v2_result(self.result(request), request)

    def test_debug_remains_win32_build_default(self):
        self.assertEqual((self.client.V2_PLATFORM, self.client.V2_CONFIGURATION),
                         ("Win32", "Debug"))
        parameters = inspect.signature(self.client.compile_project).parameters
        self.assertEqual(parameters["platform"].default, "Win32")
        self.assertEqual(parameters["configuration"].default, "Debug")
        self.assertEqual(list(parameters)[:2], ["source_path", "project_path"])
        self.assertIsNone(parameters["project_path"].default)

    def test_source_only_request_uses_nullable_project_evidence(self):
        project, source, job_id = self.client._validate_v2_request(
            "", str(self.source), "source_only", "Win32", "Debug"
        )
        self.assertIsNone(project)
        request, raw = self.client._make_v2_manifest(
            project, source, job_id, "b" * 32, "Win32", "Debug"
        )
        self.assertEqual(request["input"]["project"],
                         {"path": None, "size": None, "sha256": None})
        self.assertEqual(request["kind"], "project_wrapper_build")
        zeroed = raw.replace(request["request_hash"].encode(), b"0" * 64, 1)
        self.assertEqual(hashlib.sha256(zeroed).hexdigest(), request["request_hash"])

    def test_ce_usage_notice_evidence_is_structured_and_never_accepts_terms(self):
        request, _ = self.manifest()
        result = self.result(request)
        result["legal_notice"] = {
            "detected": True,
            "classification": "community_edition_usage_notice",
            "window_class": "TCENotificationDialog",
            "title": None,
            "text_available": False,
            "text": None,
            "text_length": 0,
            "text_sha256": None,
            "available_buttons": ["OK"],
            "action": "acknowledged",
            "accepted_terms": False,
        }
        self.client._validate_v2_result(result, request)
        result["legal_notice"]["accepted_terms"] = True
        with self.assertRaisesRegex(ValueError, "never report accepted terms"):
            self.client._validate_v2_result(result, request)

    def test_ce_usage_notice_text_hash_is_verified_when_complete(self):
        request, _ = self.manifest()
        result = self.result(request)
        text = "EULA-Hinweis für die Community Edition"
        result["legal_notice"] = {
            "detected": True,
            "classification": "community_edition_usage_notice",
            "window_class": "TCENotificationDialog",
            "title": None,
            "text_available": True,
            "text": text,
            "text_length": len(text),
            "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "available_buttons": ["OK"],
            "action": "acknowledged",
            "accepted_terms": False,
        }
        self.client._validate_v2_result(result, request)
        result["legal_notice"]["text_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "hash verification"):
            self.client._validate_v2_result(result, request)

    def test_compile_project_is_the_only_public_compile_api(self):
        public_compile_methods = {
            name for name, member in inspect.getmembers(
                DelphiCompileGateClient, predicate=inspect.isfunction
            )
            if not name.startswith("_") and name != "get_logs"
        }
        self.assertEqual(public_compile_methods, {"compile_project"})
        for removed_alias in (
            "validate", "validate_file", "validate_units",
            "validate_project_wrapper", "build_project_wrapper",
            "build_project_wrapper_v2", "batch_validate", "filter_valid",
        ):
            self.assertFalse(hasattr(self.client, removed_alias), removed_alias)

    def test_v2_target_allowlist_rejects_unknown_or_noncanonical_values(self):
        for platform, configuration in (
            ("Linux64", "Debug"), ("Win32", "Profile"), ("Win64", "Profile"),
            ("", "Debug"), ("Win32", ""), ("win32", "Debug"),
            ("win64", "Debug"), ("Win32", "debug"), ("Win64", "release"),
        ):
            with self.assertRaisesRegex(ValueError, "v2 target must be exactly"):
                self.client._validate_v2_request(
                    str(self.project), str(self.source), "demo_01", platform, configuration
                )

    def test_request_hash_binds_platform_and_configuration(self):
        requests = {}
        payloads = {}
        for platform in ("Win32", "Win64"):
            for configuration in ("Debug", "Release"):
                key = (platform, configuration)
                requests[key], payloads[key] = self.manifest(platform, configuration)
        self.assertEqual(4, len({request["request_hash"] for request in requests.values()}))
        self.assertEqual(4, len(set(payloads.values())))

    def test_result_cannot_be_reused_across_allowed_targets(self):
        targets = (
            ("Win32", "Debug"), ("Win32", "Release"),
            ("Win64", "Debug"), ("Win64", "Release"),
        )
        requests = {target: self.manifest(*target)[0] for target in targets}
        for source_target in targets:
            for requested_target in targets:
                if source_target == requested_target:
                    continue
                with self.assertRaises(ValueError):
                    self.client._validate_v2_result(
                        self.result(requests[source_target]), requests[requested_target]
                    )

    def test_echo_mismatches_are_rejected(self):
        request, _ = self.manifest()
        for field, value in (("nonce", "b" * 32), ("job_id", "other"),
                             ("request_hash", "b" * 64)):
            result = self.result(request)
            result[field] = value
            with self.assertRaisesRegex(ValueError, "echo mismatch"):
                self.client._validate_v2_result(result, request)
        result = self.result(request)
        result["requested_target"]["configuration"] = "Release"
        with self.assertRaisesRegex(ValueError, "target echo mismatch"):
            self.client._validate_v2_result(result, request)

    def test_versioned_package_identity_binds_its_ide_version(self):
        request, _ = self.manifest()
        result = self.result(request)
        result["identity"]["ide_version"] = "Unsupported IDE"
        with self.assertRaisesRegex(ValueError, "plugin IDE identity mismatch"):
            self.client._validate_v2_result(result, request)

        result = self.result(request)
        result["identity"]["compiler_version"] = 99.0
        with self.assertRaisesRegex(ValueError, "plugin IDE identity mismatch"):
            self.client._validate_v2_result(result, request)

        result = self.result(request)
        result["identity"]["package_build_id"] = "dcg-v2-20260731-win64-01"
        result["identity"]["ide_version"] = None
        with self.assertRaisesRegex(ValueError, "plugin identity mismatch"):
            self.client._validate_v2_result(result, request)

        result = self.result(request)
        result["identity"]["package_build_id"] = "untrusted-package"
        with self.assertRaisesRegex(ValueError, "plugin identity mismatch"):
            self.client._validate_v2_result(result, request)

    def test_unknown_missing_and_wrong_types_are_rejected(self):
        request, _ = self.manifest()
        result = self.result(request)
        result["unknown"] = 1
        with self.assertRaisesRegex(ValueError, "fields mismatch"):
            self.client._validate_v2_result(result, request)
        result = self.result(request)
        del result["identity"]
        with self.assertRaisesRegex(ValueError, "fields mismatch"):
            self.client._validate_v2_result(result, request)
        result = self.result(request)
        result["success"] = 1
        with self.assertRaisesRegex(ValueError, "invalid type"):
            self.client._validate_v2_result(result, request)
        result = self.result(request)
        result["failure_code"] = "compile_failed"
        with self.assertRaisesRegex(ValueError, "success/failure_code"):
            self.client._validate_v2_result(result, request)
        result = self.result(request)
        result["interventions"]["dialog_hits"] = True
        with self.assertRaisesRegex(ValueError, "invalid type"):
            self.client._validate_v2_result(result, request)

    def test_success_evidence_and_target_mutations_are_rejected(self):
        request, _ = self.manifest()
        mutations = [
            lambda r: r["artifact"].__setitem__("size", r["artifact"]["size"] + 1),
            lambda r: r["wrapper"]["project"].__setitem__("sha256", "b" * 64),
            lambda r: r["identity"].__setitem__("loaded_package_sha256", "b" * 64),
            lambda r: r["effective_target"].__setitem__("configuration", "Release"),
            lambda r: r["compile"].__setitem__("compile_platform", "Win64"),
            lambda r: r["compile"].__setitem__("selected_configuration", "Release"),
            lambda r: r["compile"].__setitem__("compile_configuration", "Release"),
            lambda r: r["compile"].__setitem__("target_matched", False),
            lambda r: r["compile"].__setitem__("release_eligible", False),
            lambda r: r["interventions"].__setitem__("known_technical_dialog_hits", 0),
            lambda r: r["interventions"].__setitem__("license_or_eula_detected", True),
            lambda r: r["interventions"].__setitem__("intervention_free", True),
            lambda r: r["interventions"].__setitem__("policy_compliant", False),
        ]
        for mutate in mutations:
            result = copy.deepcopy(self.result(request))
            mutate(result)
            with self.assertRaises(ValueError):
                self.client._validate_v2_result(result, request)

    def test_target_evidence_must_be_complete_and_exact_for_success(self):
        request, _ = self.manifest()
        for field in (
            "selected_configuration", "compile_configuration",
            "selected_platform", "compile_platform",
        ):
            result = self.result(request)
            result["compile"][field] = None
            result["compile"]["target_matched"] = False
            result["compile"]["release_eligible"] = False
            with self.assertRaises(ValueError):
                self.client._validate_v2_result(result, request)

        result = self.result(request)
        result["compile"]["target_matched"] = False
        result["compile"]["release_eligible"] = False
        with self.assertRaises(ValueError):
            self.client._validate_v2_result(result, request)

    def test_success_with_one_known_technical_closure_is_accepted(self):
        request, _ = self.manifest()
        result = self.result(request)
        self.assertFalse(result["interventions"]["intervention_free"])
        self.assertTrue(result["interventions"]["policy_compliant"])
        self.client._validate_v2_result(result, request)

    def test_success_without_dialogs_is_intervention_free_and_policy_compliant(self):
        request, _ = self.manifest()
        result = self.result(request)
        result["interventions"].update(
            dialog_hits=0,
            dialog_close_attempts=0,
            known_technical_dialog_hits=0,
            intervention_free=True,
        )
        self.client._validate_v2_result(result, request)

    def test_inconsistent_dialog_counts_are_rejected(self):
        request, _ = self.manifest()
        mutations = [
            lambda i: i.__setitem__("known_technical_dialog_hits", 0),
            lambda i: i.__setitem__("known_technical_dialog_hits", 2),
            lambda i: i.__setitem__("dialog_close_attempts", 0),
        ]
        for mutate in mutations:
            result = self.result(request)
            mutate(result["interventions"])
            with self.assertRaises(ValueError):
                self.client._validate_v2_result(result, request)

    def test_unknown_legal_and_exception_interventions_are_rejected(self):
        request, _ = self.manifest()
        mutations = [
            lambda i: i.__setitem__("unknown_dialog_detected", True),
            lambda i: i.__setitem__("license_or_eula_detected", True),
            lambda i: i.__setitem__("exceptions_swallowed", 1),
        ]
        for mutate in mutations:
            result = self.result(request)
            mutate(result["interventions"])
            with self.assertRaises(ValueError):
                self.client._validate_v2_result(result, request)

    def test_consistent_legal_unknown_and_exception_failures_are_ineligible(self):
        request, _ = self.manifest()
        cases = [
            {"known_technical_dialog_hits": 0, "dialog_close_attempts": 0,
             "license_or_eula_detected": True, "policy_compliant": False},
            {"known_technical_dialog_hits": 0, "dialog_close_attempts": 0,
             "unknown_dialog_detected": True, "policy_compliant": False},
            {"exceptions_swallowed": 1, "policy_compliant": False},
        ]
        for intervention_changes in cases:
            result = self.result(request)
            result.update(status="failed", success=False, failure_code="intervention_detected")
            result["compile"]["release_eligible"] = False
            result["interventions"].update(intervention_changes)
            self.client._validate_v2_result(result, request)
            self.assertFalse(result["compile"]["release_eligible"])

    def test_complete_failure_envelope_is_accepted_but_not_release_eligible(self):
        request, _ = self.manifest()
        result = self.result(request)
        result.update(status="failed", success=False, failure_code="artifact_missing")
        result["artifact"] = {"path": None, "size": None, "sha256": None}
        result["compile"]["release_eligible"] = False
        self.client._validate_v2_result(result, request)
        result["compile"]["release_eligible"] = True
        with self.assertRaisesRegex(ValueError, "release eligibility|failed result"):
            self.client._validate_v2_result(result, request)

    def test_raw_bytes_preserved_before_invalid_json_failure(self):
        raw = b'{"broken":true}\r\n\xff'
        destination = self.root / "evidence" / "raw.json"
        original_wait = self.client._wait_for_v2_result
        self.client._wait_for_v2_result = lambda job_id: (raw, None)
        try:
            result = self.client.compile_project(
                source_path=str(self.source), project_path=str(self.project),
                job_id="raw_test", raw_result_path=str(destination)
            )
        finally:
            self.client._wait_for_v2_result = original_wait
        self.assertEqual(destination.read_bytes(), raw)
        self.assertEqual(result["failure_code"], "invalid_result")
        self.assertEqual(result["_client_evidence"]["raw_result_sha256"], hashlib.sha256(raw).hexdigest())

    def test_fake_watcher_success_preserves_plugin_object_and_raw_bytes(self):
        destination = self.root / "evidence" / "success.json"

        def watcher():
            jobs = []
            deadline = time.monotonic() + 1
            while not jobs and time.monotonic() < deadline:
                jobs = list(self.client.INPUT_DIR.glob("*.job.json"))
                time.sleep(0.005)
            request = json.loads(jobs[0].read_bytes())
            raw = json.dumps(self.result(request), ensure_ascii=False, separators=(", ", ": ")).encode() + b"\r\n"
            temp = self.client.OUTPUT_DIR / ".result.tmp"
            temp.write_bytes(raw)
            temp.replace(self.client.OUTPUT_DIR / "demo_01.json")

        worker = threading.Thread(target=watcher)
        worker.start()
        result = self.client.compile_project(
            source_path=str(self.source), project_path=None, job_id="demo_01",
            platform="Win32", configuration="Debug",
            raw_result_path=str(destination),
        )
        worker.join()
        preserved = destination.read_bytes()
        self.assertTrue(result["success"])
        self.assertNotIn("_client_evidence", json.loads(preserved))
        self.assertEqual(result["_client_evidence"]["raw_result_sha256"], hashlib.sha256(preserved).hexdigest())

    def test_timeout_and_failed_shapes_fail_closed(self):
        timeout_client = DelphiCompileGateClient(timeout=0.01, base_dir=str(self.root / "Timeout"))
        _, failure = timeout_client._wait_for_v2_result("timeout_job")
        self.assertEqual((failure["success"], failure["failure_code"]), (False, "timeout"))
        failed_client = DelphiCompileGateClient(timeout=1, base_dir=str(self.root / "Failed"))
        (failed_client.FAILED_DIR / "failed_job.job.json").write_text("bad", encoding="utf-8")
        _, failure = failed_client._wait_for_v2_result("failed_job")
        self.assertEqual((failure["success"], failure["failure_code"]), (False, "watcher_failed"))

    def test_preexisting_v2_job_state_is_rejected(self):
        wrapper = self.client.BASE_DIR / "Projects" / "existing_job"
        wrapper.mkdir(parents=True)
        with self.assertRaisesRegex(FileExistsError, "preexisting job state"):
            self.client.compile_project(
                source_path=str(self.source), project_path=str(self.project),
                job_id="existing_job"
            )

    def test_path_target_and_job_validation(self):
        cases = [
            ("relative.dproj", str(self.source), "valid", "Win32", "Debug"),
            (str(self.project), str(self.source), "UPPER", "Win32", "Debug"),
            (str(self.project), str(self.source), "valid", "Linux64", "Debug"),
            (str(self.project), str(self.source), "valid", "Win32", "Profile"),
        ]
        for args in cases:
            with self.assertRaises(ValueError):
                self.client._validate_v2_request(*args)
        other_source = self.root / "Other.dpr"
        other_source.write_text("program Other; begin end.", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "share directory and stem"):
            self.client._validate_v2_request(str(self.project), str(other_source),
                                             "valid", "Win32", "Debug")


if __name__ == "__main__":
    unittest.main()
