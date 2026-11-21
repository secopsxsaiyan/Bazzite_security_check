#!/usr/bin/env bash
# Smoke test: run the audit against a simulated, deliberately misconfigured
# Bazzite gaming/dev desktop and check that the expected findings appear,
# that a confirmed fix runs and records an undo step, and that a declined fix
# changes nothing.
#
# Bazzite's own tools (rpm-ostree, firewall-cmd, flatpak, systemctl, ss, ...)
# are replaced by stubs; system files come from a fixture tree (AUDIT_ROOT).
# It needs root and CREATES A TEST USER ("bdatest") - run it only in a
# throwaway container or VM:   sudo tests/smoke.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$HERE/../bazzite-sec-audit.sh"
[[ $EUID -eq 0 ]] || { echo "run as root (in a throwaway container)"; exit 1; }
for t in script runuser useradd python3; do
    command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }
done

W=$(mktemp -d /tmp/bda-smoke.XXXXXX)
FX="$W/root"; STUB="$W/bin"; STATE="$W/state"
mkdir -p "$FX" "$STUB" "$STATE"
chmod 755 "$W" "$STUB"
touch "$W/calls.log" "$W/kdialog.log"; chmod 666 "$W/calls.log" "$W/kdialog.log"
U=bdatest
UH=/var/home/$U
PASS=0; FAIL=0
# SIGPIPE may be ignored when this starts (a CI runner starts its steps
# like that, a systemd service too, a terminal does not), and bash cannot
# change it afterwards. The suite must pass both ways (CI runs it twice,
# see .github/workflows/ci.yml); the few checks that see the difference
# use PIPE_END: how a program ends that writes to a closed pipe (141: ended
# by the signal; 1: its write failed).
if (( (16#$(awk '/^SigIgn:/ { print $2 }' "/proc/$$/status") >> 12) & 1 )); then
    SIGPIPE_IGNORED=1; PIPE_END=1
else
    SIGPIPE_IGNORED=0; PIPE_END=141
fi
echo "SIGPIPE at the start: $( (( SIGPIPE_IGNORED )) && echo ignored || echo default)"
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
expect() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
reject() { if grep -qF -- "$2" "$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

# ---------------------------------------------------------------- test user
id "$U" >/dev/null 2>&1 || useradd -m -d "$UH" -u 1777 -s /bin/bash "$U"
getent group docker >/dev/null || groupadd docker
usermod -aG docker "$U"
chmod 755 "$UH"
# Leftovers of an earlier run in the same container would be read instead
# (ssh-keygen would not replace an old key, for example).
rm -rf "$UH/Documents" "$UH/evil-reports" "$UH/t6.conf" "$UH/.ssh/id_ed25519" "$UH/.ssh/id_ed25519.pub" \
    "$UH/.ssh/deploy_root" "$UH/.ssh/deploy_root.pub"
install -d -o "$U" -m 700 "$UH/.ssh" "$UH/.config" "$UH/.config/sunshine" "$UH/.config/autostart" "$UH/projects/app"
if command -v ssh-keygen >/dev/null; then
    runuser -u "$U" -- ssh-keygen -q -t ed25519 -N '' -f "$UH/.ssh/id_ed25519"
    # A key root put in the user's folder (a deploy key copied with sudo).
    ssh-keygen -q -t ed25519 -N '' -f "$UH/.ssh/deploy_root"
else
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n' > "$UH/.ssh/id_ed25519"
fi
chown "$U" "$UH/.ssh/id_ed25519"; chmod 644 "$UH/.ssh/id_ed25519"
printf 'https://bob:ghp_secret@github.com\n' > "$UH/.git-credentials"; chmod 600 "$UH/.git-credentials"
printf 'API_KEY=abc123\nDEBUG=1\n' > "$UH/projects/app/.env"; chmod 644 "$UH/projects/app/.env"
printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > "$UH/.config/kscreenlockerrc"
printf 'origin_web_ui_allowed = wan\nupnp = on\n' > "$UH/.config/sunshine/sunshine.conf"
printf '[Desktop Entry]\nType=Application\nExec=/tmp/.x/run.sh\n' > "$UH/.config/autostart/updater.desktop"
# A hidden payload next to a normal folder, and a normal toolchain path.
printf '[Desktop Entry]\nType=Application\nExec=%s/.local/share/.sysd/run --config %s/.config/x\n' "$UH" "$UH" > "$UH/.config/autostart/sneaky.desktop"
printf '[Desktop Entry]\nType=Application\nExec=%s/.nvm/versions/node/v20/bin/node %s/app.js\n' "$UH" "$UH" > "$UH/.config/autostart/devserver.desktop"
chown -R "$U" "$UH/.config" "$UH/projects" "$UH/.git-credentials"

# ---------------------------------------------------------------- fixture tree
mk() { mkdir -p "$(dirname "$FX$1")"; cat > "$FX$1"; }
mk /etc/os-release << 'EOF'
NAME="Bazzite"
ID=bazzite
PRETTY_NAME="Bazzite"
EOF
mk /usr/share/ublue-os/image-info.json << 'EOF'
{"image-name": "bazzite", "image-vendor": "ublue-os", "image-ref": "ostree-image-signed:docker://ghcr.io/ublue-os/bazzite",
 "image-tag": "stable", "base-image-name": "kinoite", "fedora-version": "42", "version-pretty": "Stable (F42.20251001)"}
EOF
mk /run/ostree-booted < /dev/null
mk /etc/shadow << EOF
root:!locked::0:99999:7:::
${U}:\$6\$abc\$def:20000:0:99999:7:::
EOF
mk /etc/sudoers << 'EOF'
root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
EOF
mk /etc/sudoers.d/bdatest << EOF
${U} ALL=(ALL) NOPASSWD: ALL
EOF
mk /etc/sudoers.d/ignored.conf << 'EOF'
nobody ALL=(ALL) NOPASSWD: ALL
EOF
mk /etc/sddm.conf.d/kde_settings.conf << EOF
[Autologin]
Relogin=false
Session=plasma
User=${U}
EOF
mk /etc/yum.repos.d/copr.repo << 'EOF'
[copr:example]
name=Example
baseurl=https://example.org/repo
enabled=1
gpgcheck=0

[off]
enabled=0
gpgcheck=0
EOF
mk /etc/selinux/config <<< 'SELINUX=permissive'
mk /proc/cmdline <<< 'BOOT_IMAGE=(hd0,gpt2)/vmlinuz rhgb quiet mitigations=off'
mk /sys/kernel/security/lockdown <<< '[none] integrity confidentiality'
mk /proc/sys/kernel/kexec_load_disabled <<< '0'
for kv in kernel/randomize_va_space=2 fs/protected_hardlinks=1 fs/protected_symlinks=0 fs/protected_regular=2 \
          fs/protected_fifos=1 kernel/unprivileged_bpf_disabled=2 net/ipv4/tcp_syncookies=1 \
          net/ipv4/conf/all/accept_source_route=0; do
    mk "/proc/sys/${kv%=*}" <<< "${kv#*=}"
done
mkdir -p "$FX/sys/firmware/efi" "$FX/sys/devices/system/cpu/vulnerabilities"
echo "Vulnerable" > "$FX/sys/devices/system/cpu/vulnerabilities/spectre_v2"
echo "Not affected" > "$FX/sys/devices/system/cpu/vulnerabilities/meltdown"

# ---------------------------------------------------------------- stubs
stub() { cat > "$STUB/$1"; chmod 755 "$STUB/$1"; }
NOW=$(date +%s)
cat > "$W/status.json" << EOF
{"deployments": [{"booted": true, "staged": false, "timestamp": $((NOW - 40 * 86400)),
  "container-image-reference": "ostree-unverified-registry:ghcr.io/ublue-os/bazzite:stable",
  "requested-packages": ["htop", "kitty"], "requested-local-packages": [],
  "requested-base-removals": [], "requested-base-local-replacements": []}]}
EOF
stub rpm-ostree << EOF
#!/bin/bash
echo "rpm-ostree \$*" >> "$W/calls.log"
case "\$1" in
  status) cat "$W/status.json" ;;
  kargs) [[ \$# -eq 1 ]] && echo "rhgb quiet mitigations=off" ;;
esac
exit 0
EOF
stub systemctl << EOF
#!/bin/bash
echo "systemctl \$*" >> "$W/calls.log"
a="\$*"
case "\$a" in
  "is-enabled uupd.timer") echo disabled; exit 1 ;;
  "is-enabled rpm-ostreed-automatic.timer") echo disabled; exit 1 ;;
  "is-enabled sshd.service") echo enabled; exit 0 ;;
  "is-enabled firewalld.service") echo enabled; exit 0 ;;
  "is-enabled docker.service") echo enabled; exit 0 ;;
  "is-enabled "*) echo "Failed to get unit file state" >&2; exit 1 ;;
  "is-active --quiet sshd.service"|"is-active --quiet docker.service") exit 0 ;;
  "is-active "*) exit 3 ;;
  "--user -M ${U}@ is-enabled app-dev.lizardbyte.app.Sunshine.service") echo enabled; exit 0 ;;
  "--user -M ${U}@ is-enabled "*) echo disabled; exit 1 ;;
  "--user -M ${U}@ is-active --quiet app-dev.lizardbyte.app.Sunshine.service") exit 0 ;;
  "--user -M "*" is-active "*) exit 3 ;;
  show*) echo "" ;;
esac
exit 0
EOF
stub firewall-cmd << EOF
#!/bin/bash
echo "firewall-cmd \$*" >> "$W/calls.log"
case "\$*" in
  --state) echo running ;;
  --get-default-zone) echo FedoraWorkstation ;;
  --get-zone-of-interface=*) cat "$W/iface-zone" 2>/dev/null || echo FedoraWorkstation ;;
  "--zone=home --list-all") printf 'home (active)\n  target: default\n  services: dhcpv6-client mdns\n  ports: \n' ;;
  "--zone=devzone --list-all") printf 'devzone (active)\n  target: default\n  services: dhcpv6-client ssh\n  ports: 3000/tcp 8000/tcp 9000/tcp 47984/tcp 1720/udp\n  rich rules: \n\trule family="ipv4" source address="192.168.1.0/24" port port="9000" protocol="tcp" accept\n' ;;
  "--permanent --zone=devzone --query-port=8000/tcp") exit 1 ;;
  "--zone=FedoraWorkstation --list-all") cat << 'Z'
FedoraWorkstation (default, active)
  target: default
  interfaces: enp5s0
  services: dhcpv6-client samba-client ssh
  ports: 1025-65535/udp 1025-65535/tcp 25565/tcp 47990/tcp 47984/tcp
  forward-ports:
  source-ports:
  rich rules:
Z
  ;;
  --info-service=ssh) printf 'ssh\n  ports: 22/tcp\n' ;;
  --info-service=dhcpv6-client) printf 'dhcpv6-client\n  ports: 546/udp\n' ;;
  --info-service=samba-client) printf 'samba-client\n  ports: 137/udp 138/udp\n' ;;
  --get-services) echo "dhcpv6-client mdns kdeconnect steam-streaming ssh samba syncthing" ;;
  "--permanent --get-zones") echo "FedoraWorkstation public trusted" ;;
esac
exit 0
EOF
stub ss << 'EOF'
#!/bin/bash
cat << 'S'
udp   UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* users:(("avahi-daemon",pid=900,fd=12))
udp   UNCONN 0 0 0.0.0.0:5355 0.0.0.0:* users:(("systemd-resolve",pid=800,fd=11))
udp   UNCONN 0 0 0.0.0.0:68 0.0.0.0:* users:(("NetworkManager",pid=700,fd=20))
tcp   LISTEN 0 4096 0.0.0.0:27036 0.0.0.0:* users:(("steam",pid=3000,fd=50))
tcp   LISTEN 0 50 *:1716 *:* users:(("kdeconnectd",pid=2000,fd=20))
tcp   LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=4000,fd=22))
tcp   LISTEN 0 511 0.0.0.0:1000 0.0.0.0:* users:(("python3",pid=4100,fd=5))
tcp   LISTEN 0 4096 0.0.0.0:5432 0.0.0.0:* users:(("docker-proxy",pid=5000,fd=4))
tcp   LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=600,fd=3))
tcp   LISTEN 0 4096 127.0.0.1:631 0.0.0.0:* users:(("cupsd",pid=650,fd=7))
tcp   LISTEN 0 4096 0.0.0.0:47990 0.0.0.0:* users:(("sunshine",pid=3500,fd=30))
tcp   LISTEN 0 4096 127.0.0.1:2375 0.0.0.0:* users:(("dockerd",pid=5100,fd=6))
tcp   LISTEN 0 4096 0.0.0.0:2376 0.0.0.0:* users:(("dockerd",pid=5100,fd=7))
S
EOF
stub ip << 'EOF'
#!/bin/bash
cat << 'I'
1: lo    inet 127.0.0.1/8 scope host lo
2: enp5s0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic enp5s0
3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
I
EOF
stub flatpak << EOF
#!/bin/bash
echo "flatpak \$*" >> "$W/calls.log"
a="\$*"
case "\$a" in
  "info dev.lizardbyte.app.Sunshine") exit 0 ;;
  info\ --system\ --show-permissions\ com.visualstudio.code) printf '[Context]\nshared=network;\nfilesystems=host;\n\n[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n' ;;
  info\ --system\ --show-permissions\ net.lutris.Lutris) printf '[Context]\nfilesystems=home;\n\n[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n' ;;
  info\ --system\ --show-permissions\ com.example.BusApp) printf '[Context]\nsockets=x11;session-bus;\n' ;;
  info\ --system\ --show-permissions\ *) printf '[Context]\nshared=network;\n' ;;
  "override --system --show net.lutris.Lutris") printf '[Session Bus Policy]\norg.freedesktop.Flatpak=none\n' ;;
  override\ --system\ --show\ *) ;;
  "list --system --app --columns=application") printf 'com.visualstudio.code\nnet.lutris.Lutris\norg.mozilla.firefox\ncom.example.BusApp\n' ;;
  "remote-ls --updates --system --columns=application")
    if [[ -f "$W/fp-updates" ]]; then cat "$W/fp-updates"; else printf 'org.mozilla.firefox\norg.freedesktop.Platform\n'; fi ;;
  info*) exit 1 ;;
esac
exit 0
EOF
stub systemd-detect-virt <<< $'#!/bin/bash\necho none; exit 1'
stub getenforce <<< $'#!/bin/bash\necho Permissive'
stub mokutil <<< $'#!/bin/bash\necho "SecureBoot disabled"'
stub hostnamectl <<< $'#!/bin/bash\necho desktop'
stub findmnt <<< $'#!/bin/bash\necho "/dev/nvme0n1p3[/home]"'
stub lsblk <<< $'#!/bin/bash\nprintf "part\\ndisk\\n"'
stub loginctl <<< $'#!/bin/bash\nexit 0'
stub nmcli <<< $'#!/bin/bash\ncase "$*" in *CON-UUID*) echo 1111-2222 ;; esac; exit 0'
stub fwupdmgr <<< $'#!/bin/bash\necho \'{"Devices":[{"Name":"System Firmware","Releases":[{"Version":"1.2"}]},{"Name":"SSD","Releases":[]}]}\''
stub journalctl << EOF
#!/bin/bash
echo "journalctl \$*" >> "$W/calls.log"
printf 'kernel: audit: avc:  denied { read } for pid=1\nkernel: audit: avc:  denied { open } for pid=2\nsshd: Failed password for bob\n'
EOF
stub sshd << 'EOF'
#!/bin/bash
[[ "$1" == "-T" ]] && printf 'permitrootlogin prohibit-password\npasswordauthentication yes\nkbdinteractiveauthentication no\npermitemptypasswords no\n'
exit 0
EOF
stub docker << 'EOF'
#!/bin/bash
[[ "$1" == "ps" ]] && printf 'postgres\t0.0.0.0:5432->5432/tcp, :::5432->5432/tcp\nredis\t127.0.0.1:6379->6379/tcp\n'
exit 0
EOF
# Root has no containers; the desktop user has a rootless one published on
# every interface and one on localhost only.
stub podman << 'EOF'
#!/bin/bash
[[ "$1" == "ps" && $(id -u) -ne 0 ]] && printf 'web\t0.0.0.0:8080->80/tcp, :::8080->80/tcp\nlocalonly\t127.0.0.1:9000->9000/tcp\n'
exit 0
EOF
stub ostree <<< $'#!/bin/bash\nprintf "M    passwd\\nA    sudoers.d/bdatest\\nM    ssh/sshd_config\\nA    systemd/system/miner.service\\nM    cups/cupsd.conf\\n"'
stub xdg-user-dir <<< $'#!/bin/bash\necho "$HOME/Documents"'
stub kwriteconfig6 << EOF
#!/bin/bash
echo "kwriteconfig6 \$*" >> "$W/calls.log"
EOF
for c in passwd gpasswd usermod sysctl busctl visudo; do
    stub "$c" << EOF
#!/bin/bash
echo "$c \$*" >> "$W/calls.log"
exit 0
EOF
done


