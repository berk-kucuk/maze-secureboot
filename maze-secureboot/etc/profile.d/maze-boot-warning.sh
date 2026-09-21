# Managed by Maze Linux (maze-secureboot).
# Warn on every interactive shell while the boot chain is unsafe. Covers the
# paths a desktop notification never reaches: TTY logins and SSH.
if [ -e /var/lib/maze/boot-unsafe ] && [ -t 1 ]; then
    printf '\n\033[1;31m  BOOT CHAIN IS NOT SAFE\033[0m\n'
    sed 's/^/    /' /var/lib/maze/boot-unsafe 2>/dev/null
    printf '\n    Before you reboot:  \033[1msudo maze-boot-check --repair\033[0m\n\n'
fi
