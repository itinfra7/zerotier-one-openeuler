#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Modified by: itinfra7 from GitHub
# Downloads and adapts https://install.zerotier.com/ at runtime.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
case "${1:-}" in
    --help|-h)
        printf 'Usage: sudo bash %s [--check]\n' "$0"
        printf 'ZT_EL_VERSION=auto (default), or an official EL repository major number.\n'
        exit 0 ;;
    --check) [[ $# == 1 ]] || die 'Unexpected arguments.'; check=1 ;;
    '') [[ $# == 0 ]] || die 'Unexpected arguments.'; check=0 ;;
    *) die 'Use --help for usage.' ;;
esac
[[ $EUID == 0 ]] || die 'Run with sudo or as root.'
source /etc/os-release
[[ ${ID,,} == openeuler ]] || die 'This adapter supports openEuler only.'
[[ -d /run/systemd/system ]] || die 'A running systemd is required.'
command -v dnf >/dev/null || die 'DNF is required.'
for command in curl python3 tar flock; do
    if ! command -v "$command" >/dev/null; then
        [[ $check == 0 ]] || die 'Install prerequisites: dnf install curl python3-dnf tar util-linux'
        dnf -y install curl python3-dnf tar util-linux
        break
    fi
done
/usr/bin/python3 -c 'import dnf, rpm' || die 'Install python3-dnf.'
exec 9>/run/lock/zerotier-upgrade.lock
flock -n 9 || die 'Another ZeroTier installation or upgrade is running.'

export ZT_WORK_DIR
ZT_WORK_DIR=$(mktemp -d /tmp/zerotier-openeuler.XXXXXXXX)
was_active=0
systemctl is-active --quiet zerotier-one && was_active=1
cleanup() {
    result=$?
    trap - EXIT
    if [[ $result != 0 && $was_active == 1 ]]; then
        systemctl start zerotier-one || true
    fi
    rm -rf -- "$ZT_WORK_DIR"
    exit "$result"
}
trap cleanup EXIT
export ZT_EL_VERSION="${ZT_EL_VERSION:-auto}"
export ZT_REPO_ROOT=https://download.zerotier.com/redhat/el
[[ $ZT_EL_VERSION == auto || $ZT_EL_VERSION =~ ^[1-9][0-9]*$ ]] || die 'Invalid ZT_EL_VERSION.'
fetch() {
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
        --retry 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"
}
echo 'Downloading the current official installer...'
fetch https://install.zerotier.com/ "$ZT_WORK_DIR/upstream.sh"
if [[ $ZT_EL_VERSION == auto ]]; then
    fetch "$ZT_REPO_ROOT/" "$ZT_WORK_DIR/repositories.html"
fi

/usr/bin/python3 - <<'PY'
import os
import re
import sys
from pathlib import Path
import dnf
import rpm

work = Path(os.environ["ZT_WORK_DIR"])
text = (work / "upstream.sh").read_text()
# Unwrap the clear-signed file. HTTPS authenticates the download; this is
# parsing, not independent GPG signature verification.
match = re.search(
    r"-----BEGIN PGP SIGNED MESSAGE-----\n(?:[^\n]+\n)*\n"
    r"(.*?)\n-----BEGIN PGP SIGNATURE-----", text, re.S)
if not match:
    sys.exit("Unrecognized upstream installer format; nothing executed.")
text = re.sub(r"(?m)^- ", "", match[1])

def replace_once(old, new):
    global text
    if text.count(old) != 1:
        sys.exit("Upstream installer changed; review adapter before running: " + old.splitlines()[0])
    text = text.replace(old, new, 1)

replace_once(
    "if [ -f /usr/sbin/zerotier-one ]; then\n"
    "\techo '*** ZeroTier appears to already be installed.'\n\texit 0\nfi",
    "# Existing installations are updated through DNF.")
if "/tmp/zt-gpg-key" not in text:
    sys.exit("Upstream signing-key handling changed; nothing executed.")
text = text.replace("/tmp/zt-gpg-key", '"$ZT_WORK_DIR/zt-gpg-key"')

branch = r'''if [ "${ID,,}" = "openeuler" ]; then
    install -D -m 644 "$ZT_WORK_DIR/zt-gpg-key" /etc/pki/rpm-gpg/RPM-GPG-KEY-ZeroTier
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ZeroTier
    cat >"$ZT_WORK_DIR/zerotier.repo" <<ZT_REPO
[zerotier]
name=ZeroTier, Inc. RPM Release Repository
baseurl=$ZT_SELECTED_REPO
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ZeroTier
sslverify=1
includepkgs=zerotier-one
metadata_expire=6h
ZT_REPO
    install -m 644 "$ZT_WORK_DIR/zerotier.repo" /etc/yum.repos.d/zerotier.repo
    mkdir "$ZT_WORK_DIR/packages"
    dnf -y --refresh --best --setopt=install_weak_deps=False \
        --downloadonly --downloaddir="$ZT_WORK_DIR/packages" install "$ZT_TARGET"
    shopt -s nullglob
    packages=("$ZT_WORK_DIR/packages/"*.rpm)
    if [[ ${#packages[@]} -gt 0 ]]; then
        rpmkeys --checksig "${packages[@]}"
        if [[ -d /var/lib/zerotier-one ]]; then
            install -d -m 700 /var/backups/zerotier-one
            backup=$(mktemp -d "/var/backups/zerotier-one/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
            printf 'State backup: %s\n' "$backup"
            rpm -q zerotier-one >"$backup/previous-version" || true
            systemctl stop zerotier-one
            tar --acls --xattrs --numeric-owner -C /var/lib \
                -czf "$backup/state.tar.gz" zerotier-one
        fi
        dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=True install "${packages[@]}"
    fi
elif [ $ID == "debian" ] || [ $ID == "raspbian" ]; then'''
replace_once('if [ $ID == "debian" ] || [ $ID == "raspbian" ]; then', branch)
replace_once("systemctl start zerotier-one", "systemctl restart zerotier-one")
replace_once(
    'while [ ! -f /var/lib/zerotier-one/identity.secret ]; do\n\tsleep 1\ndone',
    'for attempt in {1..60}; do\n'
    '    [ -s /var/lib/zerotier-one/identity.secret ] && break\n    sleep 1\ndone\n'
    '[ -s /var/lib/zerotier-one/identity.secret ] || exit 1')
(work / "patched.sh").write_text(
    "#!/bin/bash\n# Runtime adapter: itinfra7 from GitHub\n" + text + "\n")

requested = os.environ["ZT_EL_VERSION"]
majors = ([int(requested)] if requested != "auto" else sorted(
    {int(n) for n in re.findall(r'href=["\']([1-9][0-9]*)/["\']',
                               (work / "repositories.html").read_text())}, reverse=True))
if not majors:
    sys.exit("No official EL repository listing found; set ZT_EL_VERSION explicitly.")

def evr(pkg):
    return str(pkg.epoch), pkg.version, pkg.release

for major in majors:
    url = f'{os.environ["ZT_REPO_ROOT"]}/{major}'
    print(f"Checking repository and dependencies: {url}", flush=True)
    try:
        with dnf.Base() as base:
            base.conf.read()
            base.conf.best = True
            base.conf.install_weak_deps = False
            base.read_all_repos()
            for repo in base.repos.iter_enabled():
                # Other repositories may supply OS dependencies, not ZeroTier.
                repo.excludepkgs = list(repo.excludepkgs) + ["zerotier-one"]
            repo = base.repos.add_new_repo(
                "zerotier_probe", base.conf, baseurl=[url], gpgcheck=True,
                sslverify=True, skip_if_unavailable=False,
                includepkgs=["zerotier-one"], metadata_expire=0)
            base.fill_sack()
            query = base.sack.query()
            packages = list(query.available().filter(
                reponame=repo.id, name="zerotier-one",
                arch=[base.conf.substitutions["arch"], "noarch"]).latest())
            if len(packages) != 1:
                print("No unique package for this architecture; trying next repository.")
                continue
            pkg = packages[0]
            installed = list(query.installed().filter(name="zerotier-one"))
            if any(rpm.labelCompare(evr(pkg), evr(old)) < 0 for old in installed):
                print("Would downgrade the installed package; skipping.")
                continue
            base.package_install(pkg, strict=True)
            base.resolve(allow_erasing=False)
            (work / "selection").write_text(f"{url}\n{pkg}\n{pkg.version}\n")
            print(f"Selected: {pkg}", flush=True)
            break
    except dnf.exceptions.DepsolveError as error:
        print(f"Dependency mismatch: {error}", file=sys.stderr)
else:
    sys.exit("No compatible official package found; nothing installed.")
PY

mapfile -t selection <"$ZT_WORK_DIR/selection"
export ZT_SELECTED_REPO="${selection[0]}" ZT_TARGET="${selection[1]}"
bash -n "$ZT_WORK_DIR/patched.sh"
printf 'Installed: '; rpm -q zerotier-one || true
if [[ $check == 1 ]]; then
    echo 'Check complete; packages, repository configuration and service were not changed.'
    exit 0
fi
[[ -c /dev/net/tun ]] || die '/dev/net/tun is required; check the container host configuration.'
/usr/bin/python3 - <<'PY'
import fcntl
import struct
# An unnamed temporary TAP is removed when this descriptor closes.
with open("/dev/net/tun", "r+b", buffering=0) as tun:
    fcntl.ioctl(tun, 0x400454ca, struct.pack("16sH", b"ztcheck%d", 0x1002))
PY
previous_id=
if [[ -s /var/lib/zerotier-one/identity.public ]]; then
    previous_id=$(cut -d: -f1 /var/lib/zerotier-one/identity.public)
fi
install -d -m 755 /etc/systemd/system/zerotier-one.service.d
cat >"$ZT_WORK_DIR/runtime.conf" <<'CONF'
[Service]
RestartSec=5s
TimeoutStopSec=30s
UMask=0077
CONF
install -m 644 "$ZT_WORK_DIR/runtime.conf" /etc/systemd/system/zerotier-one.service.d/10-runtime.conf
systemctl daemon-reload
bash -e "$ZT_WORK_DIR/patched.sh"
chmod 700 /var/lib/zerotier-one
systemctl is-enabled --quiet zerotier-one
systemctl is-active --quiet zerotier-one
for attempt in {1..30}; do
    if timeout 3 zerotier-cli -j info >"$ZT_WORK_DIR/info.json" 2>/dev/null; then
        break
    fi
    sleep 1
done
/usr/bin/python3 - "$ZT_WORK_DIR/info.json" "$previous_id" "${selection[2]}" <<'PY'
import json
import sys
info = json.load(open(sys.argv[1]))
if info["version"] != sys.argv[3] or (sys.argv[2] and info["address"] != sys.argv[2]):
    sys.exit("Post-install version/identity verification failed.")
print(f'Verified: ZeroTier {info["version"]}; node identity preserved.')
PY
echo 'Service enabled and running. Network join is managed by the operator.'
