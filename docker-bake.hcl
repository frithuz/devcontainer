# Shared by ci.yml and publish.yml (through docker/github-builder's bake.yml) and local builds.
#
# Local builds for the native platform only:
#   NATIVE=1 docker buildx bake image --load
#   NATIVE=1 docker buildx bake preflight
#
# Source images (docs/legal.md#source-images), from the manifests preflight exports:
#   scripts/build-sources.sh

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

# Directory source-plan searches for manifest.tsv files (one per platform).
variable "MANIFESTS" {
  default = "out/preflight"
}

# Repository the source-* tags are applied to; a registry repository when pushing.
variable "SOURCE_REPOSITORY" {
  default = "devcontainer"
}

# Push source images to SOURCE_REPOSITORY instead of writing OCI layouts to out/sources/oci/.
variable "SOURCE_PUSH" {
  type    = bool
  default = false
}

# Registry repository whose existing source-* tags source-plan reuses instead of rebuilding.
variable "SOURCE_REUSE" {
  default = ""
}

# This repository's URL and the last commit that changed scripts/build-source-image.sh, part of
# every source image's key. scripts/build-sources.sh and CI set them from git.
variable "SOURCE_RECIPE_REPOSITORY" {
  default = ""
}

variable "SOURCE_RECIPE_REVISION" {
  default = ""
}

function "platforms" {
  params = [native]
  result = native ? ["linux/${split("/", BAKE_LOCAL_PLATFORM)[1]}"] : ["linux/amd64", "linux/arm64"]
}

# Source images are reproducible: fixed timestamps, so identical inputs give identical digests.
function "source_output" {
  params = [tag]
  result = SOURCE_PUSH ? ["type=registry,rewrite-timestamp=true"] : ["type=oci,dest=out/sources/oci/${tag},tar=false,rewrite-timestamp=true"]
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
  output   = ["type=local,dest=out/preflight"]
}

# The apt signing keys, for the source images' apt fetch stage. A single platform: the keys are
# the same everywhere, and one platform keeps the fetch from running once per platform.
target "apt-keys" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "apt-keys"
  platforms  = platforms(true)
}

# The scripts' data files (scripts/*.yaml), validated against scripts/schemas/ and converted to
# JSON in out/config/. The image and source-plan build it themselves; this target is for checking
# the files on their own: docker buildx bake config
target "config" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "config"
  platforms  = platforms(true)
  output     = ["type=local,dest=out/config"]
}

# Resolves the source images the manifests need and exports out/sources/: plan.tsv, plans/, and
# sources.hcl with a target per source image to build (group "sources").
target "source-plan" {
  context         = "."
  dockerfile      = "source.Dockerfile"
  target          = "plan"
  contexts        = { manifests = MANIFESTS, config = "target:config" }
  no-cache-filter = ["plan-run"]
  args = {
    SOURCE_RECIPE_REPOSITORY = SOURCE_RECIPE_REPOSITORY
    SOURCE_RECIPE_REVISION   = SOURCE_RECIPE_REVISION
    SOURCE_REUSE             = SOURCE_REUSE
  }
  output = ["type=local,dest=out/sources"]
}

# Base of the generated per-root targets, which add the root's plan (root-plan context), KIND,
# tag, annotations, and output.
target "source" {
  context    = "."
  dockerfile = "source.Dockerfile"
  target     = "source"
  platforms  = ["linux/amd64", "linux/arm64"]
  contexts   = { apt-keys = "target:apt-keys" }
  args       = { SOURCE_DATE_EPOCH = "0" }
  attest     = ["type=provenance,disabled=true", "type=sbom,disabled=true"]
}
