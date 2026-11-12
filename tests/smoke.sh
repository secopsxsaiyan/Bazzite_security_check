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
# dashboard entries to open taken from another (none left: Finish).
stub kdialog << EOF
#!/bin/bash
printf '%s\0' "\$@" >> "$W/kdialog.log"; printf '\n' >> "$W/kdialog.log"
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[\$i]}" in
    --yesno|--warningyesno|--msgbox|--error|--detailederror|--sorry|--passivepopup|--textbox) exit 0 ;;
    --progressbar) echo "org.kde.kdialog-4242 /ProgressDialog"; exit 0 ;;
    --getexistingdirectory) echo "\${args[\$((i + 1))]}"; exit 0 ;;
    --newpassword) echo "secret"; exit 0 ;;
    --yesnocancel|--warningyesnocancel)
      a=\$(head -n1 "$W/q/answers"); sed -i 1d "$W/q/answers"; exit "\${a:-1}" ;;
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
expect "$W/run2.out" "⚠ downloads, needs a reboot" "fix list shows side effects"
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
) > "$W/fix5.out" 2>&1
n_ok=$(grep -c '^OK ' "$W/fix5.out" || true)
if grep -q '^BAD ' "$W/fix5.out"; then bad "invalid fix commands:"; grep -A8 '^BAD ' "$W/fix5.out"
else ok "all ${n_ok} fix scripts and their undo steps parse"; fi
[[ "$n_ok" -ge 32 ]] && ok "every fix function was exercised" || { bad "only ${n_ok} fixes ran"; cat "$W/fix5.out" | head -20; }

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
        apply_change() { printf '%s\n--\n%s\n' "$1" "$2" > "$W/ctr/two.txt"; }
        CTR_JSON=compose fix_containers_localhost 0 "podman|ollama" "podman|web"
        [[ $(grep -c "compose.yml.absent" "$W/ctr/two.txt") -eq 2 ]] \
            && [[ $(grep -n 'sed -E -i' "$W/ctr/two.txt" | tail -1 | cut -d: -f1) -lt $(grep -n "compose-up -p" "$W/ctr/two.txt" | head -1 | cut -d: -f1) ]] \
            && [[ $(grep -c '^if \[ -e .*compose-up-' "$W/ctr/two.txt") -eq 2 ]] && echo "ctr-compose-shared-file"
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
        update_verify "$R/dl" 9.9.9 && src=$(update_extract "$R/dl" 9.9.9) && [[ -f "$src/ui/app.py" ]] \
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
        rm -f "$KS/kept"; ln -s "$W/elsewhere" "$KS/kept"; kept_load
        ! _kept_save "x" && [[ ! -e "$W/elsewhere" ]] && echo "kept-symlink-refused"
        [[ "$(_dashboard_answer '{"action":"keep"}')" == keep ]] && echo "dashboard-keep-action"
    )

    # Progress: the bar shows finished checks scaled to 90%, so it never
    # reads 100% while a check still runs; the slow malware scan holds at
    # 90% with a note; 100% comes only when everything is done.
    (
        exec {_PROGRESS_FD}> "$W/progress.txt"; _PROGRESS_STEPS=10; QUIET=1
        ui_progress_set 1 "First"; ui_progress_set 10 "Last"; ui_progress_set 10 "Malware scan (ClamAV)" slow
        ui_progress_stop
        mapfile -t pl < "$W/progress.txt"
        [[ "${pl[0]%%$'\t'*}" == 0 && "${pl[1]%%$'\t'*}" == 81 && "${pl[2]}" == $'90\t1\tMalware scan (ClamAV)\tThis can take several minutes. The bar moves on when it is done.' \
           && "${pl[3]}" == $'100\t0\tDone\t' && "${pl[4]}" == QUIT && ${#pl[@]} -eq 5 ]] && echo "progress-90-until-done"
        # A busy indicator (a fix being applied): no steps, no 100%.
        exec {_PROGRESS_FD}> "$W/busy.txt"; _PROGRESS_STEPS=0; ui_progress_stop
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
    bash "$W/undo-swap.sh"
    [[ "$(stat -c %a "$W/swap-target")" == 600 && "$(grep -c . "$W/undo-swap.sh")" -eq 4 ]] \
        && echo "undo-ignores-swapped-symlink"
    unset -f apply_change

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
         undo-ignores-swapped-symlink fix-args-kept repo-section-not-run fix-umask-022 \
         fix-needs-private-tmp newline-path-not-split sudo-shell-rules-found image-policy-read \
         affects-in-use-first affects-html-escaped affects-tags affects-none-not-in-use fix-in-use-unticked ports-to-features \
         kept-becomes-note kept-not-scored kept-labelled kept-saved kept-untick-counts-again kept-symlink-refused dashboard-keep-action affects-change-not-unticked kept-exact-ports-and-severity anticheat-lockdown-mark-only-when-added detect-honest-steam-and-servers sunshine-admin-port-not-streaming kept-untick-holds-in-session kept-subset-entry-kept kept-worse-reticked; do
    expect "$W/t6.out" "$m" "$m"
done

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

echo
echo "passed: $PASS  failed: $FAIL   (work dir: $W)"
[[ $FAIL -eq 0 ]]
