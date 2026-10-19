#!/usr/bin/env bash
# Fail when a UI view carries a raw visual value instead of a design token.
# The ledger is dev-docs/DESIGN-TOKENS.md; the source of truth is Theme.swift.
set -euo pipefail

cd "$(dirname "$0")/.."
exec python3 Scripts/check_design_tokens.py
