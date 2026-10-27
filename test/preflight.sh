#!/usr/bin/env bash
# Runs the smoke tests and exports their report, status, and the image's manifest.tsv to
# /tmp/out (Dockerfile's preflight-run stage). In test/, so it isn't an image build input.
set -euo pipefail

mkdir /tmp/out
# A failing test run records its status instead of stopping the script.
status=0
bash /mnt/src/test/smoke.sh 2>&1 | tee /tmp/out/smoke.txt || status=$?
echo "$status" >/tmp/out/smoke-status
cp /legal/manifest.tsv /tmp/out/manifest.tsv
