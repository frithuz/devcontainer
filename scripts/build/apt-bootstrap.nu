# Makes every apt source HTTPS and installs ca-certificates, trusting the bundle mounted at
# /tmp/bootstrap-ca.crt: the base image's Ubuntu sources use plain HTTP and it has no CA
# certificates. Shared by the Dockerfile's image stage and source.Dockerfile's fetch-apt.
$env.DEBIAN_FRONTEND = 'noninteractive'
# Read each file fully before saving over it: save truncates it while a pipeline still reads.
let ubuntu_sources = '/etc/apt/sources.list.d/ubuntu.sources'
let https_sources = open --raw $ubuntu_sources
  | str replace --all --regex '(?m)^URIs: http://' 'URIs: https://'
$https_sources | save --force $ubuntu_sources
let plain = glob /etc/apt/{sources.list,sources.list.d/*}
  | each {|file| open --raw $file | lines } | flatten
  | where $it =~ '^\s*(URIs:|deb)' and $it =~ 'http://'
if ($plain | is-not-empty) {
  error make {msg: $"plain HTTP apt source left: ($plain | str join ', ')"}
}
let bootstrap = [-o Acquire::https::CAInfo=/tmp/bootstrap-ca.crt]
apt-get ...$bootstrap update
apt-get ...$bootstrap install -y --no-install-recommends ca-certificates