# A kdialog that answers like a person would: Yes/OK everywhere, the default
# ticks in lists, Yes/No/Cancel answers taken from a queue file, and the
# dashboard entries to open taken from another (none left: Finish). The
# tool puts the "no" answer in kdialog's Yes place when Enter must not say
# yes; the person still presses the button with the "yes" answer on it.
stub kdialog << EOF
#!/bin/bash
printf '%s\0' "\$@" >> "$W/kdialog.log"; printf '\n' >> "$W/kdialog.log"
args=("\$@")
swapped=0
for ((i = 0; i < \${#args[@]}; i++)); do
  [[ "\${args[\$i]}" == --yes-label ]] || continue
  case "\${args[\$((i + 1))]}" in No|Back|Skip|"Keep it"|"Leave it"|Cancel|"Not now"|Quit) swapped=1 ;; esac
done
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[\$i]}" in
    --yesno|--warningyesno) exit "\$swapped" ;;
    --msgbox|--error|--detailederror|--sorry|--passivepopup|--textbox) exit 0 ;;
    --progressbar) echo "org.kde.kdialog-4242 /ProgressDialog"; exit 0 ;;
    --getexistingdirectory) echo "\${args[\$((i + 1))]}"; exit 0 ;;
    --newpassword) echo "secret"; exit 0 ;;
    --yesnocancel|--warningyesnocancel)
      a=\$(head -n1 "$W/q/answers"); sed -i 1d "$W/q/answers"; a="\${a:-1}"
      if [[ \$swapped -eq 1 && \$a != 2 ]]; then a=\$(( 1 - a )); fi
      exit "\$a" ;;
    --menu)
      a=\$(head -n1 "$W/q/menu" 2>/dev/null); sed -i 1d "$W/q/menu" 2>/dev/null
      [[ -n "\$a" ]] || exit 1
      echo "\$a"; exit 0 ;;
    --checklist|--radiolist)
      for ((j = i + 2; j + 2 < \${#args[@]} + 1; j += 3)); do
        [[ "\${args[\$((j + 2))]}" == on ]] && echo "\${args[\$j]}"
      done
      exit 0 ;;
  esac
done
exit 0
EOF
stub xdg-open << EOF
#!/bin/bash
echo "xdg-open \$*" >> "$W/calls.log"
EOF

export AUDIT_ROOT="$FX" AUDIT_STATE_DIR="$STATE" AUDIT_TEST_PATH="$STUB" AUDIT_DESKTOP_USER="$U"
export PATH="$STUB:$PATH" NO_COLOR=1

# Terminal tests first: kdialog is put in place for test 4.
mv "$STUB/kdialog" "$W/kdialog.stub"

# ---------------------------------------------------------------- 1. report only
echo "== 1. report-only run (no terminal, no GUI)"
"$TOOL" --no-gui --no-wizard --report-only --use gaming,streaming,dev --deep --report-dir "$UH/Documents/reports" \
    < /dev/null > "$W/run1.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "exit status 0" || { bad "exit status $rc"; tail -30 "$W/run1.out"; }
MD=$(ls "$UH"/Documents/reports/bazzite-security-*.md 2>/dev/null | head -n1)
HTML=$(ls "$UH"/Documents/reports/bazzite-security-*.html 2>/dev/null | head -n1)
[[ -f "$MD" && -f "$HTML" ]] && ok "Markdown and HTML reports written" || bad "reports missing"
[[ "$(stat -c %U "$MD" 2>/dev/null)" == "$U" ]] && ok "report owned by the desktop user" || bad "report owner"
reject "$MD" "undo-all.sh" "a run that changed nothing names no undo script"
expect "$MD" "System updates are installed without checking their signature" "unsigned image"
expect "$MD" "Automatic updates are turned off" "update timer off"
expect "$MD" "The system image is 40 days old" "image age"
expect "$MD" "2 package(s) layered" "layered packages"
expect "$MD" "Repository 'copr:example' installs packages without a signature check" "repo gpgcheck=0"
expect "$MD" "**Now:** [copr:example] gpgcheck=0, no gpgkey= line" "report shows the current setting"
expect "$MD" "**After the fix:** [copr:example] gpgcheck=1" "report shows the setting after the fix"
expect "$MD" "repository stops working: [copr:example] names no signing key" "report warns that the repository has no key"
reject "$MD" "Repository 'off'" "disabled repo ignored"
expect "$MD" "2 Flatpak update(s) waiting" "flatpak updates"
expect "$MD" "com.visualstudio.code: can run commands outside the sandbox" "flatpak escape"
expect "$MD" "com.example.BusApp: can run commands outside the sandbox" "flatpak session bus counts as an escape"
reject "$MD" "net.lutris.Lutris: can run" "flatpak override respected"
expect "$MD" "Firmware updates are available" "firmware"
expect "$MD" "Secure Boot is off" "secure boot"
expect "$MD" "The disk is not encrypted" "disk encryption"
expect "$MD" "CPU vulnerability protections are turned off" "mitigations=off"
expect "$MD" "Games using Easy Anti-Cheat for Linux may refuse to start: 2 kernel setting(s) missing" "anti-cheat readiness for gaming"
expect "$MD" "kernel started with: sysctl.kernel.kexec_load_disabled=1; lockdown after Secure Boot is on (manual)" "with Secure Boot off, only kexec is offered"
expect "$MD" "kernel lockdown is off, and Secure Boot is disabled" "lockdown waits for Secure Boot"
expect "$MD" "SELinux is not protecting the system (permissive)" "selinux"
expect "$MD" "fs.protected_symlinks = 0" "sysctl"
expect "$MD" "The firewall lets in far more than this PC needs" "firewall zone"
expect "$MD" "3000/tcp  node" "exposed dev server"
reject "$MD" "1000/tcp  python3  (pid" "blocked listener not reported as exposed"
reject "$MD" "port(s) that nothing uses" "an unused port a wide range still opens is not offered"
expect "$MD" "LLMNR" "llmnr"
expect "$MD" "The SSH server is on, but you don't log in remotely" "ssh unused"
expect "$MD" "sudo works without a password" "sudo nopasswd"
reject "$MD" "ignored.conf" "sudoers.d files with a dot are ignored"
expect "$MD" "Automatic login is on" "autologin"
expect "$MD" "screen does not lock reliably" "screen lock"
expect "$MD" "home folder is open to other accounts" "home permissions"
expect "$MD" "readable by others" "secret permissions"
if command -v ssh-keygen >/dev/null; then
    expect "$MD" "SSH private key(s) have no passphrase" "ssh key passphrase"
    expect "$MD" "$UH/.ssh/deploy_root" "a key root owns in a home folder is still tested"
fi
expect "$MD" "Developer tools store tokens in plain text" "plaintext tokens"
expect "$MD" "can control Docker (docker group)" "docker group"
expect "$MD" "The Docker API listens on the network (port 2376)" "Docker API on the network"
reject "$MD" "2375" "loopback-only Docker API not reported"
expect "$MD" "postgres: 0.0.0.0:5432" "published container"
reject "$MD" "redis" "localhost-only container not reported"
expect "$MD" "podman (${U}) web: 0.0.0.0:8080" "rootless Podman container the firewall lets through"
reject "$MD" "localonly" "localhost-only rootless container not reported"
expect "$W/calls.log" "journalctl -b --no-pager -q _TRANSPORT=audit" "SELinux denials are also read from audit records"
expect "$MD" "2 access(es) were logged as 'would be denied'" "SELinux denials counted"
expect "$MD" "Sunshine's admin page accepts connections from the internet" "sunshine wan"
expect "$MD" "Sunshine opens ports on your router" "sunshine upnp"
expect "$MD" "Sunshine has no admin login yet" "sunshine credentials"
expect "$MD" "Autostart entries run code from suspicious places" "suspicious autostart"
awk '/^### \[HIGH\] Autostart entries run code from suspicious places/ { on = 1; next } /^### / { on = 0 } on' "$MD" > "$W/autostart-high.txt"
expect "$W/autostart-high.txt" "sneaky.desktop" "hidden payload flagged although a normal folder is in the command"
reject "$W/autostart-high.txt" "devserver.desktop" "toolchain folder (~/.nvm) not flagged"
expect "$MD" "High risk: 1 change(s) to sudo rules" "etc change to sudo rules graded high"
expect "$MD" "High risk: 1 change(s) to services, timers, scheduled jobs and startup scripts" "added service graded high"
expect "$MD" "High risk: 1 change(s) to the SSH server" "sshd change graded high"
expect "$MD" "Low risk: 1 change(s) to other settings" "printer settings graded low"
[[ $(grep -n "High risk: 1 change(s) to sudo rules" "$MD" | head -1 | cut -d: -f1) -lt $(grep -n "Low risk: 1 change(s) to other" "$MD" | head -1 | cut -d: -f1) ]] \
    && ok "high-risk /etc areas are listed first" || bad "high-risk /etc areas are not listed first"
reject "$W/run1.out" "did not complete" "no check crashed"
grep -E 'unexpected failure' "$STATE"/logs/*.log && bad "unexpected failures logged" || ok "no unexpected failures in the log"
[[ -s $(ls "$STATE"/history/findings-*.jsonl | head -n1) ]] && ok "findings history written" || bad "no history"
python3 -I -c 'import json,sys
for l in open(sys.argv[1]): json.loads(l)' "$(ls "$STATE"/history/findings-*.jsonl | head -n1)" \
    && ok "history is valid JSON lines" || bad "history JSON"
reject "$W/calls.log" "--set-default-zone" "report-only changed nothing (firewall)"
reject "$W/calls.log" "kwriteconfig6 --file" "report-only changed nothing (screen lock)"
grep -qE '^SCORE=[0-9]+$' "$STATE/last-run.conf" 2>/dev/null && ok "a full check remembers its score" || bad "no last-run.conf after a full check"

# ---------------------------------------------------------------- 2. fixes on a terminal
echo "== 2. terminal dashboard: confirm one fix, decline the next, stop"
sleep 1   # new run id
: > "$W/calls.log"; chmod 666 "$W/calls.log"
cp "$FX/etc/sudoers.d/bdatest" "$W/sudoers.before"
# Answers: dashboard entry 1 (review fixes), Enter (keep the ticks in the fix
# list), then per fix: unsigned image y, automatic updates n, sudo s(top);
# Enter after the summary, q on the dashboard.
printf '1\n\ny\nn\ns\n\nq\n' | timeout 180 script -qec "'$TOOL' --no-gui --no-wizard --fix --use gaming,streaming,dev --check image_signature,system_updates,sudo --report-dir '$UH/Documents/reports2'" /dev/null \
    > "$W/run2.out" 2>&1
expect "$W/run2.out" "Review and fix problems  —  3 can be fixed here" "dashboard offers the fixes"
expect "$W/run2.out" "✖  System image signature  —  1 high · fix available" "dashboard row per check"
expect "$W/run2.out" "Choose what to fix" "fix list shown"
expect "$W/run2.out" "[x] 1. HIGH · System updates are installed without checking their signature" "high fix ticked in the list"
expect "$W/run2.out" "→ same image and updates, signature checked" "fix list shows now → after"
expect "$W/run2.out" "[medium risk]  ⚠ Downloads: Downloads data while the fix runs; this can take several minutes. · Needs a reboot: " "fix list shows side effects and risk"
expect "$W/run2.out" "Now  image pulled without a signature check (ostree-unverified-registry)" "fix dialog shows the current setting"
expect "$W/run2.out" "Before you apply:" "fix dialog lists the side effects"
expect "$W/run2.out" "Fixes: 1 applied · 2 skipped · 0 failed" "session summary"
expect "$W/run2.out" "takes effect after a reboot" "rebase is not reported as verified"
expect "$W/calls.log" "rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/bazzite:stable" "confirmed fix ran"
reject "$W/calls.log" "systemctl enable --now uupd.timer" "declined fix did not run"
cmp -s "$W/sudoers.before" "$FX/etc/sudoers.d/bdatest" && ok "fix after 'stop' did not run" || bad "sudoers changed after stop"
UNDO=$(ls "$STATE"/undo/*/01-undo.sh 2>/dev/null | head -n1)
[[ -f "$UNDO" ]] && ok "undo step recorded" || bad "no undo step"
[[ -f "$UNDO" ]] && expect "$UNDO" "rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/bazzite:stable" "undo reverses the rebase"
expect "$(ls "$UH"/Documents/reports2/*.md | head -n1)" "Fixed during this run" "report marks the fix"

# ---------------------------------------------------------------- 3. undo
echo "== 3. undo"
: > "$W/calls.log"
printf '\ny\n' | timeout 180 script -qec "'$TOOL' --no-gui --undo" /dev/null > "$W/run3.out" 2>&1
expect "$W/calls.log" "rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/bazzite:stable" "undo ran"
ls "$STATE"/undo/*/01-undo.done >/dev/null 2>&1 && ok "undo step marked done" || bad "undo step not marked"

# ---------------------------------------------------------------- 4. KDE dialogs
echo "== 4. KDE wizard and fixes through kdialog"
mv "$W/kdialog.stub" "$STUB/kdialog"
sleep 1
: > "$W/calls.log"; : > "$W/kdialog.log"
# Wizard review page: change the answers once (1), then start (0).
# Dashboard: review fixes (the fix list ticks the two medium ones: firewall
# and file permissions), open the report, open the screen-lock check and
# fix it from there, then undo this run's firewall change. Yes/No/Cancel
# queue: firewall = apply (0); file permissions = apply (0); screen lock =
# skip (1); undo, newest first: file permissions = keep (1), firewall =
# undo (0).
mkdir -m 777 "$W/q"; printf '1\n0\n0\n0\n1\n1\n0\n' > "$W/q/answers"; chmod 666 "$W/q/answers"
printf 'fix\nreport\ncheck:check_screen_lock\nundo\n' > "$W/q/menu"; chmod 666 "$W/q/menu"
AUDIT_GUI_DISPLAY=:0 "$TOOL" --gui --wizard --check firewall,screen_lock,secrets < /dev/null > "$W/run4.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "KDE run exit status 0" || { bad "KDE run exit $rc"; tail -20 "$W/run4.out"; }
tr '\0' ' ' < "$W/kdialog.log" > "$W/kdialog.txt"
expect "$W/kdialog.txt" "STEP 1 OF 4 · YOUR PC</b></small></p><h2>How do you use this PC?" "wizard step 1 shown"
[[ $(grep -o "How do you use this PC?" "$W/kdialog.txt" | wc -l) -eq 2 ]] && ok "Change answers on the review page goes back to step 1" \
    || bad "Change answers did not go back to step 1"
expect "$W/kdialog.txt" "Ready to check this PC" "wizard review page shown"
expect "$W/kdialog.txt" "Change answers…" "review page offers to change the answers"
expect "$W/kdialog.txt" "Last full check</b>&nbsp;&nbsp;</td><td>20" "wizard overview shows the last full check"
expect "$W/kdialog.txt" "STEP 2 OF 4 · OPTIONS</b></small></p><h2>Options" "wizard options step shown"
expect "$W/kdialog.txt" "--menu" "dashboard shown"
expect "$W/kdialog.txt" "Review and fix problems" "dashboard offers fixes"
expect "$W/kdialog.txt" "Choose what to fix" "fix list shown"
expect "$W/kdialog.txt" "Autolock=true, LockOnResume=true off" "low fix not ticked in the fix list"
expect "$W/kdialog.txt" " — detected: Sunshine is set to start" "wizard shows what it detected"
expect "$W/kdialog.txt" "Choose what other devices on your network may reach" "firewall choice list shown"
expect "$W/kdialog.txt" "Keep 3000/tcp open for node" "firewall list offers the running dev server"
expect "$W/kdialog.txt" "MEDIUM</b></font> &nbsp;The firewall lets in far more than this PC needs</h3>" "fix dialog is rich text"
expect "$W/kdialog.txt" "<td><b>Now</b></td><td>zone 'FedoraWorkstation' opens 1025-65535/udp 1025-65535/tcp" "fix dialog shows the current zone"
expect "$W/kdialog.txt" "(new default) allows: DHCPv6, mDNS" "fix dialog shows the zone as ticked"
expect "$W/kdialog.txt" "No longer reachable from other devices:" "fix dialog names what the new zone blocks"
expect "$W/kdialog.txt" "3000/tcp (node)" "... including the running dev server"
expect "$W/kdialog.txt" "--warningyesnocancel" "a fix with side effects uses the warning dialog"
expect "$W/kdialog.txt" "What the check saw:" "check page shows the settings it saw"
expect "$W/run4.out" "After the fixes that were checked again:" "score after verified fixes"
MD4=$(ls -t "$UH"/Documents/bazzite-security-check/*.md | head -n1)
expect "$MD4" "Fixed during this run - checked again: gone" "verified fix marked in the report"
expect "$MD4" "/undo-all.sh" "a run that applied fixes names its undo script"
expect "$W/kdialog.txt" "checked again: still found" "fix that did not take is reported as still found"
expect "$W/kdialog.txt" "Firewall  —  1 medium · fix applied, still found" "dashboard row says the fix did not take"
expect "$MD4" "Open (fixed during this run, then undone)" "a fix undone from the dashboard is open again"
expect "$W/calls.log" "firewall-cmd --set-default-zone=FedoraWorkstation" "dashboard undo ran"
reject "$W/kdialog.txt" "quot;quot" "no double-escaped HTML"
reject "$W/kdialog.txt" "not carried over" "no 'not copied' warning when the old zone has only services and ports"
expect "$W/calls.log" "firewall-cmd --permanent --new-zone=bazzite-desktop" "zone created"
expect "$W/calls.log" "--add-service=dhcpv6-client --add-service=mdns --add-port=47984/tcp" "zone gets the chosen services"
expect "$W/calls.log" "--add-service=ssh" "ssh kept (SSH server is in use)"
expect "$W/calls.log" "--add-service=samba-client" "services the old zone allowed on purpose are kept"
reject "$W/calls.log" "--add-port=1025-65535" "the wide port range is dropped"
expect "$W/calls.log" "--add-port=25565/tcp" "narrow ports the old zone allowed are kept"
expect "$W/kdialog.txt" "port:47990/tcp Keep 47990/tcp open (Sunshine's admin page" "Sunshine admin port offered, but unticked"
[[ "$(grep -o -- '--add-port=47984/tcp' "$W/calls.log" | wc -l)" -eq 1 ]] && ok "a port an item already opens is not added twice" \
    || bad "--add-port=47984/tcp added $(grep -o -- '--add-port=47984/tcp' "$W/calls.log" | wc -l) times"
reject "$W/calls.log" "--add-port=3000/tcp" "dev server port not opened"
reject "$W/calls.log" "47990" "Sunshine admin port stays closed"
expect "$W/calls.log" "firewall-cmd --set-default-zone=bazzite-desktop" "default zone switched"
[[ "$(stat -c %a "$UH/.ssh/id_ed25519")" == 600 ]] && ok "SSH key now 600" || bad "SSH key mode $(stat -c %a "$UH/.ssh/id_ed25519")"
[[ "$(stat -c %a "$UH/projects/app/.env")" == 600 ]] && ok ".env now 600" || bad ".env mode"
reject "$W/calls.log" "kwriteconfig6 --file kscreenlockerrc" "skipped screen-lock fix did not run"
expect "$W/calls.log" "xdg-open" "report opened at the end"
reject "$W/run4.out" "New since last check" "findings of run 1 are not 'new' after a partial run 2"
UNDO4=$(ls -d "$STATE"/undo/* | tail -n1)
expect "$UNDO4/01-undo.done" "firewall-cmd --set-default-zone=FedoraWorkstation" "firewall undo restores the old zone (and is marked done)"
expect "$UNDO4/02-undo.sh" "chmod 644" "permission undo restores the old mode"
expect "$UNDO4/02-undo.sh" "# FINDING: " "undo steps name their finding"

# ---------------------------------------------------------------- 5. every fix's commands
echo "== 5. every fix builds valid shell commands"
(
    # shellcheck source=../bazzite-sec-audit.sh
    source "$TOOL"
    _load_check_table
    detect_desktop_user
    RUN_ID="test"; RUN_LOG="$W/fix5.log"; STATE_DIR="$STATE"; UI_MODE="none"
    F_SEV=(medium); F_TITLE=(t); F_DETAIL=(d); F_MANUAL=(m); F_FIX=(x); F_STATE=(open); CURRENT_FINDING=0
    ui_checklist() { shift; while [[ $# -ge 3 ]]; do echo "$1"; shift 3; done; }
    ui_yesno() { return 1; }
    apply_change() {
        if bash -n <<< "$1" 2>"$W/err" && bash -n <<< "$2" 2>>"$W/err"; then
            echo "OK $CUR"
        else
            echo "BAD $CUR: $(cat "$W/err")"; printf '%s\n---\n%s\n' "$1" "$2"
        fi
        return 1
    }
    run() { CUR="$1"; "$@" || true; }
    run fix_rebase "ostree-image-signed:docker://ghcr.io/ublue-os/bazzite:stable" "ostree-unverified-registry:ghcr.io/ublue-os/bazzite:stable" r
    run fix_enable_unit uupd.timer masked
    run fix_layered_remove htop kitty
    run fix_repo_setting /etc/yum.repos.d/copr.repo "copr:example.org" gpgcheck 1
    run fix_flatpak_update 2 "$U"
    run fix_flatpak_restrict "system|com.visualstudio.code|escape,host" "${U}|org.example.App|host"
    run fix_kargs_delete mitigations=off nopti
    run fix_anticheat_kargs lockdown=integrity sysctl.kernel.kexec_load_disabled=1
    run fix_selinux_config
    run fix_selinux_enforce karg 3
    run fix_sysctl fs.protected_symlinks kernel.randomize_va_space
    run fix_firewall_zone FedoraWorkstation "FedoraWorkstation" enp5s0
    run fix_llmnr
    run fix_close_ports "devzone|3000/tcp|node" "devzone|8000/tcp|nothing listening now" "dev zone|1-65535/tcp|ignored"
    run fix_disable_units sshd.service sshd.socket
    run fix_ssh_dropin "PasswordAuthentication no" "KbdInteractiveAuthentication no"
    run fix_lock_account root
    run fix_sudo_line /etc/sudoers.d/bdatest 1 "bdatest ALL=(ALL) NOPASSWD: ALL"
    run fix_sudo_line /etc/sudoers.d/bdatest 2 "Defaults !authenticate"
    run fix_autologin_off /etc/sddm.conf.d/kde_settings.conf
    run fix_autologin_off /etc/gdm/custom.conf
    run fix_autologin_override
    run fix_home_mode "$U" "$UH" 755
    run fix_screen_lock "$U" "Autolock|bool|true|false" "Timeout|int|10|"
    run fix_chmod_files "${U}|644|$UH/a file with spaces"
    run fix_leave_group "$U" docker
    run fix_docker_default_ip
    run fix_containers_localhost 1 "docker|postgres"
    run fix_user_units_off "$U" app-dev.lizardbyte.app.Sunshine.service
    run fix_sunshine_setting "$U" "$UH/.config/sunshine/sunshine.conf" upnp off app-dev.lizardbyte.app.Sunshine.service
    run fix_strip_suid "4755|/opt/x/helper"
    run fix_remove_world_write "${U}|666|$UH/x" "root|666|/etc/y"
    run fix_clamav_install clamav clamav-freshclam
    run fix_clamav_defs disabled
    run fix_clamav_defs enabled
    run fix_clamav_defs masked
    run fix_clamav_defs missing
    run fix_clamav_defs not-found
    run fix_clamav_defs masked-runtime
    run fix_clamav_defs enabled-runtime
    run fix_clamav_custom_off "https://a.example/x.ndb" "http://b.example/p/key123/y.hdb"
) > "$W/fix5.out" 2>&1
n_ok=$(grep -c '^OK ' "$W/fix5.out" || true)
if grep -q '^BAD ' "$W/fix5.out"; then bad "invalid fix commands:"; grep -A8 '^BAD ' "$W/fix5.out"
else ok "all ${n_ok} fix scripts and their undo steps parse"; fi
[[ "$n_ok" -ge 32 ]] && ok "every fix function was exercised" || { bad "only ${n_ok} fixes ran"; cat "$W/fix5.out" | head -20; }

# ---------------------------------------------------------------- 5b. the malware scan
echo "== 5b. the malware scan and ClamAV's setup"
(
    # shellcheck source=../bazzite-sec-audit.sh
    source "$TOOL"
    _load_check_table
    RUN_LOG="$W/clam.log"; UI_MODE="none"; CURRENT_CHECK=check_deep_malware
    CR="$W/clam-root"; mkdir -p "$CR/var/lib/clamav" "$CR/etc"; AUDIT_ROOT="$CR"
    REGULAR_USERS=("$U"); DESKTOP_USER="$U"; IS_OSTREE=1; RPMOSTREE_JSON='{"deployments":[{"booted":true,"requested-packages":[]}]}'
    HAVE=""; FLATPAKS=""; SVC=enabled; SCAN_OUT=""; SCAN_RC=0
    _have() { [[ " $HAVE " == *" $1 "* ]]; }
    _flatpak_installed() { [[ " $FLATPAKS " == *" $1 "* ]]; }
    _unit_state() { printf '%s' "$SVC"; }
    _home_of() { printf '%s' "$UH"; }
    _as_user() {
        local who="$1"; shift
        case "$1" in
            xdg-user-dir) printf '%s' "$UH" ;;
            timeout) printf '%s %s\n' "$who" "$*" >> "$W/clam-scans"; printf '%s' "$SCAN_OUT"; return "$SCAN_RC" ;;
        esac
    }
    _as_desktop_user() { _as_user "$DESKTOP_USER" "$@"; }
    defs() { rm -f "$CR"/var/lib/clamav/*; [[ $# -gt 0 ]] || return 0; echo x > "$CR/var/lib/clamav/main.cvd"; echo x > "$CR/var/lib/clamav/daily.cld"; touch -d "$1 days ago" "$CR/var/lib/clamav/daily.cld"; }
    case_() {
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=(); F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=(); F_AFFECT=(); F_KEYX=()
        CHECK_SKIPPED=(); CHECK_NOTE=(); CHECK_FAILED=(); : > "$W/clam-scans"
        check_deep_malware > /dev/null 2>&1
    }
    scans() { grep -c . "$W/clam-scans" || true; }

    # ClamUI without the system's ClamAV: ClamUI cannot scan; the fix layers both packages.
    HAVE=""; FLATPAKS="io.github.linx_systems.ClamUI"; defs; case_
    [[ "${F_SEV[0]:-}" == medium && "${F_TITLE[0]}" == "ClamUI is installed, but ClamAV is not set up on the system" \
       && "${F_FIX[0]}" == "fix_clamav_install clamav clamav-freshclam" && "${F_WARN[0]}" == "downloads|"*$'\n'"needs a reboot|"* \
       && "${F_MANUAL[0]##*$'\n'}" == "# "* && -z "$(bash -n <<< "${F_MANUAL[0]}" 2>&1)" ]] \
       && [[ ${#F_SEV[@]} -eq 1 && "${CHECK_SKIPPED[check_deep_malware]:-}" == "ClamAV is not installed" && "$(scans)" -eq 0 ]] && echo "clamui-without-clamav-offers-the-setup"
    # ... and not again while the layered packages wait for the restart (the image is staged) ...
    RPMOSTREE_JSON='{"deployments":[{"staged":true,"booted":false,"requested-packages":["clamav","clamav-freshclam"]},{"booted":true}]}'; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_SKIPPED[check_deep_malware]:-}" == *"waits for a restart"* \
       && "${CHECK_NOTE[check_deep_malware]:-}" == *"waiting for the restart: clamav clamav-freshclam"* ]] && echo "clamav-waiting-for-restart-is-not-offered-again"
    # ... but an older image to roll back to, which still lists them, is not a restart that waits.
    RPMOSTREE_JSON='{"deployments":[{"booted":true,"requested-packages":[]},{"booted":false,"requested-packages":["clamav","clamav-freshclam"]}]}'; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_install clamav clamav-freshclam" && "${CHECK_SKIPPED[check_deep_malware]:-}" == "ClamAV is not installed" ]] && echo "rollback-image-is-not-a-pending-restart"
    # Only what the waiting image lacks is offered.
    RPMOSTREE_JSON='{"deployments":[{"staged":true,"requested-packages":["clamav"]},{"booted":true}]}'; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_install clamav-freshclam" && "${CHECK_NOTE[check_deep_malware]:-}" == *"restart: clamav" \
       && "${CHECK_SKIPPED[check_deep_malware]:-}" == *"waits for a restart"* ]] && echo "only-the-missing-package-is-offered"
    RPMOSTREE_JSON='{"deployments":[{"booted":true,"requested-packages":[]}]}'
    # Nothing at all, no ClamUI: an optional note with the same fix; ClamTk alone needs nothing.
    FLATPAKS=""; case_
    [[ "${F_SEV[0]:-}" == info && "${F_FIX[0]}" == "fix_clamav_install clamav clamav-freshclam" ]] && echo "no-clamav-is-an-optional-fix"
    FLATPAKS="com.gitlab.davem.ClamTk"; SCAN_OUT=""; SCAN_RC=0; case_
    [[ ${#F_SEV[@]} -eq 0 && "$(scans)" -eq 1 ]] && grep -q "flatpak run --command=clamscan com.gitlab.davem.ClamTk" "$W/clam-scans" && echo "clamtk-alone-scans-without-setup"
    # ClamTk and ClamUI: ClamTk still scans, and ClamUI's missing ClamAV is still a finding.
    FLATPAKS="com.gitlab.davem.ClamTk io.github.linx_systems.ClamUI"; case_
    [[ "${F_TITLE[0]:-}" == "ClamUI is installed"* && "$(scans)" -eq 1 ]] && echo "clamtk-scans-while-clamui-is-not-set-up"
    # The system's clamscan without freshclam.
    FLATPAKS=""; HAVE="clamscan"; defs 1; case_
    [[ "${F_SEV[0]:-}" == low && "${F_TITLE[0]}" == *"freshclam is not installed" && "${F_FIX[0]}" == "fix_clamav_install clamav-freshclam" && "$(scans)" -eq 1 ]] && echo "clamscan-without-freshclam"
    # ... with freshclam layered and waiting for the restart: a note, no finding, and the scan runs.
    RPMOSTREE_JSON='{"deployments":[{"staged":true,"requested-packages":["clamav","clamav-freshclam"]},{"booted":true,"requested-packages":["clamav"]},{"requested-packages":["clamav"]}]}'; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" == *"waiting for the restart: clamav-freshclam"* && "$(scans)" -eq 1 ]] && echo "freshclam-waiting-for-restart"
    # ... and with the only other image a rollback that lists clamav: still offered.
    RPMOSTREE_JSON='{"deployments":[{"booted":true,"requested-packages":["clamav"]},{"requested-packages":["clamav","clamav-freshclam"]}]}'; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_install clamav-freshclam" ]] && echo "freshclam-offered-despite-rollback"
    # A malformed status (a string, not a list of packages) hides nothing.
    RPMOSTREE_JSON='{"deployments":[{"staged":true,"requested-packages":"clamav-freshclam-helper"},{"booted":true}]}'; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_install clamav-freshclam" ]] && echo "malformed-status-hides-nothing"
    RPMOSTREE_JSON='{"deployments":[{"booted":true,"requested-packages":[]}]}'
    # No definitions: a finding whose fix downloads them, and no scan.
    HAVE="clamscan freshclam"; SVC=disabled; defs; case_
    [[ "${F_SEV[0]:-}" == medium && "${F_TITLE[0]}" == "ClamAV has no virus definitions" && "${F_FIX[0]}" == "fix_clamav_defs disabled" \
       && "${F_AFTER[0]}" == *"updated automatically"* && "${CHECK_SKIPPED[check_deep_malware]:-}" == *"no virus definitions"* && "$(scans)" -eq 0 ]] && echo "no-definitions-offers-download"
    # Only the daily set: incomplete, not "none".
    defs; echo x > "$CR/var/lib/clamav/daily.cld"; case_
    [[ "${F_TITLE[0]:-}" == "ClamAV's virus definitions are incomplete" && "${F_NOW[0]}" == *"incomplete set"* && "$(scans)" -eq 0 ]] && echo "incomplete-definitions"
    # With the service on, the manual steps do not tell to turn it on.
    SVC=enabled; defs; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_defs enabled" && "${F_AFTER[0]}" == "definitions downloaded now" \
       && "$(tr '\n' '|' <<< "${F_MANUAL[0]}")" == "# The service holds the lock freshclam needs: stop it first.|sudo systemctl stop clamav-freshclam.service|sudo freshclam --update-db=main --update-db=daily --update-db=bytecode|sudo systemctl start clamav-freshclam.service|" \
       && "$(bash -n <<< "${F_MANUAL[0]}" 2>&1)" == "" ]] && echo "manual-steps-follow-the-service"
    # Every way the manual steps can come out is shell that can be pasted.
    pasteable=1
    for SVC in enabled disabled masked masked-runtime enabled-runtime not-found; do
        case_; bash -n <<< "${F_MANUAL[0]:-x(}" 2>/dev/null || { pasteable=0; echo "not pasteable for ${SVC}: ${F_MANUAL[0]:-}"; }
    done
    SVC=enabled; [[ $pasteable -eq 1 ]] && echo "manual-steps-can-be-pasted"
    # A runtime mask needs "unmask --runtime"; on only until the restart is turned on for good.
    SVC=masked-runtime; case_
    [[ "${F_MANUAL[0]:-}" == *"sudo systemctl unmask --runtime clamav-freshclam.service"* ]] && echo "runtime-mask-manual-steps"
    SVC=enabled-runtime; case_
    [[ "${F_MANUAL[0]:-}" == *"systemctl enable --now clamav-freshclam.service"* && "${F_AFTER[0]}" == *"updated automatically"* ]] && echo "runtime-enable-made-permanent"
    SVC=disabled
    # Old definitions: a low finding, and the scan still runs.
    defs 12; case_
    [[ "${F_SEV[0]:-}" == low && "${F_TITLE[0]}" == "ClamAV's virus definitions are 12 days old" && "${F_DETAIL[0]}" == *"clamav-freshclam.service is disabled"* && "$(scans)" -eq 1 ]] && echo "old-definitions-found-and-scanned"
    SVC=enabled; defs 0; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" == *"updated today (clamav-freshclam.service: enabled)"*"nothing found"* ]] && echo "fresh-definitions-no-finding"
    # The scan runs as the account, stays on each folder's file system, and never as root.
    grep -q "^${U} timeout 1800 clamscan -r -i --no-summary --cross-fs=no .* --database=/var/lib/clamav " "$W/clam-scans" && ! grep -q "^root " "$W/clam-scans" && echo "scan-as-account-on-one-file-system"
    # A scan stopped by the time limit says so - not that the database is missing.
    SCAN_OUT=""; SCAN_RC=124; case_
    [[ "${CHECK_SKIPPED[check_deep_malware]:-}" == "the scan was stopped after 30 minutes, before it finished"* && "${CHECK_SKIPPED[check_deep_malware]:-}" != *database* && ${#F_SEV[@]} -eq 0 ]] && echo "timeout-is-not-blamed-on-the-database"
    # Definitions that do not load: a finding that downloads them again.
    SCAN_OUT=$'LibClamAV Error: cli_loaddbdir(): No supported database files found in /var/lib/clamav\nERROR: Can\'t open file or directory\n'; SCAN_RC=2; case_
    [[ "${F_TITLE[0]:-}" == "ClamAV cannot load its virus definitions" && "${F_FIX[0]}" == "fix_clamav_defs enabled" && "${CHECK_SKIPPED[check_deep_malware]:-}" == *"cli_loaddbdir"* ]] && echo "broken-definitions-offer-download"
    SCAN_OUT=$'LibClamAV Error: cli_cvdload(): Corrupted CVD header\n'; SCAN_RC=2; case_
    [[ "${F_TITLE[0]:-}" == "ClamAV cannot load its virus definitions" ]] && echo "corrupted-cvd-is-a-database-error"
    SCAN_OUT=$'LibClamAV Error: cli_cvdverify: Can\'t read CVD header\n'; case_
    [[ "${F_TITLE[0]:-}" == "ClamAV cannot load its virus definitions" ]] && echo "unreadable-cvd-is-a-database-error"
    # Without freshclam, nothing offers to download them: the skip says why.
    HAVE="clamscan"; SCAN_OUT=$'LibClamAV Error: cli_cvdload(): Corrupted CVD header\n'; case_
    [[ "${F_TITLE[0]:-}" == *"freshclam is not installed" && ${#F_SEV[@]} -eq 1 && "${CHECK_SKIPPED[check_deep_malware]:-}" == *"freshclam, which downloads them, is not installed"* ]] && echo "broken-definitions-without-freshclam"
    SCAN_OUT=""; SCAN_RC=0; defs 12; case_
    [[ "${F_TITLE[0]:-}" == *"freshclam is not installed" && ${#F_SEV[@]} -eq 1 && "$(scans)" -eq 1 ]] && echo "old-definitions-without-freshclam"
    defs; case_
    [[ "${F_TITLE[0]:-}" == *"freshclam is not installed" && ${#F_SEV[@]} -eq 1 && "$(scans)" -eq 0 \
       && "${CHECK_SKIPPED[check_deep_malware]:-}" == *"freshclam, which downloads them, is not installed"* ]] && echo "no-definitions-without-freshclam"
    # The check's own error trap stays quiet (a condition that is false is not an error).
    ( set -E; trap 'echo "ERR at $LINENO: $BASH_COMMAND"' ERR; check_deep_malware ) > "$W/clam-err" 2>/dev/null
    ! grep -q "^ERR at" "$W/clam-err" && echo "no-error-trap" || head -3 "$W/clam-err"
    HAVE="clamscan freshclam"; defs 0
    # A file it could not read, even one named "database", is not a database error.
    SCAN_OUT="$UH/Downloads/database.sqlite: Can't open file or directory ERROR"$'\n'; SCAN_RC=2; case_
    [[ ${#F_SEV[@]} -eq 0 && -z "${CHECK_SKIPPED[check_deep_malware]:-}" && "${CHECK_NOTE[check_deep_malware]:-}" == *"may not read were left out"* ]] && echo "unreadable-file-is-not-a-database-error"
    # A hit is reported.
    SCAN_OUT="$UH/Downloads/x.exe: Win.Test.EICAR_HDB-1 FOUND"$'\n'; SCAN_RC=1; case_
    [[ "${F_SEV[0]:-}" == high && "${F_TITLE[0]}" == "ClamAV found 1 infected file(s)" ]] && echo "infected-file-found"
    # ... also from a scan the time limit stopped, with a note that it did not finish.
    SCAN_RC=124; case_
    [[ "${F_TITLE[0]:-}" == "ClamAV found 1 infected file(s)" && -z "${CHECK_SKIPPED[check_deep_malware]:-}" \
       && "${CHECK_NOTE[check_deep_malware]:-}" == *"stopped after 30 minutes, before it finished"* ]] && echo "hit-from-a-stopped-scan"
    # The definitions fix, run: freshclam fails, the service is started again all the same, and the fix fails.
    mkdir -p "$W/clam-bin"
    printf '#!/bin/bash\necho "systemctl $*" >> "%s"\n' "$W/clam-fix.log" > "$W/clam-bin/systemctl"
    printf '#!/bin/bash\necho freshclam >> "%s"; exit 17\n' "$W/clam-fix.log" > "$W/clam-bin/freshclam"
    chmod 755 "$W/clam-bin/systemctl" "$W/clam-bin/freshclam"
    apply_change() { printf '%s\n' "$1" > "$W/clam-fix.sh"; printf '%s\n' "$2" > "$W/clam-fix.undo"; return 0; }
    fixrun() { : > "$W/clam-fix.log"; fix_clamav_defs "$1"; PATH="$W/clam-bin:$PATH" bash -c 'set -euo pipefail; source "$1"' _ "$W/clam-fix.sh"; }
    fixrun enabled; rc=$?
    [[ $rc -eq 17 && "$(tr '\n' '|' < "$W/clam-fix.log")" == "systemctl stop clamav-freshclam.service|freshclam|systemctl start clamav-freshclam.service|" \
       && "$(cat "$W/clam-fix.undo")" == "systemctl start clamav-freshclam.service" ]] && echo "failed-download-restarts-the-service"
    fixrun disabled; rc=$?
    [[ $rc -eq 17 && "$(tr '\n' '|' < "$W/clam-fix.log")" == *"freshclam|systemctl enable --now clamav-freshclam.service|" && "$(cat "$W/clam-fix.undo")" == "systemctl disable --now clamav-freshclam.service" ]] && echo "failed-download-still-turns-updates-on"
    fixrun masked-runtime; rc=$?
    [[ $rc -eq 17 && "$(tr '\n' '|' < "$W/clam-fix.log")" == "systemctl stop clamav-freshclam.service|freshclam|systemctl unmask --runtime clamav-freshclam.service|systemctl enable --now clamav-freshclam.service|" \
       && "$(tr '\n' '|' < "$W/clam-fix.undo")" == "systemctl disable --now clamav-freshclam.service|systemctl mask --runtime clamav-freshclam.service|" ]] && echo "runtime-mask-fix-and-undo"
    fixrun enabled-runtime
    [[ "$(tr '\n' '|' < "$W/clam-fix.undo")" == "systemctl disable clamav-freshclam.service|systemctl enable --runtime clamav-freshclam.service|" ]] && echo "runtime-enable-undo-restores-it"
    # A service that does not start: the download's failure is kept; after a good download the start's failure is the fix's.
    printf '#!/bin/bash\necho "systemctl $*" >> "%s"; [[ $1 == start ]] && exit 3; exit 0\n' "$W/clam-fix.log" > "$W/clam-bin/systemctl"
    fixrun enabled; rc=$?
    [[ $rc -eq 17 && "$(tr '\n' '|' < "$W/clam-fix.log")" == *"systemctl start clamav-freshclam.service|" ]] && echo "start-failure-keeps-the-download-status"
    printf '#!/bin/bash\necho freshclam >> "%s"\n' "$W/clam-fix.log" > "$W/clam-bin/freshclam"
    fixrun enabled; rc=$?
    [[ $rc -eq 3 ]] && echo "start-failure-fails-the-fix"
    fixrun not-found; rc=$?
    [[ $rc -eq 0 && "$(tr '\n' '|' < "$W/clam-fix.log")" == "freshclam|" ]] && echo "no-service-only-downloads"
    # DatabaseDirectory from freshclam.conf is where the definitions are looked for.
    printf 'DatabaseDirectory "/srv/quoted"\n' > "$CR/etc/freshclam.conf"
    [[ "$(_clamav_db_dir)" == /srv/quoted ]] && echo "quoted-database-directory"
    mkdir -p "$CR/srv/defs"; printf 'DatabaseDirectory /srv/defs\n' > "$CR/etc/freshclam.conf"; SCAN_OUT=""; SCAN_RC=0; defs 0; case_
    [[ "$(_clamav_db_dir)" == /srv/defs && "${F_TITLE[0]:-}" == "ClamAV has no virus definitions" && "${F_DETAIL[0]}" == *"/srv/defs"* ]] && echo "database-directory-from-freshclam-conf"
    # ... and clamscan, which does not read freshclam.conf, is told to use them.
    echo x > "$CR/srv/defs/main.cvd"; echo x > "$CR/srv/defs/daily.cvd"; case_
    [[ ${#F_SEV[@]} -eq 0 ]] && grep -q -- " --database=/srv/defs " "$W/clam-scans" && echo "scan-uses-the-database-directory"
    # The layering fix records that it needs a restart.
    apply_change() { printf '%s' "$4" > "$W/clam-reboot"; return 0; }
    fix_clamav_install clamav clamav-freshclam
    [[ -n "$(cat "$W/clam-reboot")" ]] && echo "layering-records-the-restart"

    # Extra signature sources (DatabaseCustomURL).
    DEAD="https://urlhaus.example/downloads/urlhaus.ndb"; OK2="http://sigs.example/shell.ldb"
    KEYED="https://api.example/v2/files/exports/SECRETKEY123/urlhaus_clamav.ndb"
    printf 'DatabaseMirror database.clamav.net\nDatabaseCustomURL %s\n  DatabaseCustomURL %s\nDatabaseCustomURL %s\nExtraDatabase foo\nExtraDatabase a;b\nExtraDatabase SafeBrowsing\n' "$DEAD" "$OK2" "$KEYED" > "$CR/etc/freshclam.conf"
    defs 0; HAVE="clamscan freshclam"; SVC=enabled; SCAN_OUT=""; SCAN_RC=0
    FCLOG="WARNING: downloadFile: Unexpected response (410) from ${DEAD}
ERROR: Can't download urlhaus.ndb from ${DEAD}
Update failed for custom database URL: ${DEAD}
ERROR: Update failed."
    _clamav_fc_log() { printf '%s\n' "$FCLOG"; }
    # The definitions are looked for in /var/lib/clamav again (freshclam.conf no longer moves them).
    case_
    [[ "${F_SEV[0]:-}" == low && "${F_TITLE[0]}" == "freshclam cannot download 1 extra signature source(s)" \
       && "${F_FIX[0]}" == "fix_clamav_custom_off $(printf '%q' "$DEAD")" && "${F_DETAIL[0]}" == *"urlhaus.example/…/urlhaus.ndb (HTTP 410)"* \
       && "${F_DETAIL[0]}" == *"listed after it, are no longer updated"*"sigs.example/shell.ldb, api.example/…/urlhaus_clamav.ndb"* \
       && "${F_DETAIL[0]}${F_MANUAL[0]}${F_NOW[0]}${F_AFTER[0]}" != *SECRETKEY123* && -z "$(bash -n <<< "${F_MANUAL[0]}" 2>&1)" \
       && "$(scans)" -eq 1 ]] && echo "failing-extra-source-found"
    # A later download of it that worked clears the failure.
    FCLOG+=$'\nurlhaus.ndb updated (version: custom database, sigs: 12)'; echo x > "$CR/var/lib/clamav/urlhaus.ndb"; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" == *"not in /var/lib/clamav yet: sigs.example/shell.ldb, api.example/…/urlhaus_clamav.ndb"* ]] && echo "later-success-clears-and-missing-is-a-note"
    # No failure in the log, nothing missing: nothing to say.
    echo x > "$CR/var/lib/clamav/shell.ldb"; echo x > "$CR/var/lib/clamav/urlhaus_clamav.ndb"; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" != *"Extra signature"* ]] && echo "extra-sources-all-there"
    # The definitions fix updates only the official sets (and ExtraDatabase names that are names).
    [[ "$(_freshclam_cmd)" == "freshclam --update-db=main --update-db=daily --update-db=bytecode --update-db=safebrowsing" ]] && echo "definitions-fix-only-official-sets"
    cp "$CR/etc/freshclam.conf" "$W/clam-conf.keep"; printf 'Bytecode no\nExcludeDatabase Daily\nExtraDatabase valhalla\n' >> "$CR/etc/freshclam.conf"
    [[ "$(_freshclam_cmd)" == "freshclam --update-db=main --update-db=safebrowsing --update-db=valhalla" ]] && echo "definitions-fix-follows-exclusions"
    cp "$W/clam-conf.keep" "$CR/etc/freshclam.conf"
    # A failure that may pass (one busy answer) is a note, with what freshclam did not reach.
    rm -f "$CR/var/lib/clamav/urlhaus.ndb"
    FCLOG="WARNING: downloadFile: Unexpected response (503) from ${DEAD}
ERROR: Can't download urlhaus.ndb from ${DEAD}
Update failed for custom database URL: ${DEAD}"; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" == *"could not download urlhaus.example/…/urlhaus.ndb (HTTP 503); it may work next time. freshclam stopped there, so these were not updated: sigs.example/shell.ldb, api.example/…/urlhaus_clamav.ndb."* ]] && echo "passing-failure-is-a-note"
    # No connection in two updates, never worked: not coming back. Worked before: may pass.
    CONN="ERROR: Download failed (7) ERROR:  Message: Could not connect to server
ERROR: Can't download urlhaus.ndb from ${DEAD}
Update failed for custom database URL: ${DEAD}"
    RUN="ClamAV update process started at Sat Nov 21 00:13:55 2026"
    FCLOG="${RUN}"$'\n'"${CONN}"$'\n'"${RUN}"$'\n'"${CONN}"; case_
    [[ "${F_DETAIL[0]:-}" == *"urlhaus.example/…/urlhaus.ndb (download failed)"* && "${F_FIX[0]}" == fix_clamav_custom_off* ]] && echo "connection-failure-twice-is-a-finding"
    FCLOG="urlhaus.ndb updated (version: custom database, sigs: 3)"$'\n'"${RUN}"$'\n'"${CONN}"$'\n'"${RUN}"$'\n'"${CONN}"; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" == *"(download failed); it may work next time"* ]] && echo "worked-before-is-a-note"
    # One address that starts another's is not blamed for the other's failure.
    P1="https://p.example/db/x.ndb"; P2="https://p.example/db/x.ndb.old"
    printf 'DatabaseCustomURL %s\nDatabaseCustomURL %s\n' "$P1" "$P2" > "$CR/etc/freshclam.conf"
    FCLOG="WARNING: downloadFile: file not found: ${P2}
ERROR: Can't download x.ndb.old from ${P2}
Update failed for custom database URL: ${P2}"; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_custom_off $(printf '%q' "$P2")" && "${F_DETAIL[0]}" == *"x.ndb.old (HTTP 404)"* ]] && echo "prefix-address-not-blamed"
    # As freshclam words a refusal (403): two updates are needed, one is a note.
    printf 'DatabaseCustomURL %s\nDatabaseCustomURL %s\n' "$P1" "$P2" > "$CR/etc/freshclam.conf"
    F403="WARNING: Can't download x.ndb.old from ${P2}
WARNING: FreshClam received error code 403 from the ClamAV Content Delivery Network (CDN).
WARNING: You are on cool-down until after: 2026-11-21 02:00:00"
    FCLOG="${RUN}"$'\n'"${F403}"; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" == *"x.ndb.old (HTTP 403); it may work next time"* ]] && echo "refusal-once-is-a-note"
    FCLOG="${RUN}"$'\n'"${F403}"$'\n'"${RUN}"$'\n'"${F403}"; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_custom_off $(printf '%q' "$P2")" ]] && echo "refusal-in-two-updates-is-a-finding"
    # A rate limit (429) is never "gone"; something that is not a database is, after two updates.
    F429="${F403//403/429}"; FCLOG="${RUN}"$'\n'"${F429}"$'\n'"${RUN}"$'\n'"${F429}"; case_
    [[ ${#F_SEV[@]} -eq 0 && "${CHECK_NOTE[check_deep_malware]:-}" == *"(HTTP 429); it may work next time"* ]] && echo "rate-limit-is-a-note"
    # freshclam goes on after a rate limit: the source after it is not said to be left out.
    printf 'DatabaseCustomURL %s\nDatabaseCustomURL https://later.example/after.hdb\n' "$P2" > "$CR/etc/freshclam.conf"; case_
    [[ "${CHECK_NOTE[check_deep_malware]:-}" == *"(HTTP 429); it may work next time."* && "${CHECK_NOTE[check_deep_malware]:-}" != *"stopped there"* ]] && echo "rate-limit-stops-nothing"
    printf 'DatabaseCustomURL %s\nDatabaseCustomURL %s\n' "$P1" "$P2" > "$CR/etc/freshclam.conf"
    NOTDB="Unexpected error when attempting to update from custom database URL: ${P2}"
    FCLOG="${RUN}"$'\n'"${NOTDB}"$'\n'"${RUN}"$'\n'"${NOTDB}"; case_
    [[ "${F_DETAIL[0]:-}" == *"x.ndb.old (not a database)"* ]] && echo "not-a-database-in-two-updates"
    # ... but not when its file is there: it worked before.
    echo x > "$CR/var/lib/clamav/x.ndb.old"; case_
    [[ ${#F_SEV[@]} -eq 0 ]] && echo "file-there-means-it-worked"; rm -f "$CR/var/lib/clamav/x.ndb.old"
    # A time stamp in front of the lines (LogTime yes).
    FCLOG="WARNING: Sat Nov 21 00:52:05 2026 -> downloadFile: Unexpected response (410) from ${P2}"; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_custom_off $(printf '%q' "$P2")" ]] && echo "logtime-failure-counts"
    FCLOG+=$'\n'"Sat Nov 21 01:52:05 2026 -> x.ndb.old updated (version: custom database, sigs: 4)"; case_
    [[ ${#F_SEV[@]} -eq 0 ]] && echo "logtime-success-clears"
    # An official set's line does not clear a source whose file has the same name.
    printf 'DatabaseCustomURL https://o.example/x/daily.cld\n' > "$CR/etc/freshclam.conf"
    FCLOG="WARNING: downloadFile: Unexpected response (410) from https://o.example/x/daily.cld"$'\n'"daily.cld database is up-to-date (version: 28189, sigs: 355874, f-level: 90, builder: x)"; case_
    [[ ${#F_SEV[@]} -eq 1 ]] && echo "official-line-clears-no-source"
    # "The others are updated again" only when no earlier source still fails.
    printf 'DatabaseCustomURL https://a.example/a.ndb\nDatabaseCustomURL https://b.example/b.ndb\nDatabaseCustomURL https://c.example/c.ndb\n' > "$CR/etc/freshclam.conf"
    FCLOG="WARNING: downloadFile: Unexpected response (503) from https://a.example/a.ndb
WARNING: downloadFile: Unexpected response (410) from https://b.example/b.ndb"; case_
    [[ "${F_FIX[0]:-}" == "fix_clamav_custom_off https://b.example/b.ndb" && "${F_AFTER[0]}" != *"updated again"* ]] && echo "no-promise-while-an-earlier-source-fails"
    # Only sources listed after the failing one are "no longer updated"; an earlier missing one is a note.
    printf 'DatabaseCustomURL https://n.example/new.ndb\nDatabaseCustomURL https://b.example/bad.ndb\nDatabaseCustomURL https://l.example/later.ndb\nDatabaseCustomURL "https://z.example/z.ndb"\n' > "$CR/etc/freshclam.conf"
    echo x > "$CR/var/lib/clamav/later.ndb"
    FCLOG="WARNING: downloadFile: Unexpected response (410) from https://b.example/bad.ndb"; case_
    [[ "${F_DETAIL[0]:-}" == *"no longer updated:"$'\n'"l.example/later.ndb, z.example/z.ndb"* && "${F_DETAIL[0]}" != *new.ndb* \
       && "${CHECK_NOTE[check_deep_malware]:-}" == *"not in /var/lib/clamav yet: n.example/new.ndb "* ]] && echo "only-later-sources-are-blocked"
    # A user name and password, and a quoted address.
    [[ "$(_clamav_url_label "https://api:SECRET@sigs.example/db.ndb")" == "sigs.example/db.ndb" && "$(_clamav_url_label "https://SECRET@api.example/v1/x/db.ndb")" == "api.example/…/db.ndb" \
       && "$(_clamav_custom_file "https://q.example/a/q.ndb?key=SECRET")" == "q.ndb?key=SECRET" && "$(_clamav_url_label "https://q.example/a/q.ndb?key=SECRET")" == "q.example/…/q.ndb" \
       && "$(_clamav_custom_file "https://q.example/a/f.hdb#frag")" == "f.hdb#frag" \
       && "$(_clamav_custom_urls | tail -n 1)" == "https://z.example/z.ndb" ]] && echo "labels-without-credentials-and-quotes"
    # The fix, run on a copy of a freshclam.conf: only the failing line gets a #, the rest stays; undo puts it back.
    STATE_DIR="$W/clam-state"; RUN_ID=t5b; CURRENT_FINDING=0
    CF="$W/clam-fc.conf"; printf '# a comment\nDatabaseCustomURL %s\n  DatabaseCustomURL %s\nDatabaseCustomURL %sX\nDatabaseCustomURL %s\nDatabaseCustomURL "%s"\r\n\n\n' "$DEAD" "$DEAD" "$DEAD" "$OK2" "$DEAD" > "$CF"; cp "$CF" "$CF.orig"
    apply_change() { printf '%s\n' "$1" > "$W/clam-fix.sh"; printf '%s\n' "$2" > "$W/clam-fix.undo"; return 0; }
    printf '#!/bin/bash\necho "systemctl $*" >> "%s"\n' "$W/clam-fix.log" > "$W/clam-bin/systemctl"
    fix_clamav_custom_off "$DEAD"; : > "$W/clam-fix.log"
    sed -i "s|/etc/freshclam.conf|$CF|g" "$W/clam-fix.sh" "$W/clam-fix.undo"
    mkdir -p "$STATE_DIR/backups/$RUN_ID/f0$(dirname "$CF")"   # the backup's folder, for the file's new place
    PATH="$W/clam-bin:$PATH" bash -c 'set -euo pipefail; source "$1"' _ "$W/clam-fix.sh"; rc=$?
    [[ $rc -eq 0 && "$(sed -n 2p "$CF")" == "# Turned off by Security Check (it could not be downloaded): DatabaseCustomURL ${DEAD}" \
       && "$(sed -n 3p "$CF")" == "# Turned off by Security Check (it could not be downloaded):   DatabaseCustomURL ${DEAD}" \
       && "$(sed -n 4p "$CF")" == "DatabaseCustomURL ${DEAD}X" && "$(sed -n 5p "$CF")" == "DatabaseCustomURL ${OK2}" && "$(sed -n 1p "$CF")" == "# a comment" \
       && "$(sed -n 6p "$CF")" == "# Turned off by Security Check (it could not be downloaded): DatabaseCustomURL \"${DEAD}\""$'\r' \
       && "$(wc -l < "$CF")" -eq "$(wc -l < "$CF.orig")" && "$(tail -c 2 "$CF" | od -An -tx1 | tr -d ' ')" == 0a0a \
       && "$(cat "$W/clam-fix.log")" == "systemctl try-restart clamav-freshclam.service" ]] && echo "extra-source-fix-comments-only-that-line"
    PATH="$W/clam-bin:$PATH" bash -c 'set -euo pipefail; source "$1"' _ "$W/clam-fix.undo"
    cmp -s "$CF" "$CF.orig" && echo "extra-source-fix-undo"
    # Nothing left to turn off: the fix fails and the file stays as it was.
    printf 'DatabaseCustomURL %s\n' "$OK2" > "$CF"; cp "$CF" "$CF.orig"
    PATH="$W/clam-bin:$PATH" bash -c 'set -euo pipefail; source "$1"' _ "$W/clam-fix.sh"; rc=$?
    [[ $rc -ne 0 ]] && cmp -s "$CF" "$CF.orig" && [[ -z "$(ls "$W"/clam-fc.conf.?????? 2>/dev/null)" ]] && echo "extra-source-fix-fails-when-nothing-matches"
    # A service that does not restart: the file is changed all the same, and the fix succeeds.
    printf 'DatabaseCustomURL %s\n' "$DEAD" > "$CF"
    printf '#!/bin/bash\necho "systemctl $*" >> "%s"; exit 1\n' "$W/clam-fix.log" > "$W/clam-bin/systemctl"
    PATH="$W/clam-bin:$PATH" bash -c 'set -euo pipefail; source "$1"' _ "$W/clam-fix.sh" > "$W/clam-fix.out" 2>&1; rc=$?
    [[ $rc -eq 0 && "$(cat "$CF")" == "# Turned off by Security Check"* ]] && grep -q "did not restart" "$W/clam-fix.out" && echo "restart-failure-keeps-the-change"
    PATH="$W/clam-bin:$PATH" bash -c 'set -euo pipefail; source "$1"' _ "$W/clam-fix.undo" > /dev/null 2>&1 && echo "undo-restart-failure-keeps-the-restore"
) > "$W/clam.out" 2>&1
for t in clamui-without-clamav-offers-the-setup clamav-waiting-for-restart-is-not-offered-again no-clamav-is-an-optional-fix \
         clamtk-alone-scans-without-setup clamtk-scans-while-clamui-is-not-set-up clamscan-without-freshclam no-definitions-offers-download \
         old-definitions-found-and-scanned fresh-definitions-no-finding scan-as-account-on-one-file-system timeout-is-not-blamed-on-the-database \
         broken-definitions-offer-download unreadable-file-is-not-a-database-error infected-file-found database-directory-from-freshclam-conf \
         rollback-image-is-not-a-pending-restart only-the-missing-package-is-offered freshclam-waiting-for-restart freshclam-offered-despite-rollback \
         incomplete-definitions manual-steps-follow-the-service hit-from-a-stopped-scan failed-download-restarts-the-service \
         failed-download-still-turns-updates-on no-service-only-downloads malformed-status-hides-nothing runtime-mask-manual-steps \
         runtime-enable-made-permanent corrupted-cvd-is-a-database-error runtime-mask-fix-and-undo start-failure-keeps-the-download-status \
         start-failure-fails-the-fix runtime-enable-undo-restores-it unreadable-cvd-is-a-database-error broken-definitions-without-freshclam \
         old-definitions-without-freshclam scan-uses-the-database-directory layering-records-the-restart manual-steps-can-be-pasted \
         no-definitions-without-freshclam no-error-trap quoted-database-directory failing-extra-source-found \
         later-success-clears-and-missing-is-a-note extra-sources-all-there definitions-fix-only-official-sets \
         extra-source-fix-comments-only-that-line extra-source-fix-undo passing-failure-is-a-note connection-failure-twice-is-a-finding \
         worked-before-is-a-note prefix-address-not-blamed only-later-sources-are-blocked labels-without-credentials-and-quotes \
         extra-source-fix-fails-when-nothing-matches refusal-once-is-a-note refusal-in-two-updates-is-a-finding file-there-means-it-worked \
         logtime-failure-counts logtime-success-clears official-line-clears-no-source no-promise-while-an-earlier-source-fails \
         definitions-fix-follows-exclusions restart-failure-keeps-the-change rate-limit-is-a-note not-a-database-in-two-updates \
         undo-restart-failure-keeps-the-restore rate-limit-stops-nothing; do
    expect "$W/clam.out" "$t" "$t"
done

# ---------------------------------------------------------------- 6. safety details
echo "== 6. safety details"
printf 'root-owned\n' > "$W/rootfile"; chmod 644 "$W/rootfile"
printf 'secret\n' > "$W/rootsecret"; chmod 600 "$W/rootsecret"
(
    # shellcheck source=../bazzite-sec-audit.sh
    source "$TOOL"
    _load_check_table
    detect_desktop_user
    RUN_ID="t6"; RUN_LOG="$W/t6.log"; STATE_DIR="$STATE"; CURRENT_FINDING=0

    # Files in a home folder are backed up and restored as their owner.
    f="$UH/t6.conf"
    runuser -u "$U" -- sh -c 'printf "orig\n" > "$1"' sh "$f"
    bash -e -c "$(_backup_cmd "$f" "$U")" && echo "backup-ok"
    runuser -u "$U" -- sh -c 'printf "changed\n" > "$1"' sh "$f"
    bash -e -c "$(_restore_cmd "$f" "$U")" && [[ "$(cat "$f")" == orig ]] && echo "restore-ok"
    runuser -u "$U" -- ln -sfn "$W/rootfile" "$f"
    bash -c "$(_restore_cmd "$f" "$U")" 2>/dev/null
    [[ "$(cat "$W/rootfile")" == root-owned ]] && echo "symlink-restore-blocked"
    CURRENT_FINDING=1
    runuser -u "$U" -- ln -sfn "$W/rootsecret" "$f"
    bash -e -c "$(_backup_cmd "$f" "$U")" 2>/dev/null || echo "symlink-backup-refused"
    grep -rqs secret "$STATE/backups/t6/f1" || echo "secret-not-copied"
    rm -f "$f"
    # A backup that cannot be read stops the fix; a rollback then keeps the file.
    CURRENT_FINDING=5
    runuser -u "$U" -- sh -c 'printf data > "$1"; chmod 200 "$1"' sh "$f"
    bash -e -c "$(_backup_cmd "$f" "$U")" 2>/dev/null || true
    bash -c "$(_restore_cmd "$f" "$U")" 2>/dev/null
    [[ "$(stat -c %s "$f")" == 4 ]] && echo "failed-backup-no-truncate"
    rm -f "$f"

    # Findings are matched across runs without their counts, but with names.
    [[ "$(_delta_key c "The system image is 40 days old")" == "$(_delta_key c "The system image is 41 days old")" ]] \
        && [[ "$(_delta_key c "Account 'kid1' has no password")" != "$(_delta_key c "Account 'kid2' has no password")" ]] \
        && echo "delta-key-ok"

    # A report folder the desktop user cannot write is refused.
    ! _report_dir_usable "$W/rootdir-t6" 2>/dev/null && _report_dir_usable "$UH/Documents/t6ok" && echo "report-dir-checked"

    # The weekly timer's copy is compared with the running tool.
    _timer_installed() { return 0; }
    mkdir -p "$W/inst"; cp -R "$HERE/../lib" "$HERE/../checks" "$HERE/../ui" "$HERE/../release-signers" "$TOOL" "$W/inst/"
    ! installed_copy_outdated "$W/inst" && echo x >> "$W/inst/lib/ui.sh" && installed_copy_outdated "$W/inst" && echo "timer-copy-compared"

    # The sudo fix keeps the rule and only brings the password back.
    printf 'root ALL=(ALL) ALL\nbdatest ALL=(ALL) NOPASSWD: ALL\n' > "$W/sudoers-t6"
    apply_change() { bash -c "set -euo pipefail
$1"; }
    CURRENT_FINDING=2
    fix_sudo_line "$W/sudoers-t6" 2 "bdatest ALL=(ALL) NOPASSWD: ALL"
    grep -qx 'bdatest ALL=(ALL) PASSWD: ALL' "$W/sudoers-t6" && echo "sudo-rule-kept"

    # The SSH fix fails (and restores) when another file wins over its drop-in.
    apply_change() { printf '%s\n' "$1" > "$W/ssh-fix.sh"; }
    CURRENT_FINDING=3
    fix_ssh_dropin "PasswordAuthentication no"
    # Point the drop-in (not its backup copy) at a scratch file.
    sed -i -E "s#(^|[ '])${_SSH_DROPIN}#\\1$W/sshd-dropin.conf#g" "$W/ssh-fix.sh"
    bash -c "set -euo pipefail
$(cat "$W/ssh-fix.sh")" 2> "$W/ssh-fix.err" || echo "ssh-not-effective-refused"
    grep -q 'sets PasswordAuthentication first' "$W/ssh-fix.err" && [[ ! -e "$W/sshd-dropin.conf" ]] && echo "ssh-restored"
    # ... and says so plainly when sshd -T itself fails.
    mkdir -p "$W/bin-nosshd"
    printf '#!/bin/bash\n[[ "$1" == "-T" ]] && exit 1\nexit 0\n' > "$W/bin-nosshd/sshd"; chmod 755 "$W/bin-nosshd/sshd"
    PATH="$W/bin-nosshd:$PATH" bash -c "set -euo pipefail
$(cat "$W/ssh-fix.sh")" 2> "$W/ssh-fix.err" || true
    grep -q 'could not read the effective SSH configuration' "$W/ssh-fix.err" && echo "ssh-T-failure-named"
    CURRENT_FINDING=4
    fix_ssh_dropin "PermitEmptyPasswords no"
    # Point the drop-in (not its backup copy) at a scratch file.
    sed -i -E "s#(^|[ '])${_SSH_DROPIN}#\\1$W/sshd-dropin.conf#g" "$W/ssh-fix.sh"
    bash -c "set -euo pipefail
$(cat "$W/ssh-fix.sh")" 2>/dev/null && grep -qx 'PermitEmptyPasswords no' "$W/sshd-dropin.conf" && echo "ssh-effective-applied"

    # A crashed kdialog inside $(...) still moves the UI off KDE.
    _as_desktop_user() { return 3; }
    UI_MODE=kde
    ui_checklist "pick" a "A" on b "B" off > "$W/cl.out" < /dev/null
    [[ "$UI_MODE" == none && "$(cat "$W/cl.out")" == a ]] && echo "kdialog-fallback-ok"
    # ... and later dialogs, even in $(...), do not start it again.
    RUN_TMP="$W/rt"; mkdir -p "$RUN_TMP"
    _as_desktop_user() { echo x >> "$W/kd-calls"; return 3; }
    UI_MODE=kde
    out=$(ui_checklist "pick" a "A" on b "B" off < /dev/null)
    UI_MODE=kde
    out=$(ui_radiolist "pick" a "A" on b "B" off < /dev/null)
    [[ "$(wc -l < "$W/kd-calls")" -eq 1 ]] && echo "kdialog-not-retried"
    RUN_TMP=""

    # A dialog's answer only counts when it was offered. Here a tampered
    # answer to the SUID fix's list names a file it never listed, which
    # would end up in the stored undo step.
    UI_MODE=kde
    _as_desktop_user() { printf '4777|/etc/shadow\n4755|/opt/game/helper\n'; }
    apply_change() { printf '%s\n%s\n' "$1" "$2" > "$W/suid-fix.txt"; return 1; }
    fix_strip_suid "4755|/opt/game/helper"
    grep -q '/opt/game/helper' "$W/suid-fix.txt" && ! grep -q shadow "$W/suid-fix.txt" && echo "checklist-unoffered-dropped"
    _as_desktop_user() { echo "check:../evil"; }
    ! ui_menu "m" "Open" "Finish" "check:check_sudo" "row" > /dev/null && echo "menu-unoffered-dropped"
    _as_desktop_user() { echo "../evil"; }
    ! ui_radiolist "r" "20000101-000000" "a run" on > /dev/null && echo "radiolist-unoffered-dropped"
    unset -f apply_change
    _as_desktop_user() { echo x >> "$W/kd-calls"; return 3; }

    # SSH: accounts without a key are named; failed logins are counted by program.
    _users_with_keys() { echo "$U"; }
    REGULAR_USERS=("$U" nokeyuser); USE_SSH=1; CURRENT_CHECK=check_ssh_server
    : > "$W/calls.log"
    check_ssh_server
    printf '%s\n' "${F_DETAIL[@]}" | grep -q 'over SSH after this fix): nokeyuser.' && echo "nokey-listed"
    grep -q 'journalctl -t sshd -t sshd-session' "$W/calls.log" && echo "ssh-log-by-program"

    # mDNS answers on 5353/udp are expected from any program.
    _listener_known chrome 5353 udp > /dev/null && ! _listener_known chrome 5353 tcp > /dev/null && echo "mdns-known"

    # Before pkexec asks for the password, the person is told why, in an
    # information dialog: "don't show again" can never remember a Cancel.
    # Without a desktop the explanation is skipped, not fatal.
    UI_PREF=auto; ACTION=audit
    kdialog() { printf '%s\n' "$@" > "$W/explain.txt"; return 1; }
    WAYLAND_DISPLAY=wayland-0 _explain_pkexec && echo "pkexec-explain-continue"
    grep -q 'names <tt>/usr/bin/env</tt>' "$W/explain.txt" && grep -q -- '--dontagain' "$W/explain.txt" \
        && grep -qx -- '--msgbox' "$W/explain.txt" && ! grep -q -- '--yesno' "$W/explain.txt" && echo "pkexec-explained"
    WAYLAND_DISPLAY="" DISPLAY="" _explain_pkexec && echo "pkexec-no-desktop-ok"
    unset -f kdialog

    # Answers from dialogs (run as the desktop user) are never evaluated by
    # root: a fix-list tag is only used when it is an offered finding number,
    # an undo choice only when it is an offered run, and firewall tags only
    # when offered (and quoted).
    review_fixes 'x[$(touch '"$W"'/pwned1)]'
    _choose_fixes() { echo 'x[$(touch '"$W"'/pwned2)]'; }
    run_fix_session
    unset -f _choose_fixes
    mkdir -p "$STATE/evil"; printf '#!/bin/bash\ntouch %s/pwned3\n' "$W" > "$STATE/evil/01-undo.sh"
    mkdir -p "$STATE/undo/20000101-000000"; printf '#!/bin/bash\n# TITLE: t\nset -uo pipefail\ntrue\n' > "$STATE/undo/20000101-000000/01-undo.sh"
    ui_saved="$UI_MODE"; UI_MODE=kde
    _as_desktop_user() { echo "../evil"; }
    ui_choice3() { return 0; }
    run_undo > /dev/null 2>&1
    unset -f ui_choice3
    _as_desktop_user() { echo x >> "$W/kd-calls"; return 3; }
    UI_MODE="$ui_saved"
    rm -rf "$STATE/evil" "$STATE/undo/20000101-000000"
    [[ ! -e "$W/pwned1" && ! -e "$W/pwned2" && ! -e "$W/pwned3" ]] && echo "dialog-answers-not-evaluated"
    ui_checklist() { echo "dhcpv6-client"; echo "port:22/tcp; touch $W/pwned4"; }
    apply_change() { printf '%s\n' "$1" > "$W/fw-script.sh"; printf '%s\n' "$CHANGE_AFTER" > "$W/fw-after.txt"; return 1; }
    fix_firewall_zone FedoraWorkstation "FedoraWorkstation" enp5s0
    ! grep -q 'pwned4' "$W/fw-script.sh" && grep -q -- '--add-service=dhcpv6-client' "$W/fw-script.sh" && echo "firewall-tags-checked"
    : > "$W/fw-script.sh"
    ui_checklist() { return 1; }
    fix_firewall_zone FedoraWorkstation "FedoraWorkstation" enp5s0; rc=$?
    [[ $rc -eq 1 && ! -s "$W/fw-script.sh" ]] && echo "firewall-cancel-cancels"
    # What the new zone does not copy from the old one is named.
    _FW_ZONE_ALL["FedoraWorkstation"]=$'FedoraWorkstation (default, active)\n  target: default\n  services: ssh\n  ports: 1025-65535/tcp\n  protocols: gre\n  masquerade: yes\n  forward-ports: \n\tport=2222:proto=tcp:toport=22:toaddr=\n  source-ports: \n  icmp-blocks: \n  rich rules: \n\trule family="ipv4" source address="192.168.1.9" accept\n\trule family="ipv4" source address="192.168.1.10" accept'
    ui_checklist() { echo "dhcpv6-client"; }
    apply_change() { printf '%s\n' "${CHANGE_WARN[@]}" > "$W/fw-warn.txt"; return 1; }
    CHANGE_WARN=()
    fix_firewall_zone FedoraWorkstation "FedoraWorkstation" enp5s0
    grep -q '^not carried over|' "$W/fw-warn.txt" \
        && grep -qF "2 rich rule(s) (zone 'FedoraWorkstation')" "$W/fw-warn.txt" \
        && grep -qF "1 port forwarding rule(s)" "$W/fw-warn.txt" \
        && grep -qF "masquerading (NAT)" "$W/fw-warn.txt" && grep -qF "allowed protocols gre" "$W/fw-warn.txt" \
        && echo "firewall-extras-named"
    unset -f ui_checklist apply_change
    # A zone that allows a whole protocol opens every port of it.
    _FW_ZONE_ALL["ptest"]=$'ptest\n  target: default\n  services: \n  ports: \n  protocols: tcp'
    [[ "$(_fw_zone_problem ptest)" == "opens 1-65535/tcp" ]] && echo "protocol-counts-as-open"
    _FW_ZONE_ALL["etest"]=$'etest\n  target: default\n  services: \n  ports: \n  forward-ports: \n\t\n  rich rules: \n\t'
    [[ -z "$(_fw_zone_extras etest)" ]] && echo "firewall-extras-blank-lines"

    # sysctl files count in systemd-sysctl's order: by file name across the
    # folders, a name in /etc hiding the same name in /usr.
    AUDIT_ROOT="$W/sysroot"
    mkdir -p "$W/sysroot/etc/sysctl.d" "$W/sysroot/usr/lib/sysctl.d"
    echo 'fs.protected_symlinks = 0' > "$W/sysroot/etc/sysctl.d/10-local.conf"
    echo 'fs.protected_symlinks = 0' > "$W/sysroot/usr/lib/sysctl.d/90-image.conf"
    echo 'fs/protected_symlinks=0' > "$W/sysroot/usr/lib/sysctl.d/95-hidden.conf"
    echo '# emptied on purpose' > "$W/sysroot/etc/sysctl.d/95-hidden.conf"
    [[ "$(_sysctl_source fs.protected_symlinks)" == /usr/lib/sysctl.d/90-image.conf ]] && echo "sysctl-source-order"
    # A name linked to /dev/null masks it; /etc/sysctl.conf counts at the
    # place of the 99-sysctl.conf link that reads it.
    AUDIT_ROOT="$W/sysroot2"
    mkdir -p "$W/sysroot2/etc/sysctl.d" "$W/sysroot2/usr/lib/sysctl.d"
    echo 'kernel.unprivileged_bpf_disabled = 0' > "$W/sysroot2/usr/lib/sysctl.d/50-weak.conf"
    ln -sfn /dev/null "$W/sysroot2/etc/sysctl.d/50-weak.conf"
    [[ -z "$(_sysctl_source kernel.unprivileged_bpf_disabled)" ]] && echo "sysctl-mask-honoured"
    echo 'fs.protected_fifos = 1' > "$W/sysroot2/etc/sysctl.conf"
    ln -sfn ../sysctl.conf "$W/sysroot2/etc/sysctl.d/99-sysctl.conf"
    echo 'fs.protected_fifos = 0' > "$W/sysroot2/etc/sysctl.d/99-zz-games.conf"
    [[ "$(_sysctl_source fs.protected_fifos)" == /etc/sysctl.d/99-zz-games.conf ]] && echo "sysctl-conf-in-place"
    AUDIT_ROOT="$FX"

    # SELinux denials are counted once: from the journal's audit records,
    # else the larger of kernel messages and auditd's log (ausearch).
    mkdir -p "$W/bin-avc"
    cat > "$W/bin-avc/journalctl" << 'EOF'
#!/bin/bash
case "$*" in
  *_TRANSPORT=audit*) n=${AVC_AUDIT:-0} ;;
  "-k -b --no-pager -q") n=${AVC_KERNEL:-0} ;;
  *) n=0 ;;
esac
for ((i = 0; i < n; i++)); do echo "avc:  denied  { read }"; done
EOF
    cat > "$W/bin-avc/ausearch" << 'EOF'
#!/bin/bash
[[ "$*" == "-m AVC,USER_AVC -ts boot" ]] || exit 1
for ((i = 0; i < ${AVC_AUSEARCH:-0}; i++)); do echo "type=AVC msg=audit(1.2:3): avc:  denied  { read }"; done
EOF
    chmod 755 "$W/bin-avc/journalctl" "$W/bin-avc/ausearch"
    (
        export PATH="$W/bin-avc:$PATH"
        [[ "$(export AVC_AUDIT=3 AVC_KERNEL=3; _avc_denials)" == 3 ]] \
            && [[ "$(export AVC_KERNEL=2; _avc_denials)" == 2 ]] \
            && [[ "$(export AVC_KERNEL=1 AVC_AUSEARCH=4; _avc_denials)" == 4 ]] \
            && [[ "$(_avc_denials)" == 0 ]] && echo "avc-count-sources"
    )

    # Rootless Podman: each port is judged by the firewall rule of its own
    # protocol, reported apart from Docker, and never offered Docker's fix.
    (
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=()
        F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=()
        FINDINGS_FILE=""; DESKTOP_USER="$U"; USE_DEV=1; CURRENT_CHECK=check_containers
        _unit_active() { return 1; }    # Docker installed, not running
        _as_desktop_user() { printf 'game\t0.0.0.0:27015->27015/udp\nweb\t0.0.0.0:8080->80/tcp\n'; }
        _reachable() { [[ "$1/$3" == udp/27015 ]]; }
        check_containers
        for i in "${!F_TITLE[@]}"; do printf '%s|%s|%s\n' "${F_TITLE[$i]}" "${F_FIX[$i]}" "${F_DETAIL[$i]//$'\n'/ }"; done > "$W/rootless.txt"
        grep -qF "1 rootless container(s) are reachable from your network||- podman (${U}) game: 0.0.0.0:27015" "$W/rootless.txt" \
            && ! grep -qF "web: 0.0.0.0:8080" "$W/rootless.txt" && ! grep -qF "fix_docker_default_ip" "$W/rootless.txt" \
            && echo "rootless-by-protocol-no-docker-fix"
    )

    # undo-all.sh runs every step, newest first, in a folder with a space.
    mkdir -p "$W/ua dir"
    for n in 01 02; do
        printf '#!/usr/bin/env bash\n# TITLE: step %s\nset -uo pipefail\necho %s >> %q\n' "$n" "$n" "$W/ua-order" > "$W/ua dir/${n}-undo.sh"
    done
    _write_undo_all "$W/ua dir"
    bash "$W/ua dir/undo-all.sh" --yes > /dev/null 2>&1
    [[ "$(paste -sd, "$W/ua-order")" == "02,01" && -f "$W/ua dir/01-undo.done" ]] && echo "undo-all-ok"

    # Containers. Plans come from a fake "podman inspect" (one JSON file per
    # case); unsafe cases stay manual with a reason, a podman run container
    # is replaced by a new one while the old one is kept (stopped, renamed),
    # and compose files get their port lines changed as their owner.
    (
        mkdir -p "$W/ctr/bin" "$W/ctr/proj"; chmod 755 "$W/ctr" "$W/ctr/proj"
        printf 'services:\n  ollama:\n    ports:\n      - "11434:11434"   # api\n' > "$W/ctr/proj/compose.yml"
        printf 'services:\n  ollama:\n    ports:\n      - 0.0.0.0:11434:11434\n' > "$W/ctr/proj/override.yml"
        chown -R "$U" "$W/ctr/proj"
        python3 -I - "$W/ctr" << 'PY'
import json, sys
d = sys.argv[1]
def ctr(cmd, binds=None, labels=None, cmdargs=None, mounts=None, restart="always"):
    return [{"Name": "ollama", "Id": "a" * 64, "ImageName": "docker.io/library/img:latest",
             "Config": {"Labels": labels or {}, "CreateCommand": cmd, "Cmd": cmdargs or ["serve"]},
             "HostConfig": {"PortBindings": binds or {"11434/tcp": [{"HostIp": "", "HostPort": "11434"}]},
                            "RestartPolicy": {"Name": restart}},
             "Mounts": mounts or [{"Type": "volume", "Name": "models"}]}]
base = ["podman", "run", "--name", "ollama", "--restart", "always", "-p", "11434:11434", "-v", "models:/m"]
cases = {
    "run": ctr(base + ["img", "serve", "-p", "9"], cmdargs=["serve", "-p", "9"]),
    "rm": ctr(base[:2] + ["--rm"] + base[2:] + ["img"]),
    "bare": ctr(["podman", "run", "--name", "ollama", "-p", "11434", "img"], binds={"11434/tcp": [{"HostIp": "", "HostPort": "40001"}]}),
    "dp": ctr(["podman", "run", "--name", "ollama", "-dp", "11434:11434", "img"]),
    "noname": ctr(["podman", "run", "-p", "11434:11434", "img"]),
    "relvol": ctr(base[:-2] + ["-v", "./data:/data", "img"]),
    "unit": ctr(base + ["img"], labels={"PODMAN_SYSTEMD_UNIT": "ollama.service"}),
    "dv": ctr(["podman", "run", "--name", "ollama", "-dv", "./x:/x", "-p", "11434:11434", "img"]),
    "envvar": ctr(base + ["-e", "TOKEN", "img"]),
    "range": ctr(["podman", "run", "--name", "ollama", "-p", "11434-11435:11434-11435", "img"],
                 binds={"11434/tcp": [{"HostIp": "", "HostPort": "11434"}], "11435/tcp": [{"HostIp": "", "HostPort": "11435"}]}),
}
pc = {"PODMAN_SYSTEMD_UNIT": "podman-compose@hon.service", "com.docker.compose.project": "hon",
      "com.docker.compose.service": "ollama", "com.docker.compose.project.working_dir": d + "/proj"}
cases["compose"] = ctr(["podman", "run"], labels=dict(pc, **{"com.docker.compose.project.config_files": "compose.yml,override.yml"}))
web = ctr(["podman", "run"], labels=dict(pc, **{"com.docker.compose.service": "web", "com.docker.compose.project.config_files": "compose.yml,override.yml"}),
          binds={"8080/tcp": [{"HostIp": "", "HostPort": "8080"}]})
web[0]["Name"], web[0]["Id"] = "web", "b" * 64
cases["web"] = web
for k, v in cases.items():
    json.dump(v, open("%s/%s.json" % (d, k), "w"))
PY
        cat > "$W/ctr/bin/podman" << PODMAN
#!/bin/bash
echo "podman \$*" >> "$W/ctr/calls"
j="\$CTR_JSON"; [[ " \$* " == *" web "* ]] && j=web
case "\$*" in
  *ollama-before-fix*) [[ "\$*" == *.Id* ]] && exit 1 ;;
  *.Id*) [[ "\$j" == web ]] && printf 'b%.0s' {1..64} || printf 'a%.0s' {1..64}; echo ;;
  *.State.Running*) echo true ;;
  *--format*) echo "[127.0.0.1]" ;;
  "container exists"*) exit 1 ;;
  inspect*) cat "$W/ctr/\$j.json" ;;
esac
exit 0
PODMAN
        chmod 755 "$W/ctr/bin/podman"
        export PATH="$W/ctr/bin:$PATH"
        _compose_cmd() { echo "echo compose-up"; }
        local_reason() { { CTR_JSON="$1" _ctr_fixable podman ollama > /dev/null; } 2>&1; }
        [[ "$(local_reason rm)" == *--rm* && "$(local_reason bare)" == *"random port"* && "$(local_reason dp)" == *combines* \
           && "$(local_reason noname)" == *"no --name"* && "$(local_reason relvol)" == *"relative path ./data"* \
           && "$(local_reason unit)" == *"systemd unit ollama.service"* && "$(local_reason dv)" == *combines* \
           && "$(local_reason envvar)" == *"TOKEN from the shell"* && "$(local_reason range)" == *"port range"* ]] && echo "ctr-unsafe-cases-manual"

        ui_checklist() { shift; while [[ $# -ge 3 ]]; do echo "$1"; shift 3; done; }
        apply_change() { printf '%s\n--\n%s\n' "$1" "$2" > "$W/ctr/fix.txt"; }
        CTR_JSON=run fix_containers_localhost 0 "podman|ollama"
        grep -qx "podman run --detach --name ollama --restart always -p 127.0.0.1:11434:11434 -v models:/m img serve -p 9" "$W/ctr/fix.txt" \
            && grep -q "^podman rename ollama ollama-before-fix || { podman start ollama; exit 1; }" "$W/ctr/fix.txt" && grep -qx "podman update --restart=no ollama-before-fix" "$W/ctr/fix.txt" \
            && grep -q "podman rename ollama-before-fix ollama" "$W/ctr/fix.txt" && grep -q "podman update --restart=always ollama" "$W/ctr/fix.txt" \
            && grep -q 'still publishes on all interfaces' "$W/ctr/fix.txt" && ! grep -q '^podman rm -f ollama-before-fix' "$W/ctr/fix.txt" \
            && echo "ctr-run-kept-old"
        # A rollback after a failure before the rename touches nothing: the
        # kept copy is not the original (here: missing), so no rm/rename.
        : > "$W/ctr/calls"
        bash -c "$(sed -n '/^--$/,$p' "$W/ctr/fix.txt" | sed 1d)" > /dev/null 2>&1
        ! grep -qE 'podman (rm|rename|start|update)' "$W/ctr/calls" && echo "ctr-rollback-touches-nothing"
        # Docker's default: the undo restores daemon.json and restarts Docker
        # only when the fix backed it up, and before services are recreated.
        apply_change() { printf '%s\n--\n%s\n' "$1" "$2" > "$W/ctr/dflt.txt"; }
        CTR_JSON=compose fix_containers_localhost 1 "podman|ollama"
        u=$(sed -n '/^--$/,$p' "$W/ctr/dflt.txt")
        [[ "$(grep -B3 'systemctl try-restart docker.service' <<< "$u" | head -1)" == "if [ -e "* ]] \
            && [[ $(grep -n 'try-restart docker' <<< "$u" | cut -d: -f1) -lt $(grep -n 'compose-up -p' <<< "$u" | head -1 | cut -d: -f1) ]] \
            && echo "ctr-docker-undo-gated"

        # podman-compose labels (relative file names, its own systemd unit):
        # both files are edited as their owner and the service recreated.
        export CTR_JSON=compose
        apply_change() { bash -c "set -euo pipefail
$1"; }
        fix_containers_localhost 0 "podman|ollama" > "$W/ctr/up.txt" 2>&1
        grep -qF -- '- "127.0.0.1:11434:11434"   # api' "$W/ctr/proj/compose.yml" && grep -qF -- '- 127.0.0.1:11434:11434' "$W/ctr/proj/override.yml" \
            && [[ "$(stat -c %U "$W/ctr/proj/compose.yml")" == "$U" ]] \
            && grep -q "compose-up -p hon -f $W/ctr/proj/compose.yml -f $W/ctr/proj/override.yml up -d --no-deps --force-recreate ollama" "$W/ctr/up.txt" \
            && echo "ctr-compose-all-files"
        # A port in another form, or a variable from the shell, stays manual.
        printf 'services:\n  ollama:\n    ports: ["11434:11434"]\n' > "$W/ctr/proj/override.yml"
        r1=$(local_reason compose)
        printf 'services:\n  ollama:\n    ports:\n      - 11434:11434\n    volumes:\n      - ${MODELS}:/m\n' > "$W/ctr/proj/override.yml"
        r2=$(local_reason compose)
        printf 'MODELS=/srv/models\n' > "$W/ctr/proj/.env"; chmod 644 "$W/ctr/proj/.env"
        r3=$(local_reason compose)
        printf 'services:\n  ollama:\n    ports:\n      - "[::]:11434:11434"\n' > "$W/ctr/proj/override.yml"
        r4=$(local_reason compose)
        [[ "$r1" == *"in a form the tool does not change"* && "$r2" == *'${MODELS}'* && -z "$r3" \
           && "$r4" == *"in a form the tool does not change"* ]] && echo "ctr-compose-manual-forms"
        # Two services from one compose file: the file is backed up once,
        # both edits come before the first recreate, and the undo recreates
        # a service only when the fix got to it.
        printf 'services:\n  ollama:\n    ports:\n      - "11434:11434"\n  web:\n    ports:\n      - 8080:80\n' > "$W/ctr/proj/compose.yml"
        printf 'services: {}\n' > "$W/ctr/proj/override.yml"
        apply_change() { printf '%s\n--\n%s\n' "$1" "$2" > "$W/ctr/two.txt"; printf '%s\n' "${CHANGE_WARN[@]}" > "$W/ctr/two-warn.txt"; }
        CTR_JSON=compose fix_containers_localhost 0 "podman|ollama" "podman|web"
        [[ $(grep -c "compose.yml.absent" "$W/ctr/two.txt") -eq 2 ]] \
            && [[ $(grep -n 'sed -E -i' "$W/ctr/two.txt" | tail -1 | cut -d: -f1) -lt $(grep -n "compose-up -p" "$W/ctr/two.txt" | head -1 | cut -d: -f1) ]] \
            && [[ $(grep -c '^if \[ -e .*compose-up-' "$W/ctr/two.txt") -eq 2 ]] && echo "ctr-compose-shared-file"
        # The compose files are a normal account's and root starts what
        # they say: the confirmation says so, naming the account.
        grep -q "^runs another account's files|" "$W/ctr/two-warn.txt" \
            && grep -qF "files of ${U} in $W/ctr/proj" "$W/ctr/two-warn.txt" && echo "ctr-other-account-warned"
    )

    # Flatpak: apps graded by how likely a restriction breaks them; the
    # low-risk preset selects only those, and "all files" becomes home.
    (
        [[ "$(_flatpak_break_risk com.visualstudio.code escape,host)" == high* \
           && "$(_flatpak_break_risk org.kde.okular host)" == low* \
           && "$(_flatpak_break_risk org.example.Unknown host)" == medium* ]] && echo "flatpak-risk-graded"
        ui_radiolist() { echo low; }
        ui_checklist() { shift; while [[ $# -ge 3 ]]; do [[ $3 == on ]] && echo "$1"; shift 3; done; }
        apply_change() { printf '%s\n' "$1" > "$W/fp-fix.txt"; }
        # The desktop user overrides one system app (Flatseal): restricted there too.
        DESKTOP_USER="$U"; _as_desktop_user() { _as_user "$DESKTOP_USER" "$@"; }
        runuser -u "$U" -- mkdir -p "$UH/.local/share/flatpak/overrides"
        runuser -u "$U" -- sh -c 'printf "[Context]\nfilesystems=host;\n" > "$1"' sh "$UH/.local/share/flatpak/overrides/org.kde.okular"
        fix_flatpak_restrict "system|com.visualstudio.code|escape,host" "system|org.kde.okular|host" "system|org.kde.gwenview|hostro" "system|org.kde.haruna|hostos"
        grep -q 'flatpak override --system .*--filesystem=home org.kde.okular' "$W/fp-fix.txt" \
            && grep -q -- '--filesystem=home:ro org.kde.gwenview' "$W/fp-fix.txt" \
            && grep -q -- '--nofilesystem=host-os --nofilesystem=host-etc org.kde.haruna' "$W/fp-fix.txt" \
            && ! grep -q -- '--filesystem=home.* org.kde.haruna' "$W/fp-fix.txt" \
            && grep -q "^runuser -u $U -- flatpak override --user .*--filesystem=home org.kde.okular" "$W/fp-fix.txt" \
            && ! grep -q "flatpak override --user .*org.kde.gwenview" "$W/fp-fix.txt" \
            && ! grep -q 'com.visualstudio.code' "$W/fp-fix.txt" && echo "flatpak-low-preset"
    )

    # Flatpak host permissions: host and / become home (same mode);
    # host-os/host-etc (system folders only) never gain home; an override
    # that removes host is respected.
    (
        f() { printf '[Context]\nfilesystems=%s\n' "$1" > "$W/fpp"; _flatpak_perm_flags "$W/fpp" | paste -sd, -; }
        [[ "$(f 'host;')" == host && "$(f 'host:ro;')" == hostro && "$(f 'host-os:ro;')" == hostos \
           && -z "$(f '/;')" && "$(f 'host;!host;host-etc;')" == hostos && "$(f 'host;!host:reset;')" == "" ]] && echo "flatpak-host-forms"
    )

    # Anti-cheat readiness: only for gaming; arguments already set wait for
    # a reboot instead of being offered again; the fix only adds its own two.
    (
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=()
        F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=(); F_AFFECT=(); F_KEYX=(); FINDINGS_FILE=""
        CURRENT_CHECK=check_anticheat_ready
        USE_GAMING=0; check_anticheat_ready; [[ ${#F_TITLE[@]} -eq 0 ]] && na=1
        USE_GAMING=1; _configured_kargs() { echo "rhgb lockdown=integrity sysctl.kernel.kexec_load_disabled=1"; }
        check_anticheat_ready
        [[ ${na:-0} -eq 1 && ${#F_TITLE[@]} -eq 0 && "${CHECK_NOTE[check_anticheat_ready]}" == *"after a reboot: kernel lockdown, kexec off"* ]] && echo "anticheat-pending-and-gaming-only"
        apply_change() { printf '%s\n--\n%s\n' "$1" "$2" > "$W/eac.txt"; }
        # With Secure Boot on, lockdown is offered too.
        F_TITLE=(); _configured_kargs() { echo "rhgb"; }; _secure_boot_state() { echo enabled; }
        check_anticheat_ready
        [[ "${F_FIX[0]}" == *"fix_anticheat_kargs lockdown=integrity sysctl.kernel.kexec_load_disabled=1"* ]] && echo "anticheat-lockdown-with-secure-boot"
        # Lockdown is named as stopping hibernation only when the fix adds it.
        [[ "${F_AFFECT[0]}" == *"lockdown!|"* ]] && _configured_kargs() { echo "rhgb lockdown=integrity"; } \
            && check_anticheat_ready && i=$(( ${#F_SEV[@]} - 1 )) && [[ "${F_FIX[$i]}" == *"kexec_load_disabled=1" \
            && "${F_AFFECT[$i]}" == *"anticheat+|"* && "${F_AFFECT[$i]}" != *"lockdown"* ]] && echo "anticheat-lockdown-mark-only-when-added"
        fix_anticheat_kargs lockdown=integrity "evil;rm" sysctl.kernel.kexec_load_disabled=1
        grep -qx 'rpm-ostree kargs --append-if-missing=lockdown=integrity --append-if-missing=sysctl.kernel.kexec_load_disabled=1' "$W/eac.txt" \
            && grep -qx 'rpm-ostree kargs --delete-if-present=lockdown=integrity --delete-if-present=sysctl.kernel.kexec_load_disabled=1' "$W/eac.txt" \
            && ! grep -q evil "$W/eac.txt" && echo "anticheat-fix-and-undo"
    )

    # Updates: a release is installed only when SHA256SUMS carries a good
    # signature by the release key and the archive matches it; the archive
    # may only hold the tool's own folder.
    (
        command -v ssh-keygen > /dev/null || { echo "ssh-keygen is missing: the update checks cannot run"; exit 0; }
        R="$W/rel"; mkdir -p "$R/k" "$R/pkg/bazzite-sec-audit-9.9.9" "$R/dl"
        ssh-keygen -q -t ed25519 -N '' -f "$R/k/key"
        printf 'release@bazzite-sec-audit namespaces="bazzite-sec-audit-release" %s\n' "$(cut -d' ' -f1-2 "$R/k/key.pub")" > "$R/k/signers"
        cp -R "$HERE/../lib" "$HERE/../checks" "$HERE/../ui" "$HERE/../release-signers" "$TOOL" "$R/pkg/bazzite-sec-audit-9.9.9/"
        tar -C "$R/pkg" -czf "$R/dl/bazzite-sec-audit-9.9.9.tar.gz" bazzite-sec-audit-9.9.9
        (cd "$R/dl" && sha256sum bazzite-sec-audit-9.9.9.tar.gz > SHA256SUMS)
        ssh-keygen -q -Y sign -f "$R/k/key" -n bazzite-sec-audit-release "$R/dl/SHA256SUMS"
        RELEASE_SIGNERS="$R/k/signers"
        update_verify "$R/dl" 9.9.9 && src=$(update_extract "$R/dl" 9.9.9) && [[ -f "$src/ui/app.py" && -f "$src/ui/qml/Shell.qml" ]] \
            && _version_newer 1.10.0 1.9.2 && ! _version_newer 1.1.0 1.1.0 && ! _version_newer 1.0.9 1.1.0 && echo "update-verified"
        # Tampered archive, wrong key, path outside the tool's folder.
        cp "$R/dl/bazzite-sec-audit-9.9.9.tar.gz" "$R/good.tgz"
        printf 'x' >> "$R/dl/bazzite-sec-audit-9.9.9.tar.gz"; ! update_verify "$R/dl" 9.9.9 && t1=1
        cp "$R/good.tgz" "$R/dl/bazzite-sec-audit-9.9.9.tar.gz"
        RELEASE_SIGNERS="$HERE/../release-signers"; ! update_verify "$R/dl" 9.9.9 && t2=1
        mkdir -p "$R/evil/bazzite-sec-audit-9.9.9"; cp -R "$R/pkg/bazzite-sec-audit-9.9.9/." "$R/evil/bazzite-sec-audit-9.9.9/"
        ln -s /etc/shadow "$R/evil/bazzite-sec-audit-9.9.9/shadow"
        tar -C "$R/evil" -czf "$R/dl/bazzite-sec-audit-9.9.9.tar.gz" bazzite-sec-audit-9.9.9
        rm -rf "$R/dl/src"; ! update_extract "$R/dl" 9.9.9 > /dev/null 2>&1 && t3=1
        # A signature for another purpose (namespace), and a second line for
        # the archive in SHA256SUMS, are refused too; so is a ".." member.
        cp "$R/good.tgz" "$R/dl/bazzite-sec-audit-9.9.9.tar.gz"; RELEASE_SIGNERS="$R/k/signers"
        cp "$R/dl/SHA256SUMS.sig" "$R/good.sig"
        rm -f "$R/dl/SHA256SUMS.sig"; ssh-keygen -q -Y sign -f "$R/k/key" -n file "$R/dl/SHA256SUMS"; ! update_verify "$R/dl" 9.9.9 && t4=1
        cp "$R/good.sig" "$R/dl/SHA256SUMS.sig"
        cp "$R/dl/SHA256SUMS" "$R/good.sums"
        printf '%064d  bazzite-sec-audit-9.9.9.tar.gz\n' 0 >> "$R/dl/SHA256SUMS"; rm -f "$R/dl/SHA256SUMS.sig"
        ssh-keygen -q -Y sign -f "$R/k/key" -n bazzite-sec-audit-release "$R/dl/SHA256SUMS"; ! update_verify "$R/dl" 9.9.9 && t5=1
        python3 -I - "$R/dl/bazzite-sec-audit-9.9.9.tar.gz" << 'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    data = b"x"
    i = tarfile.TarInfo("bazzite-sec-audit-9.9.9/../evil"); i.size = len(data); t.addfile(i, io.BytesIO(data))
PY
        rm -rf "$R/dl/src"; ! update_extract "$R/dl" 9.9.9 > /dev/null 2>&1 && t6=1
        [[ ${t1:-0}${t2:-0}${t3:-0}${t4:-0}${t5:-0}${t6:-0} == 111111 ]] && echo "update-tamper-rejected"
    )

    # Settings and wizard answers from the front end are checked before use;
    # settings are kept in root's state folder and read back.
    (
        [[ "$(_settings_answer '{"theme":"dark","update_check":true,"action":"save"}')" == "dark 1 save" ]] \
            && ! _settings_answer '{"theme":"../x","update_check":true,"action":"save"}' \
            && ! _settings_answer '{"theme":"dark","update_check":"yes","action":"save"}' \
            && ! _settings_answer '[1]' && echo "settings-answer-checked"
        UI_THEME=dark; UPDATE_CHECK=1; save_settings; UI_THEME=system; UPDATE_CHECK=0; load_settings
        printf 'THEME=$(id)\nUPDATE_CHECK=7\n' >> "$(_settings_file)"; load_settings
        [[ "$UI_THEME" == dark && "$UPDATE_CHECK" == 1 ]] && echo "settings-saved-and-loaded"
        a=$(_wizard_answer '{"use":["dev","gaming"],"fix":false,"deep":true,"action":"start","report_dir":"/home/x/r"}')
        [[ "$a" == $'use dev,gaming\nfix 0\ndeep 1\naction start\ndir /home/x/r' ]] \
            && ! _wizard_answer '{"use":[],"fix":false,"deep":true,"action":"start","report_dir":"/x\u0000y"}' \
            && ! _wizard_answer '{"use":["rm -rf"],"fix":false,"deep":true,"action":"start","report_dir":"/x"}' \
            && ! _wizard_answer '{"use":[],"fix":false,"deep":true,"action":"start","report_dir":"relative"}' \
            && ! _wizard_answer '{"use":[],"fix":0,"deep":true,"action":"start","report_dir":"/x"}' \
            && echo "wizard-answer-checked"
        OS_PRETTY="Bazzite"; CHASSIS=desktop; DISK_ENCRYPTED=yes; DETECTED=([gaming]="Steam is installed")
        USE_GAMING=1; USE_DEV=1; USE_STREAMING=0; USE_SSH=0; USE_SHARING=0; USE_PORTABLE=0; FIX_MODE=confirm; DEEP=0; REPORT_DIR=/r
        python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["answers"]["use"]==["gaming","dev"] and d["answers"]["fix"] is True and d["detected"]=={"gaming":"Steam is installed"} and d["facts"]["disk"]=="yes"' "$(_wizard_input)" \
            && echo "wizard-input-json"
        UI_MODE=none; _QML_OK=""; ui_app wizard '{}' > /dev/null; [[ $? -eq 4 ]] && echo "front-end-not-without-kde"
    )

    # Dashboard: its input is well-formed JSON with every check, and only a
    # known action (or a known check) is taken back from the window.
    (
        [[ "$(_dashboard_answer '{"action":"fix"}')" == fix && "$(_dashboard_answer '{"action":"finish"}')" == finish \
           && "$(_dashboard_answer '{"action":"check","check":"check_firewall"}')" == check:check_firewall ]] \
            && ! _dashboard_answer '{"action":"check","check":"check_nope"}' \
            && ! _dashboard_answer '{"action":"check","check":"../x"}' \
            && ! _dashboard_answer '{"action":"rm -rf"}' && ! _dashboard_answer 'garbage' && echo "dashboard-answer-checked"
        CHECK_ORDER=(check_firewall check_sudo); CHECK_STATUS=(); CHECK_TITLE["check_firewall"]="Firewall"; CHECK_TITLE["check_sudo"]="sudo rules"
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_STATE=(); F_VERIFY=(); F_FIX=(); _CF_READY=0; _CSTATE=()
        SCORE=90; SCORE_NOW=91; GRADE_NOW=A; NEEDS_REBOOT=0; HAD_PREVIOUS_RUN=0; FIX_MODE=report; REPORT_FALLBACK=0
        python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["score"]==91 and d["nfix"]==0 and d["report_only"] is True and [c["id"] for c in d["checks"]]==["check_firewall","check_sudo"] and d["checks"][0]["summary"]=="OK" and d["areas"][0]=={"name":"Network","state":"ok"}' "$(_dashboard_input 0)" \
            && echo "dashboard-input-json"
        # A title with markup and a line break stays one field of text: it
        # cannot add keys (score, nfix) to the input.
        CHECK_TITLE["check_sudo"]=$'<b>x</b><img src="/etc/x">\nnfix\t99\nscore\t1'
        python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["nfix"]==0 and d["score"]==91 and "\n" not in d["checks"][1]["title"] and d["checks"][1]["title"].startswith("<b>x</b><img")' "$(_dashboard_input 0)" \
            && echo "dashboard-input-one-line"
        # Fix only when fixes are offered and there is one; undo only with undo steps.
        _undo_available() { return 1; }
        FIX_MODE=report; ! _dashboard_offered fix 5 && FIX_MODE=confirm && ! _dashboard_offered fix 0 && _dashboard_offered fix 2 \
            && ! _dashboard_offered undo && _dashboard_offered settings && echo "dashboard-actions-offered-only"
    )

    # What a fix affects: each finding names the Bazzite features it
    # touches; those this PC uses come first, are marked in use, and their
    # fixes start unticked. Unknown keys and repeats are dropped.
    (
        _feature_detect() {
            case "$1" in remote_play) echo "Steam is installed"; return 0 ;; game_server) return 2 ;; *) return 1 ;; esac
        }
        USE_GAMING=0; USE_STREAMING=0; USE_SSH=0; USE_SHARING=0; USE_DEV=0; _FEATURE_SEEN=()
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=(); F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=(); F_AFFECT=()
        FINDINGS_FILE=""; CURRENT_CHECK=check_firewall
        finding high "Open <b>ports</b>" "d" "m" true
        finding_affects "sshx|unknown key" "ssh!|SSH stops" "remote_play!|Remote Play stops <i>here</i>" "ssh|again" "game_server?|maybe" "noseparator"
        mapfile -t L < <(affects_list 0)
        [[ ${#L[@]} -eq 3 && "${L[0]}" == remote_play$'\t'*$'\t'in$'\t'"Steam is installed"$'\t!\t'* \
           && "${L[1]}" == game_server$'\t'*$'\t'unknown$'\t-\t?\t'* && "${L[2]}" == ssh$'\t'*$'\t'out$'\t-\t!\t'* ]] && echo "affects-in-use-first"
        h=$(affects_html 0)
        [[ "$h" == *"Steam Remote Play and LAN game transfers</b> - stops it"*"in use here: Steam is installed"* && "$h" == *"&lt;i&gt;here&lt;/i&gt;"* \
           && "$h" == *"not set up on this PC: SSH logins to this PC"* && "$h" != *"<i>here"* ]] && echo "affects-html-escaped"
        [[ "$(affects_tags 0)" == "Steam Remote Play and LAN game transfers" ]] && _affects_in_use 0 && echo "affects-tags"
        finding high "Other problem" "d" "m" true
        _affects_in_use 1 || echo "affects-none-not-in-use"
        # High findings start ticked, except one whose fix stops a feature in
        # use. (An earlier test stubbed _choose_fixes; take the real one.)
        eval "$(sed -n '/^_choose_fixes() {/,/^}/p' "$HERE/../lib/fixes.sh")"
        ui_checklist() { shift; while [[ $# -ge 3 ]]; do echo "$1=$3"; shift 3; done; }
        true() { :; }
        [[ "$(_choose_fixes | sort | tr '\n' ' ')" == "0=off 1=on " ]] && echo "fix-in-use-unticked"
        mapfile -t P < <(_ports_affects "!" "s" "27036/tcp" "27031-27036/udp" "47984/tcp  sunshine" "8080/tcp" "22/tcp" "25565/tcp")
        [[ "${P[*]}" == "remote_play!|s sunshine!|s ssh!|s game_server!|s" ]] && echo "ports-to-features"
        # "Changes" and "you choose" alone do not untick a fix.
        F_AFFECT[0]=$'remote_play|changes\nremote_play?|choose'
        _affects_in_use 0 || echo "affects-change-not-unticked"
    )

    # Kirigami chooser, check page and confirm window: inputs are JSON with
    # every part as text, and only offered answers are taken back.
    (
        it=$(ui_item "App <b>x</b>" "removes: host" high "will break")
        [[ "$(_ui_item_part "$it" 0)" == "App <b>x</b>" && "$(_ui_item_part "$it" 2)" == high \
           && "$(_ui_item_line "$it")" == "App <b>x</b>  —  removes: host  [high risk]  ⚠ will break" \
           && "$(_ui_item_line "$(ui_item plain "" low "")")" == plain ]] && echo "ui-item-parts"
        j=$(_choose_input "<html><h3>Pick &lt;apps&gt;</h3><p>Some &amp; text</p></html>" a "$it" on b "$(ui_item B "" bogus "")" off)
        python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); i=d["items"]
assert d["title"]=="Pick <apps>" and "Some & text" in d["intro"] and i[0]=={"tag":"a","label":"App <b>x</b>","detail":"removes: host","risk":"high","warn":"will break","on":True}
assert i[1]["risk"]=="" and i[1]["on"] is False and d["allow_none"] is False' "$j" && echo "choose-input-json"
        # Earlier tests stubbed ui_checklist; take the real one.
        eval "$(sed -n '/^ui_checklist() {/,/^}/p' "$HERE/../lib/ui.sh")"
        _qml_ok() { return 0; }
        ui_app() { cat > "$W/app-in.json" <<< "$2"; printf '%s' "$APP_OUT"; return "${APP_RC:-0}"; }
        APP_OUT='{"tags":["b","zzz","a"]}'
        [[ "$(ui_checklist "t" a A on b B off | tr '\n' ' ')" == "b a " ]] \
            && APP_OUT='{"tags":"a"}' && UI_MODE=none && [[ -z "$(ui_checklist "t" a A off b B off)" ]] \
            && APP_RC=1 && ! ui_checklist "t" a A on && echo "choose-answer-offered-only"
        APP_RC=0; UI_MODE=kde
        [[ "$(_confirm_answer '{"choice":"apply"}')" == 0 && "$(_confirm_answer '{"choice":"stop"}')" == 2 ]] \
            && ! _confirm_answer '{"choice":"rm"}' && ! _confirm_answer 'x' && echo "confirm-answer-checked"
        [[ "$(_check_answer '{"action":"fix","ids":["3","5"]}' | tr '\n' ' ')" == "fix 3 5 " && "$(_check_answer '{"action":"back"}')" == back ]] \
            && ! _check_answer '{"action":"fix","ids":["1;rm"]}' && ! _check_answer '{"action":"fix","ids":[3]}' && echo "check-answer-checked"
        # The check page: findings as JSON; only offered fixes run.
        F_SEV=(medium low); F_CHECK=(check_firewall check_firewall); F_TITLE=("Wide <zone>" "Other"); F_DETAIL=(d d); F_MANUAL=(m m)
        F_FIX=(true ""); F_STATE=(open open); F_NOW=(now ""); F_AFTER=(after ""); F_WARN=("" ""); F_VERIFY=("" ""); F_AFFECT=("remote_play?|x" "")
        CHECK_TITLE["check_firewall"]="Firewall"; CHECK_NOTE["check_firewall"]=$'seen 1\nseen 2'; FIX_MODE=confirm; _CF_READY=0
        true() { :; }
        python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); f=d["findings"]
assert d["title"]=="Firewall" and d["notes"]==["seen 1","seen 2"] and [x["id"] for x in f]==["0","1"]
assert f[0]["fixable"] is True and f[0]["on"] is True and f[0]["title"]=="Wide <zone>" and f[0]["affects"][0]["how"]=="you choose in the fix"
assert f[1]["fixable"] is False' "$(_check_input check_firewall)" && echo "check-input-json"
        # shellcheck disable=SC2120
        run_fix_session() { printf '%s\n' "$@" > "$W/fixrun"; }
        APP_OUT='{"action":"fix","ids":["1","0","9"]}'; : > "$W/fixrun"
        show_check check_firewall
        [[ "$(cat "$W/fixrun")" == 0 ]] && echo "check-page-fixes-offered-only"
        # Closing a port of a feature in use is high risk and starts unticked.
        feature_status() { [[ "$1" == remote_play ]] && printf 'in\tSteam is installed' || printf 'out'; }
        [[ "$(_port_close_risk 27036/tcp)" == "high|"*"in use here: Steam is installed"*"|off" && "$(_port_close_risk 8000/tcp)" == low\|*\|on ]] \
            && echo "port-close-risk"
        # Where a tick keeps something (the firewall list) there is no "Low
        # risk only"; the fix list rates a fix that may stop an undetectable
        # feature medium, with a warning.
        python3 -I -c 'import json,sys; assert json.loads(sys.argv[1])["low_only"] is False and json.loads(sys.argv[2])["low_only"] is True' \
            "$(UI_CHOOSE_LOWONLY=0 _choose_input t a A on)" "$(_choose_input t a A on)" \
            && grep -q 'UI_CHOOSE_LOWONLY=0 UI_CHOOSE_NOTE=0 ui_checklist "Choose what other devices' "$HERE/../checks/network.sh" && echo "firewall-list-no-low-only"
        feature_status() { [[ "$1" == remote_play ]] && printf 'unknown\tSteam is installed' || printf 'out'; }
        F_AFFECT[0]="remote_play!|x"; F_WARN[0]=""
        [[ "$(_ui_item_part "$(_fix_item 0)" 2)" == medium && "$(_ui_item_part "$(_fix_item 0)" 3)" == "May stop Steam Remote Play"* ]] && echo "fix-item-maybe-medium"
        # The Apply window: a bad answer falls back to the plain dialog;
        # closing it skips the fix.
        eval "$(sed -n '/^apply_change() {/,/^}/p' "$HERE/../lib/fixes.sh")"   # earlier tests stubbed it
        ui_choice3() { echo choice3 > "$W/c3"; return 1; }
        CURRENT_FINDING=0; : > "$W/c3"; APP_OUT='{"choice":"rm"}'; APP_RC=0
        apply_change "true" "" >/dev/null 2>&1; r1=$?
        APP_RC=1; : > "$W/c3-none"; apply_change "true" "" >/dev/null 2>&1; r2=$?
        [[ $r1 -eq 1 && "$(cat "$W/c3")" == choice3 && $r2 -eq 1 ]] && echo "confirm-fallback-and-close-skips"
        APP_RC=0
        # The themed dialog: only a button that was there and a tag offered.
        APP_OUT='{"button":1}'; ui_yesno "q" && APP_OUT='{"button":0}' && ! ui_yesno "q" \
            && APP_OUT='{"button":7}' && UI_MODE=none && ! ui_yesno "q" && UI_MODE=kde \
            && APP_OUT='{"button":1,"tag":"b"}' && [[ "$(ui_radiolist "t" a A on b B off)" == b ]] \
            && APP_OUT='{"button":1,"tag":"zz"}' && UI_MODE=none && [[ "$(ui_radiolist "t" a A on b B off)" == a ]] && echo "dialog-answer-checked"
        UI_MODE=kde
        # The button: a whole number from 0 to the last button's, nothing else.
        dlg() { APP_OUT="$1"; _ui_dialog question "q" "" "No" "Yes" 2>/dev/null; }
        [[ "$(dlg '{"button":0}')" == 0 && "$(dlg '{"button":1}')" == 1 ]] && ! dlg '{"button":2}' > /dev/null && ! dlg '{"button":-1}' > /dev/null \
            && ! dlg '{"button":true}' > /dev/null && ! dlg '{"button":"1"}' > /dev/null && ! dlg '{"button":1.0}' > /dev/null && ! dlg '[1]' > /dev/null \
            && echo "dialog-button-in-range"
        # The button a stray Enter or Space presses in the window ("primary",
        # counted from 0, buttons in the order Cancel, No, Yes; -1: none). It
        # follows the default answer, and it is never a Yes that changes the
        # PC as administrator ("careful", "warn").
        for fn in ui_yesno ui_choice3 ui_radiolist ui_msg run_undo; do eval "$(sed -n "/^${fn}() {/,/^}/p" "$HERE"/../lib/ui.sh "$HERE"/../lib/fixes.sh)"; done
        prim() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["primary"], d["kind"], end=";")' "$W/app-in.json"; }
        APP_OUT='{"button":0}'; p=""
        ui_yesno "q" Y N n; p+=$(prim); ui_yesno "q" Y N y; p+=$(prim)
        ui_yesno "q" Y N y careful; p+=$(prim); ui_yesno "q" Y N n careful; p+=$(prim)
        ui_yesno "q" Y N y warn; p+=$(prim); ui_yesno "q" Y N n warn; p+=$(prim)
        [[ "$p" == "0 question;1 question;-1 question;0 question;-1 warning;0 warning;" ]] && echo "yesno-enter-follows-the-default-never-a-change"
        p=""
        ui_choice3 "q" "" Y N C; p+=$(prim); ui_choice3 "q" "" Y N C "" y; p+=$(prim)
        ui_choice3 "q" "" Y N C careful; p+=$(prim); ui_choice3 "q" "" Y N C careful y; p+=$(prim)
        ui_choice3 "q" "" Y N C warn; p+=$(prim); ui_choice3 "q" "" Y N C warn y; p+=$(prim)
        [[ "$p" == "1 question;2 question;1 question;-1 question;1 warning;-1 warning;" ]] && echo "choice3-enter-follows-the-default-never-a-change"
        # The windows that change something. Each answer comes from a
        # queue; every dialog that was asked for is kept.
        ui_app() {
            local a
            printf '%s\n' "$2" >> "$W/app-all.jsonl"
            if [[ "$1" != dialog ]]; then printf '%s' "$APP_OUT"; return 0; fi
            a=$(head -n 1 "$W/app-q"); sed -i 1d "$W/app-q"
            printf '%s' "${a:-{\"button\":0\}}"
        }
        # dlgs — of every dialog: its primary, its kind and its last button.
        dlgs() { python3 -I -c 'import json, sys
for line in open(sys.argv[1]):
    d = json.loads(line)
    print(d["primary"], d["kind"], d["buttons"][-1]["label"], sep="/", end=";")' "$1"; }
        # Apply, where the Apply window gave no usable answer: with and
        # without a warning, Enter is "Skip".
        APP_OUT='{"choice":"rm"}'; : > "$W/app-all.jsonl"; : > "$W/app-q"
        _fix_warnings() { :; }; apply_change "true" "" > /dev/null 2>&1; r1=$?
        _fix_warnings() { echo "x|Something stops working"; }; apply_change "true" "" > /dev/null 2>&1; r2=$?
        [[ $r1 -eq 2 && $r2 -eq 2 && "$(grep '"buttons"' "$W/app-all.jsonl" > "$W/app-dlg.jsonl"; dlgs "$W/app-dlg.jsonl")" == "1/question/Apply;1/warning/Apply;" ]] && echo "apply-fallback-enter-is-skip"
        # Undo: the older of two runs is picked, "Undo anyway" is pressed,
        # the first step's window is closed with Stop. Enter was Cancel,
        # then "Keep it"; nothing was undone.
        (
            STATE_DIR="$W/undo-prim"; mkdir -p "$STATE_DIR/undo/20250101-000000" "$STATE_DIR/undo/20250102-000000"
            for r in 20250101-000000 20250102-000000; do
                printf '%s\n' '#!/usr/bin/env bash' '# TITLE: A change' 'set -uo pipefail' "touch '$W/undo-prim/ran'" > "$STATE_DIR/undo/$r/01-undo.sh"
            done
            : > "$W/app-all.jsonl"
            printf '%s\n' '{"button":1,"tag":"20250101-000000"}' '{"button":1}' '{"button":0}' '{"button":0}' > "$W/app-q"
            run_undo > /dev/null 2>&1
            [[ "$(dlgs "$W/app-all.jsonl")" == "1/question/OK;0/warning/Undo anyway;1/question/Undo it;0/info/OK;" && ! -e "$W/undo-prim/ran" \
               && -e "$STATE_DIR/undo/20250101-000000/01-undo.sh" ]] && echo "undo-enter-is-cancel-then-keep-it"
        )
        # kdialog cannot be told its default button: a marked question
        # uses its warning dialog.
        (
            _ui_dialog() { return 4; }; _kd() { printf '%s ' "$@" >> "$W/kd-kinds"; echo >> "$W/kd-kinds"; return 1; }
            _kd_answer() { _kd "$@"; }
            UI_MODE=kde; : > "$W/kd-kinds"
            ui_yesno "q" Y N y; ui_yesno "q" Y N y careful; ui_yesno "q" Y N n warn
            ui_choice3 "q" "" Y N C; ui_choice3 "q" "" Y N C careful; ui_choice3 "q" "" Y N C warn
            [[ "$(grep -oE -- '--(warning)?yesno(cancel)? ' "$W/kd-kinds" | tr -d '\n')" == "--yesno --warningyesno --warningyesno --yesnocancel --warningyesnocancel --warningyesnocancel " ]] \
                && echo "careful-questions-use-the-kdialog-warning"
        )
        # Enter presses kdialog's Yes place in every question (since 19.12):
        # unless Yes is the default, No is put there, and the answer is read
        # back the other way round; Esc or closing (exit 2) is never Yes.
        (
            _ui_dialog() { return 4; }
            _kd() { printf '%s|' "$2" "$4" >> "$W/kd-swap"; echo >> "$W/kd-swap"; return "$KD_RC"; }
            _kd_answer() { _kd "$@"; }
            UI_MODE=kde; : > "$W/kd-swap"; out=""
            for q in "y" "y careful" "n" "n warn"; do
                for KD_RC in 0 1 2; do
                    # shellcheck disable=SC2086 # $q is two words on purpose
                    ui_yesno "q" Y N $q; out+="$?"
                done
                out+=" "
            done
            for q in ":n" "careful:n" "warn:y" ":y"; do
                for KD_RC in 0 1 2; do
                    ui_choice3 "q" "" Y N C "${q%%:*}" "${q#*:}"; out+="$?"
                done
                out+=" "
            done
            want=""; for p in "Y|N|" "N|Y|" "N|Y|" "N|Y|" "N|Y|" "N|Y|" "N|Y|" "Y|N|"; do want+="$p $p $p "; done
            [[ "$out" == "012 101 101 101 102 102 102 012 " && "$(tr '\n' ' ' < "$W/kd-swap")" == "$want" ]] && echo "kdialog-enter-is-not-yes" \
               || echo "kdialog answers: $out / $(tr '\n' ' ' < "$W/kd-swap")"
            # kdialog failing (255) is no answer: the question goes on to the
            # next way of asking. Here nobody is left to ask, and a marked
            # question is then "no" even when its default is "yes".
            _kd_answer() { UI_MODE=none; return 255; }
            UI_MODE=kde; ui_choice3 "q" "" Apply Skip Stop careful; r1=$?
            UI_MODE=kde; ui_yesno "q" "Undo anyway" Cancel n warn; r2=$?
            UI_MODE=kde; ui_yesno "q" Remove Cancel y careful; r3=$?
            UI_MODE=kde; ui_yesno "q" "Roll back" "Leave it" y warn; r4=$?
            [[ "$r1$r2$r3$r4" == 1111 ]] && echo "kdialog-failure-asks-on" || echo "kdialog failure gave $r1$r2$r3$r4"
        )
        # Exit 1 means "yes" in a swapped question: only when kdialog itself
        # said so. A wrapper that fails (here: no desktop user) is kdialog
        # failing, never an answer.
        (
            _ui_dialog() { return 4; }; _ui_fallback() { UI_MODE=none; }
            _as_desktop_user() { return 1; }
            UI_MODE=kde; RUN_TMP="$W/kd-wrap-rt"; mkdir -p "$RUN_TMP"
            ui_choice3 "q" "" Apply Skip Stop careful; r1=$?
            UI_MODE=kde; ui_yesno "q" "Undo anyway" Cancel n warn; r2=$?
            UI_MODE=kde; ui_yesno "Remove the app?" Remove Cancel y careful < /dev/null; r4=$?
            [[ "$r1" == 1 && "$r2" == 1 && "$r4" == 1 && -e "$RUN_TMP/kdialog-failed" ]] && echo "kdialog-wrapper-failure-is-not-yes"
            # ... while kdialog's own exit 1 (the button with the yes answer) is yes.
            rm -f "$RUN_TMP/kdialog-failed"; UI_MODE=kde
            _as_desktop_user() { shift 1; [[ "$1" == XDG_CONFIG_HOME=* ]] && shift; "$@"; }
            mkdir -p "$W/kd-own-bin"; printf '#!/bin/sh\nexit 1\n' > "$W/kd-own-bin/kdialog"; chmod 755 "$W/kd-own-bin/kdialog"
            PATH="$W/kd-own-bin:$PATH"
            ui_choice3 "q" "" Apply Skip Stop careful; r3=$?
            [[ "$r3" == 0 ]] && echo "kdialog-own-exit-1-is-yes" || echo "own exit 1 gave $r3"
            # ... and its 0 and 2 are Skip and Stop; 3 is kdialog failing.
            got=""
            for k in 0 2 3; do
                rm -f "$RUN_TMP/kdialog-failed"; UI_MODE=kde
                printf '#!/bin/sh\nexit %s\n' "$k" > "$W/kd-own-bin/kdialog"
                ui_choice3 "q" "" Apply Skip Stop careful; got+="$?$([[ -e "$RUN_TMP/kdialog-failed" ]] && echo f || true) "
            done
            [[ "$got" == "1 2 1f " ]] && echo "kdialog-own-exits-mapped" || echo "own exits gave: $got"
        )
        # Every question whose Yes changes the PC there and then is marked.
        marked=1
        for q in 'echo warn || echo careful)"' '"Roll back" "Leave it" "y" careful' '"Undo anyway" "Cancel" "n" warn' \
                 '"Undo it" "Keep it" "Stop" careful' '"${verb}" "Cancel" "y" careful' '"Set it up" "Cancel" "y" careful' '"Update" "Not now" "y" careful'; do
            grep -qF -- "$q" "$HERE"/../lib/fixes.sh "$HERE"/../lib/install.sh "$HERE"/../lib/update.sh || { marked=0; echo "not marked: $q"; }
        done
        [[ "$(grep -cF '"Remove" "Cancel" "y" careful' "$HERE/../lib/install.sh")" -eq 2 && $marked -eq 1 ]] && echo "root-changing-questions-are-marked"
    )

    # The real detection rules: Steam alone does not mean Remote Play is
    # used, the default gaming answer does not mean a game server is
    # hosted, and Sunshine's admin port is not a streaming port.
    (
        _have() { [[ "$1" == steam ]]; }; _flatpak_installed() { return 1; }
        USE_GAMING=1; USE_STREAMING=0; USE_SSH=0; USE_SHARING=0; USE_DEV=0; DETECTED=(); _FEATURE_SEEN=()
        [[ "$(feature_status remote_play)" == unknown$'\t'"Steam is installed" && "$(feature_status game_server)" == unknown$'\t' \
           && "$(feature_status anticheat)" == in$'\t'"Steam is installed" ]] \
            && USE_STREAMING=1 && [[ "$(feature_status remote_play)" == in$'\t'* ]] && echo "detect-honest-steam-and-servers"
        [[ -z "$(_ports_affects "!" s 47990/tcp)" && "$(_ports_affects "!" s 47990/tcp 47989/tcp)" == "sunshine!|s" ]] && echo "sunshine-admin-port-not-streaming"
    )

    # Kept on purpose: a kept finding becomes a note that does not lower the
    # score and offers no fix; counts in titles do not matter; the file is
    # root's and a symlink is refused; unticking counts it again.
    (
        _feature_detect() { [[ "$1" == remote_play ]] && { echo "Steam is installed"; return 0; }; return 1; }
        USE_GAMING=0; USE_STREAMING=0; USE_SSH=0; USE_SHARING=0; USE_DEV=0; _FEATURE_SEEN=()
        KS="$W/kept-state"; rm -rf "$KS"; mkdir -p "$KS"; STATE_DIR="$KS"
        printf 'check_firewall\tThe firewall opens # port(s) that nothing uses\t2026-11-12\tSteam Remote Play\nbad line\ncheck_other\tSomething\t2026-11-01\t\n' > "$KS/kept"
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=(); F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=(); F_AFFECT=(); F_KEPT_SEV=()
        CHECK_FAILED=(); CHECK_STATUS=(); CHECK_ORDER=(check_firewall check_ssh_server); CHECK_WEIGHT=([check_firewall]=10 [check_ssh_server]=10)
        FINDINGS_FILE=""; CURRENT_CHECK=check_firewall
        finding low "The firewall opens 3 port(s) that nothing uses" "d" "m" true
        finding_affects "remote_play!|closes Remote Play ports"
        CHECK_STATUS[check_firewall]=fail
        CURRENT_CHECK=check_ssh_server
        finding medium "SSH accepts passwords" "d" "m" true
        finding_affects "remote_play!|x"
        CHECK_STATUS[check_ssh_server]=fail
        kept_load; kept_apply
        [[ "${F_STATE[0]}" == kept && "${F_SEV[0]}" == info && -z "${F_FIX[0]}" && "${F_KEPT_SEV[0]}" == low \
           && "${F_DETAIL[0]}" == "Kept on purpose since 2026-11-12 (for Steam Remote Play)"* \
           && "${CHECK_STATUS[check_firewall]}" == pass && -z "${CHECK_FAILED[check_firewall]:-}" \
           && "${F_STATE[1]}" == open && "${CHECK_STATUS[check_ssh_server]}" == fail ]] && echo "kept-becomes-note"
        # Two checks of weight 10: the kept low finding costs nothing, the
        # open medium one 5 points: 100 * 15 / 20 = 75.
        [[ "$(_score found)" == 75 ]] && echo "kept-not-scored"
        [[ "$(_finding_state_label 0)" == "Kept on purpose"* && "$(kept_count)" == 1 ]] && kept_offered && echo "kept-labelled"
        # A kept entry without a date says no "since".
        printf 'check_sudo\tsudo works without a password\t\t\thigh\n' > "$KS/kept.nodate"
        ( KEPT_FILE=""; STATE_DIR="$KS"; cp "$KS/kept.nodate" "$KS/kept"; kept_load
          F_SEV=(medium); F_CHECK=(check_sudo); F_TITLE=("sudo works without a password"); F_DETAIL=(d); F_FIX=(x); F_STATE=(open); F_VERIFY=(""); F_AFFECT=(""); F_KEYX=("")
          kept_apply; [[ "${F_STATE[0]}" == kept && "${F_DETAIL[0]}" == "Kept on purpose: this does not lower"* ]] ) && echo "kept-no-date-no-since"
        # The dialog: the kept one is ticked, the SSH one offered; keep both,
        # and the entry of a check that did not run stays.
        ui_checklist() { shift; while [[ $# -ge 3 ]]; do echo "$1"; shift 3; done; }
        ui_msg() { :; }; log() { :; }; write_reports() { :; }
        manage_kept
        grep -q $'^check_other\tSomething\t2026-11-01' "$KS/kept" && grep -q $'^check_firewall\tThe firewall opens # port(s) that nothing uses\t2026-11-12' "$KS/kept" \
           && grep -q $'^check_ssh_server\tSSH accepts passwords\t' "$KS/kept" && ! grep -q 'bad line' "$KS/kept" \
           && [[ "$(stat -c %a "$KS/kept")" == 600 ]] && echo "kept-saved"
        # Untick everything: only the entry of the check that did not run is left.
        ui_checklist() { return 0; }
        manage_kept
        [[ "$(grep -c . "$KS/kept")" == 1 ]] && grep -q '^check_other' "$KS/kept" && echo "kept-untick-counts-again"
        # Reopened in the same session, the unticked problems stay unticked.
        [[ "${F_STATE[0]}" == kept && -z "$(_keep_candidates | grep $'\ton$')" && "$(_keep_candidates | grep -c $'\toff$')" == 2 ]] && echo "kept-untick-holds-in-session"
        # Kept ports cover exactly those ports: a new port counts again; a
        # kept problem that got worse counts again too.
        printf 'check_listening_services\t# service(s) can be reached from your network [22/tcp,27036/tcp]\t2026-11-12\tSSH\tmedium\ncheck_sudo\tsudo works without a password\t2026-11-12\t\tlow\n' > "$KS/kept"; kept_load
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_FIX=(); F_STATE=(); F_VERIFY=(); F_AFFECT=(); F_KEYX=(); F_KEPT_SEV=()
        CURRENT_CHECK=check_listening_services
        finding medium "1 service(s) can be reached from your network" d m true; finding_keep_key "22/tcp"
        finding medium "2 service(s) can be reached from your network" d m true; finding_keep_key "4444/tcp" "22/tcp"
        CURRENT_CHECK=check_sudo
        finding medium "sudo works without a password" d m true
        kept_apply
        # 22 alone is covered by the kept 22+27036 (27036 is closed now, Steam
        # not running); 22+4444 is not (4444 is new).
        [[ "${F_STATE[0]}" == kept && "${F_STATE[1]}" == open && "${F_SEV[1]}" == medium && "${F_STATE[2]}" == open ]] && echo "kept-exact-ports-and-severity"
        # Saving again keeps the entry that covered it (22+27036), not just 22.
        _feature_detect() { [[ "$1" == ssh ]] && { echo x; return 0; }; return 1; }; _FEATURE_SEEN=()
        F_AFFECT[0]="ssh!|x"; F_AFFECT[1]="ssh!|x"
        ui_checklist() { echo 0; }
        manage_kept
        grep -q '\[22/tcp,27036/tcp\]' "$KS/kept" && ! grep -q '\[22/tcp\]' "$KS/kept" && ! grep -q '4444' "$KS/kept" && echo "kept-subset-entry-kept"
        # Ticking a kept problem that got worse keeps it at its new severity.
        F_AFFECT[2]="ssh!|x"; ui_checklist() { echo 0; echo 2; }
        manage_kept
        grep -q $'^check_sudo\tsudo works without a password\t.*\tmedium$' "$KS/kept" && [[ "${F_STATE[2]}" == kept ]] && echo "kept-worse-reticked"
        # Overlapping entries: a narrower one kept at medium and a broader one
        # at high. The high problem is kept (the broader entry allows it);
        # saving it ticked merges them into one entry (all ports, high, the
        # earliest date); unticking removes every entry that kept it.
        printf 'check_listening_services\t# service(s) can be reached from your network [22/tcp]\t2026-11-01\tSSH\tmedium\ncheck_listening_services\t# service(s) can be reached from your network [22/tcp,27036/tcp]\t2026-11-05\tSSH\thigh\n' > "$KS/kept"; kept_load
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_FIX=(); F_STATE=(); F_VERIFY=(); F_AFFECT=(); F_KEYX=(); F_KEPT_SEV=(); F_KEPT_FROM=()
        CURRENT_CHECK=check_listening_services
        finding high "1 service(s) can be reached from your network" d m true; finding_keep_key "22/tcp"; finding_affects "ssh!|x"
        kept_apply
        ui_checklist() { echo 0; }; manage_kept
        [[ "${F_STATE[0]}" == kept && "$(grep -c . "$KS/kept")" == 1 ]] \
            && grep -q $'^check_listening_services\t# service(s) can be reached from your network \\[22/tcp,27036/tcp\\]\t2026-11-01\t[^\t]*\thigh$' "$KS/kept" && echo "kept-overlap-merged"
        printf 'check_listening_services\t# service(s) can be reached from your network [22/tcp]\t2026-11-01\tSSH\tmedium\ncheck_listening_services\t# service(s) can be reached from your network [22/tcp,27036/tcp]\t2026-11-05\tSSH\thigh\n' > "$KS/kept"; kept_load
        ui_checklist() { return 0; }; manage_kept
        [[ ! -s "$KS/kept" && -z "$(_keep_candidates | grep $'\ton$')" ]] && echo "kept-overlap-untick-all"
        # The session remembers the widest keep: [1] medium + [1,22] high keep
        # a low finding; untick, then tick again: high, both ports, the
        # earliest date come back.
        printf 'check_listening_services\t# service(s) can be reached from your network [1/tcp]\t2026-10-01\tSSH\tmedium\ncheck_listening_services\t# service(s) can be reached from your network [1/tcp,22/tcp]\t2026-10-05\tSSH\thigh\n' > "$KS/kept"; kept_load
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_FIX=(); F_STATE=(); F_VERIFY=(); F_AFFECT=(); F_KEYX=(); F_KEPT_SEV=(); F_KEPT_FROM=(); F_KEPT_DATE=(); F_KEPT_PORTS=()
        finding low "1 service(s) can be reached from your network" d m true; finding_keep_key "1/tcp"; finding_affects "ssh!|x"
        kept_apply
        ui_checklist() { return 0; }; manage_kept
        ui_checklist() { echo 0; }; manage_kept
        grep -qx $'check_listening_services\t# service(s) can be reached from your network \\[1/tcp,22/tcp\\]\t2026-10-01\t[^\t]*\thigh' "$KS/kept" \
            && [[ "$(grep -c . "$KS/kept")" == 1 && "${F_STATE[0]}" == kept ]] && echo "kept-retick-restores-widest"
        # An entry without a level keeps any level; saving it again does not
        # narrow it to the finding's level.
        printf 'check_sudo\tsudo works without a password\t2026-10-01\t\t\n' > "$KS/kept"; kept_load
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_FIX=(); F_STATE=(); F_VERIFY=(); F_AFFECT=(); F_KEYX=(); F_KEPT_SEV=(); F_KEPT_FROM=(); F_KEPT_DATE=(); F_KEPT_PORTS=()
        CURRENT_CHECK=check_sudo; finding low "sudo works without a password" d m true; finding_affects "ssh!|x"
        kept_apply; manage_kept
        grep -q $'^check_sudo\tsudo works without a password\t2026-10-01\t.*\thigh$' "$KS/kept" && echo "kept-any-level-stays-any"
        rm -f "$KS/kept"; ln -s "$W/elsewhere" "$KS/kept"; kept_load
        ! _kept_save "x" && [[ ! -e "$W/elsewhere" ]] && echo "kept-symlink-refused"
        [[ "$(_dashboard_answer '{"action":"keep"}')" == keep ]] && echo "dashboard-keep-action"
    )

    # Progress: the bar shows finished checks scaled to 90%, so it never
    # reads 100% while a check still runs; the slow malware scan holds at
    # 90% with a note; 100% comes only when everything is done.
    (
        exec {_PROGRESS_FD}> "$W/progress.txt"; _PROGRESS_BACKEND=window; _PROGRESS_STEPS=10; QUIET=1
        ui_progress_set 1 "First"; ui_progress_set 10 "Last"; ui_progress_set 10 "Malware scan (ClamAV)" slow
        ui_progress_stop
        mapfile -t pl < "$W/progress.txt"
        [[ "${pl[0]%%$'\t'*}" == 0 && "${pl[1]%%$'\t'*}" == 81 && "${pl[2]}" == $'90\t1\tMalware scan (ClamAV)\tThis can take several minutes. The bar moves on when it is done.' \
           && "${pl[3]}" == $'100\t0\tDone\t' && "${pl[4]}" == QUIT && ${#pl[@]} -eq 5 ]] && echo "progress-90-until-done"
        # A busy indicator (a fix being applied): no steps, no 100%.
        exec {_PROGRESS_FD}> "$W/busy.txt"; _PROGRESS_BACKEND=window; _PROGRESS_STEPS=0; ui_progress_stop
        [[ "$(cat "$W/busy.txt")" == QUIT ]] && echo "busy-no-percent"
    )

    # On a terminal, Enter takes the given default of a three-way question.
    ( source "$HERE/../lib/ui.sh"   # ui_choice3 is stubbed above
      UI_MODE="tty"; _tty_read() { echo ""; }
      ui_choice3 "<html>q" "" Start Change Quit "" y 2>/dev/null; a=$?
      ui_choice3 "<html>q" "" Apply Skip Stop 2>/dev/null; b=$?
      [[ $a -eq 0 && $b -eq 1 ]] && echo "choice3-tty-default" )

    # Ports a zone opens by hand are closed by the fix (the dev server that
    # listens on one, and one nothing uses); ports a service opens are not.
    (
        F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=()
        F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=()
        FINDINGS_FILE=""; USE_SHARING=0; CURRENT_CHECK=check_listening_services
        _FW_ZONE_ALL=(); _FW_ZONE_OPEN=()
        printf 'devzone\n' > "$W/iface-zone"
        check_listening_services
        rm -f "$W/iface-zone"
        for i in "${!F_TITLE[@]}"; do printf '%s|%s|%s\n' "${F_TITLE[$i]}" "${F_FIX[$i]}" "${F_AFTER[$i]}"; done > "$W/close.txt"
        grep -qF '1 service(s) can be reached from your network|fix_close_ports devzone\|3000/tcp\|node|blocked by the firewall' "$W/close.txt" \
            && grep -qF 'The firewall opens 1 port(s) that nothing uses|fix_close_ports devzone\|8000/tcp\|' "$W/close.txt" \
            && ! grep -qF '47984/tcp' "$W/close.txt" && ! grep -qF '9000/tcp' "$W/close.txt" \
            && ! grep -qF '1720/udp' "$W/close.txt" && echo "exposed-port-fix-offered"
        _fw_running() { return 0; }
        _listener_zones() { echo devzone; }
        ! _closable_entries tcp 0.0.0.0 22 && echo "service-port-not-closable"
        ui_checklist() { shift; while [[ $# -ge 3 ]]; do echo "$1"; shift 3; done; }
        apply_change() { printf '%s\n--\n%s\n' "$1" "$2" > "$W/close-fix.txt"; }
        fix_close_ports "devzone|3000/tcp|node"
        grep -qx 'firewall-cmd --zone=devzone --remove-port=3000/tcp' "$W/close-fix.txt" \
            && grep -qx 'firewall-cmd --permanent --zone=devzone --remove-port=3000/tcp' "$W/close-fix.txt" \
            && grep -qx 'firewall-cmd --permanent --zone=devzone --add-port=3000/tcp' "$W/close-fix.txt" \
            && ! grep -q -- '--reload' "$W/close-fix.txt" && echo "close-ports-fix-and-undo"
        fix_close_ports "devzone|8000/tcp|nothing listening now" "bad zone;x|8001/tcp|evil"
        grep -qx 'firewall-cmd --zone=devzone --remove-port=8000/tcp' "$W/close-fix.txt" \
            && ! grep -q -- '--permanent' "$W/close-fix.txt" && ! grep -q 'evil\|8001' "$W/close-fix.txt" \
            && echo "runtime-only-port-and-bad-zone"
    )

    # The app install: a root-owned copy, a menu entry for everyone that
    # runs it, the command, and an older per-user entry removed. Removing
    # the app keeps the copy while the weekly timer still uses it.
    (
        DESKTOP_USER="$U"; UI_MODE="none"
        _as_desktop_user() { _as_user "$DESKTOP_USER" "$@"; }   # stubbed above
        ui_yesno() { return 0; }; ui_msg() { :; }; ui_error() { echo "ERR $*"; }
        old="$UH/.local/share/applications/bazzite-security-check.desktop"
        runuser -u "$U" -- mkdir -p "$(dirname "$old")"
        runuser -u "$U" -- touch "$old"
        install_app
        exe="$INSTALL_DIR/$(basename "$TOOL")"
        [[ -x "$exe" && "$(stat -c %U:%G "$exe")" == root:root && "$(stat -c %a "$INSTALL_DIR/lib")" == 755 ]] \
            && grep -qx "Exec=$exe --gui" "$APP_DESKTOP" && grep -qx "Exec=$exe --gui --undo" "$APP_DESKTOP" \
            && grep -qx "Icon=bazzite-security-check" "$APP_DESKTOP" && [[ -f "$APP_ICON_DIR/bazzite-security-check.svg" && -f "$APP_ICON_22/bazzite-security-check-symbolic.svg" && -f "$INSTALL_DIR/ui/app.py" && -f "$INSTALL_DIR/release-signers" ]] \
            && [[ "$(readlink "$APP_BIN")" == "$exe" && ! -e "$old" ]] \
            && ! installed_copy_outdated && echo "app-installed"
        _timer_installed() { return 0; }
        uninstall_app
        [[ ! -e "$APP_DESKTOP" && ! -e "$APP_BIN" && ! -e "$APP_ICON_DIR/bazzite-security-check.svg" && -d "$INSTALL_DIR" ]] && echo "app-removed-copy-kept"
        _timer_installed() { return 1; }
        _remove_copy
        [[ ! -e "$INSTALL_DIR" ]] && echo "copy-removed-when-unused"
    )

    # A root run started through pkexec that stops with an error says why.
    (
        pkexec() { echo "The state folder /x is not a folder owned by root; refusing to use it." >&2; return 1; }
        _explain_pkexec() { :; }
        kdialog() { printf '%s\n' "$@" > "$W/pk-sorry.txt"; }
        UI_PREF=auto; WAYLAND_DISPLAY=wayland-0
        _elevate --check sudo
    ) < /dev/null > /dev/null 2>&1
    grep -qx -- '--sorry' "$W/pk-sorry.txt" \
        && grep -q 'Security Check stopped: The state folder /x is not a folder owned by root' "$W/pk-sorry.txt" \
        && echo "pkexec-error-shown"

    # Applied fixes are checked again: gone, still there, or after a reboot.
    RUN_TMP="$W/rt6"; mkdir -p "$RUN_TMP"; FINDINGS_FILE=""; QUIET=1
    F_SEV=(); F_CHECK=(); F_TITLE=(); F_DETAIL=(); F_MANUAL=(); F_FIX=(); F_STATE=()
    F_NOW=(); F_AFTER=(); F_WARN=(); F_VERIFY=(); F_RECHECK=()
    check_fake() { [[ -e "$W/fake-problem" ]] && finding medium "Fake problem 7" "d" "m"; return 0; }
    CHECK_ORDER=(check_fake); CHECK_WEIGHT["check_fake"]=10; CHECK_STATUS["check_fake"]=fail
    CURRENT_CHECK=check_fake; finding medium "Fake problem 3" "d" "m" fix_x; CURRENT_CHECK=""
    F_STATE[0]=fixed; SESSION_DONE=(0)
    touch "$W/fake-problem"; verify_fixes
    [[ "${F_VERIFY[0]}" == still && "${F_RECHECK[0]}" == "Fake problem 7" ]] && echo "verify-still"
    rm -f "$W/fake-problem"; F_VERIFY[0]=""; verify_fixes
    [[ "${F_VERIFY[0]}" == verified ]] && echo "verify-gone"
    compute_score; update_score_now
    [[ "$SCORE" -eq 50 && "$SCORE_NOW" -eq 100 ]] && echo "score-now-counts-verified"
    F_VERIFY[0]=reboot; verify_fixes
    [[ "${F_VERIFY[0]}" == reboot ]] && echo "verify-reboot-kept"
    # A fix pending a reboot is not counted as open (as on its dashboard row).
    [[ "$(_open_count medium)" -eq 0 ]] && echo "pending-fix-not-open"

    # Checks that depend on a fixed one run again too; what they no longer
    # find is gone, and comes back when the fix is undone.
    check_dep() { [[ -e "$W/dep-problem" ]] && finding low "Dep problem" "d" "m"; return 0; }
    CHECK_ORDER=(check_fake check_dep); CHECK_STATUS["check_dep"]=fail; CHECK_WEIGHT["check_dep"]=5
    _CHECK_DEPENDENTS["check_fake"]="check_dep"
    CURRENT_CHECK=check_dep; finding low "Dep problem" "d" "m"; CURRENT_CHECK=""
    F_VERIFY[0]=""; rm -f "$W/dep-problem"; verify_fixes
    [[ "${F_VERIFY[1]}" == gone && "$(_open_count low)" -eq 0 ]] && echo "dependent-recheck-gone"
    [[ "$(_finding_state_label 1)" == Gone* ]] && echo "gone-labelled"

    # A fix undone before the reboot it needed: open again, no reboot asked.
    RUN_ID="t6u"; mkdir -p "$(_undo_dir)"
    printf '#!/usr/bin/env bash\n# TITLE: x\n# Applied: now\n# FINDING: 0\nset -uo pipefail\ntrue\n' > "$(_undo_dir)/01-undo.done"
    F_STATE[0]=fixed; F_VERIFY[0]=reboot; NEEDS_REBOOT=1; REBOOT_REASONS=("rebase"); REBOOT_OF[0]="rebase"
    _sync_undone
    [[ "${F_STATE[0]}" == open && "$NEEDS_REBOOT" -eq 0 && ${#REBOOT_REASONS[@]} -eq 0 ]] && echo "undo-sync-ok"
    [[ -z "${F_VERIFY[1]}" ]] && echo "undo-brings-back-gone"
    F_STATE[0]=fixed; _sync_undone
    [[ "${F_STATE[0]}" == fixed ]] && echo "undo-sync-once"
    [[ "$(_undo_body "$(_undo_dir)/01-undo.done")" == true ]] && echo "undo-body-without-header"

    # Undo steps run as root, later: a path swapped for a symlink since the
    # fix must not hand the old mode to the file it now points to.
    UI_MODE=none
    ui_checklist() { shift; while [[ $# -ge 3 ]]; do echo "$1"; shift 3; done; }
    apply_change() { printf '%s\n' "$2" >> "$W/undo-swap.sh"; return 1; }
    printf 'x\n' > "$W/swap-target"; chmod 600 "$W/swap-target"
    ln -sfn "$W/swap-target" "$W/swapped"
    : > "$W/undo-swap.sh"
    fix_strip_suid "4777|$W/swapped"
    fix_remove_world_write "root|666|$W/swapped" "${U}|666|$W/swapped"
    fix_home_mode "$U" "$W/swapped" 777
    bash "$W/undo-swap.sh" 2> /dev/null
    # (Root's own two are not even offered here: $W is under /tmp, which is
    # not root's alone. Below, the same swap on a path that is.)
    [[ "$(stat -c %a "$W/swap-target")" == 600 && "$(grep -c swapped "$W/undo-swap.sh")" -eq 2 ]] \
        && echo "undo-ignores-swapped-symlink"

    # The same for the folders above a file. As root, a mode is changed
    # only where root alone can change every folder on the way; a file
    # elsewhere is left to the person, and an undo recorded earlier does
    # nothing once a folder on its path has been swapped for a link.
    (
        RO=$(mktemp -d /var/lib/bda-ro.XXXXXX); chmod 755 "$RO"
        mkdir -p "$RO/keep" "$RO/later"; install -d -o "$U" "$RO/theirs"
        printf 'x\n' > "$RO/keep/f"; chmod 666 "$RO/keep/f"
        apply_change() { printf '%s\n' "$1" > "$W/rc-fix.sh"; printf '%s\n' "$2" > "$W/rc-undo.sh"; return 1; }
        fix_remove_world_write "root|666|$RO/keep/f"
        bash "$W/rc-fix.sh"; m1=$(stat -c %a "$RO/keep/f")
        bash "$W/rc-undo.sh"; m2=$(stat -c %a "$RO/keep/f")
        [[ "$m1" == 664 && "$m2" == 666 ]] && echo "root-chmod-on-root-path"

        printf 'x\n' > "$RO/theirs/f"; chmod 666 "$RO/theirs/f"
        : > "$W/rc-fix.sh"
        ui_msg() { printf '%s\n' "$1" > "$W/rc-msg.txt"; }
        fix_remove_world_write "root|666|$RO/theirs/f"
        [[ ! -s "$W/rc-fix.sh" && "$(stat -c %a "$RO/theirs/f")" == 666 ]] \
            && grep -qF "$RO/theirs/f" "$W/rc-msg.txt" && grep -q "by hand" "$W/rc-msg.txt" && echo "chmod-by-hand-left-out"

        printf 'x\n' > "$RO/later/f"; chmod 4755 "$RO/later/f"; chmod 600 "$RO/keep/f"
        fix_strip_suid "4755|$RO/later/f"
        mv "$RO/later" "$RO/later2"; ln -s "$RO/keep" "$RO/later"
        bash "$W/rc-undo.sh" 2> "$W/rc-undo.err"
        [[ "$(stat -c %a "$RO/keep/f")" == 600 ]] && grep -q "not changed" "$W/rc-undo.err" && echo "undo-ignores-swapped-folder"

        printf 'x\n' > "$RO/keep/g"; chmod 4755 "$RO/keep/g"
        fix_strip_suid "4755|$RO/keep/g"
        rm -f "$RO/keep/g"; ln -s "$RO/keep/f" "$RO/keep/g"
        bash "$W/rc-undo.sh" 2> "$W/rc-undo.err"
        [[ "$(stat -c %a "$RO/keep/f")" == 600 ]] && grep -q "is a link now" "$W/rc-undo.err" && echo "undo-ignores-swapped-file"
        rm -rf "$RO"
    )
    unset -f apply_change

    # A fix runs in its own session and is not stopped by a signal to the
    # tool: the tool waits for it and writes its undo step before it stops.
    RUN_TMP=$(mktemp -d "$W/runtmp.XXXXXX")
    (
        RUN_ID="t6int"
        trap _on_signal INT TERM HUP
        echo "$BASHPID" > "$W/int.pid"
        _run_change "t6 slow" "sleep 2; touch $W/int-done" "rm -f $W/int-done" > /dev/null 2>&1
        : > "$W/int-reached"
    ) &
    sleep 0.7; kill -TERM "$(cat "$W/int.pid")"; wait $! 2> /dev/null
    [[ -e "$W/int-done" && ! -e "$W/int-reached" && -f "$STATE_DIR/undo/t6int/01-undo.sh" ]] && echo "interrupt-keeps-undo"
    RUN_TMP=""

    # A new password is one line: a line break in the dialog's answer would
    # hand chpasswd a second account.
    (
        ui_yesno() { return 0; }
        ui_error() { printf '%s\n' "$1" > "$W/pw-err.txt"; }
        chpasswd() { cat > "$W/pw-called"; }
        ui_newpassword() { printf 'x\nroot:evil'; }
        rc=0; fix_set_password "$U" > /dev/null || rc=$?
        [[ $rc -eq 1 && ! -e "$W/pw-called" ]] && grep -q "line break" "$W/pw-err.txt" || exit 0
        ui_newpassword() { printf 'a good one'; }
        fix_set_password "$U" > /dev/null
        [[ "$(cat "$W/pw-called")" == "${U}:a good one" ]] && echo "password-line-break-refused"
    )

    # Text quoted in the Markdown report stays text in a viewer that
    # renders it: no HTML, link, image or code span - and a plain [name] is
    # left alone.
    [[ "$(_md '<img src=x> `a` ![i](u) [l](u) [copr:x] [r]: u \<')" == '\<img src=x> \`a\` !\[i]\(u) [l]\(u) [copr:x] [r]\: u \\\<' \
       && "$(_md_fence 'a ``` b')" == '````' && "$(_md_fence 'plain')" == '```' ]] && echo "md-text-not-markup"

    # Run from a folder that an account other than root owns, the tool says
    # so when it asks for administrator rights (not when installing).
    (
        ACTION=audit; SCRIPT_DIR="$UH"; SCRIPT_PATH="$UH/.config"
        _copy_changeable || exit 0
        SCRIPT_DIR=/usr/bin; SCRIPT_PATH=/usr/bin/env
        _copy_changeable && exit 0
        SCRIPT_DIR="$UH"; ACTION=install
        _copy_changeable || echo "copy-changeable-noted"
    )

    # A fix gets its arguments exactly as the check gave them, spaces,
    # bars and line breaks included.
    _t_fix() { [[ $# -eq 3 && "$1" == "%wheel ALL=(ALL) NOPASSWD: ALL" && "$2" == "a|b" && "$3" == $'l1\nl2' ]] && echo "fix-args-kept"; return 1; }
    finding medium "t6 args" "d" "m" _t_fix "%wheel ALL=(ALL) NOPASSWD: ALL" "a|b" $'l1\nl2'
    review_fixes $(( ${#F_SEV[@]} - 1 ))

    # Text from a repository file never runs as a command in a fix.
    apply_change() { printf '%s\n' "$1" > "$W/repo-fix.sh"; return 1; }
    fix_repo_setting "$W/none.repo" "x'; touch $W/pwned; echo '" gpgcheck 1
    bash "$W/repo-fix.sh" > /dev/null 2>&1
    [[ ! -e "$W/pwned" ]] && grep -q 'sed -i' "$W/repo-fix.sh" && echo "repo-section-not-run"
    unset -f apply_change

    # Fix scripts run with a normal umask, and only from the private folder.
    UI_MODE=none
    RUN_TMP=$(mktemp -d "$W/runtmp.XXXXXX")
    _run_change "t6 umask" "touch $W/umask-probe" "" > /dev/null
    [[ "$(stat -c %a "$W/umask-probe")" == 644 ]] && echo "fix-umask-022"
    RUN_TMP=""
    rc=0; _run_change "t6 no tmp" "touch $W/no-private-tmp" "" > /dev/null 2>&1 || rc=$?
    [[ $rc -eq 3 && ! -e "$W/no-private-tmp" ]] && echo "fix-needs-private-tmp"
    # A fix that fails while nobody can answer the rollback question is
    # not rolled back, and its undo step is kept for --undo.
    (
        UI_MODE=none; RUN_ID="t6left"; RUN_TMP=$(mktemp -d "$W/runtmp.XXXXXX"); ui_error() { :; }
        rc=0; _run_change "t6 half" "echo half > $W/t6-half; exit 1" "rm -f $W/t6-half" > /dev/null 2>&1 || rc=$?
        [[ $rc -eq 3 && -e "$W/t6-half" && -f "$STATE_DIR/undo/t6left/01-undo.sh" ]] \
            && grep -qx '# TITLE: t6 half (did not complete)' "$STATE_DIR/undo/t6left/01-undo.sh" && echo "failed-fix-left-keeps-undo"
        # ... one that is rolled back keeps no step to undo (it is marked rolled back) ...
        RUN_ID="t6back"; ui_yesno() { return 0; }
        _run_change "t6 back" "echo half > $W/t6-back; exit 1" "rm -f $W/t6-back" > /dev/null 2>&1
        [[ ! -e "$W/t6-back" && -z "$(compgen -G "$STATE_DIR/undo/t6back/*-undo.sh")" && -f "$STATE_DIR/undo/t6back/01-undo.rolledback" ]] && echo "failed-fix-rolled-back-keeps-nothing"
        # ... and a rolled-back attempt does not later mark the same fix, retried and working, as undone.
        RUN_ID="t6sync"; F_STATE[7]="open"; F_CHECK[7]="c"; F_VERIFY[7]=""; CURRENT_FINDING=7
        _run_change "s" "exit 1" "true" > /dev/null 2>&1; F_STATE[7]=failed
        rrc=0; _run_change "s" "true" "true" > /dev/null 2>&1 || rrc=$?; F_STATE[7]=fixed
        [[ $rrc -eq 0 && -f "$STATE_DIR/undo/t6sync/02-undo.sh" ]] || echo "retry did not apply: $rrc"
        _sync_undone > /dev/null 2>&1
        [[ $rrc -eq 0 && -f "$STATE_DIR/undo/t6sync/02-undo.sh" && "${F_STATE[7]}" == fixed && "${F_VERIFY[7]}" != undone ]] && echo "rolled-back-attempt-not-an-undo" || echo "sync after rollback: ${F_STATE[7]} ${F_VERIFY[7]}"
        CURRENT_FINDING=""
        # A signal while the rollback runs waits until it is marked rolled back.
        RUN_ID="t6rbsig"
        ( trap _on_signal INT TERM HUP; pid=$BASHPID
          _run_change "t6 rbsig" "exit 1" "kill -HUP $pid; sleep 1" ) > "$W/t6-rbsig.out" 2>&1; rc=$?
        # (130 is the tool's own stop; a shell killed by HUP would end with 129.)
        [[ $rc -eq 130 && -f "$STATE_DIR/undo/t6rbsig/01-undo.rolledback" ]] && echo "rollback-interrupted-is-marked" \
            || echo "rbsig rc=$rc $(ls "$STATE_DIR/undo/t6rbsig" | tr '\n' ' ')"
        # ... one whose rollback fails keeps its step, once ...
        RUN_ID="t6bad"
        _run_change "t6 bad" "echo half > $W/t6-bad; exit 1" "exit 4" > /dev/null 2>&1
        [[ -e "$W/t6-bad" && "$(compgen -G "$STATE_DIR/undo/t6bad/*-undo.sh" | wc -l)" -eq 1 ]] && echo "failed-rollback-keeps-undo-once"
        # ... one left as it is by the person says so in a window too ...
        RUN_ID="t6leave"; ui_yesno() { return 1; }; ui_interactive() { return 0; }; ui_msg() { printf '%s\n' "$1" > "$W/t6-leave-msg"; }
        UI_MODE=kde; _ui_dialog() { return 4; }; ui_busy_start() { :; }; ui_busy_stop() { :; }; ui_error() { :; }
        _run_change "t6 leave" "echo half > $W/t6-leave; exit 1" "rm -f $W/t6-leave" > /dev/null 2>&1
        UI_MODE=none
        [[ -f "$STATE_DIR/undo/t6leave/01-undo.sh" ]] && grep -q '"t6 leave" was left as it is. Its undo step was kept' "$W/t6-leave-msg" && echo "failed-fix-left-says-so"
        # ... but on the terminal only the printed line says it (no second copy in a window).
        RUN_ID="t6leavetty"; : > "$W/t6-leave-msg"; UI_MODE="tty"
        _run_change "t6 leave tty" "echo half > $W/t6-leavetty; exit 1" "rm -f $W/t6-leavetty" > /dev/null 2>&1
        UI_MODE=none
        [[ -f "$STATE_DIR/undo/t6leavetty/01-undo.sh" && ! -s "$W/t6-leave-msg" ]] && echo "failed-fix-left-not-twice-on-terminal"
        # ... and one interrupted at the rollback question keeps it too.
        RUN_ID="t6hup"; ui_yesno() { kill -HUP "$BASHPID"; sleep 1; return 1; }; : > "$W/t6-hup-msg"
        ( UI_MODE=kde; ui_msg() { echo left >> "$W/t6-hup-msg"; }; trap _on_signal INT TERM HUP
          _run_change "t6 hup" "echo half > $W/t6-hup; exit 1" "rm -f $W/t6-hup" ) > /dev/null 2>&1; rc=$?
        [[ $rc -eq 130 && -e "$W/t6-hup" && -f "$STATE_DIR/undo/t6hup/01-undo.sh" && ! -s "$W/t6-hup-msg" ]] && echo "failed-fix-interrupted-at-question-keeps-undo" \
            || echo "hup at question: rc=$rc"
    )
    # An action whose window stopped working on the way ends with status 1 and says so.
    (
        ACTION=install; UI_MODE=none; ui_interactive() { [[ "$UI_MODE" != none ]]; }
        ( _action_end ) 2> "$W/action-end.err"; r1=$?
        UI_MODE=kde; ( _action_end ) 2>/dev/null; r2=$?
        [[ "$r1 $r2" == "1 0" ]] && grep -q -- "--install: the window stopped working, so it may not have finished" "$W/action-end.err" && echo "action-end-after-lost-window"
    )
    # On the terminal, Enter is "no" for a question that changes the PC, whatever its default.
    (
        # (An earlier test removed ui_choice3 from this shell: take it again.)
        eval "$(sed -n '/^ui_choice3() {/,/^}/p' "$HERE/../lib/ui.sh")"
        UI_MODE="tty"; _ui_dialog() { return 4; }; _tty_read() { printf '%s\n' "$1" >> "$W/tty-prompts"; printf ''; }
        : > "$W/tty-prompts"
        ui_yesno "q" Remove Cancel y careful 2>/dev/null; r1=$?
        ui_yesno "q" Open Close y 2>/dev/null; r2=$?
        ui_choice3 "q" "q" Apply Skip Stop careful y 2>/dev/null; r3=$?
        [[ "$r1$r2$r3" == 101 ]] && grep -qF 'Remove / Cancel? [y/N]' "$W/tty-prompts" && grep -qF 'Open / Close? [Y/n]' "$W/tty-prompts" \
            && grep -qF '(default n)' "$W/tty-prompts" && echo "tty-enter-is-no-for-a-change" || echo "tty answers $r1$r2$r3: $(tr '\n' '|' < "$W/tty-prompts")"
    )

    # A line break in a path does not turn it into two paths.
    mkdir -p "$UH/t6nl"$'\n'"/etc"
    : > "$UH/t6nl"$'\n'"/etc/passwd"; chmod 4755 "$UH/t6nl"$'\n'"/etc/passwd"
    t6files=(); t6odd=()
    _deep_find t6files t6odd -type f -perm /6000
    [[ " ${t6files[*]} " != *" /etc/passwd "* && "${t6odd[*]}" == *t6nl* ]] && echo "newline-path-not-split"
    rm -rf "$UH/t6nl"$'\n'

    # sudo rules that give a root shell without a password, however written.
    mkdir -p "$W/sudoroot/etc/sudoers.d" "$W/sudoroot/etc/containers"
    printf '%s\n' 'bob ALL=(ALL) NOPASSWD: ALL, !/bin/su  # all but su' \
        'bob ALL=(root) NOPASSWD: /usr/bin/env' \
        'bob ALL=(root) NOPASSWD: /usr/bin/systemctl restart x.service' > "$W/sudoroot/etc/sudoers.d/t6"
    AUDIT_ROOT="$W/sudoroot"; CURRENT_CHECK=check_sudo
    n0=$(printf '%s\n' "${F_TITLE[@]}" | grep -c 'sudo works without a password')
    check_sudo
    n1=$(printf '%s\n' "${F_TITLE[@]}" | grep -c 'sudo works without a password')
    [[ $((n1 - n0)) -eq 2 ]] && echo "sudo-shell-rules-found"

    # A "signed" image whose policy accepts anything is not checked at all.
    printf '%s' '{"default":[{"type":"reject"}],"transports":{"docker":{"ghcr.io/ublue-os":[{"type":"insecureAcceptAnything"}]}}}' \
        > "$W/sudoroot/etc/containers/policy.json"
    p1=$(_image_policy "ostree-image-signed:docker://ghcr.io/ublue-os/bazzite:stable")
    printf '%s' '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"ghcr.io/ublue-os":[{"type":"sigstoreSigned","keyPath":"/k"}]}}}' \
        > "$W/sudoroot/etc/containers/policy.json"
    p2=$(_image_policy "ostree-image-signed:docker://ghcr.io/ublue-os/bazzite:stable")
    [[ "$p1" == "anything" && -z "$p2" ]] && echo "image-policy-read"
    AUDIT_ROOT="$FX"; CURRENT_CHECK=""
) > "$W/t6.out" 2>&1
for m in backup-ok restore-ok symlink-restore-blocked symlink-backup-refused secret-not-copied \
         sudo-rule-kept ssh-not-effective-refused ssh-restored ssh-effective-applied kdialog-fallback-ok mdns-known \
         failed-backup-no-truncate delta-key-ok report-dir-checked timer-copy-compared ssh-T-failure-named \
         kdialog-not-retried nokey-listed ssh-log-by-program pkexec-explained \
         pkexec-explain-continue pkexec-no-desktop-ok verify-still verify-gone score-now-counts-verified \
         verify-reboot-kept undo-sync-ok undo-sync-once undo-body-without-header \
         dialog-answers-not-evaluated firewall-tags-checked firewall-cancel-cancels pending-fix-not-open \
         dependent-recheck-gone gone-labelled undo-brings-back-gone \
         checklist-unoffered-dropped menu-unoffered-dropped radiolist-unoffered-dropped \
         firewall-extras-named protocol-counts-as-open sysctl-source-order undo-all-ok \
         choice3-tty-default dashboard-answer-checked dashboard-input-json dashboard-input-one-line dashboard-actions-offered-only progress-90-until-done busy-no-percent update-verified update-tamper-rejected settings-answer-checked settings-saved-and-loaded wizard-answer-checked wizard-input-json front-end-not-without-kde anticheat-lockdown-with-secure-boot anticheat-pending-and-gaming-only anticheat-fix-and-undo ctr-unsafe-cases-manual ctr-run-kept-old ctr-compose-all-files ctr-compose-manual-forms ctr-rollback-touches-nothing ctr-docker-undo-gated ctr-compose-shared-file flatpak-host-forms flatpak-risk-graded flatpak-low-preset exposed-port-fix-offered service-port-not-closable close-ports-fix-and-undo app-installed app-removed-copy-kept copy-removed-when-unused runtime-only-port-and-bad-zone firewall-extras-blank-lines sysctl-mask-honoured sysctl-conf-in-place \
         avc-count-sources rootless-by-protocol-no-docker-fix pkexec-error-shown \
         undo-ignores-swapped-symlink root-chmod-on-root-path chmod-by-hand-left-out undo-ignores-swapped-folder undo-ignores-swapped-file \
         interrupt-keeps-undo password-line-break-refused md-text-not-markup copy-changeable-noted ctr-other-account-warned \
         fix-args-kept repo-section-not-run fix-umask-022 \
         fix-needs-private-tmp newline-path-not-split sudo-shell-rules-found image-policy-read \
         affects-in-use-first affects-html-escaped affects-tags affects-none-not-in-use fix-in-use-unticked ports-to-features \
         kept-becomes-note kept-not-scored kept-labelled kept-saved kept-untick-counts-again kept-symlink-refused dashboard-keep-action affects-change-not-unticked kept-exact-ports-and-severity anticheat-lockdown-mark-only-when-added detect-honest-steam-and-servers sunshine-admin-port-not-streaming kept-untick-holds-in-session kept-subset-entry-kept kept-worse-reticked kept-overlap-merged kept-overlap-untick-all kept-retick-restores-widest kept-any-level-stays-any ui-item-parts choose-input-json choose-answer-offered-only confirm-answer-checked check-answer-checked check-input-json check-page-fixes-offered-only port-close-risk firewall-list-no-low-only fix-item-maybe-medium confirm-fallback-and-close-skips dialog-answer-checked dialog-button-in-range kept-no-date-no-since \
         yesno-enter-follows-the-default-never-a-change choice3-enter-follows-the-default-never-a-change apply-fallback-enter-is-skip \
         undo-enter-is-cancel-then-keep-it careful-questions-use-the-kdialog-warning root-changing-questions-are-marked \
         kdialog-enter-is-not-yes kdialog-failure-asks-on kdialog-wrapper-failure-is-not-yes kdialog-own-exit-1-is-yes \
         kdialog-own-exits-mapped failed-fix-left-keeps-undo failed-fix-rolled-back-keeps-nothing tty-enter-is-no-for-a-change \
         failed-rollback-keeps-undo-once failed-fix-interrupted-at-question-keeps-undo action-end-after-lost-window \
         failed-fix-left-says-so rolled-back-attempt-not-an-undo rollback-interrupted-is-marked failed-fix-left-not-twice-on-terminal; do
    expect "$W/t6.out" "$m" "$m"
done
# --install and the other actions that change the PC only after a "yes"
# say so and stop when nobody can answer (no terminal, no desktop).
mkdir -p "$W/unatt-state"; chmod 700 "$W/unatt-state"
unatt_ok=1
for a in --install --install-timer --uninstall --remove-timer --undo --update; do
    out=$(env -u DISPLAY -u WAYLAND_DISPLAY AUDIT_STATE_DIR="$W/unatt-state" setsid bash "$TOOL" "$a" --no-gui < /dev/null 2>&1); rc=$?
    [[ $rc -eq 1 && "$out" == *"${a} asks before it changes anything"*"nothing was changed."* ]] || { unatt_ok=0; echo "  $a: rc=$rc ${out: -160}"; }
done
[[ $unatt_ok -eq 1 && ! -e "/usr/local/share/applications/bazzite-security-check.desktop" ]] && ok "unattended-changes-refused" || bad "unattended-changes-refused"

# One window for the whole run: ui_app talks to one long-lived front end
# over two pipes. A stand-in that speaks the same protocol (no Qt here)
# shows that it is one process for every page, that it works from $(...),
# and that a front end that fails or goes away means "use kdialog" (3), not
# a hang and not "cancelled".
cat > "$W/fake-front.py" <<'PYEOF'
import json, os, signal, subprocess, sys, time
log = open(sys.argv[1], "a")
def note(*a):
    print(*a, file=log, flush=True)
def send(rid, status, answer):
    sys.stdout.write('{"id":%s,"status":%d,"answer":%s}\n' % (json.dumps(rid), status, json.dumps(answer)))
    sys.stdout.flush()
if sys.argv[2] != "serve":
    note("oneshot", sys.argv[2])
    print(json.dumps({"oneshot": sys.argv[2]}))
    sys.exit(0)
n = 0
note("pid", os.getpid())
for line in sys.stdin:
    m = json.loads(line)
    if m.get("hang") or m.get("data", {}).get("hang"):
        # Stuck: deaf to "quit", to the end of its input and to SIGTERM.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        note("hanging")
        while True:
            time.sleep(1000)
    if m.get("deaf"):
        # Deaf to "quit" and to the end of its input, but not to SIGTERM.
        note("deaf")
        while True:
            time.sleep(1000)
    if m.get("freeze"):
        # Stopped (as by SIGSTOP from outside): it reads nothing any more.
        note("frozen")
        os.kill(os.getpid(), signal.SIGSTOP)
    if m.get("quit"):
        note("quit")
        break
    if m.get("leave"):
        sys.exit(7)             # it ends while nobody waits for an answer
    if "mode" not in m:
        note(json.dumps(m, sort_keys=True))
        continue
    n += 1
    d = m["data"]
    if d.get("die"):
        sys.exit(7)
    if d.get("chatty"):
        # It ends, and leaves a program behind that holds its stderr and
        # keeps writing to it.
        p = subprocess.Popen(["bash", "-c", "while echo chatter >&2; do sleep 0.2; done"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        note("child", p.pid)
        os._exit(0)
    if d.get("holder"):
        # It ends, and leaves a program behind that holds its answer pipe.
        p = subprocess.Popen(["sleep", "300"], stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        note("child", p.pid)
        os._exit(0)
    if d.get("fds"):
        # What this process has open: {descriptor: what it is}.
        fds = {}
        for fd in os.listdir("/proc/self/fd"):
            try:
                fds[fd] = os.readlink("/proc/self/fd/" + fd)
            except OSError:
                pass
        send(m["id"], 0, fds)
        continue
    try:
        if d.get("stderr"):
            sys.stderr.write(d["stderr"])
        for _ in range(d.get("flood", 0) // 100):
            sys.stderr.write("f" * 99 + "\n")
        sys.stderr.flush()
    except OSError:
        pass                    # the other side stopped reading
    if d.get("long"):
        sys.stdout.write("x" * d["long"])
        sys.stdout.flush()
        continue
    if d.get("line"):
        # A line whose first d["line"] bytes have the form of an answer:
        # "fill" in the answer, then d["more"] bytes, then the line end.
        head = '{"id":%s,"status":0,"answer":"' % json.dumps(m["id"])
        fill = d.get("fill", "x").encode()
        body = fill * ((d["line"] - len(head) - 2) // len(fill))
        body += b"x" * (d["line"] - len(head) - 2 - len(body))
        sys.stdout.buffer.write(head.encode() + body + b'"}' + b"y" * d.get("more", 0) + b"\n")
        sys.stdout.flush()
        continue
    if d.get("noid"):
        # "That request could not be read", and an answer to it all the same.
        send("", 3, None)
    if d.get("stale"):
        send("an-earlier-request", 0, {"wrong": True})
    if d.get("garbage"):
        sys.stdout.write("not an answer\n")
        sys.stdout.flush()
    elif d.get("fail"):
        send(m["id"], 3, None)
    elif d.get("cancel"):
        send(m["id"], 1, None)
    elif "status" in d:
        send(m["id"], d["status"], {"status": d["status"]})
    else:
        send(m["id"], 0, {"mode": m["mode"], "say": d.get("say"), "n": n})
PYEOF
(
    # shellcheck disable=SC1090
    source "$TOOL"
    RUN_LOG="$W/front-run.log"; : > "$RUN_LOG"
    FL="$W/front.log"
    _ui_app_cmd() { python3 -I "$W/fake-front.py" "$FL" "$@"; }
    ui_theme_prepare() { :; }
    new_run() { ui_front_stop; RUN_TMP=$(mktemp -d "$W/front-rt.XXXXXX"); UI_MODE=kde; _QML_OK=yes; : > "$FL"; }

    new_run; ui_front_start
    # (Its two pipes have no name any more; what is in the private folder
    # is the note of its processes.)
    [[ -n "$_UI_FRONT_W" && "$(ls -A "$RUN_TMP")" == ui-front-seen ]] && echo "front-started"
    a=$(ui_app wizard '{"say":"one"}'); rc=$?
    [[ $rc -eq 0 && "$a" == '{"mode": "wizard", "say": "one", "n": 1}' ]] && echo "front-answer-in-subshell"
    a=$(ui_app dialog '{"say":"two } \"x\""}'); rc=$?
    ui_app check '{"say":"three"}' > "$W/front-a3"
    [[ $rc -eq 0 && "$a" == *'"n": 2}' && "$(cat "$W/front-a3")" == *'"n": 3}' ]] && ! grep -q oneshot "$FL" && echo "front-one-process"
    a=$(ui_app confirm '{"cancel":true}'); rc=$?
    [[ $rc -eq 1 && -z "$a" ]] && echo "front-cancelled-is-1"
    a=$(ui_app confirm '{"stale":true,"say":"s"}'); rc=$?
    [[ $rc -eq 0 && "$a" == *'"say": "s"'* ]] && echo "front-stale-answer-skipped"
    a=$(ui_app dashboard "$(python3 -I -c 'import json; print(json.dumps({"say": "x" * 60000}))')"); rc=$?
    [[ $rc -eq 0 && ${#a} -gt 60000 ]] && echo "front-large-answer"
    # A fix being applied: the window's spinner. The scan: its progress window.
    ui_busy_start 'Applying: "Firewall"'; ui_busy_stop
    ui_progress_start "Checking your PC…" 4; ui_progress_set 2 "Firewall"; ui_progress_set 4 "Malware" slow; ui_progress_stop
    ui_theme_prepare() { echo "prepared for ${UI_THEME}" >> "$W/front-theme-prepared"; }
    UI_THEME=light; ui_theme_changed; UI_THEME=system
    ui_theme_prepare() { :; }
    [[ "$(cat "$W/front-theme-prepared" 2>/dev/null)" == "prepared for light" ]] && echo "theme-change-refreshes-the-kdialog-theme"
    a=$(ui_app wizard '{"say":"after"}')
    [[ "$a" == *'"n": 7}' ]] && grep -qxF '{"busy": "Applying: \"Firewall\""}' "$FL" && grep -qxF '{"busy": ""}' "$FL" \
        && [[ -z "$_PROGRESS_FD" && -z "$_PROGRESS_REF" ]] && echo "front-busy-in-window"
    [[ "$(grep -c '"progress"' "$FL")" -eq 6 ]] && grep -qF '"line": "22\t0\tFirewall\t"' "$FL" && grep -qF '"line": "90\t1\tMalware\t' "$FL" \
        && grep -qF '"line": "100\t0\tDone\t"' "$FL" && grep -qxF '{"progress": "stop"}' "$FL" && echo "front-progress-lines"
    grep -qxF '{"theme": "light"}' "$FL" && echo "front-theme-sent"

    # It dies while a page is asked from $(...): 3 there, and the main
    # shell learns it from the file.
    a=$(ui_app wizard '{"die":true}'); rc=$?
    [[ $rc -eq 3 && -z "$a" && "$_QML_OK" == yes ]] && ! _qml_ok && [[ "$_QML_OK" == no && -z "$_UI_FRONT_W" ]] && echo "front-died-falls-back"
    ui_app wizard '{}' > /dev/null; [[ $? -eq 4 ]] && echo "front-not-used-again"
    # With the front end gone, a question is asked with kdialog (whose
    # Enter, exit 0, is the "No" answer of a question that defaults to No).
    _as_desktop_user() { printf '%s\n' "$@" >> "$W/front-kd"; echo "bsa-kdialog-exit:0"; return 0; }
    ! ui_yesno "Continue?" && [[ "$(grep -A1 -x -- --yes-label "$W/front-kd" | tail -n 1)" == No && "$(grep -A1 -x -- --no-label "$W/front-kd" | tail -n 1)" == Yes ]] \
        && [[ ! -e "$RUN_TMP/kdialog-failed" && "$UI_MODE" == kde ]] && echo "front-gone-kdialog-asks"

    new_run; ui_front_start
    a=$(ui_app wizard '{"fail":true}'); rc=$?
    for _ in $(seq 1 100); do grep -qx quit "$FL" && break; sleep 0.1; done
    [[ $rc -eq 3 ]] && grep -qx quit "$FL" && ! _qml_ok && echo "front-page-failure-is-3"
    # A status that is none of "answered", "cancelled" and "failed" is not
    # an answer either.
    new_run; ui_front_start
    a=$(ui_app wizard '{"status":2}'); rc=$?
    [[ $rc -eq 3 && -z "$a" ]] && ! _qml_ok && echo "front-unknown-status-is-3"
    # Where the front end cannot run it is not started.
    new_run; _QML_OK=no; ui_front_start
    [[ -z "$_UI_FRONT_W" && -z "$(ls -A "$RUN_TMP")" ]] && ! grep -q '^pid ' "$FL" && echo "front-not-started-where-it-cannot-run"
    new_run; ui_front_start
    a=$(ui_app wizard '{"garbage":true}'); rc=$?
    [[ $rc -eq 3 && -z "$a" ]] && echo "front-bad-answer-is-3"
    new_run
    _ui_app_cmd() { return 3; }
    ui_front_start
    a=$(ui_app wizard '{"say":"x"}'); rc=$?
    [[ ( $rc -eq 3 || $rc -eq 4 ) && -z "$a" ]] && ! _qml_ok && echo "front-cannot-start"
    # A page in a window of its own (the front end was not started): every
    # end but "answered" and "cancelled" is 3, and the shell that asked in
    # $(...) knows afterwards that the front end is not to be used.
    new_run
    _ui_app_cmd() { echo '{"not":"an answer"}'; return 2; }
    a=$(ui_app settings '{}'); rc=$?
    [[ $rc -eq 3 && -z "$a" && "$_QML_OK" == yes ]] && ! _qml_ok && echo "front-one-shot-failure-is-3-and-remembered"
    # Its answer has the limit of the long-lived one's, and no more of it
    # is read: 300 MB of "answer" under a memory limit the shell could not
    # hold them in.
    new_run
    _ui_app_cmd() { head -c $(( _UI_FRONT_LINE_MAX - 1 )) /dev/zero | tr '\0' x; echo; }
    a=$(ui_app settings '{}'); rc=$?
    [[ $rc -eq 0 && ${#a} -eq $(( _UI_FRONT_LINE_MAX - 1 )) ]] && _qml_ok && echo "front-one-shot-longest-answer"
    _ui_app_cmd() { head -c 300000000 /dev/zero 2>/dev/null | tr '\0' x 2>/dev/null; }
    a=$(ulimit -v 200000; ui_app settings '{}'); rc=$?
    [[ $rc -eq 3 && -z "$a" ]] && ! _qml_ok && echo "front-one-shot-answer-capped"
    # kdialog's answer: read up to the same limit, its status kept.
    (
        RUN_TMP=""; UI_MODE=kde
        set +o pipefail     # the status must not depend on the caller's options
        _as_desktop_user() { head -c 300000000 /dev/zero 2>/dev/null | tr '\0' x 2>/dev/null; }
        n=$(_kd --inputbox x | wc -c)
        _as_desktop_user() { echo picked; return 1; }
        a=$(_kd --menu x); rc=$?
        [[ "$n" -eq "$_UI_FRONT_LINE_MAX" && $rc -eq 1 && "$a" == picked ]] && echo "kdialog-answer-capped-status-kept"
    )
    _ui_app_cmd() { python3 -I "$W/fake-front.py" "$FL" "$@"; }

    # A subshell does not start the front end: it would end with the subshell.
    new_run
    ( ui_front_start; [[ -z "$_UI_FRONT_W" ]] ) && [[ -z "$(ls -A "$RUN_TMP")" ]] && echo "front-not-started-in-a-subshell"
    # A request is one line, whatever is in its input.
    ui_front_start
    a=$(ui_app wizard $'{"say":\n"two lines"}'); rc=$?
    [[ $rc -eq 0 && "$a" == *'"say": "two lines"'* ]] && echo "front-request-is-one-line"
    # "That request could not be read" (an answer without an id) means the
    # front end failed, even if an answer follows.
    a=$(ui_app wizard '{"noid":true,"say":"late"}'); rc=$?
    [[ $rc -eq 3 && -z "$a" ]] && ! _qml_ok && echo "front-answer-without-id-is-3"
    # The longest answer line: one byte less than the limit. A longer line
    # is refused even when what is read of it has the form of an answer,
    # and the limit counts bytes whatever the language settings are.
    new_run; ui_front_start
    a=$(ui_app wizard "{\"line\":$(( _UI_FRONT_LINE_MAX - 1 ))}"); rc=$?
    [[ $rc -eq 0 && "$a" == '"xxx'*'x"' ]] && _ui_front_up && echo "front-longest-answer"
    a=$(ui_app wizard "{\"line\":${_UI_FRONT_LINE_MAX},\"more\":50}"); rc=$?
    [[ $rc -eq 3 && -z "$a" ]] && ! _qml_ok && echo "front-cut-answer-is-3"
    if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        # A whole line of exactly the limit in bytes, and half as many characters.
        new_run; ui_front_start
        a=$(LC_ALL=C.UTF-8; ui_app wizard "{\"line\":${_UI_FRONT_LINE_MAX},\"fill\":\"é\"}"); rc=$?
        [[ $rc -eq 3 && -z "$a" ]] && echo "front-answer-limit-counts-bytes"
    else
        echo "front-answer-limit-counts-bytes (no UTF-8 locale here: not tried)"
    fi

    # The front end ends between two requests, when nobody waits for an
    # answer: the helper's file says so. From then on nothing is sent to
    # it, and the scan's progress is a kdialog bar.
    new_run; ui_front_start
    a=$(ui_app wizard '{"say":"x"}')
    _ui_front_send '{"leave":true}'
    for _ in $(seq 1 50); do [[ -e "$RUN_TMP/ui-front-gone" ]] && break; sleep 0.1; done
    [[ -e "$RUN_TMP/ui-front-gone" && -n "$_UI_FRONT_W" ]] && _proc_stat "$_UI_FRONT_PID" && echo "front-gone-between-requests-is-noted"
    ! _ui_front_up && ! _ui_front_send '{"busy":"x"}' && echo "front-gone-nothing-sent"
    ui_progress_start "Checking" 3
    [[ "$_PROGRESS_BACKEND" == kdialog && -z "$_UI_FRONT_W" ]] && echo "front-gone-progress-is-kdialog"
    ui_progress_stop

    # A write to a pipe that nobody reads fails: it does not end the shell
    # (SIGPIPE), which would skip the EXIT trap. Afterwards the signal is
    # as it was before, for this shell and for the programs started from
    # here: at its default, unless it was ignored when the suite started.
    sigign() { bash -c 'awk "/^SigIgn:/ { print \$2 }" "/proc/$$/status"'; }
    ign0=$(sigign)
    mkfifo "$W/dead-pipe"
    cat "$W/dead-pipe" > /dev/null & rdr=$!
    exec {dw}> "$W/dead-pipe"
    kill "$rdr"; wait "$rdr" 2>/dev/null
    ( _pipe_write "$dw" "x"; echo "pipe-write-status-$?" ); echo "pipe-write-shell-status-$?"
    ( _pipe_write "$dw" "x"; echo x >&"$dw"; echo "pipe-write-shell-went-on" ) > "$W/pipe-after" 2>/dev/null; prc=$?
    if (( SIGPIPE_IGNORED )); then
        [[ $prc -eq 0 ]] && grep -qx pipe-write-shell-went-on "$W/pipe-after" && pipe_after=same
    else
        [[ $prc -eq 141 && ! -s "$W/pipe-after" ]] && pipe_after=same
    fi
    [[ "${pipe_after:-}" == same && -n "$ign0" && "$(sigign)" == "$ign0" ]] && echo "pipe-write-leaves-sigpipe-alone"
    exec {dw}>&-
    # The same write to a pipe that is full, with a reader that takes
    # nothing out of it: given up after a moment, and nothing left behind.
    mkfifo "$W/full-pipe"
    exec {dr}<> "$W/full-pipe" {dw}> "$W/full-pipe"
    timeout 2 head -c 200000 /dev/zero >&"$dw"; filled=$?
    # (In a shell of its own, which is ended should it wait for ever.
    # Processes are counted without the ones that have ended and wait to
    # be collected, which "pgrep" and "kill -0" still find.)
    procs_running() { local p n=0; for p in $(pgrep -x "$1"); do _proc_stat "$p" && n=$((n + 1)); done; echo "$n"; }
    nb=$(procs_running bash); rm -f "$W/soon-status"
    ( _pipe_write_soon "$dw" '{"quit":true}'; echo "$?" > "$W/soon-status" ) & soon=$!
    for _ in $(seq 1 300); do [[ -s "$W/soon-status" ]] && break; sleep 0.1; done
    [[ -s "$W/soon-status" ]] || pkill -KILL -P "$soon"
    kill -KILL "$soon" 2>/dev/null; wait "$soon" 2>/dev/null
    for _ in $(seq 1 50); do [[ "$(procs_running bash)" -le "$nb" ]] && break; sleep 0.1; done
    [[ $filled -eq 124 && "$(cat "$W/soon-status" 2>/dev/null)" == 1 && "$(procs_running bash)" -le "$nb" ]] && echo "pipe-write-soon-gives-up-on-a-full-pipe"
    exec {dw}>&- {dr}<&-
    # ... and to a pipe that is read: the line arrives.
    mkfifo "$W/read-pipe"
    cat "$W/read-pipe" > "$W/read-pipe.out" & rdr=$!
    exec {dw}> "$W/read-pipe"
    _pipe_write_soon "$dw" "a line"; src=$?
    exec {dw}>&-; wait "$rdr"
    [[ $src -eq 0 && "$(cat "$W/read-pipe.out")" == "a line" ]] && echo "pipe-write-soon-writes"

    # The front end is a program of a less trusted account. It never gets
    # the run log itself: its stderr is a pipe, which this side copies into
    # the log line by line, cut to size, cleaned and marked "ui: ".
    # Nor the run's lock, which this shell holds while it starts it.
    _UI_LOG_MAX=20000
    exec {lk}> "$W/front.lock"; _RUN_LOCK_FD=$lk
    new_run; : > "$RUN_LOG"; ui_front_start
    a=$(ui_app wizard '{"fds":true}'); rc=$?
    [[ $rc -eq 0 && "$a" == *'"2": "pipe:'* && "$a" == *"/front.log"* && "$a" != *"front-run.log"* ]] && echo "front-no-log-descriptor"
    [[ $rc -eq 0 && -e "/proc/self/fd/$lk" && "$a" != *"front.lock"* ]] && echo "front-no-lock-descriptor"
    # It has its three standard descriptors and nothing else of this
    # tool's (what is left over is the stand-in's own: its notes, and the
    # folder it lists).
    python3 -I -c 'import json, sys
d = json.loads(sys.argv[1])
own = [k for k, v in d.items() if "front.log" in v or v.endswith("/fd")]
sys.exit(0 if sorted(set(d) - set(own)) == ["0", "1", "2"] else 1)' "$a" && echo "front-three-descriptors-only"
    # Of the window's two pipes, only the helper and the front end hold a
    # copy: not the log reader (and its dd), which lives longer than the
    # front end when something else still writes to its stderr.
    fpid=$(awk '$1 == "pid" { print $2 }' "$FL"); mapfile -t tree < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START")
    held=0
    for p in "${tree[@]}"; do
        pid=${p%% *}
        [[ "$pid" == "$_UI_FRONT_PID" || "$pid" == "$fpid" ]] && continue
        for l in "/proc/$pid/fd"/*; do
            [[ "$(readlink "$l" 2>/dev/null)" == *"/ui-front/re"[qp]* ]] && held=1
        done
    done
    [[ -n "$fpid" && ${#tree[@]} -ge 4 && $held -eq 0 ]] && echo "front-log-reader-holds-no-window-pipe"
    _RUN_LOCK_FD=""; exec {lk}>&-
    a=$(ui_app wizard "$(python3 -I -c 'import json; print(json.dumps({"say": "e", "stderr": "plain line\n12:00:00 [OK] forged\x1b[31m\ttab\r\n\x00caf\u00e9\n" + "y" * 4500 + "\n"}))')")
    for _ in $(seq 1 100); do [[ "$(grep -c 'ui: yyy' "$RUN_LOG")" -eq 3 ]] && break; sleep 0.1; done
    [[ "$a" == *'"say": "e"'* ]] && grep -qE '^[0-9:]{8} ui: plain line$' "$RUN_LOG" \
        && grep -qE '^[0-9:]{8} ui: 12:00:00 \[OK\] forged\[31m tab$' "$RUN_LOG" && grep -qE '^[0-9:]{8} ui: caf\?\?$' "$RUN_LOG" \
        && ! grep -qvE '^[0-9:]{8} ui: ' "$RUN_LOG" && ! LC_ALL=C grep -q '[^ -~]' "$RUN_LOG" && echo "front-stderr-marked-and-cleaned"
    [[ "$(grep -c 'ui: yyy' "$RUN_LOG")" -eq 3 && "$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$RUN_LOG")" -eq 2013 ]] \
        && echo "front-stderr-line-capped"
    a=$(ui_app wizard '{"say":"f","flood":300000}'); rc=$?
    for _ in $(seq 1 100); do grep -q 'the rest is not recorded' "$RUN_LOG" && break; sleep 0.1; done
    sleep 0.3
    b=$(ui_app wizard '{"say":"g","stderr":"after the cap\n"}')
    [[ $rc -eq 0 && "$a" == *'"say": "f"'* && "$b" == *'"say": "g"'* && "$(stat -c %s "$RUN_LOG")" -lt 30000 ]] \
        && grep -q 'ui: (the window wrote more than 20000 bytes' "$RUN_LOG" && ! grep -q 'after the cap' "$RUN_LOG" && echo "front-stderr-total-capped"

    # NUL bytes are counted too ("read" drops them unseen): a front end
    # that writes nothing else is cut off at the same limit, and the reader
    # ends instead of reading for the rest of the run.
    : > "$RUN_LOG"; t0=$SECONDS
    timeout 30 cat /dev/zero | _ui_log_reader "$W/no-such-stop-file"; st=("${PIPESTATUS[@]}")
    # (The writer ends when the reader has closed the pipe, long before
    # its 60 seconds are over; how it ends: see PIPE_END.)
    timeout 60 cat /dev/zero 2>/dev/null | _ui_log_reader "$W/no-such-stop-file"; st=("${PIPESTATUS[@]}")
    [[ ${st[0]} -eq $PIPE_END && ${st[1]} -eq 0 && $(( SECONDS - t0 )) -lt 30 && ! -s "$RUN_LOG" ]] && echo "front-stderr-nul-bytes-capped"
    t0=$SECONDS
    timeout 60 bash -c 'while :; do head -c 5000 /dev/zero || exit; echo || exit; done' 2>/dev/null | _ui_log_reader "$W/no-such-stop-file"; st=("${PIPESTATUS[@]}")
    [[ ${st[0]} -eq $PIPE_END && $(( SECONDS - t0 )) -lt 30 && "$(stat -c %s "$RUN_LOG")" -lt 1000 ]] && echo "front-stderr-nul-lines-capped"
    # What it logs is not held back, and a program that keeps the pipe
    # open does not keep the reader (or its dd) once the stop file is there.
    dd_running() { procs_running dd; }
    # The writer goes on (to the stop file, then to holding the pipe) only
    # when this side has seen its first line in the log.
    : > "$RUN_LOG"; rm -f "$W/reader-stop" "$W/reader-go"; ndd=$(dd_running)
    ( echo "first line"; until [[ -e "$W/reader-go" ]]; do sleep 0.1; done; : > "$W/reader-stop"; exec sleep 21 ) \
        {_UI_FRONT_W}>&- {_UI_FRONT_R}<&- | _ui_log_reader "$W/reader-stop" &
    rd=$!
    for _ in $(seq 1 200); do grep -q 'ui: first line' "$RUN_LOG" && break; sleep 0.1; done
    grep -q 'ui: first line' "$RUN_LOG" && [[ ! -e "$W/reader-stop" ]] && echo "front-stderr-logged-at-once"
    : > "$W/reader-go"
    for _ in $(seq 1 200); do _proc_stat "$rd" || break; sleep 0.1; done
    for _ in $(seq 1 50); do [[ "$(dd_running)" == "$ndd" ]] && break; sleep 0.1; done
    [[ -e "$W/reader-stop" ]] && ! _proc_stat "$rd" && [[ "$(dd_running)" == "$ndd" ]] && echo "front-stderr-reader-ends-on-stop-file"
    pkill -x -f 'sleep 21'
    # Nor does a program that keeps writing keep it: the stop file is seen
    # while the lines keep coming, too.
    : > "$RUN_LOG"; rm -f "$W/chatty-stop"
    ( while echo chatter; do sleep 0.2; done ) {_UI_FRONT_W}>&- {_UI_FRONT_R}<&- 2>/dev/null | _ui_log_reader "$W/chatty-stop" &
    rd=$!
    for _ in $(seq 1 200); do grep -q 'ui: chatter' "$RUN_LOG" && break; sleep 0.1; done
    : > "$W/chatty-stop"
    for _ in $(seq 1 200); do _proc_stat "$rd" || break; sleep 0.1; done
    for _ in $(seq 1 50); do [[ "$(dd_running)" == "$ndd" ]] && break; sleep 0.1; done
    grep -q 'ui: chatter' "$RUN_LOG" && ! _proc_stat "$rd" && [[ "$(dd_running)" == "$ndd" ]] && echo "front-stderr-reader-ends-while-lines-keep-coming"
    builtin kill "$rd" 2>/dev/null; wait 2>/dev/null

    # A program started through _no_tty (a fix, another account's program)
    # does not get the window's two pipes; any other child does. Its exit
    # status comes through.
    probe='for f in "$@"; do [[ -e /proc/self/fd/$f ]] && printf "has-%s " "$f"; done; exit 7'
    plain=$(bash -c "$probe" _ "$_UI_FRONT_W" "$_UI_FRONT_R"); prc=$?
    quiet=$(_no_tty bash -c "$probe" _ "$_UI_FRONT_W" "$_UI_FRONT_R"); qrc=$?
    [[ -n "$_UI_FRONT_W" && "$plain" == "has-${_UI_FRONT_W} has-${_UI_FRONT_R} " && -z "$quiet" && $prc -eq 7 && $qrc -eq 7 ]] \
        && echo "no-tty-drops-window-pipes"
    # The same for a program started "as another account" that is this one.
    same=$(_as_user root bash -c "$probe" _ "$_UI_FRONT_W" "$_UI_FRONT_R"); src=$?
    [[ -n "$_UI_FRONT_W" && -z "$same" && $src -eq 7 ]] && echo "same-account-drops-window-pipes"

    # ui_front_stop ends the front end's processes (the helper subshell,
    # the front end, the log reader) and nothing else - also a front end
    # that is stuck.
    # Every signal this shell sends from here on is noted, with what the
    # target was at that moment: its start time and its account.
    kill() {
        local t="${!#}" sig="${1#-}"
        [[ "$1" == -s ]] && sig=$2
        if _proc_stat "$t"; then echo "$t $_PS_START $(stat -c %u "/proc/$t" 2>/dev/null) $sig"; else echo "$t gone - $sig"; fi >> "$W/front-kills"
        builtin kill "$@"
    }
    # kills_in_tree — every signal noted went to a process of the list.
    kills_in_tree() {
        local kp ks _ p
        while read -r kp ks _; do
            for p in "${tree[@]}"; do [[ "$p" == "$kp $ks "* ]] && continue 2; done
            return 1
        done < "$W/front-kills"
        return 0
    }
    fpid=$(awk '$1 == "pid" { print $2 }' "$FL"); mapfile -t tree < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START")
    builtin kill -0 "$_UI_FRONT_PID" && [[ -n "$_UI_FRONT_START" && "${tree[0]}" == "$_UI_FRONT_PID $_UI_FRONT_START own" ]] \
        && [[ -z "$(_proc_tree "$_UI_FRONT_PID" "1$_UI_FRONT_START")" ]] && echo "front-helper-named-by-id-and-start-time"
    sleep 300 {_UI_FRONT_W}>&- {_UI_FRONT_R}<&- & other=$!
    : > "$W/front-kills"
    ui_front_stop
    # A front end that leaves when told is not signalled at all.
    [[ ! -s "$W/front-kills" && -z "$_UI_FRONT_PID" && -z "$_UI_FRONT_START" ]] && echo "front-stop-sends-no-signal"
    # An id that another process has taken over (the start time differs) is
    # never signalled, whatever the list says about it.
    _proc_stat "$other"; ostart=$_PS_START
    _kill_same KILL "$other" "1$ostart"
    _ui_front_signal KILL "$other 1$ostart own" "$other 1$ostart user" "$other $ostart other"
    _ui_front_reap "$other 1$ostart own"
    builtin kill -0 "$other" 2>/dev/null && [[ ! -s "$W/front-kills" ]] && echo "front-stop-spares-a-reused-id"
    [[ -n "$fpid" && ${#tree[@]} -ge 2 && " ${tree[*]%% *} " == *" $fpid "* && -z "$(_procs_left "${tree[@]}")" ]] \
        && ! kill -0 "$fpid" 2>/dev/null && kill -0 "$other" 2>/dev/null && echo "front-processes-gone-after-stop"
    # A child of this shell that still holds the two pipes keeps the helper
    # waiting: only the helper is signalled then, and without a long wait.
    # (The wait is counted in looks, 0.02 seconds apart, not in seconds: a
    # busy machine makes each look slower, not more of them. The full wait
    # for a front end that does not leave is 100 looks.)
    new_run; ui_front_start
    a=$(ui_app wizard '{"say":"x"}')
    mapfile -t tree < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START"); hpid=$_UI_FRONT_PID
    command sleep 300 & holder=$!
    : > "$W/front-kills"; looks=0
    sleep() { looks=$(( looks + 1 )); command sleep "$@"; }
    ui_front_stop
    unset -f sleep
    [[ "$(cut -d' ' -f1 "$W/front-kills" | sort -u)" == "$hpid" && $looks -ge 10 && $looks -lt 60 && -z "$(_procs_left "${tree[@]}")" ]] \
        && kills_in_tree && builtin kill -0 "$holder" 2>/dev/null && echo "front-stop-with-a-pipe-holder"
    builtin kill "$holder" 2>/dev/null
    new_run; ui_front_start; _ui_front_send '{"hang":true}'
    for _ in $(seq 1 100); do grep -qx hanging "$FL" && break; sleep 0.1; done
    fpid=$(awk '$1 == "pid" { print $2 }' "$FL"); mapfile -t tree < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START")
    : > "$W/front-kills"; t0=$SECONDS
    ui_front_stop
    grep -qx hanging "$FL" && [[ -n "$fpid" && ${#tree[@]} -ge 3 && -z "$(_procs_left "${tree[@]}")" ]] && ! _proc_stat "$fpid" \
        && builtin kill -0 "$other" 2>/dev/null && [[ $(( SECONDS - t0 )) -le 20 ]] && echo "front-stuck-process-ended"
    [[ -s "$W/front-kills" ]] && kills_in_tree && echo "front-stuck-signals-only-its-processes"
    # It is asked to end (TERM) before it is ended (KILL) ...
    [[ "$(awk -v p="$fpid" '$1 == p { print $4 }' "$W/front-kills" | uniq | tr '\n' ' ')" == "TERM KILL " ]] && echo "front-stuck-term-before-kill"
    # ... and one that ends when asked is not sent KILL at all.
    new_run; ui_front_start; _ui_front_send '{"deaf":true}'
    for _ in $(seq 1 100); do grep -qx deaf "$FL" && break; sleep 0.1; done
    fpid=$(awk '$1 == "pid" { print $2 }' "$FL"); mapfile -t tree < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START")
    : > "$W/front-kills"
    ui_front_stop
    grep -qx deaf "$FL" && [[ -n "$fpid" ]] && ! _proc_stat "$fpid" && [[ -z "$(_procs_left "${tree[@]}")" ]] && kills_in_tree \
        && grep -q "^$fpid .* TERM\$" "$W/front-kills" && ! grep -q ' KILL$' "$W/front-kills" && echo "front-that-ends-on-term-gets-no-kill"
    # The same when the helper has ended before it (ended from outside):
    # there is no process to find the front end from, so what was seen
    # below the helper while it lived is what is ended.
    new_run; ui_front_start; _ui_front_send '{"hang":true}'
    for _ in $(seq 1 100); do grep -qx hanging "$FL" && break; sleep 0.1; done
    fpid=$(awk '$1 == "pid" { print $2 }' "$FL"); _ui_front_up; mapfile -t tree < <(_proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START"); hpid=$_UI_FRONT_PID
    builtin kill -KILL "$hpid"
    for _ in $(seq 1 100); do _proc_stat "$hpid" || break; sleep 0.1; done
    orphan=no; ! _proc_stat "$hpid" && _proc_stat "$fpid" && [[ " $(_ui_front_seen | tr '\n' ' ')" == *" $fpid $_PS_START own "* ]] && orphan=yes
    : > "$W/front-kills"; t0=$SECONDS
    ui_front_stop
    [[ "$orphan" == yes && -s "$W/front-kills" && $(( SECONDS - t0 )) -le 20 ]] && ! _proc_stat "$fpid" && kills_in_tree \
        && builtin kill -0 "$other" 2>/dev/null && echo "front-stuck-without-its-helper-ended"
    builtin kill -KILL "$fpid" 2>/dev/null
    builtin kill "$other" 2>/dev/null
    unset -f kill
    _UI_LOG_MAX=262144

    # An answer that never ends (no line end within the limit) is a failed
    # front end, not memory without end.
    new_run; ui_front_start
    a=$(ui_app wizard '{"long":1200000}'); rc=$?
    [[ $rc -eq 3 && -z "$a" ]] && ! _qml_ok && echo "front-endless-answer-is-3"

    # The tool's exit: quit is sent, nothing is left running.
    new_run; ui_front_start
    a=$(ui_app wizard '{"say":"x"}'); pid="$_UI_FRONT_PID"
    _cleanup
    for _ in $(seq 1 100); do grep -qx quit "$FL" && ! kill -0 "$pid" 2>/dev/null && break; sleep 0.1; done
    grep -qx quit "$FL" && ! kill -0 "$pid" 2>/dev/null && [[ -z "$_UI_FRONT_W" && ! -d "$RUN_TMP" ]] && echo "front-stopped-on-exit"

    # Not running (no private folder for the pipes): one page, one window.
    UI_MODE=kde; _QML_OK=yes; RUN_TMP=""; : > "$FL"
    ui_app wizard '{"say":"x"}' > "$W/front-a9"; rc=$?
    [[ $rc -eq 0 && "$(cat "$W/front-a9")" == '{"oneshot": "wizard"}' && -z "$_UI_FRONT_W" ]] && echo "front-one-shot-without-folder"
    # ... and the scan's progress in a window of its own ("app.py progress").
    : > "$FL"
    ui_progress_start "Checking" 3; pb=$_PROGRESS_BACKEND; pfd=$_PROGRESS_FD
    ui_progress_set 1 "Firewall"; ui_progress_stop
    for _ in $(seq 1 100); do grep -qx 'oneshot progress' "$FL" && break; sleep 0.1; done
    [[ "$pb" == window && -n "$pfd" && -z "$_PROGRESS_FD" && -z "$_UI_FRONT_W" ]] && grep -qx 'oneshot progress' "$FL" && echo "progress-in-a-window-of-its-own"
) > "$W/front.out" 2>&1
for m in front-started front-answer-in-subshell front-one-process front-cancelled-is-1 front-stale-answer-skipped front-large-answer \
         front-busy-in-window front-progress-lines front-theme-sent front-died-falls-back front-not-used-again front-gone-kdialog-asks \
         front-page-failure-is-3 front-bad-answer-is-3 front-cannot-start front-stopped-on-exit front-one-shot-without-folder \
         front-no-log-descriptor front-stderr-marked-and-cleaned front-stderr-line-capped front-stderr-total-capped \
         front-stderr-nul-bytes-capped front-stderr-nul-lines-capped front-stderr-logged-at-once front-stderr-reader-ends-on-stop-file \
         no-tty-drops-window-pipes front-helper-named-by-id-and-start-time front-processes-gone-after-stop front-stop-sends-no-signal \
         front-stop-spares-a-reused-id front-stop-with-a-pipe-holder front-stuck-process-ended front-stuck-signals-only-its-processes front-endless-answer-is-3 \
         front-one-shot-failure-is-3-and-remembered front-not-started-in-a-subshell front-request-is-one-line front-answer-without-id-is-3 \
         front-longest-answer front-cut-answer-is-3 front-answer-limit-counts-bytes front-gone-between-requests-is-noted front-gone-nothing-sent \
         front-gone-progress-is-kdialog pipe-write-status-1 pipe-write-shell-status-0 pipe-write-leaves-sigpipe-alone front-no-lock-descriptor \
         same-account-drops-window-pipes front-stuck-without-its-helper-ended \
         front-unknown-status-is-3 front-not-started-where-it-cannot-run front-one-shot-longest-answer front-one-shot-answer-capped \
         kdialog-answer-capped-status-kept theme-change-refreshes-the-kdialog-theme pipe-write-soon-gives-up-on-a-full-pipe \
         pipe-write-soon-writes front-three-descriptors-only front-stderr-reader-ends-while-lines-keep-coming \
         front-log-reader-holds-no-window-pipe front-stuck-term-before-kill front-that-ends-on-term-gets-no-kill \
         progress-in-a-window-of-its-own; do
    expect "$W/front.out" "$m" "$m"
done

# A signal that goes to every process of the tool while a fix is being
# recorded (the session ends, the terminal is closed): the main shell holds
# it back, the window's helper and the front end are ended by it. The next
# line for the window then has no reader. The tool must not be ended by
# that write (SIGPIPE: no EXIT trap, nothing cleaned up): it goes on
# without the window, and stops in order when the fix is recorded.
cat > "$W/sigpipe.sh" <<'SIGEOF'
# shellcheck disable=SC1090
source "$TOOL"
RUN_LOG="$W/sigpipe-run.log"; : > "$RUN_LOG"; RUN_TMP=$(mktemp -d "$W/sigpipe-rt.XXXXXX")
_ui_app_cmd() { python3 -I "$W/fake-front.py" "$W/sigpipe-front.log" "$@"; }
UI_MODE=kde; _QML_OK=yes
trap _on_signal INT TERM HUP
trap 'echo "exit-trap-ran"; _cleanup' EXIT
ui_front_start
a=$(ui_app wizard '{"say":"x"}'); echo "first-page-status-$?"
_signals_hold
ui_busy_start "Applying a fix"
kill -TERM 0
for _ in $(seq 1 50); do _proc_stat "$_UI_FRONT_PID" || break; sleep 0.1; done
_proc_stat "$_UI_FRONT_PID" || echo "helper-ended"
ui_busy_stop
[[ -e "$RUN_TMP/ui-front-gone" ]] && echo "window-marked-gone"
a=$(ui_app confirm '{"say":"y"}'); echo "next-page-status-$?"
echo "fix-recorded"
_signals_release
echo "not reached: the signal takes effect at the release"
SIGEOF
env TOOL="$TOOL" W="$W" setsid --wait bash "$W/sigpipe.sh" > "$W/sigpipe.out" 2>&1
rc=$?
[[ $rc -eq 130 ]] && ok "a signal to every process of the tool: it stops in order (130)" || bad "after a signal to every process of the tool: exit $rc"
for m in first-page-status-0 helper-ended window-marked-gone next-page-status-4 fix-recorded exit-trap-ran; do
    expect "$W/sigpipe.out" "$m" "no window after its helper ended: $m"
done
reject "$W/sigpipe.out" "not reached" "the held signal takes effect when the fix is recorded"
[[ -z "$(compgen -G "$W/sigpipe-rt.*")" ]] && ok "the private folder is removed after that" || bad "private folder left behind: $(compgen -G "$W/sigpipe-rt.*")"

# A front end is a program of a less trusted account, and it can end badly
# in more ways than "it is gone": it leaves a program behind that holds one
# of its pipes, it is stopped with the request pipe full, it hangs on the
# first page. In none of them may this side wait for ever, and the tool's
# exit must always get to its end: the private folder removed, the run's
# lock released, nothing of the tool's left running. Each case is a run of
# its own, in a session of its own, with the lock and the exit trap of a
# real run.
cat > "$W/front-end.sh" <<'FEEOF'
# shellcheck disable=SC1090
source "$TOOL"
echo "$$" > "$W/fe-$1.sid"
STATE_DIR="$W/fe-$1.state"; RUN_ID="fe"; TMPDIR="$W/fe-$1.tmp"; export TMPDIR
mkdir -p "$STATE_DIR" "$TMPDIR"
_init_state
FL="$W/fe-$1.log"; : > "$FL"
_ui_app_cmd() { python3 -I "$W/fake-front.py" "$FL" "$@"; }
# On the first page the front end's process appears a second after it was
# started, when the main shell has long gone on: the real one, at the far
# end of runuser, is not there at once either.
[[ "$1" != hung-first-page ]] || _ui_app_cmd() { sleep 1; python3 -I "$W/fake-front.py" "$FL" "$@"; }
UI_MODE=kde; _QML_OK=yes
trap _on_signal INT TERM HUP
trap 'echo "exit-trap-ran"; _cleanup; echo "exit-trap-done"' EXIT
ui_front_start
case "$1" in
    chatty|holder)
        # The front end ends while a page is asked, and something it
        # started still holds its stderr (chatty) or its answer pipe.
        a=$(ui_app wizard "{\"$1\":true}"); echo "page-status-$?"
        a=$(ui_app wizard '{"say":"x"}'); echo "next-page-status-$?"
        ;;
    frozen)
        # The front end is stopped, and the request pipe is full.
        a=$(ui_app wizard '{"say":"x"}'); echo "page-status-$?"
        _ui_front_send '{"freeze":true}'
        fpid=$(awk '$1 == "pid" { print $2 }' "$FL")
        for _ in $(seq 1 100); do
            [[ "$(sed 's/.*) //' "/proc/$fpid/stat" 2>/dev/null | cut -c1)" == T ]] && break
            sleep 0.1
        done
        timeout 2 head -c 200000 /dev/zero >&"$_UI_FRONT_W"; echo "pipe-filled-$?"
        ;;
    hung-first-page)
        # The first page is asked from $(...), as the wizard's is. The
        # front end hangs on it, and then a signal goes to every process
        # of the tool (the session ends): it ends the helper, not the
        # front end. The signal is sent when this side had the time to
        # note the front end's process, or after ten seconds.
        (
            until grep -qx hanging "$FL"; do sleep 0.1; done
            fpid=$(awk '$1 == "pid" { print $2 }' "$FL")
            for _ in $(seq 1 100); do grep -q "^$fpid " "$RUN_TMP/ui-front-seen" 2>/dev/null && break; sleep 0.1; done
            kill -TERM 0
        ) > /dev/null 2>&1 &
        a=$(ui_app wizard '{"hang":true}'); echo "page-status-$?"
        ;;
    signal-twice)
        # As above, and the signal comes again a second later (Ctrl-C
        # pressed twice), while the tool is still ending the front end:
        # the clean-up must finish all the same.
        (
            until grep -qx hanging "$FL"; do sleep 0.1; done
            fpid=$(awk '$1 == "pid" { print $2 }' "$FL")
            for _ in $(seq 1 100); do grep -q "^$fpid " "$RUN_TMP/ui-front-seen" 2>/dev/null && break; sleep 0.1; done
            trap '' TERM        # this sender is in the group too, and has a second signal to send
            kill -TERM 0; sleep 1; kill -TERM "$$"
        ) > /dev/null 2>&1 &
        a=$(ui_app wizard '{"hang":true}'); echo "page-status-$?"
        ;;
esac
exit 0
FEEOF
# running PID — the process is there (and not one that has ended and waits
# to be collected, which pgrep still lists).
running() { [[ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)" == [A-Y] ]]; }
# front_end_case NAME — run one of them; one that takes longer than two
# minutes is ended. Leaves its exit status in FE_RC and what is left of
# its session afterwards (process ids) in FE_LEFT.
front_end_case() {
    local name="$1" pid sid="" p i
    rm -f "$W/fe-$name.sid"
    env TOOL="$TOOL" W="$W" setsid --wait bash "$W/front-end.sh" "$name" > "$W/fe-$name.out" 2>&1 &
    pid=$!
    for (( i = 0; i < 1200; i++ )); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    sid=$(cat "$W/fe-$name.sid" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        echo "not-ended-in-time" >> "$W/fe-$name.out"
        [[ -n "$sid" ]] && pkill -KILL -s "$sid"
    fi
    wait "$pid"; FE_RC=$?
    # What it left behind may need a moment to end by itself (a program
    # that finds its pipe closed).
    FE_LEFT="no session id"
    [[ -n "$sid" ]] || return 0
    for (( i = 0; i < 100; i++ )); do
        FE_LEFT=""
        for p in $(pgrep -s "$sid"); do running "$p" && FE_LEFT+="$p "; done
        [[ -n "$FE_LEFT" && "$FE_LEFT" != "${2:-} " ]] || break
        sleep 0.1
    done
    [[ -z "$FE_LEFT" ]] || pkill -KILL -s "$sid"
    return 0
}
# front_end_clean NAME — after it: no private folder, and the lock is free.
front_end_clean() {
    [[ -z "$(ls -A "$W/fe-$1.tmp" 2>/dev/null)" ]] && flock -n "$W/fe-$1.state/.lock" true \
        && grep -qx exit-trap-done "$W/fe-$1.out" && ! grep -q not-ended-in-time "$W/fe-$1.out"
}
front_end_case chatty
if [[ $FE_RC -eq 0 && -z "$FE_LEFT" ]] && grep -qx page-status-3 "$W/fe-chatty.out" && grep -qx next-page-status-4 "$W/fe-chatty.out" \
   && front_end_clean chatty; then
    ok "a front end that ends and leaves a program writing to its stderr: no wait, a clean exit, nothing left"
else
    bad "front end gone, its stderr still written to: exit $FE_RC, left '$FE_LEFT', $(tr '\n' ' ' < "$W/fe-chatty.out")"
fi
front_end_case holder "$(awk '$1 == "child" { print $2 }' "$W/fe-holder.log" 2>/dev/null)"
held_by=$(awk '$1 == "child" { print $2 }' "$W/fe-holder.log")
# (What is left is the program that holds the pipe: the desktop user's
# own, and not below the front end any more. This side leaves it alone.)
if [[ $FE_RC -eq 0 && -n "$held_by" && "$FE_LEFT" == "$held_by " ]] && grep -qx page-status-3 "$W/fe-holder.out" \
   && grep -qx next-page-status-4 "$W/fe-holder.out" && front_end_clean holder; then
    ok "a front end that ends while a program holds its answer pipe: noticed, a clean exit"
else
    bad "front end gone, its answer pipe still held: exit $FE_RC, left '$FE_LEFT' (holder '$held_by'), $(tr '\n' ' ' < "$W/fe-holder.out")"
fi
front_end_case frozen
if [[ $FE_RC -eq 0 && -z "$FE_LEFT" ]] && grep -qx page-status-0 "$W/fe-frozen.out" && grep -qx pipe-filled-124 "$W/fe-frozen.out" \
   && grep -qx frozen "$W/fe-frozen.log" && front_end_clean frozen; then
    ok "a stopped front end with a full request pipe: the exit trap finishes, nothing left"
else
    bad "front end stopped, request pipe full: exit $FE_RC, left '$FE_LEFT', $(tr '\n' ' ' < "$W/fe-frozen.out")"
fi
front_end_case hung-first-page
if [[ $FE_RC -eq 130 && -z "$FE_LEFT" ]] && grep -qx hanging "$W/fe-hung-first-page.log" && ! grep -q page-status "$W/fe-hung-first-page.out" \
   && front_end_clean hung-first-page; then
    ok "a front end that hangs on the first page is ended after a signal to every process of the tool"
else
    bad "front end hung on the first page, then a signal: exit $FE_RC, left '$FE_LEFT', $(tr '\n' ' ' < "$W/fe-hung-first-page.out")"
fi
front_end_case signal-twice
if [[ $FE_RC -eq 130 && -z "$FE_LEFT" ]] && grep -qx hanging "$W/fe-signal-twice.log" && front_end_clean signal-twice; then
    ok "a second signal while the tool ends a hung front end does not cut the clean-up short"
else
    bad "a second signal during the clean-up: exit $FE_RC, left '$FE_LEFT', $(tr '\n' ' ' < "$W/fe-signal-twice.out")"
fi

# Started with SIGPIPE ignored (the weekly check's systemd service, a CI
# runner), the tool starts again with the signal at its default, so that
# every program it runs has it: the checks count on "find | head" ending
# find. A stand-in for "date", the first program the tool runs, notes what
# it finds each time: ignored, then (started again) default.
mkdir "$W/sigbin"
cat > "$W/sigbin/date" <<EOF
#!/bin/bash
awk '/^SigIgn:/ { print \$2 }' "/proc/\$\$/status" >> "$W/sigpipe-states"
exec "$(command -v date)" "\$@"
EOF
chmod 755 "$W/sigbin/date"
# sigpipe_states — "i" (ignored) or "d" (default) for each time it ran.
sigpipe_states() {
    local m out=""
    while read -r m; do (( (16#$m >> 12) & 1 )) && out+=i || out+=d; done < "$W/sigpipe-states"
    echo "$out"
}
: > "$W/sigpipe-states"
env --ignore-signal=PIPE PATH="$W/sigbin:$PATH" "$TOOL" --list-checks > "$W/sigpipe-list-ignored" 2>&1; rc_i=$?
st_i=$(sigpipe_states); : > "$W/sigpipe-states"
env --default-signal=PIPE PATH="$W/sigbin:$PATH" "$TOOL" --list-checks > "$W/sigpipe-list-default" 2>&1; rc_d=$?
st_d=$(sigpipe_states)
if [[ $rc_i -eq 0 && $rc_d -eq 0 && "$st_i" == id && "$st_d" == d ]] && grep -q '^firewall' "$W/sigpipe-list-default" \
   && cmp -s "$W/sigpipe-list-ignored" "$W/sigpipe-list-default"; then
    ok "started with SIGPIPE ignored, the tool starts again with the default (same arguments, same result)"
else
    bad "SIGPIPE at the start: ignored gave '$st_i' (exit $rc_i), default gave '$st_d' (exit $rc_d)"
fi

# The form of an answer line is written down twice: where the root side
# takes it apart, and where the test of the real front end checks every
# answer against it. The two must be the same.
re_sh=$(sed -n "s/^ *local re='\\(.*\\)'\$/\\1/p" "$HERE/../lib/ui.sh")
re_py=$(sed -n "s/^ANSWER_RE = re\\.compile(r'\\(.*\\)')\$/\\1/p" "$HERE/../tests/ui-offscreen.py")
if [[ -n "$re_sh" && "$re_sh" != *$'\n'* && "$re_sh" == "$re_py" ]]; then
    ok "one form of an answer line in lib/ui.sh and tests/ui-offscreen.py"
else
    bad "answer line pattern differs: lib/ui.sh '${re_sh}', tests/ui-offscreen.py '${re_py}'"
fi

# The run's lock (descriptor 9) stays with this tool: a program started as
# another account, or by a fix, does not get a copy, so it can neither
# release the lock during the run nor hold it afterwards.
(
    # shellcheck disable=SC1090
    source "$TOOL"
    STATE_DIR="$W/lockstate"; RUN_ID="lock"; mkdir -p "$STATE_DIR"
    probe='if [ -e /proc/self/fd/9 ]; then echo has-9; else echo no-9; fi'
    plain=$(bash -c "$probe")
    [[ "$plain" == no-9 && -z "$_RUN_LOCK_FD" && "$(_no_tty bash -c "$probe")" == no-9 ]] && echo "lock-not-open-is-fine"
    # Descriptor 9 is closed only when it is the lock.
    other9=$(exec 9< /dev/null; _no_tty bash -c "$probe")
    [[ "$other9" == has-9 ]] && echo "lock-close-leaves-another-9-alone"
    _init_state
    plain=$(bash -c "$probe")
    [[ "$_RUN_LOCK_FD" == 9 && "$plain" == has-9 ]] && ! flock -n "$STATE_DIR/.lock" true && echo "lock-held"
    [[ "$(_no_tty bash -c "$probe")" == no-9 ]] && echo "lock-not-given-to-a-fix"
    [[ "$(_as_user "$U" bash -c "$probe")" == no-9 ]] && echo "lock-not-given-to-another-account"
    [[ "$(_as_user root bash -c "$probe")" == no-9 ]] && echo "lock-not-given-as-the-same-account"
    DESKTOP_USER="$U"
    [[ "$(_as_desktop_user bash -c "$probe")" == no-9 ]] && echo "lock-not-given-to-the-desktop-user"
    # Something the desktop user's program leaves running...
    _as_user "$U" bash -c 'sleep 30 > /dev/null 2>&1 < /dev/null & echo started' > "$W/lock-bg"
    # ... does not let go of the lock for this run,
    grep -qx started "$W/lock-bg" && [[ -e /proc/self/fd/9 ]] && ! flock -n "$STATE_DIR/.lock" true && echo "lock-still-held-by-the-run"
    # and the lock is free the moment the run ends.
    exec 9>&-
    pgrep -u "$U" -x sleep > /dev/null && flock -n "$STATE_DIR/.lock" true && echo "lock-free-after-the-run"
    pkill -u "$U" -x sleep
    rm -rf -- "$RUN_TMP"
) > "$W/lock.out" 2>&1
for m in lock-not-open-is-fine lock-close-leaves-another-9-alone lock-held lock-not-given-to-a-fix lock-not-given-to-another-account \
         lock-not-given-as-the-same-account lock-not-given-to-the-desktop-user lock-still-held-by-the-run lock-free-after-the-run; do
    expect "$W/lock.out" "$m" "$m"
done

# An undo step's output: limited where it is read (a step that prints
# without end costs no memory and is not ended by a closed pipe), its exit
# status kept, and the end of it logged.
(
    # shellcheck disable=SC1090
    source "$TOOL"
    RUN_LOG="$W/undo-out.log"
    set +o pipefail     # the status must not depend on the caller's options
    run() { : > "$RUN_LOG"; rc=0; _undo_run bash -c "$1" || rc=$?; }
    run 'echo done; exit 0'
    [[ $rc -eq 0 ]] && grep -qE '^[0-9:]{8} undo: done$' "$RUN_LOG" && echo "undo-out-small-ok"
    run 'echo oops >&2; exit 7'
    [[ $rc -eq 7 ]] && grep -qE '^[0-9:]{8} undo: oops$' "$RUN_LOG" && echo "undo-out-status-kept"
    run 'seq 1 300000; echo all-done; exit 0'
    [[ $rc -eq 0 && "$(wc -l < "$RUN_LOG")" -eq $(( _LOG_FOREIGN_LINES + 1 )) && "$(tail -n 1 "$RUN_LOG")" == *" undo: all-done" ]] \
        && grep -q "undo: (the last ${_LOG_FOREIGN_LINES} lines" "$RUN_LOG" && ! grep -q ' undo: 1$' "$RUN_LOG" && echo "undo-out-large-ok-is-ok"
    run 'seq 1 300000; echo "the reason it failed" >&2; exit 5'
    [[ $rc -eq 5 && "$(tail -n 1 "$RUN_LOG")" == *" undo: the reason it failed" ]] && echo "undo-out-failure-logs-the-end"
    # 200 MB of output under a memory limit that the shell could not hold
    # it in: only the end is kept.
    ( ulimit -v 200000; run 'yes | head -c 200000000; echo end; exit 3'
      [[ $rc -eq 3 && "$(wc -l < "$RUN_LOG")" -eq $(( _LOG_FOREIGN_LINES + 1 )) ]] && grep -q ' undo: end$' "$RUN_LOG" && echo "undo-out-memory-bounded" )
    run 'printf "a\\0b\\n"; exit 0'
    [[ $rc -eq 0 ]] && grep -q ' undo: ab$' "$RUN_LOG" && echo "undo-out-nul-bytes-dropped"
    # A line without end is cut ("12:00:00 undo: " are 15 characters).
    run 'head -c 5000 /dev/zero | tr "\0" x; echo; exit 0'
    [[ $rc -eq 0 && "$(awk '{ print length($0) }' "$RUN_LOG")" == $(( _LOG_FOREIGN_LINE + 15 )) ]] && echo "undo-out-long-line-cut"
    # A fix's output goes the same way: it can run a program as another
    # account too. Marked "fix: ", cleaned, only the end, and 200 MB of it
    # under a memory limit that the shell could not hold them in.
    RUN_TMP=$(mktemp -d "$W/fix-out-rt.XXXXXX"); UI_MODE=none
    : > "$RUN_LOG"
    _run_change "A noisy fix" 'seq 1 300000; printf "a\0b\n\033[31m12:00:00 [OK] forged\n"; echo the-end' "" > /dev/null 2>&1; rc=$?
    [[ $rc -eq 0 && "$(grep -cE '^[0-9:]{8} fix: ' "$RUN_LOG")" -eq $(( _LOG_FOREIGN_LINES + 1 )) && "$(stat -c %s "$RUN_LOG")" -lt 20000 ]] \
        && grep -qE '^[0-9:]{8} fix: the-end$' "$RUN_LOG" && grep -qE '^[0-9:]{8} fix: \[31m12:00:00 \[OK\] forged$' "$RUN_LOG" \
        && grep -qE '^[0-9:]{8} fix: ab$' "$RUN_LOG" && ! grep -qE '(^| )299000$' "$RUN_LOG" && grep -q 'end of the output (exit 0)' "$RUN_LOG" \
        && echo "fix-out-capped-marked-cleaned"
    ( ulimit -v 200000; : > "$RUN_LOG"
      _run_change "A fix that prints without end" 'head -c 200000000 /dev/zero | tr "\0" y; echo; echo end; exit 3' "" > /dev/null 2>&1; rc=$?
      [[ $rc -eq 3 ]] && grep -q ' fix: end$' "$RUN_LOG" && grep -q 'end of the output (exit 3)' "$RUN_LOG" && echo "fix-out-memory-bounded" )
    rm -rf -- "$RUN_TMP"
    # What a program of another account wrote: no more lines of it than
    # _LOG_FOREIGN_LINES in one go.
    : > "$RUN_LOG"; _log_foreign "x: " "$(seq 1 $(( _LOG_FOREIGN_LINES + 100 )))"
    [[ "$(wc -l < "$RUN_LOG")" -eq $(( _LOG_FOREIGN_LINES + 1 )) && "$(tail -n 1 "$RUN_LOG")" == *" x: (more lines were dropped)" ]] \
        && grep -q " x: ${_LOG_FOREIGN_LINES}\$" "$RUN_LOG" && ! grep -q " x: $(( _LOG_FOREIGN_LINES + 1 ))\$" "$RUN_LOG" && echo "foreign-log-lines-capped"
) > "$W/undo-out.out" 2>&1
for m in undo-out-small-ok undo-out-status-kept undo-out-large-ok-is-ok undo-out-failure-logs-the-end undo-out-memory-bounded undo-out-nul-bytes-dropped undo-out-long-line-cut \
         fix-out-capped-marked-cleaned fix-out-memory-bounded foreign-log-lines-capped; do
    expect "$W/undo-out.out" "$m" "$m"
done

# The real front end, started the real way (as the desktop user, through
# runuser, in a session of its own). Until the first request it needs no
# Qt, so this runs here: it has no descriptor on the run log, it is ended by
# ui_front_stop, and it leaves by itself when the root side is killed while
# another child of the root side still holds the pipes (so there is no EOF).
install -d -m 755 -o "$U" "$UH/bsa-front" "$UH/bsa-front/ui"
install -m 644 "$HERE/../ui/app.py" "$UH/bsa-front/ui/app.py"
cat > "$W/owner.sh" <<'OWNEREOF'
# shellcheck disable=SC1090
source "$TOOL"
RUN_LOG="$W/owner-run.log"; : > "$RUN_LOG"; RUN_TMP=$(mktemp -d "$W/owner-rt.XXXXXX")
DESKTOP_USER="$U"; DESKTOP_UID=$(id -u "$U"); UI_MODE=kde; _QML_OK=yes; SCRIPT_DIR="$UH/bsa-front"
ui_front_start
sleep 300 &
echo "$!" > "$W/owner.sleep"
# Until the front end's own process (python, as the desktop user) is there.
for _ in $(seq 1 200); do
    _proc_tree "$_UI_FRONT_PID" "$_UI_FRONT_START" > "$W/owner.tree"
    while read -r p _ k; do
        [[ "$k" == user && "$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline")" == *"app.py serve"* ]] && break 2
    done < "$W/owner.tree"
    sleep 0.1
done
if [[ "${1:-}" == stop || "${1:-}" == stuck ]]; then
    if [[ "$1" == stuck ]]; then
        # The front end (python, the desktop user's) does not react any
        # more. Root's own signals are noted with the target's account.
        while read -r p _ k; do [[ "$k" == user ]] && kill -STOP "$p"; done < "$W/owner.tree"
        kill() { echo "${!#} $(stat -c %u "/proc/${!#}" 2>/dev/null)" >> "$W/owner.kills"; builtin kill "$@"; }
    fi
    : > "$W/owner.kills"; t0=$SECONDS
    ui_front_stop
    echo $(( SECONDS - t0 )) > "$W/owner.secs"
    unset -f kill
    mapfile -t tree < "$W/owner.tree"
    _procs_left "${tree[@]}" > "$W/owner.left"
    kill "$(cat "$W/owner.sleep")"
    exit 0
fi
: > "$W/owner.ready"
while :; do sleep 1; done
OWNEREOF
(
    # shellcheck disable=SC1090
    source "$TOOL"
    # front_pid — the process in owner.tree that is app.py and runs as $U.
    front_pid() {
        local p _
        while read -r p _; do
            [[ "$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline")" == *"app.py serve"* && "$(stat -c %U "/proc/$p" 2>/dev/null)" == "$U" ]] && echo "$p"
        done < "$W/owner.tree"
        return 0
    }
    env TOOL="$TOOL" W="$W" U="$U" UH="$UH" bash "$W/owner.sh" stop
    [[ "$(wc -l < "$W/owner.tree")" -ge 4 && ! -s "$W/owner.left" ]] && echo "real-front-stopped"

    # A front end that is stuck is ended within a few seconds: its own
    # processes (the desktop user's) by a signal sent as the desktop user,
    # never by root, which signals only root's helper processes.
    env TOOL="$TOOL" W="$W" U="$U" UH="$UH" bash "$W/owner.sh" stuck
    uid=$(id -u "$U")
    grep -q " user$" "$W/owner.tree" && grep -q " own$" "$W/owner.tree" && [[ ! -s "$W/owner.left" && "$(cat "$W/owner.secs")" -le 6 ]] \
        && echo "real-front-stuck-ended"
    [[ -s "$W/owner.kills" ]] && ! grep -qvE ' 0?$' "$W/owner.kills" && echo "real-front-root-signals-only-root-processes"
    # The signal sent as the desktop user: it ends that user's process, it
    # cannot end root's (the kernel refuses), and it checks the start time.
    DESKTOP_USER="$U"; DESKTOP_UID=$uid
    runuser -u "$U" -- sleep 300 & ru=$!
    sleep 300 & rootp=$!
    up=""; for _ in $(seq 1 30); do up=$(pgrep -u "$U" -P "$ru" -x sleep) && break; sleep 0.1; done
    if [[ -n "$up" ]] && _proc_stat "$up"; then
        ustart=$_PS_START; _proc_stat "$rootp"; rstart=$_PS_START
        # Root's own signal is for root's own processes: not for one of
        # another account, even with the right id and start time.
        _kill_same KILL "$up" "$ustart"; ksrc=$?
        _kill_same 0 "$rootp" "$rstart" && [[ $ksrc -ne 0 ]] && echo "root-signal-not-for-another-account"
        _ui_front_signal KILL "$up 1$ustart user" "$rootp $rstart user"; sleep 0.3
        [[ -d "/proc/$up" && -d "/proc/$rootp" ]] && echo "user-signal-spares-root-and-reused-ids"
        _ui_front_signal KILL "$up $ustart user"
        for _ in $(seq 1 30); do [[ -d "/proc/$up" ]] || break; sleep 0.1; done
        [[ ! -d "/proc/$up" ]] && echo "user-signal-ends-the-users-process"
    fi
    kill "$rootp" "$ru" 2>/dev/null

    # Whose a process is. One of root's below the desktop user's front
    # end is nobody's here ("other": root did not start it), and so is one
    # whose real and effective accounts differ (a setuid program). Neither
    # is signalled, by root or as the desktop user.
    cat > "$W/lineage.py" <<'LINEAGEEOF'
import os, pwd, subprocess, sys, time
uid = int(sys.argv[1])
if sys.argv[2] == "below":
    # A program of root's, started before this process becomes the user's.
    child = subprocess.Popen(["sleep", "300"]).pid
    os.setgroups([]); os.setgid(pwd.getpwuid(uid).pw_gid); os.setuid(uid)
else:
    child = 0
    os.setresuid(uid, 0, 0)
print("ready", child, flush=True)
time.sleep(300)
LINEAGEEOF
    ( python3 -I "$W/lineage.py" "$uid" below > "$W/lineage-below.out"; : ) & top=$!
    python3 -I "$W/lineage.py" "$uid" split > "$W/lineage-split.out" & split=$!
    for _ in $(seq 1 100); do grep -q ready "$W/lineage-below.out" && grep -q ready "$W/lineage-split.out" && break; sleep 0.1; done
    below=$(awk '{ print $2 }' "$W/lineage-below.out")
    _proc_stat "$top"; mapfile -t lt < <(_proc_tree "$top" "$_PS_START")
    if [[ ${#lt[@]} -eq 3 && "${lt[0]}" == "$top "*" own" && "${lt[1]}" == *" user" && "${lt[2]}" == "$below "*" other" ]]; then
        _ui_front_signal KILL "${lt[@]}"
        for _ in $(seq 1 50); do _proc_stat "$top" || break; sleep 0.1; done
        ! _proc_stat "$top" && ! _proc_stat "${lt[1]%% *}" && _proc_stat "$below" && echo "root-process-below-the-user-is-left-alone"
    fi
    _proc_stat "$split"; sstart=$_PS_START
    [[ "$(_proc_tree "$split" "$sstart")" == "$split $sstart other" ]] && ! _proc_uid "$split" && ! _kill_same KILL "$split" "$sstart" \
        && { _ui_front_signal KILL "$split $sstart other"; sleep 0.3; _proc_stat "$split"; } && echo "setuid-process-is-left-alone"
    kill -KILL "$top" "$below" "$split" 2>/dev/null

    rm -f "$W/owner.ready"
    env TOOL="$TOOL" W="$W" U="$U" UH="$UH" bash "$W/owner.sh" & owner=$!
    for _ in $(seq 1 50); do [[ -e "$W/owner.ready" ]] && break; sleep 0.1; done
    py=$(front_pid)
    if [[ -n "$py" && -d "/proc/$py" ]]; then
        echo "real-front-runs-as-user"
        # Read as that user: root in a container may not look at them.
        # shellcheck disable=SC2016
        fds=$(runuser -u "$U" -- sh -c 'for f in "/proc/$1/fd"/*; do printf "%s=%s\n" "${f##*/}" "$(readlink "$f")"; done' sh "$py" 2>/dev/null)
        [[ "$fds" == *$'\n'* && "$fds" != *owner-run.log* && "$fds" == *"2=pipe:"* ]] && echo "real-front-no-log-descriptor"
        kill -9 "$owner"; wait "$owner" 2>/dev/null
        kill -0 "$(cat "$W/owner.sleep")" 2>/dev/null && echo "pipes-still-held"
        for _ in $(seq 1 80); do [[ -d "/proc/$py" ]] || break; sleep 0.1; done
        [[ ! -d "/proc/$py" ]] && echo "real-front-leaves-when-root-side-is-killed"
    fi
    kill "$(cat "$W/owner.sleep")" 2>/dev/null
    mapfile -t tree < "$W/owner.tree"; _ui_front_reap "${tree[@]}"
) > "$W/owner.out" 2>&1
for m in real-front-stopped real-front-stuck-ended real-front-root-signals-only-root-processes root-signal-not-for-another-account user-signal-spares-root-and-reused-ids \
         root-process-below-the-user-is-left-alone setuid-process-is-left-alone \
         user-signal-ends-the-users-process real-front-runs-as-user real-front-no-log-descriptor pipes-still-held real-front-leaves-when-root-side-is-killed; do
    expect "$W/owner.out" "$m" "$m"
