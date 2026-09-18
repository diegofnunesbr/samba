#!/bin/bash
set -e

mkdir -p /var/lib/samba/private
chmod 700 /var/lib/samba/private

id -u "$SMB_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SMB_USER"

if ! pdbedit -L | grep -q "^${SMB_USER}:"; then
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -a -s "$SMB_USER"
else
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -s "$SMB_USER"
fi

exec smbd --foreground --no-process-group
