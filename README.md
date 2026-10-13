# Codex setup for Ubuntu EC2

One command to prepare a fresh Ubuntu server with the **newest Node.js Current
release**, **latest stable Bun**, and **latest Codex CLI installed with Bun**.
Works on x64 (Intel/AMD) and ARM64 (AWS Graviton). Use an Ubuntu 22.04 or newer
AMI and SSH in as `ubuntu`.

## Paste this on the server

Run this in your Ubuntu server's SSH session:

```bash
curl -fsSL https://raw.githubusercontent.com/ccollier86/codex-setup/main/install.sh -o codex-setup.sh && bash codex-setup.sh && . "$HOME/.config/codex-setup/env.sh"
```

This downloads the complete installer before executing it, installs everything,
then activates the tools in your current shell. It leaves `codex-setup.sh` in the
current folder so you can inspect or rerun it. New SSH login shells pick up the
tools automatically.

Then sign in to Codex once:

```bash
codex login --device-auth
```

Open the displayed URL on your own computer and enter the displayed code. If
your account requires it, enable device-code login in ChatGPT security settings
(or have your workspace admin enable it). Once signed in, open a project folder
and run `codex`.

For API-key authentication instead, with `OPENAI_API_KEY` already supplied to
your shell securely:

```bash
printenv OPENAI_API_KEY | codex login --with-api-key
```

Authentication is deliberately separate from machine provisioning. The installer
does not contain credentials or overwrite existing Codex settings.

## What gets installed

| Tool | Installation |
| --- | --- |
| Node.js + npm/npx | Latest Current release from nodejs.org, verified against its published SHA-256 checksum |
| Bun | Latest stable release through Bun's official installer |
| Codex | `bun add --global @openai/codex@latest` |
| Ubuntu tools | Git, curl, CA certificates, unzip, xz, jq, ripgrep, Python 3, build-essential and util-linux |

Node, Bun and Codex belong to your login user. `sudo` is used for Ubuntu packages.
The installer prints all installed versions and verifies that Codex starts.

Node's **Current** channel means the newest stable release, which can be newer
than LTS. To choose the newest LTS instead:

```bash
bash codex-setup.sh --node-channel lts
```

Rerun the same one-line command to update to the newest versions available at that
time. Existing `~/.codex` configuration and login are preserved. Repeated runs do
not duplicate the managed PATH entries. Old Node version directories are retained.

## Root, sudo and cloud-init

Normal use is to run as `ubuntu`, without putting `sudo` before the whole command.
If run as root, the installer selects `SUDO_USER`, or `ubuntu` when available.
To provision a different existing user explicitly:

```bash
sudo bash codex-setup.sh --user developer
```

The target must be a non-root user with a home directory. The script waits up to
five minutes for dpkg locks, which helps on freshly booted EC2 instances.
It installs prerequisites rather than upgrading every Ubuntu package. It does
not change SSH, open ports, alter Codex approval settings, or start a daemon.

Install locations:

- `~/.local/share/codex-setup/`: Node versions and installer lock.
- `~/.local/bin/`: managed `node`, `npm` and `npx` links.
- `~/.bun/`: Bun and global packages, including Codex.
- `~/.config/codex-setup/env.sh`: shell environment, sourced by shell profiles.

## Maintaining the installer

Source: [ccollier86/codex-setup](https://github.com/ccollier86/codex-setup).
The local checkout is `/Volumes/code-bank/scripts/codex-setup`.
The public repository lets fresh servers fetch the script without GitHub credentials.

After editing and validating changes in the local checkout:

```bash
cd /Volumes/code-bank/scripts/codex-setup
git add install.sh README.md tests/ .github/
git commit -m "Update Ubuntu Codex provisioning"
git push origin main
```

For future script changes, commit and push to `main`; the server one-liner will
fetch the updated script. To freeze the installer itself, replace `main` in the
URL with a commit SHA (tool versions still resolve to latest on each run).

## Validation

```bash
bash -n install.sh && bash -n tests/ubuntu-smoke.sh
shellcheck install.sh tests/ubuntu-smoke.sh
bash tests/ubuntu-smoke.sh linux/arm64
bash tests/ubuntu-smoke.sh linux/amd64
```

The smoke test performs real downloads in disposable Ubuntu 24.04 containers,
checks login-shell PATH and native Codex execution, reruns as a sudo user, and
checks ownership, preserved Codex configuration and nonduplicated profile entries.
Docker receives only this repository as a read-only mount; host credentials are
not mounted. GitHub Actions runs the checks on both CPU architectures after push.

References: [Codex CLI](https://developers.openai.com/codex/cli/),
[headless authentication](https://developers.openai.com/codex/auth/#login-on-headless-devices),
[Bun installation](https://bun.sh/docs/installation),
[Bun global packages](https://bun.sh/docs/pm/cli/install),
[Node.js downloads](https://nodejs.org/en/download).
