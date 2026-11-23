(
set -euo pipefail
business_uid=$(id -u ctrsvc)
sudo systemd-run --user --machine=ctrsvc@.host --pty --wait --collect \
    --service-type=exec --expand-environment=no --working-directory=/home/ctrsvc \
    /usr/bin/env -i HOME=/home/ctrsvc USER=ctrsvc LOGNAME=ctrsvc \
    PATH=/usr/local/bin:/usr/bin TERM=xterm-256color HISTFILE=/dev/null \
    XDG_RUNTIME_DIR="/run/user/$business_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$business_uid/bus" \
    /usr/bin/bash --noprofile --norc -c 'umask 077; ctrsvc-check && exec /usr/bin/bash --noprofile --norc -i'
)
