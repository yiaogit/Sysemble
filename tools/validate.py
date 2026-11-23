#!/usr/bin/env python3
"""Validate Sysemble examples against the JSON Schemas in spec/.

Usage:
    python tools/validate.py

Requires: jsonschema, pyyaml
    pip install jsonschema pyyaml
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    try:
        import yaml
        from jsonschema import Draft202012Validator
        from jsonschema.exceptions import SchemaError
    except ImportError:
        fail("missing dependencies; run: pip install jsonschema pyyaml")
        return 2

    schemas = {}
    for name in ("buildspec", "module"):
        path = ROOT / "spec" / f"{name}.schema.json"
        schema = load_json(path)
        try:
            Draft202012Validator.check_schema(schema)
        except SchemaError as exc:
            fail(f"{path.relative_to(ROOT)} is not a valid schema: {exc.message}")
            return 1
        schemas[name] = Draft202012Validator(schema)
        print(f"ok    {path.relative_to(ROOT)}")

    failures = 0
    for path in sorted((ROOT / "examples").glob("*.yaml")):
        with path.open(encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
        errors = sorted(schemas["buildspec"].iter_errors(document), key=lambda e: list(e.path))
        if errors:
            failures += 1
            print(f"FAIL  {path.relative_to(ROOT)}")
            for error in errors:
                location = "/".join(str(part) for part in error.path) or "<root>"
                print(f"      {location}: {error.message}")
        else:
            print(f"ok    {path.relative_to(ROOT)}")

    modules_dir = ROOT / "examples" / "modules"
    if modules_dir.is_dir():
        for path in sorted(modules_dir.glob("*.yaml")):
            with path.open(encoding="utf-8") as handle:
                document = yaml.safe_load(handle)
            errors = sorted(schemas["module"].iter_errors(document), key=lambda e: list(e.path))
            if errors:
                failures += 1
                print(f"FAIL  {path.relative_to(ROOT)}")
                for error in errors:
                    location = "/".join(str(part) for part in error.path) or "<root>"
                    print(f"      {location}: {error.message}")
            else:
                print(f"ok    {path.relative_to(ROOT)}")

    if failures:
        print(f"\n{failures} file(s) failed validation", file=sys.stderr)
        return 1
    print("\nall specs valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
