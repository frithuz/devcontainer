# Makes every apt source HTTPS: the base image's Debian and DHI sources use plain HTTP. It ships
# ca-certificates, so the update trusts the installed store. Shared by the Dockerfile's image
# stage and source.Dockerfile's fetch-apt.
$env.DEBIAN_FRONTEND = 'noninteractive'
# Read each file fully before saving over it: save truncates it while a pipeline still reads.
for file in (glob /etc/apt/sources.list.d/*.sources) {
  let https_sources = open --raw $file
    | str replace --all --regex '(?m)^URIs: http://' 'URIs: https://'
  $https_sources | save --force $file
}
let plain = glob /etc/apt/{sources.list,sources.list.d/*}
  | each {|file| open --raw $file | lines } | flatten
  | where $it =~ '^\s*(URIs:|deb)' and $it =~ 'http://'
if ($plain | is-not-empty) {
  error make {msg: $"plain HTTP apt source left: ($plain | str join ', ')"}
}
apt-get update
