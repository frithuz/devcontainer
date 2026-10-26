# Runs a Dockerfile step's scripts in order. Each is printed to the build log between a header,
# which carries its sha256, and a footer, so the log shows exactly what ran without the image's
# history recording it. Scripts are mounted under /mnt/src at their repository paths.
def main [...scripts: path] {
  let rule = '' | fill --character '-' --width 72
  for script in $scripts {
    let name = $script | str replace --regex '^/mnt/src/' ''
    let text = open --raw $script
    print ([
      $rule
      $"Script filename: ($name)"
      $"sha256: ($text | hash sha256)"
      $rule
      ($text | str trim --right)
      $rule
      $"End of script: ($name)"
      $rule
    ] | str join "\n")
    nu $script
  }
}
