#!/bin/sh
# =============================================================================
# sysctl-wrapper.sh — graceful sysctl for containers with read-only /proc/sys
# =============================================================================
# Docker sets sysctl values at container startup via --sysctl flag,
# but /proc/sys is mounted read-only inside the container.
# awg-quick calls sysctl internally and fails fatally.
# This wrapper succeeds silently when the value is already correct.

# Try the real sysctl first
if /sbin/sysctl "$@" 2>/dev/null; then
    exit 0
fi

# If it failed, check whether the desired value is already set
for arg in "$@"; do
    case "$arg" in
        -q|-w|-n|-e|-p) continue ;;
        *=*)
            key="${arg%%=*}"
            expected="${arg#*=}"
            actual="$(/sbin/sysctl -n "$key" 2>/dev/null)"
            if [ "$actual" = "$expected" ]; then
                exit 0
            fi
            ;;
    esac
done

# Cannot set the value and it's not already set — warn but don't fail.
# In restricted environments (HA, read-only /proc/sys) crashing here
# causes an unrecoverable restart loop.
echo "sysctl-wrapper: WARNING: cannot set $* (read-only /proc/sys), continuing anyway" >&2
exit 0
