from __future__ import annotations

import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


DIST = Path("dist")
EXPECTED_SDIST_FILES = {
    "delphi_compile_gate.py",
    "LICENSE",
    "pyproject.toml",
    "README.md",
    "INSTALLATION.md",
    "AGENTS.md",
    "ASSISTANT_GUIDE.md",
    "KNOWN_ISSUES.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "RELEASE_CHECKLIST.md",
    "SECURITY.md",
    "Src/DelphiCompileGate.BuildInfo.pas",
    "Src/DelphiCompileGate.IdeCompat.inc",
    "Src/DelphiCompileGate.ProtocolV2.pas",
    "Package/DelphiCompileGate.dpk",
    "Package/DelphiCompileGate.dproj",
    "examples/HelloGate/HelloGate.dpr",
    "examples/HelloGate/src/HelloGate.Greeting.pas",
    "tests/test_protocol_v2.py",
    "tests/fixtures/nested_source_metadata.xml",
    "tests/fixtures/capture_scope_project/ExampleProject/src/ScriptEngine.pas",
}
REQUIRED_SDIST_TREES = ("Src/", "Package/", "examples/", "tests/", "tests/fixtures/")
FORBIDDEN_PARTS = {
    ".git",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "__pycache__",
    "run",
    "temp",
    "build",
    "dist",
    "bin",
    "obj",
    "debug",
    "release",
    "win32",
    "win64",
    "win64x",
    "android",
    "android64",
    "iosdevice64",
    "iossimulator64",
    "osx64",
}
FORBIDDEN_SUFFIXES = {
    ".pyc",
    ".pyo",
    ".dcu",
    ".dcuil",
    ".dcp",
    ".bpl",
    ".drc",
    ".map",
    ".rsm",
    ".tds",
    ".dres",
    ".res",
    ".exe",
    ".dll",
    ".so",
    ".a",
    ".o",
    ".obj",
    ".lib",
    ".exp",
    ".ilc",
    ".ild",
    ".ilf",
    ".ils",
    ".pem",
    ".key",
    ".pfx",
    ".p12",
    ".crt",
    ".cer",
}


def one_artifact(pattern: str) -> Path:
    matches = list(DIST.glob(pattern))
    if len(matches) != 1:
        raise AssertionError(f"Expected one {pattern} artifact, found: {matches}")
    return matches[0].resolve()


def verify_wheel(wheel: Path) -> None:
    with zipfile.ZipFile(wheel) as archive:
        files = [PurePosixPath(name) for name in archive.namelist() if not name.endswith("/")]
    payload = {
        path.as_posix()
        for path in files
        if not any(part.endswith(".dist-info") for part in path.parts)
    }
    if payload != {"delphi_compile_gate.py"}:
        raise AssertionError(f"Unexpected wheel payload: {sorted(payload)}")


def relative_sdist_files(sdist: Path) -> tuple[str, set[str]]:
    with tarfile.open(sdist, "r:gz") as archive:
        members = archive.getmembers()
    if not members:
        raise AssertionError("The sdist is empty")
    roots = {PurePosixPath(member.name).parts[0] for member in members}
    if len(roots) != 1:
        raise AssertionError(f"The sdist must have one root directory: {sorted(roots)}")
    root = roots.pop()
    files = {
        PurePosixPath(*PurePosixPath(member.name).parts[1:]).as_posix()
        for member in members
        if member.isfile()
    }
    return root, files


def verify_sdist_files(sdist: Path) -> None:
    _, files = relative_sdist_files(sdist)
    missing = sorted(EXPECTED_SDIST_FILES - files)
    if missing:
        raise AssertionError(f"Missing expected sdist files: {missing}")
    missing_trees = [prefix for prefix in REQUIRED_SDIST_TREES if not any(name.startswith(prefix) for name in files)]
    if missing_trees:
        raise AssertionError(f"Missing expected sdist trees: {missing_trees}")

    forbidden = []
    for name in sorted(files):
        path = PurePosixPath(name)
        folded_parts = {part.casefold() for part in path.parts}
        folded_name = path.name.casefold()
        contains_secret = any(token in folded_name for token in ("secret", "credential"))
        is_env = folded_name == ".env" or folded_name.startswith(".env.")
        if (
            folded_parts & FORBIDDEN_PARTS
            or path.suffix.casefold() in FORBIDDEN_SUFFIXES
            or contains_secret
            or is_env
        ):
            forbidden.append(name)
    if forbidden:
        raise AssertionError(f"Forbidden files in sdist: {forbidden}")
    if not any(PurePosixPath(name).name == "LICENSE" for name in files):
        raise AssertionError("The sdist must contain the MIT LICENSE file")


def extract_install_and_test(sdist: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="delphi-compile-gate-sdist-") as temp_name:
        temp = Path(temp_name)
        extract_dir = temp / "extracted"
        extract_dir.mkdir()
        with tarfile.open(sdist, "r:gz") as archive:
            archive.extractall(extract_dir, filter="data")
        roots = list(extract_dir.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise AssertionError(f"Unexpected extracted sdist roots: {roots}")
        source = roots[0]

        venv = temp / "venv"
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
        python = venv / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
        subprocess.run(
            [str(python), "-m", "pip", "install", "--disable-pip-version-check", f"{sdist}[dev]"],
            check=True,
            cwd=temp,
        )
        subprocess.run(
            [str(python), "-I", "-c", "import delphi_compile_gate"],
            check=True,
            cwd=temp,
        )
        subprocess.run(
            [str(python), "-I", "-m", "pytest", "--import-mode=importlib", str(source / "tests")],
            check=True,
            cwd=temp,
        )


def main() -> None:
    wheel = one_artifact("*.whl")
    sdist = one_artifact("*.tar.gz")
    verify_wheel(wheel)
    verify_sdist_files(sdist)
    extract_install_and_test(sdist)
    print(f"Verified wheel and clean sdist install/test: {wheel.name}, {sdist.name}")


if __name__ == "__main__":
    main()
