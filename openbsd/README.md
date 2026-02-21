# OpenBSD QEMU Autoinstall

Autoinstall OpenBSD on QEMU for cross-building Tesseras.

Based on: https://www.skreutz.com/posts/autoinstall-openbsd-on-qemu/

## Prerequisites

```sh
pacman -S qemu-full python socat curl
```

Allow binding to port 80 (one-time, needed for OpenBSD autoinstall discovery via
SLIRP NAT):

```sh
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80

# To make permanent:
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-local.conf
```

## Usage

```sh
./autoinstall.sh                    # Install OpenBSD
./autoinstall.sh --boot             # Boot existing image (serial console)
./autoinstall.sh --boot --daemon    # Boot in background
./autoinstall.sh --clean            # Remove work directory
./autoinstall.sh --help             # Show help
```

After installation, connect with:

```sh
ssh openbsd-builder
```

The script automatically adds an `openbsd-builder` entry to `~/.ssh/config` if
it doesn't exist.

## Configuration

All settings are environment variables with sensible defaults:

| Variable           | Default                                    | Description                  |
| ------------------ | ------------------------------------------ | ---------------------------- |
| `OPENBSD_VERSION`  | `7.7`                                      | OpenBSD version              |
| `OPENBSD_MIRROR`   | `https://openbsd.c3sl.ufpr.br/pub/OpenBSD` | Mirror base URL              |
| `OPENBSD_CPUS`     | `4`                                        | Number of CPUs               |
| `OPENBSD_MEM`      | `4G`                                       | Memory size                  |
| `OPENBSD_DISK`     | `20G`                                      | Disk size                    |
| `OPENBSD_SSH_KEY`  | `~/.ssh/id_ed25519.pub`                    | Path to SSH public key       |
| `OPENBSD_USER`     | current user                               | Username to create in VM     |
| `OPENBSD_HOSTNAME` | `openbsd`                                  | VM hostname                  |
| `OPENBSD_IMAGE`    | `~/vms/openbsd77/openbsd77.qcow2`          | Output disk image path       |
| `OPENBSD_SSH_PORT` | `7722`                                     | Host port for SSH forwarding |

Example with custom settings:

```sh
OPENBSD_VERSION=7.6 OPENBSD_MEM=8G OPENBSD_CPUS=8 ./autoinstall.sh
```

## What it does

1. Downloads OpenBSD sets from the mirror (cached for reruns)
2. Generates `install.conf` (autoinstall responses), `disklabel`, and
   `install.site`
3. Creates a qcow2 disk image
4. Starts a local HTTP server on port 80 and launches QEMU with PXE boot
5. OpenBSD installs unattended via serial console
6. On first boot, `rc.firsttime` installs packages

### Disk layout

Single `/` partition using the full disk (no swap, no sub-partitions).

### install.site

The site-specific script runs at the end of installation:

- Sets the package mirror in `/etc/installurl`
- Configures `doas` with `permit nopass keepenv <user>`
- Creates `/etc/rc.firsttime` to install `rust` and `rsync--` via pkg_add

### Networking

- QEMU SLIRP NAT forwards guest `10.0.2.2:80` to host `127.0.0.1:80` (the local
  HTTP server)
- PXE boot via QEMU's built-in TFTP server
- Root SSH login disabled, key-only auth for your user
- SSH forwarded to host port 7722 by default
