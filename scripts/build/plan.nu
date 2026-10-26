# Resolves every root program's exact inputs from the manifests (source.Dockerfile's plan-run).
let manifests = glob /mnt/manifests/**/manifest.tsv | sort
let reuse = $env.SOURCE_REUSE? | default ''
let reuse_args = if ($reuse | is-empty) { [] } else { [--reuse $reuse] }
bash /mnt/scripts/plan-sources.sh --config /mnt/config --out /out ...$reuse_args ...$manifests
