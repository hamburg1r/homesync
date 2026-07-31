#!/usr/bin/env bash
# Phone-free Flutter guardrail (mirrors backend `uv run pytest`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/mobile"

echo "==> flutter pub get"
flutter pub get

echo "==> build_runner (codegen not in VCS)"
flutter pub run build_runner build

echo "==> flutter analyze"
flutter analyze

echo "==> flutter test"
flutter test

echo "mobile_check OK"
