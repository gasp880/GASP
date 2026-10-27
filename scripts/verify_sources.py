#!/usr/bin/env python3
"""Check distributed source hashes without reading or generating results."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Reject additional files in a clean source package",
    )
    args = parser.parse_args()
    manifest = json.loads((ROOT / "SOURCE_MANIFEST.json").read_text())
    expected = {"SOURCE_MANIFEST.json"}
    errors = []
    for row in manifest["files"]:
        name = row["path"]
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or name in expected:
            raise SystemExit("Invalid or duplicate manifest path")
        expected.add(name)
        path = ROOT / relative
        if not path.is_file() or path.is_symlink():
            errors.append(name + ": missing or symlink")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != row["sha256"]:
            errors.append(name + ": hash mismatch")
    if args.strict:
        actual = {
            str(p.relative_to(ROOT))
            for p in ROOT.rglob("*")
            if p.is_file() and ".git" not in p.relative_to(ROOT).parts
        }
        errors.extend(
            name + ": not in source manifest" for name in sorted(actual - expected)
        )
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Verified {len(manifest['files'])} distributed files.")


if __name__ == "__main__":
    main()
