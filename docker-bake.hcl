# Shared by ci.yml and publish.yml (through docker/github-builder's bake.yml) and local builds.
#
# Local builds for the native platform only:
#   NATIVE=1 docker buildx bake image --load
#   NATIVE=1 docker buildx bake preflight

# Changes on every scheduled run to invalidate the apt and agent-installer layers.
variable "REFRESH" {
  default = ""
}

# Project revision recorded in /legal/manifest.tsv; CI passes the commit SHA.
variable "REVISION" {
  default = ""
}

# Build only for the host's architecture (as linux/<arch>).
variable "NATIVE" {
  type    = bool
  default = false
}

variable "TAG" {
  default = "devcontainer:local"
}

function "platforms" {
  params = [native]
  result = native ? ["linux/${split("/", BAKE_LOCAL_PLATFORM)[1]}"] : ["linux/amd64", "linux/arm64"]
}

group "default" {
  targets = ["image"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = platforms(NATIVE)
  args = {
    REFRESH  = REFRESH
    REVISION = REVISION
  }
}

target "image" {
  inherits = ["_common"]
  target   = "image"
  tags     = [TAG]
}

target "preflight" {
  inherits = ["_common"]
  target   = "preflight"
  output   = ["type=local,dest=out"]
}
