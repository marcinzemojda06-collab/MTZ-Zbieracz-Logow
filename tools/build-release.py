#!/usr/bin/env python3
"""Create the reviewed MTZ collector release; no uploads or network access."""
from pathlib import Path
import argparse
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.3.0-rc.1"
RUNTIME = [
    "Uruchom-MTZ-Logi.cmd", "Instaluj-MTZ-Logi.cmd", "Instaluj-MTZ-Logi.ps1",
    "Launch-MTZ.ps1", "MTZ-Logi.ps1", "core.ps1", "session.ps1",
    "full-bundle.ps1", "Collect-Worker.ps1", "Restore-MTZ-Paczka.ps1",
    "bridge/Bridge.cs", "rozszerzenie/manifest.json", "rozszerzenie/common.js",
    "rozszerzenie/content.js", "rozszerzenie/service-worker.js",
    "rozszerzenie/README-PL.txt", "START-TUTAJ.txt", "INSTRUKCJA-PL.txt",
    "PRYWATNOSC-PL.txt", "ZMIANY-0.3.0-rc.1.txt", "WERYFIKACJA-PL.txt",
    "LICENSE.txt", "VERSION.json",
]
SKIP_PARTS = {".git", "node_modules", "__pycache__", "dist", "Paczki", "Zadania"}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def pack(path, files, prefix):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in sorted(files):
            src = ROOT / rel
            if src.is_symlink() or not src.is_file():
                raise ValueError("Not a regular source file: " + rel)
            entry = zipfile.ZipInfo(prefix + "/" + rel, (2026, 11, 6, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(entry, src.read_bytes(), compresslevel=9)
    with zipfile.ZipFile(path) as z:
        if z.testzip() is not None:
            raise ValueError("Archive CRC validation failed")
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": sha(path), "files": len(files)}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    version = json.loads((ROOT / "VERSION.json").read_text(encoding="utf-8-sig"))
    if version["version"] != VERSION or version["releaseStage"] != "release-candidate":
        raise ValueError("Unexpected version or release stage")
    review = json.loads((ROOT / "validation/release-0.3.0-rc.1/release-validation.json").read_text(encoding="utf-8-sig"))
    if review["status"] != "passed-with-explicit-platform-limitations":
        raise ValueError("The release has not passed the required checks")
    for rel, expected in review["production_sha256"].items():
        if sha(ROOT / rel) != expected:
            raise ValueError("Production file changed since validation: " + rel)
    for rel in RUNTIME:
        if not (ROOT / rel).is_file():
            raise ValueError("Missing runtime file: " + rel)
    manifest = {
        "application": "MTZ Zbieracz logow Minecrafta", "version": VERSION,
        "native_windows_validated": False, "files": [
            {"path": rel, "bytes": (ROOT / rel).stat().st_size, "sha256": sha(ROOT / rel)}
            for rel in sorted(RUNTIME)
        ]
    }
    (ROOT / "release-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    runtime_files = RUNTIME + ["release-manifest.json"]
    source_files = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT)
        if any(part in SKIP_PARTS for part in rel.parts) or p.suffix == ".pyc":
            continue
        if rel.parts[0] == "validation" and len(rel.parts) > 1 and rel.parts[1] != "release-0.3.0-rc.1":
            continue
        if rel.parts[0] == "walidacja-launchera" and p.name != "Test-Launcher.ps1":
            continue
        if p.name == "ustawienia.json" or p.suffix == ".lock":
            continue
        source_files.append(rel.as_posix())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result = [
        pack(output / ("MTZ-Zbieracz-Logow-Windows-" + VERSION + ".zip"), runtime_files, "MTZ-Zbieracz-Logow"),
        pack(output / ("MTZ-Zbieracz-Logow-Zrodla-" + VERSION + ".zip"), source_files, "MTZ-Zbieracz-Logow-Zrodla"),
    ]
    (output / "release-files.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text("".join(x["sha256"] + "  " + x["name"] + "\n" for x in result), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))

if __name__ == "__main__":
    main()
