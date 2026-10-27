# Downloads Task's release archive for TARGETARCH, checks it against the SHA-256 the stage pins
# for that architecture, and unpacks the binary and its LICENSE to /opt/task (Dockerfile's task
# stage). SOURCE records the archive, for scripts/collect-legal.sh (install: release).
let version = $env.VERSION
let arch = $env.TARGETARCH
let expected = match $arch {
  amd64 => $env.SHA256_AMD64
  arm64 => $env.SHA256_ARM64
  _ => { error make {msg: $"task: no pinned archive for ($arch)"} }
}
let url = $"https://github.com/go-task/task/releases/download/v($version)/task_linux_($arch).tar.gz"
let archive = http get --raw $url
let digest = $archive | hash sha256
if $digest != $expected {
  error make {msg: $"task: ($url) has sha256 ($digest), expected ($expected)"}
}
let work = mktemp --directory
$archive | save $"($work)/task.tar.gz"
mkdir /opt/task
^tar -xzf $"($work)/task.tar.gz" -C /opt/task task LICENSE
rm --recursive $work
$"component: task
repository: https://github.com/go-task/task
ref: v($version)
release: ($url)
sha256: ($digest)
" | save /opt/task/SOURCE
