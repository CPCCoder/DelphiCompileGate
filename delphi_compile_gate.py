"""
DelphiCompileGate Python Client

Automated compiler validator for Delphi Starter/Community Edition.
Uses the OTA plugin through file-watched directories.

Requirements:
  - The Delphi IDE is running
  - The DelphiCompileGate plugin is installed and active
  - In Settings / Status, the user selected Start Watch and then OK

The runtime directory defaults to %LOCALAPPDATA%\\DelphiCompileGate\\Run.
"""

import hashlib
import json
import os
import secrets
import tempfile
import time
from pathlib import Path
from typing import Optional
import re


class DelphiCompileGateClient:
    """
    Client for the DelphiCompileGate OTA plugin.
    Communicates through file-watched directories (no direct IDE interaction required).
    """

    V2_HASH_PLACEHOLDER = "0" * 64
    V2_JOB_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
    V2_NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
    V2_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
    V2_PLATFORM = "Win32"
    V2_CONFIGURATION = "Debug"
    V2_ALLOWED_TARGETS = frozenset({
        ("Win32", "Debug"),
        ("Win32", "Release"),
        ("Win64", "Debug"),
        ("Win64", "Release"),
    })
    # Result shape is exact. Only packages that emit the current legal_notice
    # evidence object are accepted.
    V2_ALLOWED_PACKAGE_BUILD_IDS = frozenset({
        "dcg-v2-20260905-searchpathfix-03",
    })
    V2_PACKAGE_IDE_IDENTITIES = {
        "dcg-v2-20260905-searchpathfix-03": ("Delphi 13 Community Edition", 37.0),
    }

    def __init__(self, timeout: int = 60, base_dir: str = ""):
        self.timeout = timeout
        self.BASE_DIR = self._resolve_base_dir(base_dir)
        self.INPUT_DIR = self.BASE_DIR / "Input"
        self.OUTPUT_DIR = self.BASE_DIR / "Output"
        self.PROCESSED_DIR = self.BASE_DIR / "Processed"
        self.FAILED_DIR = self.BASE_DIR / "Failed"
        self.LOG_DIR = self.BASE_DIR / "Logs"
        self._ensure_dirs()

    def _resolve_base_dir(self, base_dir: str) -> Path:
        """Resolve the watcher base directory (config > environment > per-user default)."""
        if base_dir:
            return Path(os.path.expandvars(base_dir))

        env_base = os.getenv("DELPHI_COMPILE_GATE_BASE_DIR", "").strip()
        if env_base:
            return Path(env_base)

        local_root = os.getenv("LOCALAPPDATA", "").strip()
        if local_root:
            return Path(local_root) / "DelphiCompileGate" / "Run"

        user_profile = os.getenv("USERPROFILE", "").strip()
        if user_profile:
            return Path(user_profile) / "AppData" / "Local" / "DelphiCompileGate" / "Run"

        return Path(tempfile.gettempdir()) / "DelphiCompileGate" / "Run"

    def _ensure_dirs(self) -> None:
        """Create all required directories."""
        for d in [self.INPUT_DIR, self.OUTPUT_DIR, self.PROCESSED_DIR, self.FAILED_DIR, self.LOG_DIR]:
            d.mkdir(parents=True, exist_ok=True)

    def compile_project(self, source_path: str, project_path: Optional[str] = None,
                        job_id: str = "", platform: str = "Win32",
                        configuration: str = "Debug",
                        raw_result_path: str = "") -> dict:
        """Compile a Delphi DPR/DPK through the authenticated Protocol-v2 gate.

        ``project_path`` is optional. When omitted, the plugin creates a minimal
        managed ``.dproj`` under ``Run\\Projects`` without modifying the source
        directory.
        """
        project, main_source, job_id = self._validate_v2_request(
            project_path or "", source_path, job_id, platform, configuration
        )
        nonce = secrets.token_hex(16)
        manifest, manifest_bytes = self._make_v2_manifest(
            project, main_source, job_id, nonce, platform, configuration
        )
        job_file = self.INPUT_DIR / f"{job_id}.job.json"
        out_file = self.OUTPUT_DIR / f"{job_id}.json"
        failed_file = self.FAILED_DIR / f"{job_id}.job.json"
        processed_file = self.PROCESSED_DIR / f"{job_id}.job.json"
        wrapper_dir = self.BASE_DIR / "Projects" / job_id
        evidence_destination = Path(raw_result_path) if raw_result_path else None
        if evidence_destination is not None and evidence_destination.exists() and evidence_destination.is_dir():
            evidence_destination = evidence_destination / f"{job_id}.json"
        paths = [job_file, out_file, failed_file, processed_file, wrapper_dir]
        if evidence_destination is not None:
            paths.append(evidence_destination)
        for path in paths:
            if path.exists():
                raise FileExistsError(f"v2 refuses preexisting job state: {path}")

        temp_file = self.INPUT_DIR / f".{job_id}.{nonce}.tmp"
        try:
            temp_file.write_bytes(manifest_bytes)
            os.replace(temp_file, job_file)
            raw_bytes, wait_failure = self._wait_for_v2_result(job_id)
            if wait_failure is not None:
                wait_failure["nonce"] = nonce
                wait_failure["request_hash"] = manifest["request_hash"]
                wait_failure["_client_evidence"] = {
                    "raw_result": None,
                    "raw_result_size": None,
                    "raw_result_sha256": None,
                }
                return wait_failure

            evidence_path = self._preserve_raw_result(raw_bytes, raw_result_path, job_id)
            evidence = {
                "raw_result": str(evidence_path) if evidence_path else None,
                "raw_result_size": len(raw_bytes),
                "raw_result_sha256": hashlib.sha256(raw_bytes).hexdigest(),
            }
            try:
                result = json.loads(raw_bytes.decode("utf-8"))
                self._validate_v2_result(result, manifest)
            except (UnicodeDecodeError, json.JSONDecodeError, OSError, TypeError, ValueError) as exc:
                return self._v2_client_failure(job_id, nonce, manifest["request_hash"],
                                               "invalid_result", str(exc), evidence)
            result["_client_evidence"] = evidence
            return result
        finally:
            for path in (temp_file, job_file, out_file):
                try:
                    if path.exists():
                        path.unlink()
                except OSError:
                    pass

    def _validate_v2_request(self, project_path: str, dpr_path: str, job_id: str,
                               platform: str, configuration: str) -> tuple[Optional[Path], Path, str]:
        if (platform, configuration) not in self.V2_ALLOWED_TARGETS:
            raise ValueError(
                "v2 target must be exactly Win32/Debug, Win32/Release, "
                "Win64/Debug, or Win64/Release"
            )
        project = None
        if project_path:
            project_candidate = Path(project_path)
            if (not project_candidate.is_absolute()
                    or project_candidate.suffix.lower() != ".dproj"
                    or not project_candidate.is_file() or project_candidate.is_symlink()):
                raise ValueError("project_path must be an absolute regular .dproj file")
            project = project_candidate.resolve(strict=True)
        if dpr_path:
            main_source = Path(dpr_path)
        elif project is not None:
            main_source = project.with_suffix(".dpr")
            if not main_source.exists():
                main_source = project.with_suffix(".dpk")
        else:
            raise ValueError("compile_project requires an absolute .dpr or .dpk source_path")
        if (not main_source.is_absolute() or main_source.suffix.lower() not in (".dpr", ".dpk")
                or not main_source.is_file() or main_source.is_symlink()):
            raise ValueError("dpr_path must be an absolute regular .dpr or .dpk file")
        main_source = main_source.resolve(strict=True)
        if project is not None and (
                project.parent != main_source.parent
                or project.stem.lower() != main_source.stem.lower()):
            raise ValueError("v2 project and main source must share directory and stem")
        if not job_id:
            identity = project or main_source
            job_id = f"{re.sub(r'[^a-z0-9_]+', '_', identity.stem.lower()).strip('_')[:40] or 'project'}_{secrets.token_hex(6)}"
        if not isinstance(job_id, str) or not self.V2_JOB_RE.fullmatch(job_id):
            raise ValueError("job_id must match [a-z0-9][a-z0-9_-]{0,63}")
        return project, main_source, job_id

    @staticmethod
    def _file_evidence(path: Path) -> dict:
        data = path.read_bytes()
        return {"path": str(path), "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    @classmethod
    def _nullable_file_evidence(cls, path: Optional[Path]) -> dict:
        if path is None:
            return {"path": None, "size": None, "sha256": None}
        return cls._file_evidence(path)

    @classmethod
    def _canonical_json_bytes(cls, value: dict) -> bytes:
        return json.dumps(value, ensure_ascii=False, sort_keys=True,
                          separators=(",", ":")).encode("utf-8")

    @classmethod
    def _make_v2_manifest(cls, project: Optional[Path], main_source: Path, job_id: str,
                          nonce: str, platform: str, configuration: str) -> tuple[dict, bytes]:
        if not cls.V2_NONCE_RE.fullmatch(nonce):
            raise ValueError("nonce must be 32 lowercase hexadecimal characters")
        manifest = {
            "input": {
                "main_source": cls._file_evidence(main_source),
                "project": cls._nullable_file_evidence(project),
            },
            "job_id": job_id,
            "kind": "project_wrapper_build",
            "nonce": nonce,
            "protocol": 2,
            "request_hash": cls.V2_HASH_PLACEHOLDER,
            "schema_version": 2,
            "target": {"configuration": configuration, "platform": platform},
        }
        zero_bytes = cls._canonical_json_bytes(manifest)
        request_hash = hashlib.sha256(zero_bytes).hexdigest()
        marker = cls.V2_HASH_PLACEHOLDER.encode("ascii")
        if zero_bytes.count(marker) != 1:
            raise ValueError("request_hash placeholder is not unique")
        manifest["request_hash"] = request_hash
        return manifest, zero_bytes.replace(marker, request_hash.encode("ascii"), 1)

    def _wait_for_v2_result(self, job_id: str) -> tuple[Optional[bytes], Optional[dict]]:
        out_file = self.OUTPUT_DIR / f"{job_id}.json"
        failed_job = self.FAILED_DIR / f"{job_id}.job.json"
        start = time.monotonic()
        while time.monotonic() - start < self.timeout:
            try:
                if out_file.is_file():
                    return out_file.read_bytes(), None
            except OSError:
                pass
            if failed_job.exists():
                return None, self._v2_client_failure(job_id, None, None,
                                                     "watcher_failed", "Watcher moved v2 job to Failed")
            time.sleep(0.05)
        return None, self._v2_client_failure(job_id, None, None, "timeout",
                                             f"Timeout after {self.timeout}s")

    def _preserve_raw_result(self, raw_bytes: bytes, raw_result_path: str,
                             job_id: str) -> Optional[Path]:
        if not raw_result_path:
            return None
        destination = Path(raw_result_path)
        if destination.exists() and destination.is_dir():
            destination = destination / f"{job_id}.json"
        destination.parent.mkdir(parents=True, exist_ok=True)
        temp = destination.with_name(f".{destination.name}.{secrets.token_hex(8)}.tmp")
        try:
            temp.write_bytes(raw_bytes)
            os.replace(temp, destination)
        finally:
            try:
                if temp.exists():
                    temp.unlink()
            except OSError:
                pass
        return destination.resolve()

    @classmethod
    def _validate_v2_result(cls, result: object, request: dict) -> None:
        if not isinstance(result, dict):
            raise ValueError("result must be an object")
        required = {
            "schema_version", "protocol", "job_id", "nonce", "request_hash", "status",
            "success", "failure_code", "requested_target", "effective_target", "input",
            "wrapper", "artifact", "identity", "compile", "interventions", "legal_notice",
        }
        if set(result) != required:
            raise ValueError(f"result fields mismatch: missing={sorted(required - set(result))}, unknown={sorted(set(result) - required)}")
        scalar_types = {
            "schema_version": int, "protocol": int, "job_id": str, "nonce": str,
            "request_hash": str, "status": str, "success": bool,
        }
        for name, expected in scalar_types.items():
            if type(result[name]) is not expected:
                raise ValueError(f"{name} has invalid type")
        for name in ("requested_target", "effective_target", "input", "wrapper", "artifact",
                     "identity", "compile", "interventions", "legal_notice"):
            if not isinstance(result[name], dict):
                raise ValueError(f"{name} must be an object")
        if result["failure_code"] is not None and (
                not isinstance(result["failure_code"], str) or not result["failure_code"]):
            raise ValueError("failure_code must be string or null")
        if result["schema_version"] != 2 or result["protocol"] != 2:
            raise ValueError("protocol/schema_version mismatch")
        if result["status"] not in ("ok", "failed"):
            raise ValueError("invalid status")
        if result["success"] != (result["status"] == "ok"):
            raise ValueError("status/success mismatch")
        if result["success"] != (result["failure_code"] is None):
            raise ValueError("success/failure_code mismatch")
        for name, regex in (("job_id", cls.V2_JOB_RE), ("nonce", cls.V2_NONCE_RE),
                            ("request_hash", cls.V2_HASH_RE)):
            if not regex.fullmatch(result[name]):
                raise ValueError(f"invalid {name}")
        for name in ("job_id", "nonce", "request_hash"):
            if result[name] != request[name]:
                raise ValueError(f"{name} echo mismatch")
        target_fields = {"platform", "configuration"}
        if set(result["requested_target"]) != target_fields:
            raise ValueError("requested_target fields mismatch")
        if result["requested_target"] != request["target"]:
            raise ValueError("requested_target echo mismatch")
        cls._validate_v2_nested_fields(result)
        if result["input"] != request["input"]:
            raise ValueError("input evidence echo mismatch")
        package_build_id = result["identity"]["package_build_id"]
        if (result["identity"]["protocol"] != 2
                or result["identity"]["plugin_version"] != "2.0.0"
                or package_build_id not in cls.V2_ALLOWED_PACKAGE_BUILD_IDS):
            raise ValueError("plugin identity mismatch")
        expected_ide_identity = cls.V2_PACKAGE_IDE_IDENTITIES.get(package_build_id)
        if (expected_ide_identity is not None
                and (result["identity"]["ide_version"], result["identity"]["compiler_version"])
                != expected_ide_identity):
            raise ValueError("plugin IDE identity mismatch")
        package_hash = result["identity"]["loaded_package_sha256"]
        if package_hash is not None and not cls.V2_HASH_RE.fullmatch(package_hash):
            raise ValueError("loaded package hash invalid")
        if (result["identity"]["loaded_package_path"] is None) != (package_hash is None):
            raise ValueError("loaded package identity must be wholly known or null")
        expected_target = request["target"]
        if (expected_target.get("platform"), expected_target.get("configuration")) not in cls.V2_ALLOWED_TARGETS:
            raise ValueError("request target is not an allowed v2 target")
        for field, expected in expected_target.items():
            if result["effective_target"][field] not in (None, expected):
                raise ValueError(f"effective_target.{field} invalid")
        compile_info = result["compile"]
        for field, expected in (
            ("selected_platform", expected_target["platform"]),
            ("selected_configuration", expected_target["configuration"]),
            ("compile_platform", expected_target["platform"]),
            ("compile_configuration", expected_target["configuration"]),
        ):
            if compile_info[field] not in (None, expected):
                raise ValueError(f"compile.{field} invalid")
        exact_target_evidence = (
            compile_info["selected_platform"], compile_info["selected_configuration"],
            compile_info["compile_platform"], compile_info["compile_configuration"],
        ) == (
            expected_target["platform"], expected_target["configuration"],
            expected_target["platform"], expected_target["configuration"],
        )
        if compile_info["target_matched"] and not exact_target_evidence:
            raise ValueError("target_matched lacks exact target evidence")
        if result["compile"]["release_eligible"] and not result["compile"]["target_matched"]:
            raise ValueError("release eligibility requires matched target evidence")
        if result["compile"]["release_eligible"] and (
                not result["success"]
                or result["effective_target"] != expected_target
                or not exact_target_evidence):
            raise ValueError("release eligibility lacks exact target evidence")
        if result["success"]:
            cls._validate_v2_success(result, request)
        elif result["compile"]["release_eligible"]:
            raise ValueError("failed result cannot be release eligible")

    @classmethod
    def _validate_v2_success(cls, result: dict, request: dict) -> None:
        expected_target = request["target"]
        if result["effective_target"] != expected_target:
            raise ValueError("successful result effective target mismatch")
        compile_info = result["compile"]
        target_values = (
            compile_info["selected_platform"], compile_info["selected_configuration"],
            compile_info["compile_platform"], compile_info["compile_configuration"],
        )
        if target_values != (expected_target["platform"], expected_target["configuration"],
                             expected_target["platform"], expected_target["configuration"]):
            raise ValueError("successful result compile target mismatch")
        if not (compile_info["succeeded"] and compile_info["target_matched"]
                and compile_info["release_eligible"]):
            raise ValueError("successful result lacks compile eligibility")

        wrapper_dir = result["wrapper"]["directory"]
        if not isinstance(wrapper_dir, str) or not Path(wrapper_dir).is_absolute():
            raise ValueError("successful result wrapper directory invalid")
        expected_base = "DCG_" + request["job_id"].replace("-", "_").replace(".", "_").replace(" ", "_")
        expected_names = {
            "project": expected_base + ".dproj",
            "main_source": expected_base + Path(request["input"]["main_source"]["path"]).suffix.lower(),
        }
        for name in ("project", "main_source"):
            cls._recompute_file_evidence(result["wrapper"][name], f"wrapper.{name}")
            if Path(result["wrapper"][name]["path"]).parent.resolve() != Path(wrapper_dir).resolve():
                raise ValueError(f"wrapper.{name} is outside wrapper directory")
            if Path(result["wrapper"][name]["path"]).name.lower() != expected_names[name].lower():
                raise ValueError(f"wrapper.{name} name mismatch")
        cls._recompute_file_evidence(result["artifact"], "artifact")
        artifact_extension = ".bpl" if expected_names["main_source"].endswith(".dpk") else ".exe"
        if Path(result["artifact"]["path"]).name.lower() != (expected_base + artifact_extension).lower():
            raise ValueError("artifact name mismatch")
        if Path(result["artifact"]["path"]).parent.resolve() != Path(wrapper_dir).resolve():
            raise ValueError("artifact is outside wrapper directory")

        package_path = result["identity"]["loaded_package_path"]
        package_hash = result["identity"]["loaded_package_sha256"]
        if not isinstance(package_path, str) or not isinstance(package_hash, str):
            raise ValueError("successful result lacks loaded package identity")
        package_file = Path(package_path)
        if (not package_file.is_absolute() or not package_file.is_file()
                or package_file.is_symlink() or package_file.suffix.lower() != ".bpl"):
            raise ValueError("loaded package path does not exist")
        if package_file.stat().st_nlink != 1:
            raise ValueError("loaded package must not have hard links")
        package_bytes = package_file.read_bytes()
        if hashlib.sha256(package_bytes).hexdigest() != package_hash:
            raise ValueError("loaded package evidence mismatch")

        interventions = result["interventions"]
        if (interventions["known_technical_dialog_hits"] != interventions["dialog_hits"]
                or interventions["dialog_close_attempts"] != interventions["dialog_hits"]
                or interventions["exceptions_swallowed"] != 0
                or interventions["license_or_eula_detected"] is not False
                or interventions["unknown_dialog_detected"] is not False
                or interventions["policy_compliant"] is not True):
            raise ValueError("successful result has intervention evidence")
        if result["legal_notice"]["detected"] and \
                result["legal_notice"]["action"] != "acknowledged":
            raise ValueError("successful result has unacknowledged legal notice")

    @classmethod
    def _recompute_file_evidence(cls, evidence: dict, name: str) -> None:
        cls._validate_file_evidence(evidence, name, nullable=False)
        path = Path(evidence["path"])
        if not path.is_absolute() or not path.is_file() or path.is_symlink():
            raise ValueError(f"{name} path does not exist")
        if path.stat().st_nlink != 1:
            raise ValueError(f"{name} must not have hard links")
        data = path.read_bytes()
        if len(data) != evidence["size"] or hashlib.sha256(data).hexdigest() != evidence["sha256"]:
            raise ValueError(f"{name} evidence mismatch")

    @classmethod
    def _validate_v2_nested_fields(cls, result: dict) -> None:
        expected = {
            "effective_target": {"platform", "configuration"},
            "input": {"project", "main_source"},
            "wrapper": {"directory", "project", "main_source"},
            "artifact": {"path", "size", "sha256"},
            "identity": {"protocol", "plugin_version", "package_build_id", "loaded_package_path",
                         "loaded_package_sha256", "ide_path", "ide_version", "compiler_version"},
            "compile": {"succeeded", "compile_time_ms", "selected_platform", "selected_configuration",
                        "compile_platform", "compile_configuration", "target_matched",
                        "release_eligible", "errors"},
            "interventions": {"dialog_hits", "dialog_close_attempts", "known_technical_dialog_hits",
                              "exceptions_swallowed",
                              "license_or_eula_detected", "unknown_dialog_detected",
                              "intervention_free", "policy_compliant"},
            "legal_notice": {"detected", "classification", "window_class", "title",
                             "text_available", "text", "text_length", "text_sha256",
                             "available_buttons", "action", "accepted_terms"},
        }
        for name, fields in expected.items():
            if set(result[name]) != fields:
                raise ValueError(f"{name} fields mismatch")
        for name in ("project", "main_source"):
            cls._validate_file_evidence(result["input"][name], f"input.{name}", nullable=True)
        for name in ("project", "main_source"):
            cls._validate_file_evidence(result["wrapper"][name], f"wrapper.{name}", nullable=True)
        cls._validate_file_evidence(result["artifact"], "artifact", nullable=True)
        cls._validate_v2_nested_types(result)

    @classmethod
    def _validate_v2_nested_types(cls, result: dict) -> None:
        nullable_strings = {
            "effective_target": ("platform", "configuration"),
            "identity": ("loaded_package_path", "loaded_package_sha256", "ide_path", "ide_version"),
            "compile": ("selected_platform", "selected_configuration", "compile_platform",
                        "compile_configuration"),
        }
        for obj_name, fields in nullable_strings.items():
            for field in fields:
                if result[obj_name][field] is not None and not isinstance(result[obj_name][field], str):
                    raise ValueError(f"{obj_name}.{field} has invalid type")
        if result["identity"]["compiler_version"] is not None and type(result["identity"]["compiler_version"]) not in (int, float):
            raise ValueError("identity.compiler_version has invalid type")
        for field in ("protocol",):
            if type(result["identity"][field]) is not int:
                raise ValueError(f"identity.{field} has invalid type")
        for field in ("plugin_version", "package_build_id"):
            if not isinstance(result["identity"][field], str):
                raise ValueError(f"identity.{field} has invalid type")
        for field in ("succeeded", "target_matched", "release_eligible"):
            if type(result["compile"][field]) is not bool:
                raise ValueError(f"compile.{field} has invalid type")
        if type(result["compile"]["compile_time_ms"]) is not int or result["compile"]["compile_time_ms"] < 0:
            raise ValueError("compile.compile_time_ms has invalid type")
        if not isinstance(result["compile"]["errors"], list):
            raise ValueError("compile.errors has invalid type")
        error_fields = {"file", "line", "column", "code", "text", "warning", "source",
                        "kind", "canonical_code", "canonical_message_en", "raw_text", "locale"}
        for error in result["compile"]["errors"]:
            if not isinstance(error, dict) or set(error) != error_fields:
                raise ValueError("compile error fields mismatch")
            for field in ("file", "code", "text", "source", "kind", "canonical_code",
                          "canonical_message_en", "raw_text", "locale"):
                if not isinstance(error[field], str):
                    raise ValueError(f"compile error {field} has invalid type")
            if type(error["line"]) is not int or type(error["column"]) is not int:
                raise ValueError("compile error location has invalid type")
            if type(error["warning"]) is not bool:
                raise ValueError("compile error warning has invalid type")
        for field in ("dialog_hits", "dialog_close_attempts", "known_technical_dialog_hits",
                      "exceptions_swallowed"):
            if type(result["interventions"][field]) is not int or result["interventions"][field] < 0:
                raise ValueError(f"interventions.{field} has invalid type")
        for field in ("license_or_eula_detected", "unknown_dialog_detected", "intervention_free",
                      "policy_compliant"):
            if type(result["interventions"][field]) is not bool:
                raise ValueError(f"interventions.{field} has invalid type")
        interventions = result["interventions"]
        if interventions["known_technical_dialog_hits"] > interventions["dialog_hits"]:
            raise ValueError("known technical dialog hits exceed total dialog hits")
        if interventions["dialog_close_attempts"] > interventions["dialog_hits"]:
            raise ValueError("dialog close attempts exceed deduplicated dialog hits")
        has_disqualifying_dialog = (
            interventions["license_or_eula_detected"] is True
            or interventions["unknown_dialog_detected"] is True
        )
        if ((interventions["known_technical_dialog_hits"] < interventions["dialog_hits"])
                != has_disqualifying_dialog):
            raise ValueError("dialog classification counts are inconsistent")
        expected_intervention_free = (
            interventions["dialog_hits"] == 0
            and interventions["dialog_close_attempts"] == 0
            and interventions["exceptions_swallowed"] == 0
            and interventions["license_or_eula_detected"] is False
            and interventions["unknown_dialog_detected"] is False
        )
        if interventions["intervention_free"] is not expected_intervention_free:
            raise ValueError("intervention_free evidence is inconsistent")
        expected_policy_compliant = (
            interventions["known_technical_dialog_hits"] == interventions["dialog_hits"]
            and interventions["dialog_close_attempts"] == interventions["dialog_hits"]
            and interventions["exceptions_swallowed"] == 0
            and interventions["license_or_eula_detected"] is False
            and interventions["unknown_dialog_detected"] is False
        )
        if interventions["policy_compliant"] is not expected_policy_compliant:
            raise ValueError("policy_compliant evidence is inconsistent")
        if result["wrapper"]["directory"] is not None and not isinstance(result["wrapper"]["directory"], str):
            raise ValueError("wrapper.directory has invalid type")
        notice = result["legal_notice"]
        for field in ("detected", "text_available", "accepted_terms"):
            if type(notice[field]) is not bool:
                raise ValueError(f"legal_notice.{field} has invalid type")
        if type(notice["text_length"]) is not int or notice["text_length"] < 0:
            raise ValueError("legal_notice.text_length has invalid type")
        if not isinstance(notice["available_buttons"], list) or not all(
                isinstance(button, str) and button for button in notice["available_buttons"]):
            raise ValueError("legal_notice.available_buttons has invalid type")
        if notice["accepted_terms"] is not False:
            raise ValueError("legal notice must never report accepted terms")
        if notice["detected"]:
            for field in ("classification", "window_class", "action"):
                if not isinstance(notice[field], str) or not notice[field]:
                    raise ValueError(f"legal_notice.{field} has invalid type")
            if notice["title"] is not None and not isinstance(notice["title"], str):
                raise ValueError("legal_notice.title has invalid type")
            if notice["classification"] != "community_edition_usage_notice":
                raise ValueError("legal_notice classification mismatch")
            if notice["window_class"] != "TCENotificationDialog":
                raise ValueError("legal_notice window class mismatch")
            if notice["action"] not in ("acknowledged", "left_open"):
                raise ValueError("legal_notice action mismatch")
            normalized_notice_button = notice["available_buttons"][0].replace("&", "").strip().lower() \
                if len(notice["available_buttons"]) == 1 else ""
            if normalized_notice_button != "ok":
                raise ValueError("legal_notice button evidence mismatch")
            if notice["action"] == "acknowledged":
                if interventions["known_technical_dialog_hits"] < 1:
                    raise ValueError("legal notice lacks known technical dialog evidence")
            elif interventions["unknown_dialog_detected"] is not True:
                raise ValueError("open legal notice lacks blocking evidence")
            if notice["text_available"]:
                if not isinstance(notice["text"], str) or not notice["text"]:
                    raise ValueError("legal_notice text is unavailable")
                if len(notice["text"]) > 4096:
                    raise ValueError("legal_notice text excerpt is too long")
                if notice["text_length"] != len(notice["text"]):
                    raise ValueError("legal_notice text length mismatch")
                if not isinstance(notice["text_sha256"], str) or not cls.V2_HASH_RE.fullmatch(
                        notice["text_sha256"]):
                    raise ValueError("legal_notice text hash mismatch")
                if hashlib.sha256(notice["text"].encode("utf-8")).hexdigest() != notice["text_sha256"]:
                    raise ValueError("legal_notice text hash verification failed")
            elif (notice["text"] is not None or notice["text_sha256"] is not None
                  or notice["text_length"] != 0):
                raise ValueError("unavailable legal notice text must be null")
        else:
            if (notice["classification"] is not None or notice["window_class"] is not None
                    or notice["title"] is not None or notice["text_available"] is not False
                    or notice["text"] is not None or notice["text_length"] != 0
                    or notice["text_sha256"] is not None or notice["available_buttons"] != []
                    or notice["action"] is not None):
                raise ValueError("absent legal_notice evidence is inconsistent")

    @classmethod
    def _validate_file_evidence(cls, value: object, name: str, nullable: bool = False) -> None:
        if not isinstance(value, dict) or set(value) != {"path", "size", "sha256"}:
            raise ValueError(f"{name} fields mismatch")
        if nullable and all(value[k] is None for k in value):
            return
        if not isinstance(value["path"], str) or type(value["size"]) is not int or value["size"] < 0:
            raise ValueError(f"{name} path/size invalid")
        if not isinstance(value["sha256"], str) or not cls.V2_HASH_RE.fullmatch(value["sha256"]):
            raise ValueError(f"{name} sha256 invalid")

    @staticmethod
    def _v2_client_failure(job_id: str, nonce: Optional[str], request_hash: Optional[str],
                           failure_code: str, message: str, evidence: Optional[dict] = None) -> dict:
        return {
            "schema_version": 2, "protocol": 2, "job_id": job_id,
            "nonce": nonce, "request_hash": request_hash, "status": "client_failure",
            "success": False, "failure_code": failure_code,
            "errors": [{"text": message}],
            "_client_evidence": evidence or {"raw_result": None, "raw_result_size": None,
                                               "raw_result_sha256": None},
        }

    def get_logs(self) -> str:
        """Read the current logs."""
        log_files = sorted(self.LOG_DIR.glob("watch_*.log"))
        if not log_files:
            return ""
        try:
            return log_files[-1].read_text(encoding="utf-8")
        except IOError:
            return ""


# Example usage
