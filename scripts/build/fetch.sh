#!/usr/bin/env bash
# The download tools the fetch stage's dependents use, after apt-bootstrap.sh (Dockerfile's fetch
# stage): curl for releases, gpg for the apt signing key's fingerprint, and unzip for ast-grep's
# archive.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y --no-install-recommends curl gpg unzip
