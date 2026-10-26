# The image's system and agents, after apt-bootstrap.nu and python3-shim.nu (Dockerfile's image
# stage, step 2): apt packages, the locale, the shared directories, the agent user, and the
# agent CLIs.
$env.DEBIAN_FRONTEND = 'noninteractive'
let arch = dpkg --print-architecture | str trim

apt-get upgrade -y
let packages = [
  bash ca-certificates curl less locales openssh-client sudo-rs
  media-types netbase tzdata
  libatomic1
  libbz2-1.0 libdb5.3t64 libffi8 libgdbm6t64 liblzma5 libmpdec4 libncursesw6
  libreadline8t64 libsqlite3-0 libssl3t64 libtinfo6 libuuid1 libzstd1 zlib1g
]
apt-get install -y --no-install-recommends ...$packages

# git from the git-core PPA and Docker Engine from Docker's repository.
let codename = open --raw /etc/os-release | lines
  | where $it starts-with 'VERSION_CODENAME=' | first
  | str replace 'VERSION_CODENAME=' '' | str trim --char '"'
$"Types: deb
URIs: https://ppa.launchpadcontent.net/git-core/ppa/ubuntu
Suites: ($codename)
Components: main
Signed-By: /etc/apt/keyrings/git-core.asc
" | save /etc/apt/sources.list.d/git-core.sources
$"Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ($codename)
Components: stable
Architectures: ($arch)
Signed-By: /etc/apt/keyrings/docker.asc
" | save /etc/apt/sources.list.d/docker.sources
apt-get update
apt-get install -y --no-install-recommends git
(apt-get install -y --no-install-recommends
  docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io)

# No apt installs follow, so record the exact .deb URL and checksum of every installed
# package (base image included) from the package lists.
mkdir /legal/provenance
# The python3 shim is this project's own package, not from a repository.
let installed = dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}=${Version}\n' | lines
  | each {|line| $line | split row --regex '\s+' }
  | where {|fields| $fields.0 == 'ii' and not ($fields.1 starts-with 'devcontainer-') }
  | each {|fields| $fields.1 }
apt-get download --print-uris ...$installed | save /legal/provenance/apt-uris.txt
let recorded = open --raw /legal/provenance/apt-uris.txt | lines | length
if $recorded != ($installed | length) {
  error make {msg: $"apt-uris.txt has ($recorded) entries for ($installed | length) packages"}
}

# The locale the ENV below selects, and the copied shared libraries.
locale-gen en_US.UTF-8
ldconfig

# Shared GOPATH: root:staff, group-writable, setgid.
mkdir /go/src /go/bin
chown -R root:staff /go
chmod -R 775 /go
chmod 2775 /go /go/src /go/bin
go version

# Rename the stock ubuntu user to agent, with nu as its login shell; passwordless sudo that
# keeps PATH.
usermod --login agent --home /home/agent --move-home ubuntu
groupmod --new-name agent ubuntu
# Only docker and staff: drop the stock ubuntu user's adm, sudo, cdrom, ... groups.
usermod --groups docker,staff agent
"/usr/local/bin/nu\n" | save --append /etc/shells
usermod --shell /usr/local/bin/nu agent
let sudoers = open --raw /etc/sudoers | lines | where $it !~ '^Defaults\s+secure_path' | append ''
  | str join "\n"
$sudoers | save --force /etc/sudoers
if (open --raw /etc/sudoers | str contains secure_path) {
  error make {msg: 'secure_path still set in /etc/sudoers'}
}
# visudo -c accepts an empty file, so check that the drop-in below is still included.
if not (open --raw /etc/sudoers | lines | any {|line| $line == '@includedir /etc/sudoers.d' }) {
  error make {msg: '/etc/sudoers no longer includes /etc/sudoers.d'}
}
r#'Defaults env_keep += "PATH HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY http_proxy https_proxy ftp_proxy no_proxy"
agent ALL=(ALL) NOPASSWD:ALL
'# | save /etc/sudoers.d/agent
chmod 0440 /etc/sudoers /etc/sudoers.d/agent
visudo -c
install -d -o agent -g agent /home/agent/workspace

# Shared /usr/local/bin and PNPM_HOME: the directories only, never recursively.
chown root:staff /usr/local/bin
chmod 2775 /usr/local/bin
let pnpm_home = '/usr/local/share/pnpm'
mkdir $"($pnpm_home)/global" $"($pnpm_home)/store"
chown -R root:staff $pnpm_home
chmod 2775 $pnpm_home $"($pnpm_home)/global" $"($pnpm_home)/store"

# Agent CLIs, installed as agent so they can self-update. setpriv rather than sudo: Claude
# Code's installer refuses to run under sudo.
let as_agent = [--reuid=agent --regid=agent --init-groups env HOME=/home/agent USER=agent LOGNAME=agent]
http get https://claude.ai/install.sh | setpriv ...$as_agent bash
http get https://chatgpt.com/codex/install.sh | setpriv ...$as_agent CODEX_NON_INTERACTIVE=1 sh
# The installer runs codex once, leaving arg0 temp dirs. In a lower image layer they
# can't be renamed away (overlayfs EXDEV), so codex warns on every start.
rm -rf /home/agent/.codex/tmp
# Runtime leftovers: Claude Code's socket directory and Node's compile cache.
rm -rf /tmp/cc-socks /tmp/node-compile-cache
# Chained links, so the agents resolve for root too and survive self-updates.
ln -s /home/agent/.local/bin/claude /home/agent/.local/bin/codex /usr/local/bin/
