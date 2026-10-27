# The apt signing key for Docker's repository, checked against its published fingerprint
# (Dockerfile's apt-keys stage).
$env.GNUPGHOME = (mktemp -d)
mkdir /keys
http get https://download.docker.com/linux/debian/gpg | save /keys/docker.asc
# The fingerprint is field 10 of the fpr line after each pub line.
def check [file: string, expected: string] {
  let rows = gpg --show-keys --with-colons $file | lines
  let fingerprints = $rows | enumerate | where {|row| $row.item starts-with 'pub:' }
    | each {|row| $rows | get ($row.index + 1) | split row ':' | get 9 }
    | str join "\n"
  if $fingerprints != $expected {
    error make {msg: $"unexpected key in ($file): ($fingerprints)"}
  }
}
check /keys/docker.asc 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
