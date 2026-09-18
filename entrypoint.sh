#!/bin/bash
set -e

# The persistent volume is mounted empty over /var/lib/samba, replacing
# what the package installed there - "private" (passdb.tdb, secrets.tdb)
# needs to exist with the right permissions before smbd will use it.
mkdir -p /var/lib/samba/private
chmod 700 /var/lib/samba/private

# /var/lib/samba (the passdb) is on a persistent volume, but /etc/passwd
# is not (the container filesystem itself is ephemeral) - the shell
# account needs recreating every start regardless of whether the Samba
# account already exists in the persisted passdb.
id -u "$SMB_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SMB_USER"

# Only the first start (empty passdb) needs "-a" (add); after that the
# account already exists in the persisted passdb, and re-syncing the
# password each start is what lets rotating SMB_PASSWORD in the secret
# and restarting the pod actually change it.
if ! pdbedit -L | grep -q "^${SMB_USER}:"; then
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -a -s "$SMB_USER"
else
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -s "$SMB_USER"
fi

exec smbd --foreground --no-process-group
