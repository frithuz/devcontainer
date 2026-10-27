# Builds a pinned Go command, static, and copies the verified module's LICENSE beside it
# (Dockerfile's jv, task, and dnslookup stages). From the stage's ARGs: MODULE is
# <module path>@<version>, PACKAGE the command's directory in the module ('.' for its root), OUT
# the destination, and LDFLAGS (optional) the linker flags, where {version} stands for the
# module's version.
let path = $env.MODULE | split row '@' | first
let version = $env.MODULE | split row '@' | last
let package = if $env.PACKAGE == '.' { $path } else { $"($path)/($env.PACKAGE)" }
let ldflags = $env.LDFLAGS? | default '' | str replace --all '{version}' $version
with-env {CGO_ENABLED: '0', GOBIN: $env.OUT} {
  go install $"-ldflags=($ldflags)" $"($package)@($version)"
}
cp $"(go env GOMODCACHE | str trim)/($env.MODULE)/LICENSE" $"($env.OUT)/LICENSE"
