#!/usr/bin/env python3
"""Select the immutable trust and Stage 1 data for an image build."""
from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
PROFILES = {
    "production": {
        "trust": ROOT / "candidate-trust",
        "stage1": None,
    },
    "j714s-developer": {
        "trust": ROOT / "profiles/j714s-developer/candidate-trust",
        "stage1": ROOT / "profiles/j714s-developer/stage1-qualification.json",
    },
}


def select(name: str = "production") -> dict:
    try:
        return {"name": name, **PROFILES[name]}
    except (KeyError, TypeError):
        raise ValueError(f"unknown image profile: {name}") from None


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("trust", "stage1"):
        print("usage: image_profile.py trust|stage1 PROFILE", file=sys.stderr)
        return 64
    try:
        value = select(argv[2])[argv[1]]
    except ValueError as error:
        print(f"image_profile: {error}", file=sys.stderr)
        return 1
    print("" if value is None else value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