done

# The front end itself: every page the root side can ask for has its file
miss=""
for f in $(python3 -I -c 'import ast, sys
for node in ast.walk(ast.parse(open(sys.argv[1]).read())):
    if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "PAGES":
        print(" ".join(ast.literal_eval(node.value).values()))' "$HERE/../ui/app.py") Shell.qml Progress.qml; do
    [[ -f "$HERE/../ui/qml/$f" ]] || miss+=" $f"
done
if [[ -z "$miss" ]] && grep -q '"serve"' "$HERE/../ui/app.py"; then ok "every page file of the front end is there"; else bad "front end: missing page files:${miss:- (or no serve mode)}"; fi

# Reports go into the user's folder as the user: a symlink there to a
# root-owned folder must not make root create files in it.
mkdir -p "$W/rootdir"; chmod 755 "$W/rootdir"
runuser -u "$U" -- ln -sfn "$W/rootdir" "$UH/evil-reports"
sleep 1
"$TOOL" --no-gui --no-wizard --report-only --use gaming --check selinux --report-dir "$UH/evil-reports" \
    < /dev/null > "$W/run6a.out" 2>&1
[[ -z "$(ls -A "$W/rootdir")" ]] && ok "no report written through a user's symlink" || bad "report written into $W/rootdir"
expect "$W/run6a.out" "Could not write to" "falls back to the state folder"

# Undo steps run as root, so a state folder root does not own is refused.
mkdir -p "$W/userstate"; chown "$U" "$W/userstate"
AUDIT_STATE_DIR="$W/userstate" "$TOOL" --no-gui --no-wizard --report-only --use gaming --check selinux \
    < /dev/null > "$W/run6h.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q "not a folder owned by root" "$W/run6h.out" && [[ -z "$(ls -A "$W/userstate")" ]] \
    && ok "a state folder root does not own is refused" || bad "user-owned state folder used (exit $rc)"
ln -sfn "$STATE" "$W/statelink"
AUDIT_STATE_DIR="$W/statelink/" "$TOOL" --no-gui --no-wizard --report-only --use gaming --check selinux \
    < /dev/null > "$W/run6i.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q "not a folder owned by root" "$W/run6i.out" \
    && ok "a state folder reached through a symlink (trailing slash) is refused" || bad "symlinked state folder used (exit $rc)"

sleep 1
"$TOOL" --no-gui --no-wizard --report-only --use gaming --check deep_etc_changes --report-dir "$UH/Documents/r6" \
    < /dev/null > "$W/run6b.out" 2>&1
expect "$W/run6b.out" "Running 1 checks" "a deep check named with --check runs without --deep"
expect "$W/run6b.out" "standard check + named deep checks" "the depth label says so"

# Only numbers changed (image age, update count): nothing is "new".
sleep 1
sed -i "s/\"timestamp\": [0-9]*/\"timestamp\": $((NOW - 41 * 86400))/" "$W/status.json"
printf 'org.mozilla.firefox\norg.freedesktop.Platform\norg.kde.Platform\n' > "$W/fp-updates"
"$TOOL" --no-gui --no-wizard --report-only --use gaming --check system_updates,flatpak --report-dir "$UH/Documents/r6" \
    < /dev/null > "$W/run6c.out" 2>&1
MD6=$(ls -t "$UH"/Documents/r6/*.md | head -n1)
expect "$MD6" "3 Flatpak update(s) waiting" "update count changed"
expect "$MD6" "The system image is 41 days old" "image age changed"
expect "$MD6" "- No changes." "changed numbers are not new findings"
reject "$W/run6c.out" "since last check" "summary shows no new or resolved findings"

# The default zone is judged even when no connection uses it right now.
sleep 1
echo home > "$W/iface-zone"
: > "$W/calls.log"
"$TOOL" --no-gui --no-wizard --report-only --use gaming --check firewall --report-dir "$UH/Documents/r6" \
    < /dev/null > "$W/run6d.out" 2>&1
MD6=$(ls -t "$UH"/Documents/r6/*.md | head -n1)
expect "$MD6" "the default zone 'FedoraWorkstation', which new connections get" "unused default zone checked"
expect "$MD6" "### [LOW] The firewall lets in far more" "lower severity while no connection uses it"
for z in home FedoraWorkstation; do
    n=$(grep -c -- "--zone=${z} --list-all" "$W/calls.log" || true)
    [[ "$n" -eq 1 ]] && ok "zone ${z} read once" || bad "zone ${z} read ${n} times"
done
rm -f "$W/iface-zone"

# Undoing an older run while a newer one has changes asks first.
mkdir -p "$STATE/undo/29991231-235959"
printf '#!/usr/bin/env bash\n# TITLE: newer change\n# Applied: now\nset -uo pipefail\ntrue\n' \
    > "$STATE/undo/29991231-235959/01-undo.sh"
sleep 1
printf '2\nn\n' | timeout 180 script -qec "'$TOOL' --no-gui --undo" /dev/null > "$W/run6e.out" 2>&1
expect "$W/run6e.out" "newer run(s) also made changes" "undoing an older run warns"
[[ -f "$UNDO4/02-undo.sh" ]] && ok "cancelled undo changed nothing" || bad "older run undone after cancel"
rm -rf "$STATE/undo/29991231-235959"

# --no-dashboard goes straight to the fix list and then finishes.
sleep 1
cp "$FX/etc/sudoers.d/bdatest" "$W/sudoers.before6"
printf '\nn\n' | timeout 180 script -qec "'$TOOL' --no-gui --no-wizard --no-dashboard --fix --use gaming --check sudo --report-dir '$UH/Documents/r6'" /dev/null \
    > "$W/run6g.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "--no-dashboard run finished" || bad "--no-dashboard run exit $rc"
expect "$W/run6g.out" "Choose what to fix" "--no-dashboard shows the fix list"
reject "$W/run6g.out" "Pick a check" "--no-dashboard skips the dashboard"
cmp -s "$W/sudoers.before6" "$FX/etc/sudoers.d/bdatest" && ok "declined fix changed nothing" || bad "sudoers changed after decline"

# "stable-42" pins Fedora 42 on the stable channel.
sleep 1
sed -i 's#bazzite:stable"#bazzite:stable-42"#' "$W/status.json"
"$TOOL" --no-gui --no-wizard --report-only --use gaming --check system_updates --report-dir "$UH/Documents/r6" \
    < /dev/null > "$W/run6f.out" 2>&1
MD6=$(ls -t "$UH"/Documents/r6/*.md | head -n1)
expect "$MD6" "The system is pinned to Fedora 42" "stable-42 is a Fedora pin"
expect "$MD6" "When you are ready: rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/bazzite:stable" "... back to its channel"

# --check/--skip without a list must not quietly mean "every check".
for flag in --check --skip; do
    "$TOOL" --list-checks "$flag" < /dev/null > "$W/run7a.out" 2>&1
    rc=$?
    [[ $rc -ne 0 ]] && grep -q "needs a list of checks" "$W/run7a.out" \
        && ok "${flag} without a list is refused" || bad "${flag} without a list accepted (exit $rc)"
done
"$TOOL" --list-checks --check nosuch < /dev/null > "$W/run7b.out" 2>&1
expect "$W/run7b.out" "Unknown check for --check: nosuch " "an unknown check is named as typed"

# Not a Fedora Atomic system and nobody to ask: say so, don't exit quietly.
mkdir -p "$W/plainroot/etc"
printf 'NAME="Other"\nID=other\nPRETTY_NAME="Other Linux"\n' > "$W/plainroot/etc/os-release"
AUDIT_ROOT="$W/plainroot" "$TOOL" --no-gui --no-wizard --report-only --use gaming --check selinux \
    < /dev/null > "$W/run7c.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q "nothing was checked" "$W/run7c.out" \
    && ok "non-interactive run on another system says why it stops" || bad "non-Atomic system: exit $rc, no reason given"

# One published version: --version, SCRIPT_VERSION and the changelog section.
ver=$(sed -n 's/^readonly SCRIPT_VERSION="\(.*\)"/\1/p' "$TOOL")
got=$("$TOOL" --version 2>/dev/null || true)
if [[ "$got" == "bazzite-sec-audit $ver" && "$ver" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] \
    && grep -q "^## \[${ver}\]" "$HERE/../CHANGELOG.md"; then
    ok "version string is ${ver}"
else
    bad "version string: declared '${ver:-}', --version '${got:-}', changelog section missing"
fi

echo
echo "passed: $PASS  failed: $FAIL   (work dir: $W)"
[[ $FAIL -eq 0 ]]
