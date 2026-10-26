# Runs the smoke tests and exports their report, status, and the image's manifest.tsv to
# /tmp/out (Dockerfile's preflight-run stage). In test/, so it isn't an image build input.
mkdir /tmp/out
# complete keeps a failing exit status instead of stopping the script.
let smoke = bash /mnt/src/test/smoke.sh o+e>| complete
print $smoke.stdout
$smoke.stdout | save /tmp/out/smoke.txt
$"($smoke.exit_code)\n" | save /tmp/out/smoke-status
cp /legal/manifest.tsv /tmp/out/manifest.tsv
