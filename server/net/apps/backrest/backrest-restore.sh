(
set -euo pipefail
umask 077
IFS= read -r -p '仓库 URI 或本地仓库绝对路径: ' REPO_URI < /dev/tty || exit 1
[[ "$REPO_URI" == rclone:* || "$REPO_URI" == /* ]] \
  || { printf '请填写 rclone 仓库 URI 或本地绝对路径\n' >&2; exit 1; }
if [[ "$REPO_URI" == rclone:* ]]; then
    IFS= read -r -p '本次恢复所需 rclone.conf 绝对路径: ' RCLONE_CONFIG < /dev/tty || exit 1
    [[ "$RCLONE_CONFIG" == /* && -f "$RCLONE_CONFIG" && -r "$RCLONE_CONFIG" ]] \
      || { printf '无法读取指定的 rclone 配置\n' >&2; exit 1; }
    export RCLONE_CONFIG
fi
restic -r "$REPO_URI" snapshots
IFS= read -r -p '已核对的快照 ID（不使用 latest）: ' SNAPSHOT_ID < /dev/tty || exit 1
[[ "$SNAPSHOT_ID" =~ ^[0-9a-fA-F]{8,64}$ ]] \
  || { printf '快照 ID 无效\n' >&2; exit 1; }
restic -r "$REPO_URI" ls "$SNAPSHOT_ID"
IFS= read -r -p '新恢复目录的已有父目录（绝对路径）: ' RESTORE_PARENT < /dev/tty || exit 1
[[ "$RESTORE_PARENT" == /* && -d "$RESTORE_PARENT" && -w "$RESTORE_PARENT" && -x "$RESTORE_PARENT" ]] \
  || { printf '恢复父目录不可写或不可遍历\n' >&2; exit 1; }
IFS= read -r -p '确认将所选快照恢复到新建空目录？[y/N]: ' confirm < /dev/tty || exit 1
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0
RESTORE_DIR=$(mktemp -d "$RESTORE_PARENT/restic-restore.XXXXXX")
printf '本次恢复目录: %q\n' "$RESTORE_DIR"
restic -r "$REPO_URI" restore "$SNAPSHOT_ID" --target "$RESTORE_DIR"
printf '恢复命令完成；请核对文件内容与应用恢复要求: %q\n' "$RESTORE_DIR"
)
