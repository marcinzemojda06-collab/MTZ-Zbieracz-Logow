#!/usr/bin/env python3
"""Build the verified RC2 replacement package. No uploads or network access."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.3.0-rc.2"
REVIEW = "validation/release-0.3.0-rc.2/release-validation.json"
REPOSITORY = "https://github.com/marcinzemojda06-collab/MTZ-Zbieracz-Logow"
RUNTIME = [
    "Uruchom-MTZ-Logi.cmd", "Instaluj-MTZ-Logi.cmd", "Instaluj-MTZ-Logi.ps1",
    "Launch-MTZ.ps1", "MTZ-Logi.ps1", "core.ps1", "session.ps1",
    "full-bundle.ps1", "Collect-Worker.ps1", "Restore-MTZ-Paczka.ps1",
    "bridge/Bridge.cs", "rozszerzenie/manifest.json", "rozszerzenie/common.js",
    "rozszerzenie/content.js", "rozszerzenie/service-worker.js",
    "rozszerzenie/README-PL.txt", "START-TUTAJ.txt", "INSTRUKCJA-PL.txt",
    "PRYWATNOSC-PL.txt", "ZMIANY-0.3.0-rc.2.txt", "WERYFIKACJA-PL.txt",
    "LICENSE.txt", "VERSION.json",
]
PACKAGE_DOCUMENTS = ["PODMIANA-PL.txt"]
SKIP_PARTS = {".git", "node_modules", "__pycache__", "dist", "Paczki", "Zadania"}


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(relative):
    posix = PurePosixPath(relative)
    if posix.is_absolute() or ".." in posix.parts or "\\" in relative:
        raise ValueError("Unsafe source path: " + relative)
    source = ROOT / relative
    if source.is_symlink() or not source.is_file():
        raise ValueError("Not a regular source file: " + relative)
    if not source.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError("Source path leaves the repository: " + relative)
    return source.read_bytes()


def read_json(data):
    return json.loads(data.decode("utf-8-sig"))


def read_evidence(spec, label):
    relative = spec["path"]
    if not relative.startswith("validation/release-" + VERSION + "/"):
        raise ValueError("Evidence must belong to this release: " + label)
    data = read_regular(relative)
    if sha_bytes(data) != spec["sha256"]:
        raise ValueError("Evidence changed since review: " + relative)
    return read_json(data)


def verified_files(expected, names, label):
    if set(expected) != set(names):
        raise ValueError("Review must cover exactly all " + label)
    result = {}
    for relative in names:
        data = read_regular(relative)
        if sha_bytes(data) != expected[relative]:
            raise ValueError("File changed since validation: " + relative)
        result[relative] = data
    return result


def check_launcher(report, spec, runtime, windows):
    if spec.get("exit_code") != 0:
        raise ValueError("Launcher test process did not succeed")
    minimum_checks = 70 if windows else 68
    if report.get("status") != "PASS" or report.get("launcherRevision") != VERSION:
        raise ValueError("Launcher report is not a passing result for " + VERSION)
    checks = report.get("checks", 0)
    if not isinstance(checks, int) or checks < minimum_checks:
        raise ValueError("Launcher report has too few completed checks")
    if len(report.get("checksPassed", [])) != checks:
        raise ValueError("Launcher report check count does not match its results")
    if report.get("launcherSha256") != sha_bytes(runtime["Uruchom-MTZ-Logi.cmd"]):
        raise ValueError("Tested CMD differs from the packaged CMD")
    if report.get("sharedLauncherSha256") != sha_bytes(runtime["Launch-MTZ.ps1"]):
        raise ValueError("Tested launcher differs from the packaged launcher")
    for field in ("actualGuiRun", "actualComShortcut", "actualAntivirusTest", "antivirusResolutionVerified"):
        if report.get(field) is not False:
            raise ValueError("Unexpected desktop/antivirus claim in launcher report: " + field)
    if windows:
        if report.get("actualWindowsRun") is not True or report.get("actualWindowsPowerShell51") is not True:
            raise ValueError("Windows PowerShell 5.1 launcher evidence is required")
        if not str(report.get("runtime", "")).startswith("5.1."):
            raise ValueError("Windows launcher report does not identify PowerShell 5.1")
        if report.get("nativeCmdPreflightRuns", 0) < 2:
            raise ValueError("Both Windows CMD preflight cases must run")


def validate_release():
    review_data = read_regular(REVIEW)
    review = read_json(review_data)
    if review.get("version") != VERSION or review.get("status") != "passed-with-explicit-platform-limitations":
        raise ValueError("This release has no passing RC2 review")
    if review.get("failed") != 0:
        raise ValueError("Release review reports failed checks")
    for field in ("native_windows_validated", "live_opera_validated", "antivirus_resolution_verified"):
        if review.get(field) is not False:
            raise ValueError("This candidate must retain its explicit unverified limit: " + field)
    source_commit = review.get("source_commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Review needs an exact tested source commit")

    runtime = verified_files(review["production_sha256"], RUNTIME, "runtime files")
    documents = verified_files(review["package_documents_sha256"], PACKAGE_DOCUMENTS, "package documents")
    version = read_json(runtime["VERSION.json"])
    if version.get("version") != VERSION or version.get("releaseStage") != "release-candidate":
        raise ValueError("Unexpected application version or release stage")
    if version.get("antivirusResolutionVerified") is not False:
        raise ValueError("VERSION.json must retain the unresolved antivirus status")

    evidence = review["evidence"]
    local = read_evidence(evidence["local_launcher"], "local launcher")
    windows = read_evidence(evidence["windows_launcher"], "Windows launcher")
    ci = read_evidence(evidence["windows_ci"], "Windows CI run")
    check_launcher(local, evidence["local_launcher"], runtime, windows=False)
    check_launcher(windows, evidence["windows_launcher"], runtime, windows=True)
    if ci.get("status") != "completed" or ci.get("conclusion") != "success":
        raise ValueError("Windows CI must have completed successfully")
    if ci.get("head_sha") != source_commit:
        raise ValueError("Windows CI did not test the reviewed source commit")
    run_url = ci.get("html_url", "")
    if not re.fullmatch(re.escape(REPOSITORY + "/actions/runs/") + r"[0-9]+", run_url):
        raise ValueError("Unexpected Windows CI run URL")
    return review, runtime, documents, local, windows, ci


def pack(path, entries):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for relative, data in sorted(entries.items()):
            entry = zipfile.ZipInfo(relative, (2026, 11, 6, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data, compresslevel=9)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("Archive CRC validation failed")
        if set(archive.namelist()) != set(entries):
            raise ValueError("Unexpected archive entry list")
        for relative, expected in entries.items():
            if archive.read(relative) != expected:
                raise ValueError("Archive content differs from verified bytes: " + relative)
    return {"name": path.name, "bytes": path.stat().st_size,
            "sha256": sha_bytes(path.read_bytes()), "files": len(entries)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--with-sources", action="store_true", help="Also package repository sources")
    args = parser.parse_args()
    review, runtime, documents, local, windows, ci = validate_release()
    manifest = {
        "application": "MTZ Zbieracz logow Minecrafta", "version": VERSION,
        "release_stage": "release-candidate", "source_commit": review["source_commit"],
        "native_windows_validated": False, "antivirus_resolution_verified": False,
        "validation": {
            "scope": "Launcher regression and Windows PowerShell 5.1 syntax; GUI/COM mocked; RAV unverified",
            "local_launcher_checks": local["checks"], "windows_launcher_checks": windows["checks"],
            "windows_ci_url": ci["html_url"], "release_review_sha256": sha_bytes(read_regular(REVIEW)),
        },
        "files": [{"path": rel, "bytes": len(data), "sha256": sha_bytes(data)}
                  for rel, data in sorted(runtime.items())],
        "package_documents": [{"path": rel, "bytes": len(data), "sha256": sha_bytes(data)}
                              for rel, data in sorted(documents.items())],
    }
    manifest_data = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    (ROOT / "release-manifest.json").write_bytes(manifest_data)
    entries = {"Aplikacja/" + rel: data for rel, data in runtime.items()}
    entries["Aplikacja/release-manifest.json"] = manifest_data
    entries.update(documents)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result = [pack(output / ("MTZ-Zbieracz-Logow-Podmiana-" + VERSION + ".zip"), entries)]
    if args.with_sources:
        source_entries = {}
        for path in ROOT.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(ROOT)
            if any(part in SKIP_PARTS for part in rel.parts) or path.suffix == ".pyc":
                continue
            if path.resolve().is_relative_to(output):
                continue
            if path.name == "ustawienia.json" or path.suffix == ".lock":
                continue
            source_entries["MTZ-Zbieracz-Logow-Zrodla/" + rel.as_posix()] = read_regular(rel.as_posix())
        result.append(pack(output / ("MTZ-Zbieracz-Logow-Zrodla-" + VERSION + ".zip"), source_entries))
    (output / "release-files.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text("".join(item["sha256"] + "  " + item["name"] + "\n" for item in result), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
