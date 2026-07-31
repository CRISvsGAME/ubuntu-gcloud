# Ubuntu Google Cloud CLI Installer

Installs Google Cloud CLI on supported Ubuntu systems using Google Cloud's official APT repository.

## Requirements

- Ubuntu 24.04 or later
- Root privileges
- Bash
- `apt-get`
- `curl`
- `dpkg`
- `gpg`
- `install`
- `mktemp`

## Installation

```bash
curl -fsLS https://raw.githubusercontent.com/crisvsgame/ubuntu-gcloud/main/install.sh | sudo /bin/bash
```

Or, after downloading the script:

```bash
sudo ./install.sh
```

```bash
sudo /bin/bash install.sh
```

## Behaviour

The installer:

- validates the Ubuntu version;
- downloads and validates the repository signing key against trusted fingerprints;
- installs the key under `/etc/apt/keyrings/`;
- configures the repository using Deb822 `.sources` format;
- updates the APT package index;
- installs Google Cloud CLI non-interactively.

The installer uses a temporary working directory that is removed when the script exits.

## Environment

Colour output is automatically enabled for terminal output.

Supported overrides:

```bash
NO_COLOR=1
FORCE_COLOR=1
FORCE_COLOR=0
```

## Scope

This installer manages only artifacts created by the current installer version.

Legacy repository files or signing keys from previous installer versions are not migrated or removed automatically.
