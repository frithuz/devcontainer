# Codex's legal record for the kit (codex.dockerfile's legal stage), into /out/legal. Docker's
# mixin ships no notices, so this takes Codex's LICENSE and NOTICE from its release tag, and the
# license texts of the ripgrep it bundles from ripgrep's tag, at the version Codex's package
# manifest for rg pins. Writes the image's manifest (/mnt/manifest.tsv) with both rows added. The
# package's bwrap is the image's own, recorded as Debian's bubblewrap package already.
let package = open /mnt/codex/codex-package.json
let version = $package.version
let pinned = $env.MIXIN | parse --regex ':(?<tag>[0-9]+\.[0-9]+\.[0-9]+)@' | get tag.0
if $version != $pinned {
  error make {msg: $"the mixin's package is Codex ($version), not the pinned ($pinned)"}
}
let arch = $env.TARGETARCH
let tag = $"rust-v($version)"

let manifest = open --raw /mnt/manifest.tsv | lines
if ($manifest | any {|line| $line starts-with "codex\t" }) {
  error make {msg: 'the image already records Codex; pin an image without agents'}
}

# Files from <repo> at <ref> into /legal/attribution/<component> (staged under /out), with a
# SOURCE record of where each came from, as scripts/collect-legal.sh records them. Returns the
# notices' paths in the kit.
def fetch [component: string, repo: string, ref: string, license: string, ...paths: string] {
  let dir = $"/out/legal/attribution/($component)"
  mkdir $dir
  let files = $paths | each {|path|
    let url = $"https://raw.githubusercontent.com/($repo)/($ref)/($path)"
    let file = $"($dir)/($path | path basename)"
    http get --raw $url | save $file
    $"  - path: ($path)\n    url: https://github.com/($repo)/blob/($ref)/($path)\n    sha256: (open --raw $file | hash sha256)\n"
  }
  $"component: ($component)\nrepository: https://github.com/($repo)\nref: ($ref)\nlicense: ($license)\nfiles:\n($files | str join)"
    | save $"($dir)/SOURCE"
  $paths | each {|path| $"/legal/attribution/($component)/($path | path basename)" } | str join ' '
}

let codex_notices = fetch codex openai/codex $tag Apache-2.0 LICENSE NOTICE
let codex_sha = open --raw /mnt/codex/codex | hash sha256

# Codex's package takes rg from a DotSlash manifest that names the ripgrep release per platform.
let rg_platform = match $arch {
  amd64 => 'linux-x86_64'
  arm64 => 'linux-aarch64'
  _ => { error make {msg: $"unsupported TARGETARCH: ($arch)"} }
}
let dotslash = http get --raw $"https://raw.githubusercontent.com/openai/codex/($tag)/scripts/codex_package/rg"
  | lines | where {|line| not ($line starts-with '#!') } | str join "\n" | from json
let rg_version = $dotslash.platforms | get $rg_platform | get path
  | parse --regex '^ripgrep-(?<version>[0-9.]+)-' | get version.0
let rg_notices = fetch ripgrep BurntSushi/ripgrep $rg_version 'Unlicense OR MIT' COPYING LICENSE-MIT UNLICENSE

let release = $"https://github.com/openai/codex/releases/tag/($tag)"
let rows = [
  [codex $version $arch Apache-2.0 $codex_notices
    $"mixin:($env.MIXIN) release:($release) target:($package.target) binary-sha256:($codex_sha) paths: /opt/codex /usr/local/bin/codex"]
  [ripgrep $rg_version $arch 'Unlicense OR MIT' $rg_notices
    $"embedded-in:codex source:https://github.com/BurntSushi/ripgrep/tree/($rg_version) paths: /opt/codex/codex-path/rg"]
] | each {|row| $row | str join "\t" }
$manifest | append $rows | each {|line| $"($line)\n" } | str join | save /out/legal/manifest.tsv
print $"legal: codex ($version) ($package.target), ripgrep ($rg_version)"
