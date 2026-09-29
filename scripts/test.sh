#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run --build-system native NotificationCoreTests
python3 scripts/test-hooks.py
