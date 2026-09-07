# zerotier-openeuler

ZeroTier One installation and upgrade support for openEuler.

## Compatibility

- Tested platform: openEuler 25.03, x86_64, LXC
- Package manager: DNF with Python bindings
- Service manager: systemd
- Package version: latest available in the selected official RPM repository

## Technical Design

The script downloads the [official installer](https://install.zerotier.com/) on each run and adds openEuler support.
It checks official EL repositories from the highest major version downward, selecting the first whose latest package satisfies DNF dependencies for the detected architecture.
Downloads use HTTPS, and RPM signature checks remain enabled.

## Requirements

- Root privileges
- Access to ZeroTier download servers and configured openEuler repositories
- `/dev/net/tun` and permission to create TAP devices (`CAP_NET_ADMIN`)

## Install

```sh
sudo dnf install -y curl python3-dnf tar util-linux
sudo bash ./zerotier-install-openeuler.sh
```

The installer enables and starts `zerotier-one.service`. Network membership is managed separately.

To select an EL repository explicitly:

```sh
sudo env ZT_EL_VERSION=9 bash ./zerotier-install-openeuler.sh
```

`ZT_EL_VERSION` defaults to `auto`.

## Upgrade

Check the available package, then rerun the installer:

```sh
sudo bash ./zerotier-install-openeuler.sh --check
sudo bash ./zerotier-install-openeuler.sh
```

`--check` leaves packages, repository configuration, and the service unchanged.
A normal run restarts the service even when the package is already current.
Node identity and joined networks are preserved.

Before a package change, new RPMs are downloaded and existing state is backed up with the service stopped:

```text
/var/backups/zerotier-one/<timestamp>-<id>/state.tar.gz
```

State backups are root-only and include secret keys. Previous RPMs are not included. Rollback is manual.

## Verify

```sh
zerotier-cli info
zerotier-cli listnetworks
systemctl is-enabled zerotier-one
systemctl status zerotier-one --no-pager
```

Check for `ONLINE` and `OK` on joined, authorized networks.

## Service Management

```sh
sudo systemctl restart zerotier-one
sudo systemctl disable --now zerotier-one
sudo systemctl enable --now zerotier-one
```

## Troubleshooting

```sh
sudo journalctl -u zerotier-one -n 100 --no-pager
zerotier-cli peers
```

If the upstream patch locations change, installation stops. Update the adapter before retrying.

## License

[BSD-3-Clause](LICENSE).

## Credits

- [ZeroTier, Inc.](https://www.zerotier.com/) — [ZeroTierOne](https://github.com/zerotier/ZeroTierOne) and the [official installer](https://github.com/zerotier/install.zerotier.com)
- [openEuler](https://www.openeuler.org/)
- openEuler adaptation: [itinfra7 from GitHub](https://github.com/itinfra7)
