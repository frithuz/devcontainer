# Validates each scripts/*.yaml against its schema, checks it for duplicate names, and converts
# it to /config/<name>.json (Dockerfile's config-run stage). scripts/ is mounted at /mnt/scripts.
mkdir /config
for schema in (glob /mnt/scripts/schemas/*.schema.json | sort) {
  let name = $schema | path basename | str replace --regex '\.schema\.json$' ''
  let yaml = $"/mnt/scripts/($name).yaml"
  print $"validating scripts/($name).yaml"
  jv $schema $yaml
  let data = open $yaml
  $data | to json | save $"/config/($name).json"
  # Names identify entries across every list in a file; a schema can't express that.
  let duplicates = $data | values | where ($it | describe) =~ '^(list|table)'
    | each {|list| $list | each {|entry| $entry.name? | default $entry.module? } }
    | flatten | uniq --repeated
  if ($duplicates | is-not-empty) {
    error make {msg: $"scripts/($name).yaml: duplicate names: ($duplicates | str join ', ')"}
  }
}
