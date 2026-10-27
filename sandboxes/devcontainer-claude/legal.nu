# Claude Code's legal record for the kit (claude.dockerfile's legal stage), into /out/legal. Docker's
# mixin ships no notices, so this verifies the target's binary (/mnt/claude) against Anthropic's
# release manifest for the version the mixin is pinned to, takes Anthropic's notice (LICENSE.md)
# from the npm package of the same version, checked against its integrity, and writes the image's
# manifest (/mnt/manifest.tsv) with Claude Code's row added.
let version = $env.MIXIN | parse --regex ':(?<tag>[0-9]+\.[0-9]+\.[0-9]+)@' | get tag.0
let arch = $env.TARGETARCH
let platform = match $arch {
  amd64 => 'linux-x64'
  arm64 => 'linux-arm64'
  _ => { error make {msg: $"unsupported TARGETARCH: ($arch)"} }
}

let manifest = open --raw /mnt/manifest.tsv | lines
if ($manifest | any {|line| $line starts-with "claude\t" }) {
  error make {msg: 'the image already records Claude Code; pin an image without agents'}
}

let release = $"https://downloads.claude.ai/claude-code-releases/($version)/manifest.json"
let published = http get $release
let binary_sha = open --raw /mnt/claude | hash sha256
let expected = $published.platforms | get $platform | get checksum
if $binary_sha != $expected {
  error make {msg: $"claude ($version) ($platform) sha256 ($binary_sha) doesn't match ($release) \(($expected)\)"}
}

let npm = http get $"https://registry.npmjs.org/@anthropic-ai/claude-code/($version)"
let work = mktemp -d
http get --raw $npm.dist.tarball | save $"($work)/package.tgz"
let integrity = $"sha512-(^openssl dgst -sha512 -binary $"($work)/package.tgz" | ^base64 -w0)"
if $integrity != $npm.dist.integrity {
  error make {msg: $"claude's npm package doesn't match its registry integrity ($npm.dist.integrity)"}
}
^tar -xzf $"($work)/package.tgz" -C $work package/LICENSE.md

let attribution = '/out/legal/attribution/claude'
mkdir $attribution
cp $"($work)/package/LICENSE.md" $"($attribution)/LICENSE.md"
let notice_sha = open --raw $"($attribution)/LICENSE.md" | hash sha256
$"component: claude
repository: none \(proprietary)
ref: ($version) \(commit ($published.commit))
license: LicenseRef-Anthropic-Terms
files:
  - path: package/LICENSE.md
    url: ($npm.dist.tarball)
    integrity: ($npm.dist.integrity)
    sha256: ($notice_sha)
" | save $"($attribution)/SOURCE"

let row = [
  claude $version $arch LicenseRef-Anthropic-Terms /legal/attribution/claude/LICENSE.md
  $"mixin:($env.MIXIN) release:($release) commit:($published.commit) binary-sha256:($binary_sha) paths: /usr/local/bin/claude"
] | str join "\t"
$manifest | append $row | each {|line| $"($line)\n" } | str join | save /out/legal/manifest.tsv
print $"legal: claude ($version) ($platform), binary sha256 ($binary_sha)"
