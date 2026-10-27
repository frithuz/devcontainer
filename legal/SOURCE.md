# Corresponding Source

This image includes software under copyleft licenses (GPL, LGPL, and MPL-2.0), such as git
(compiled from source for this image), the bubblewrap and GStreamer/GLib libraries bundled with
Codex, MPL-2.0 Go modules, and Debian packages including Bash and coreutils. `manifest.tsv` lists
each component with its license and exact source provenance. The source image for a component
compiled for this image also holds the script that built it and the archives of the libraries
compiled into it.

The complete source of every copyleft component is published in the same registry repository as
this image, as source images: one per root program and exact version (on GHCR also tagged
`source-*`). Each published image, and each of its platform manifests, has a source index attached
(an OCI referrer of artifact type `application/vnd.frithuz.devcontainer.source.v1`) that lists its
source images by digest. The first entry, the `source record`, maps each component to its source
images. `oras` is installed in this image, so you can find the source from inside the container.

The image can't know its own digest, so start from the image you pulled:

```sh
image=<registry>/<repo>@<digest>
oras discover --artifact-type application/vnd.frithuz.devcontainer.source.v1 "$image"
oras manifest fetch "<registry>/<repo>@<source-index-digest>" |
  jq -r '.manifests[] | .digest + "  " + .annotations["org.opencontainers.image.title"]'
docker create --name source "<registry>/<repo>@<source-image-digest>" none
docker cp source:/source ./source && docker rm source
```

The commands work against either registry the image is published to, `quay.io/frithuz/devcontainer`
or its GHCR mirror, and against the sandbox kits built on it, `quay.io/frithuz/claude-kit` and
`quay.io/frithuz/codex-kit`, which carry the same source. Each source image's `/source/SOURCE.json` records where its source came from and
how it was verified.

An image built locally from this repository has no attached source index; the provenance in
`manifest.tsv` identifies the exact upstream sources.
