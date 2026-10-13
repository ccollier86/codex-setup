#!/usr/bin/env bash
# Real installation in a disposable Ubuntu container. No host credentials mounted.
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
platform=${1:-linux/arm64}
docker run --rm -i --platform "$platform" \
    --mount "type=bind,src=$project_dir,dst=/setup,readonly" \
    ubuntu:24.04 bash -s <<'CONTAINER'
set -euo pipefail
cp /setup/install.sh /tmp/codex-setup.sh
# This container is discarded, so avoid expensive package fsyncs during tests.
printf 'force-unsafe-io\n' > /etc/dpkg/dpkg.cfg.d/02-smoke-test-unsafe-io
id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
mkdir -p /home/ubuntu/.codex
printf '# Preserve existing Codex settings\n' > /home/ubuntu/.codex/config.toml
chown -R ubuntu:ubuntu /home/ubuntu/.codex
bash /tmp/codex-setup.sh
test ! -e /root/.bun
test ! -e /root/.codex
runuser -u ubuntu -- bash -lc 'node --version; bun --version; codex --version; codex login --help | grep -F -- --device-auth'

# Exercise the ordinary sudo-user rerun, not only root/cloud-init provisioning.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo
printf 'ubuntu ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/ubuntu
chmod 0440 /etc/sudoers.d/ubuntu
runuser -u ubuntu -- bash /tmp/codex-setup.sh
runuser -u ubuntu -- bash -lc '
  set -eu
  test "$(grep -c "# Codex setup tools" "$HOME/.profile")" -eq 1
  test "$(grep -c "# Codex setup tools" "$HOME/.bashrc")" -eq 1
  grep -Fx "# Preserve existing Codex settings" "$HOME/.codex/config.toml"
  test "$(stat -c %U "$HOME/.bun/bin/bun")" = ubuntu
  node --version
  bun --version
  codex --version
  bun pm --global ls
'
echo 'PASS: fresh install, login-shell PATH, native Codex executable, normal-user rerun, ownership, and preserved configuration'
CONTAINER
