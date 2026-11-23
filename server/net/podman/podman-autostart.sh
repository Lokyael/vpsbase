(
set -euo pipefail
ctrsvc-check
systemctl --user enable --now podman-restart.service
podman --remote=false info --format '{{.Store.GraphRoot}}'
)
