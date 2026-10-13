#!/usr/bin/env bash
# Ubuntu EC2 provisioning: current Node.js, stable Bun, and Codex installed with Bun.
set -Eeuo pipefail
trap 'printf "\nSetup failed at line %s. Fix the error above, then rerun.\n" "$LINENO" >&2' ERR

usage() {
    cat <<'HELP'
Usage: bash install.sh [--user USER] [--node-channel current|lts]

Installs the newest stable Node.js Current release (or newest LTS), stable Bun,
and @openai/codex@latest through Bun. Supports Ubuntu 22.04+ on x64 and ARM64.

Run as your normal Ubuntu user with sudo available. When run as root, the target
defaults to SUDO_USER or ubuntu; --user selects another existing non-root user.
HELP
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
target_user=''
node_channel=current
while (($#)); do
    case "$1" in
        --user) (($# >= 2)) || fail '--user needs a username'; target_user=$2; shift 2 ;;
        --node-channel) (($# >= 2)) || fail '--node-channel needs current or lts'; node_channel=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ $node_channel == current || $node_channel == lts ]] || fail 'Node channel must be current or lts'
[[ $(uname -s) == Linux ]] || fail 'This installer runs on Ubuntu Linux, not this operating system'
[[ -r /etc/os-release ]] || fail 'Cannot identify this operating system'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || fail 'Use an Ubuntu EC2 AMI (Amazon Linux is not supported)'
[[ ${VERSION_ID%%.*} -ge 22 ]] || fail 'Ubuntu 22.04 or newer is required'
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) fail 'Supported architectures are x64 and ARM64' ;; esac

if [[ -z $target_user ]]; then
    if ((EUID != 0)); then
        target_user=$(id -un)
    elif [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        target_user=$SUDO_USER
    elif id ubuntu >/dev/null 2>&1; then
        target_user=ubuntu
    else
        fail 'Run as a normal user, or use --user with an existing non-root username'
    fi
fi
id "$target_user" >/dev/null 2>&1 || fail "User does not exist: $target_user"
[[ $(id -u "$target_user") != 0 ]] || fail 'Select a non-root user for the developer tools'
if ((EUID != 0)) && [[ $(id -un) != "$target_user" ]]; then
    fail 'Run with sudo to provision another user'
fi
target_home=$(getent passwd "$target_user" | cut -d: -f6)
[[ -d $target_home && $target_home == /* ]] || fail 'Target user needs an existing absolute home directory'

admin=()
if ((EUID != 0)); then
    command -v sudo >/dev/null || fail 'sudo is required for Ubuntu packages'
    # sudo -v can still request a password for NOPASSWD users when verifypw=all.
    # EC2's ubuntu account normally has no password, so test a permitted command.
    if ! sudo -n true 2>/dev/null; then
        sudo -v
    fi
    admin=(sudo)
fi
printf '\nInstalling prerequisites for %s on Ubuntu %s...\n' "$target_user" "$VERSION_ID"
# Wait for cloud-init/Ubuntu's unattended apt jobs on newly booted EC2 instances.
"${admin[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update
"${admin[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils jq ripgrep build-essential python3 util-linux

as_user=(bash)
if ((EUID == 0)); then
    as_user=(runuser -u "$target_user" -- bash)
fi
"${as_user[@]}" -s -- "$target_home" "$node_channel" <<'USER_INSTALL'
set -Eeuo pipefail
target_home=$1
node_channel=$2
[[ $HOME == "$target_home" ]] || { echo 'Unexpected user home; refusing installation' >&2; exit 1; }
install_root="$target_home/.local/share/codex-setup"
mkdir -p "$install_root" "$target_home/.local/bin" "$target_home/.config/codex-setup"
exec 9>"$install_root/install.lock"
flock -n 9 || { echo 'Another Codex setup is running' >&2; exit 1; }
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
fetch() { curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 "$@"; }

case "$(uname -m)" in x86_64) node_arch=x64 ;; aarch64|arm64) node_arch=arm64 ;; esac
fetch https://nodejs.org/dist/index.json -o "$work_dir/node-releases.json"
if [[ $node_channel == lts ]]; then
    node_version=$(jq -er '[.[] | select(.lts != false and (.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))][0].version' "$work_dir/node-releases.json")
else
    node_version=$(jq -er '[.[] | select(.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))][0].version' "$work_dir/node-releases.json")
fi
[[ $node_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid Node release metadata' >&2; exit 1; }
archive="node-$node_version-linux-$node_arch.tar.xz"
node_dir="$install_root/node-$node_version-linux-$node_arch"
printf '\nInstalling Node.js %s (%s)...\n' "$node_version" "$node_arch"
if [[ ! -x $node_dir/bin/node ]]; then
    fetch "https://nodejs.org/dist/$node_version/$archive" -o "$work_dir/$archive"
    fetch "https://nodejs.org/dist/$node_version/SHASUMS256.txt" -o "$work_dir/SHASUMS256.txt"
    awk -v filename="$archive" '$2 == filename {print}' "$work_dir/SHASUMS256.txt" > "$work_dir/node.sha256"
    [[ $(wc -l < "$work_dir/node.sha256") -eq 1 ]] || { echo 'Missing Node checksum' >&2; exit 1; }
    (cd "$work_dir" && sha256sum --check node.sha256)
    tar -xJf "$work_dir/$archive" -C "$work_dir"
    mv "$work_dir/node-$node_version-linux-$node_arch" "$node_dir"
fi
for tool in node npm npx; do
    destination="$target_home/.local/bin/$tool"
    if [[ -e $destination || -L $destination ]]; then
        [[ -L $destination && $(readlink "$destination") == "$install_root/"* ]] || {
            printf 'Refusing to replace an unrelated installation: %s\n' "$destination" >&2; exit 1;
        }
    fi
    ln -sfn "$node_dir/bin/$tool" "$destination"
done

export BUN_INSTALL="$target_home/.bun"
export PATH="$BUN_INSTALL/bin:$target_home/.local/bin:$PATH"
printf '\nInstalling the latest stable Bun...\n'
fetch https://bun.sh/install -o "$work_dir/install-bun.sh"
bash "$work_dir/install-bun.sh"
printf '\nInstalling the latest Codex CLI with Bun...\n'
bun add --global @openai/codex@latest

cat > "$target_home/.config/codex-setup/env.sh" <<'ENV'
# Managed by codex-setup. Source this file to activate the installed tools.
export BUN_INSTALL="$HOME/.bun"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
case ":$PATH:" in *":$BUN_INSTALL/bin:"*) ;; *) export PATH="$BUN_INSTALL/bin:$PATH" ;; esac
ENV
profile_line='[ ! -f "$HOME/.config/codex-setup/env.sh" ] || . "$HOME/.config/codex-setup/env.sh"'
profiles=("$target_home/.profile" "$target_home/.bashrc")
for optional_profile in .bash_profile .bash_login .zshrc; do
    [[ ! -f $target_home/$optional_profile ]] || profiles+=("$target_home/$optional_profile")
done
for profile in "${profiles[@]}"; do
    touch "$profile"
    if ! grep -Fqx "$profile_line" "$profile"; then
        printf '\n# Codex setup tools\n%s\n' "$profile_line" >> "$profile"
    fi
done
printf '\nInstalled successfully:\n'
printf 'Node:  '; node --version
printf 'npm:   '; npm --version
printf 'Bun:   '; bun --version
printf 'Codex: '; codex --version
USER_INSTALL

cat <<DONE

Ready for user: $target_user

In that user's terminal, activate the tools:
  . "\$HOME/.config/codex-setup/env.sh"

Sign in on the headless server:
  codex login --device-auth

Then open your project and run:
  codex

Rerun this installer any time to update Node, Bun, and Codex.
DONE
