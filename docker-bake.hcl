# Shared by ci.yml and publish.yml (through docker/github-builder's bake.yml) and local builds.
#
# Local builds for the native platform only:
#   NATIVE=1 docker buildx bake image --load
#   NATIVE=1 docker buildx bake preflight

# Changes on every scheduled run to invalidate the apt and agent-installer layers.
variable "REFRESH" {
  default = ""
}

# Project revision recorded in /legal/manifest.tsv; CI passes the commit SHA. With
# REPOSITORY_URL, it also sets the images' source, revision, and documentation permalink, and
# the permalinks to build scripts in /legal/source.tsv.
variable "REVISION" {
  default = ""
}

# This repository's web URL; CI passes it.
variable "REPOSITORY_URL" {
  default = ""
}

# The image stage's base, as pinned in its FROM line; CI reads them from the Dockerfile.
variable "BASE_NAME" {
  default = ""
}

variable "BASE_DIGEST" {
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
    REFRESH        = REFRESH
    REVISION       = REVISION
    REPOSITORY_URL = REPOSITORY_URL
  }
}

target "image" {
  inherits = ["_common"]
  target   = "image"
  tags     = [TAG]
  # Left out when the build doesn't say, rather than set empty.
  labels = merge(
    REVISION != "" && REPOSITORY_URL != "" ? {
      "org.opencontainers.image.source"        = REPOSITORY_URL
      "org.opencontainers.image.revision"      = REVISION
      "org.opencontainers.image.documentation" = "${REPOSITORY_URL}/blob/${REVISION}/docs/usage.md"
    } : {},
    BASE_NAME != "" && BASE_DIGEST != "" ? {
      "org.opencontainers.image.base.name"   = BASE_NAME
      "org.opencontainers.image.base.digest" = BASE_DIGEST
    } : {},
  )
}

target "preflight" {
  inherits = ["_common"]
  target   = "preflight"
  output   = ["type=local,dest=out/preflight"]
}

# The scripts' data files (scripts/*.yaml), validated against scripts/schemas/ and converted to
# JSON in out/config/. The image builds it itself; this target is for checking
# the files on their own: docker buildx bake config
target "config" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "config"
  platforms  = platforms(true)
  output     = ["type=local,dest=out/config"]
}
