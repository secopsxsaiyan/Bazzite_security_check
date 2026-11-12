# shellcheck shell=bash
# Development and gaming services: Docker/Podman exposure and Sunshine game
# streaming.

# ====================== CONTAINERS ======================
# _published_all_ifaces ENGINE_OUTPUT — containers that publish on every
# interface (0.0.0.0, ::, [::] or no address), one per line:
# "name<TAB>host side of each such binding<TAB>its host port/protocol", e.g.
# "web<TAB>0.0.0.0:8080, :::8080<TAB>8080/tcp 8080/tcp" (the first port of a range).
_published_all_ifaces() {
    awk -F'\t' '
        {
            n = split($2, p, /, */); hosts = ""; ports = ""
            for (i = 1; i <= n; i++) {
                if (p[i] !~ /->/) continue
                if (p[i] ~ /^(0\.0\.0\.0|::|\[::\]|:::)/ || p[i] ~ /^[0-9]+(-[0-9]+)?->/ || p[i] ~ /^:[0-9]/) {
                    host = p[i]; sub(/->.*/, "", host)
                    proto = p[i]; sub(/^.*\//, "", proto); if (proto !~ /^[a-z]+$/) proto = "tcp"
                    port = host; sub(/^.*:/, "", port); sub(/-.*/, "", port)
                    hosts = hosts (hosts == "" ? "" : ", ") host
                    if (port ~ /^[0-9]+$/) ports = ports (ports == "" ? "" : " ") port "/" proto
                }
            }
            if (hosts != "") print $1 "\t" hosts "\t" ports
        }' <<< "$1" 2>/dev/null || true
}

# Container plans are one line of fields separated by \x1f (so empty fields
# survive and paths keep their spaces); lists inside a field use \x1e.
#   compose  OWNER  WORKDIR  PROJECT  SERVICE  FILES  PORTS  ENV_FILE  NAME
#   run      NAME  ORIGINAL-COMMAND  NEW-COMMAND  RESTART-POLICY
#   manual   REASON
_CTR_US=$'\x1f'
_CTR_RS=$'\x1e'

# _ctr_plan ENGINE NAME — how the fix can make a Docker or rootful Podman
# container publish on 127.0.0.1 only, from "ENGINE inspect NAME". Compose
# files are not read here (see _compose_check, which reads them as their
# owner).
_ctr_plan() {
    local engine="$1" name="$2"
    timeout 20 "$engine" inspect "$name" 2>/dev/null | python3 -I -c '
import json, os, pwd, re, shlex, sys
engine, US, RS = sys.argv[1], "\x1f", "\x1e"
def out(*f):
    print(US.join(str(x).replace(US, " ").replace("\n", " ") for x in f)); sys.exit(0)
try:
    d = json.load(sys.stdin)
    d = d[0] if isinstance(d, list) else d
except Exception:
    out("manual", "could not read the container settings")
cfg, hc = d.get("Config") or {}, d.get("HostConfig") or {}
labels = cfg.get("Labels") or {}
name = (d.get("Name") or "").lstrip("/")
allif = set()
for binds in (hc.get("PortBindings") or {}).values():
    for b in binds or []:
        if b.get("HostIp", "") in ("", "0.0.0.0", "::", "[::]") and str(b.get("HostPort", "")).isdigit():
            allif.add(str(b["HostPort"]))
if not allif:
    out("manual", "no port published on all interfaces")
for m in d.get("Mounts") or []:
    if m.get("Type") == "volume" and re.fullmatch(r"[0-9a-f]{64}", m.get("Name", "")):
        out("manual", "it keeps data in an anonymous volume, which a new container would not get")
cid = d.get("Id") or ""
if not re.fullmatch(r"[0-9a-f]{12,64}", cid):
    out("manual", "could not read the container ID")
files = labels.get("com.docker.compose.project.config_files") or ""
unit = labels.get("PODMAN_SYSTEMD_UNIT") or ""
# podman-compose labels every container with its own podman-compose@ unit.
if unit and not (files and unit.startswith("podman-compose@")):
    out("manual", "started by the systemd unit %s: change -p/PublishPort= there to 127.0.0.1:PORT:PORT" % unit)
if files:
    wd = labels.get("com.docker.compose.project.working_dir") or ""
    proj = labels.get("com.docker.compose.project") or ""
    svc = labels.get("com.docker.compose.service") or ""
    if not (os.path.isabs(wd) and os.path.isdir(wd) and proj and svc and name):
        out("manual", "started with compose, but its project folder was not found")
    fl = []
    for f in files.split(","):
        f = f.strip()
        if not f:
            continue
        f = f if os.path.isabs(f) else os.path.join(wd, f)
        if not os.path.isfile(f) or os.path.islink(f) or RS in f or US in f:
            out("manual", "started with compose, but its compose file %s was not found" % f)
        fl.append(f)
    if not fl:
        out("manual", "started with compose, but its compose file was not found")
    if any(os.path.realpath(os.path.dirname(f)) != os.path.realpath(wd) for f in fl):
        out("manual", "its compose project folder (%s) is not the folder of all its compose files, so relative paths would change" % wd)
    envf = labels.get("com.docker.compose.project.environment_file") or ""
    if envf and not (os.path.isabs(envf) and os.path.isfile(envf)):
        out("manual", "its compose environment file %s was not found" % envf)
    try:
        owner = pwd.getpwuid(os.stat(fl[0]).st_uid).pw_name
    except KeyError:
        out("manual", "the compose file belongs to an unknown account")
    out("compose", owner, wd, proj, svc, RS.join(fl), ",".join(sorted(allif, key=int)), envf, name, cid)
if engine != "podman":
    out("manual", "recreate it with -p 127.0.0.1:PORT:PORT (Docker keeps no record of the original command)")
cmd = cfg.get("CreateCommand") or []
if len(cmd) < 3 or os.path.basename(cmd[0]) != "podman" or cmd[1] != "run":
    out("manual", "its original podman run command is not recorded")
if any(US in a or "\n" in a for a in cmd):
    out("manual", "its podman run command has characters the tool cannot repeat safely")
# Where the image is: the options before it are rewritten, the container
# command after it is copied as it is.
def norm(x):
    x = re.sub(r"^(docker\.io/|localhost/)?(library/)?", "", x)
    return re.sub(r":latest$", "", x)
img = norm(d.get("ImageName") or cfg.get("Image") or "")
usercmd = list(cfg.get("Cmd") or [])
idx = None
for cand in ([len(cmd) - len(usercmd) - 1] if usercmd and cmd[-len(usercmd):] == usercmd else []) + [len(cmd) - 1]:
    if 2 <= cand < len(cmd) and not cmd[cand].startswith("-") and img and (norm(cmd[cand]) == img or img.endswith("/" + norm(cmd[cand]))):
        idx = cand
        break
if idx is None:
    out("manual", "the image could not be found in its podman run command")
opts, rest = cmd[2:idx], cmd[idx:]
done, newopts, detached, named, i = set(), [], False, False, 0
def local(spec):
    host, sep, proto = spec.partition("/")
    parts = host.rsplit(":", 2) if not host.startswith("[") else [host[:host.index("]") + 1]] + host[host.index("]") + 2:].split(":", 1)
    if len(parts) == 3 and parts[0] in ("0.0.0.0", "[::]", "::", ""):
        hp = parts[1]
    elif len(parts) == 2:
        hp = parts[0]
    elif len(parts) == 1:
        hp = ""
    else:
        return spec
    if not re.fullmatch(r"[0-9]+(-[0-9]+)?", hp or ""):
        out("manual", "it publishes %s on a random port: recreate it yourself with -p 127.0.0.1:PORT:PORT" % spec)
    if "-" in hp:
        out("manual", "it publishes the port range %s, which the tool does not change: recreate it yourself with -p 127.0.0.1:%s:..." % (hp, hp))
    done.add(hp.split("-")[0])
    return "127.0.0.1:%s:%s%s%s" % (hp, parts[-1], sep, proto)
while i < len(opts):
    a = opts[i]
    if a in ("--rm", "-P", "--publish-all", "--env-host") or a.startswith(("--pod", "--rm=", "--env-file", "--cidfile", "--publish-all=", "--label-file", "--authfile", "--seccomp-policy", "--security-opt=seccomp=", "--secret-env")):
        out("manual", "it was started with %s: recreate it yourself with -p 127.0.0.1:PORT:PORT" % a.split("=")[0])
    if re.fullmatch(r"-[A-Za-z]{2,}", a) and set("pve") & set(a[1:]):
        out("manual", "its podman run command combines options (%s): recreate it yourself with -p 127.0.0.1:PORT:PORT" % a)
    if a in ("-d", "--detach") or a.startswith("--detach="):
        detached = True
    val = None
    if a in ("--name", "-v", "--volume", "--mount", "-p", "--publish") and i + 1 < len(opts):
        val = opts[i + 1]
    elif a.startswith(("--name=", "--volume=", "--mount=", "--publish=")):
        val = a.split("=", 1)[1]
    elif a.startswith("-v") and len(a) > 2:
        val = a[2:]
    if a in ("-e", "--env") or a.startswith("--env=") or (a.startswith("-e") and not a.startswith("--") and len(a) > 2):
        ev = opts[i + 1] if a in ("-e", "--env") and i + 1 < len(opts) else a.split("=", 1)[1] if a.startswith("--env=") else a[2:] if a.startswith("-e") and not a.startswith("--") else ""
        if "=" not in ev or ev.endswith("*"):
            out("manual", "it takes %s from the shell it was started in (-e without a value)" % (ev or "a variable"))
    if a == "--security-opt" and i + 1 < len(opts) and opts[i + 1].startswith("seccomp=") and opts[i + 1][8:] != "unconfined" and not opts[i + 1][8:].startswith("/"):
        out("manual", "it uses a seccomp profile from a relative path")
    if a == "--name" or a.startswith("--name="):
        named = (val == name)
    if a in ("-v", "--volume") or a.startswith("--volume=") or (a.startswith("-v") and not a.startswith("--") and len(a) > 2):
        src = (val or "").split(":")[0]
        if src and not src.startswith("/") and ("/" in src or src.startswith(".") or src.startswith("~")):
            out("manual", "it mounts the relative path %s, which would point elsewhere when run again" % src)
    if a == "--mount" or a.startswith("--mount="):
        for kv in (val or "").split(","):
            k, _, v = kv.partition("=")
            if k in ("src", "source") and v and not v.startswith("/") and ("/" in v or v.startswith(".")):
                out("manual", "it mounts the relative path %s, which would point elsewhere when run again" % v)
    if a in ("-p", "--publish") and val is not None:
        newopts += [a, local(val)]; i += 2; continue
    if a.startswith("--publish="):
        newopts.append("--publish=" + local(a[10:])); i += 1; continue
    if a.startswith("-p") and len(a) > 2 and not a.startswith("--"):
        newopts.append("-p" + local(a[2:])); i += 1; continue
    newopts.append(a); i += 1
if not named:
    out("manual", "its podman run command has no --name %s, so it cannot be put back by name" % name)
missing = sorted(allif - done)
if missing:
    out("manual", "not every published port (%s) is a -p option the tool can change" % ", ".join(missing))
orig, new = list(cmd), cmd[:2] + newopts + rest
if not detached:
    orig.insert(2, "--detach"); new.insert(2, "--detach")
restart = (hc.get("RestartPolicy") or {}).get("Name") or ""
out("run", name, " ".join(shlex.quote(x) for x in orig), " ".join(shlex.quote(x) for x in new), restart, cid)
' "$engine" 2>/dev/null || printf 'manual%scould not read the container settings\n' "$_CTR_US"
}

# _compose_check WORKDIR ENV_FILE PORTS FILE... — run as the compose files'
# owner: prints "ok<US>FILE<RS>FILE..." (the files whose port lines can be
# changed) or "manual<US>REASON". A file that uses ~ or a variable from the
# person's shell, or that publishes a port in a form the tool does not
# change, stays manual: compose runs again as root.
_compose_check() {
    python3 -I -c '
import os, re, sys
US, RS = "\x1f", "\x1e"
wd, envf, ports, files = sys.argv[1], sys.argv[2], sys.argv[3].split(","), sys.argv[4:]
def out(*f):
    print(US.join(f)); sys.exit(0)
known = {"HOME", "USER", "PWD"}
for ef in [os.path.join(wd, ".env")] + ([envf] if envf else []):
    try:
        for line in open(ef):
            m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
            if m:
                known.add(m.group(1))
    except OSError:
        pass
edit, hit = [], set()
for f in files:
    text = open(f).read()
    if re.search(r"(^|[\s:=\"\x27\[,])~/", text, re.M):
        out("manual", "%s uses ~ (a home folder), which means /root when compose runs as administrator" % os.path.basename(f))
    for v in re.findall(r"(?<!\$)\$\{?([A-Za-z_][A-Za-z0-9_]*)", text):
        if v not in known:
            out("manual", "%s uses ${%s}, which comes from your shell, not from .env" % (os.path.basename(f), v))
    mine = False
    for line in text.split("\n"):
        for p in ports:
            short = re.match(r"^\s*-\s*[\"\x27]?(0\.0\.0\.0:)?" + p + r"(-[0-9]+)?:[0-9][^\s\"\x27]*[\"\x27]?\s*(#.*)?$", line)
            mention = re.search(r"(^|[^0-9.:])" + p + r"(-[0-9]+)?:[0-9]", line) or re.search(r"published:\s*[\"\x27]?" + p + r"\b", line) \
                or re.search(r"\[?::\]?:" + p + r"(-[0-9]+)?:", line)
            if short:
                mine = True; hit.add(p)
            elif mention:
                out("manual", "%s publishes port %s in a form the tool does not change (use - \"127.0.0.1:%s:...\")" % (os.path.basename(f), p, p))
    if mine:
        edit.append(f)
missing = [p for p in ports if p not in hit]
if missing:
    out("manual", "no compose port line was found for %s" % ", ".join(missing))
out("ok", RS.join(edit))
' "$@" 2>/dev/null || printf 'manual%scould not read the compose files\n' "$_CTR_US"
}

# _compose_port_re PORT — the extended regex of a short-syntax port line of
# host PORT ("- 8080:80", "- \"0.0.0.0:8080:80\""); PORT is digits.
_compose_port_re() { printf '^([[:space:]]*-[[:space:]]*["'"'"']?)(0\\.0\\.0\\.0:)?(%s(-[0-9]+)?:[0-9])' "$1"; }

# _compose_edit_cmd OWNER FILE PORT,... — fix-script lines that put
# 127.0.0.1 in front of those lines (as OWNER).
_compose_edit_cmd() {
    local owner="$1" file="$2" p run=""
    local -a ports=()
    IFS=',' read -ra ports <<< "$3"
    [[ "$owner" == root ]] || run="runuser -u $(_q "$owner") -- "
    for p in "${ports[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        printf '%ssed -E -i %s %s\n' "$run" "$(_q "s/$(_compose_port_re "$p")/\\1127.0.0.1:\\3/")" "$(_q "$file")"
    done
}

# _compose_cmd ENGINE — a compose command for ENGINE that root may run: a
# root-owned program that no other account can change (a compose installed
# in a home folder, such as Homebrew's, is not run as root). Status 1 when
# there is none.
_compose_cmd() {
    local c
    _root_owned_exe() { [[ -x "$1" && ! -L "$1" && "$(stat -c '%u' -- "$1")" == 0 && $(( 0$(stat -c '%a' -- "$1") & 022 )) -eq 0 ]]; }
    if [[ "$1" == docker ]]; then
        for c in /usr/bin/docker /usr/local/bin/docker; do _root_owned_exe "$c" && { echo "$c compose"; return 0; }; done
    else
        for c in /usr/bin/podman-compose /usr/local/bin/podman-compose; do _root_owned_exe "$c" && { echo "$c"; return 0; }; done
        for c in /usr/bin/docker-compose /usr/local/bin/docker-compose; do _root_owned_exe "$c" && { echo "$c"; return 0; }; done
    fi
    return 1
}

# _sq TEXT — TEXT quoted for a fix script, readable in the dialog: in
# single quotes when it has none, else as _q quotes it.
_sq() { if [[ "$1" != *"'"* ]]; then printf "'%s'" "$1"; else _q "$1"; fi; }

# _ctr_verify_cmd ENGINE NAME — fix-script lines that fail unless NAME is
# running and publishes nothing on all interfaces.
_ctr_verify_cmd() {
    printf '[ "$(%s inspect --format %s %s)" = true ] || { echo %s >&2; exit 1; }\n' \
        "$1" "$(_sq '{{.State.Running}}')" "$(_q "$2")" "$(_sq "$2 is not running")"
    printf 'ips=$(%s inspect --format %s %s); case "$ips" in *"[]"*|*"[0.0.0.0]"*|*"[::]"*) echo %s >&2; exit 1 ;; esac\n' \
        "$1" "$(_sq '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}[{{.HostIp}}]{{end}}{{end}}')" "$(_q "$2")" \
        "$(_sq "$2 still publishes on all interfaces")"
}

# _ctr_fixable ENGINE NAME — the container's plan when the fix can carry it
# out; for compose plans a 10th field lists the files to edit. Status 1
# (and the reason on stderr) otherwise.
_ctr_fixable() {
    local plan method owner wd proj svc files ports envf cname cid chk
    local -a fl=()
    plan=$(_ctr_plan "$1" "$2")
    IFS="$_CTR_US" read -r method owner wd proj svc files ports envf cname cid <<< "$plan"
    case "$method" in
        run) printf '%s\n' "$plan"; return 0 ;;
        compose)
            if ! _compose_cmd "$1" >/dev/null; then
                echo "no compose program installed for the whole system (one in a home folder is not run as administrator)" >&2
                return 1
            fi
            IFS="$_CTR_RS" read -ra fl <<< "$files"
            chk=$(_as_user "$owner" bash -c "$(declare -f _compose_check); _CTR_US=\$'\\x1f'; _compose_check \"\$@\"" _ "$wd" "$envf" "$ports" "${fl[@]}")
            if [[ "${chk%%"$_CTR_US"*}" == ok ]]; then
                printf '%s%s%s\n' "$plan" "$_CTR_US" "${chk#*"$_CTR_US"}"
                return 0
            fi
            echo "${chk#*"$_CTR_US"}" >&2
            return 1 ;;
    esac
    echo "${plan#*"$_CTR_US"}" >&2
    return 1
}

check_containers() {
    local has_docker=0 members u out
    { _have docker || [[ "$(_unit_state docker.service)" != "missing" ]]; } && has_docker=1
    if [[ $has_docker -eq 0 && "$USE_DEV" -ne 1 ]]; then
        mark_na "Docker is not installed (Podman/Distrobox run rootless and are covered by the network checks)"
        return 0
    fi

    # docker group = root without a password prompt.
    members=$(getent group docker 2>/dev/null | cut -d: -f4 || true)
    if [[ -n "$members" ]]; then
        local -a mem=()
        IFS=',' read -ra mem <<< "$members"
        for u in "${mem[@]}"; do
            [[ -n "$u" ]] || continue
            finding low "${u} can control Docker (docker group)" \
"Members of the docker group can start a container that mounts the whole disk,
which makes them root without a password prompt. Convenient for development,
but anything running as ${u} (a malicious package, an exploited app) gets the
same power." \
"Use rootless Podman (podman, podman-compose, distrobox) or Docker's rootless mode,
or accept the trade-off. To leave the group: sudo gpasswd -d ${u} docker" \
                fix_leave_group "$u" docker
            finding_change "${u} is in the docker group" "${u} removed from the docker group" \
                "next login|Takes effect at ${u}'s next login." \
                "docker needs sudo|docker commands then need sudo (or switch to rootless Podman)."
            finding_affects \
                "docker|docker commands need sudo after the next login (or switch to rootless Podman)."
        done
    fi

    # Docker API on TCP. _listeners leaves out loopback addresses, which only
    # this PC can reach.
    local api
    api=$(_listeners | awk -F'\t' '$1 == "tcp" && $4 == "dockerd" { print $3 }' | sort -un | paste -sd, - || true)
    if [[ -n "$api" ]]; then
        finding high "The Docker API listens on the network (port ${api})" \
"dockerd accepts API connections over TCP. Unless it is protected with TLS client
certificates, anyone who can reach that port controls this PC as root." \
"Remove the tcp:// entry from \"hosts\" in /etc/docker/daemon.json (or the -H flag in
the docker.service override) and restart Docker; use 'docker context' over SSH
for remote access instead."
        finding_change "dockerd listens on TCP port ${api}" "Docker API on the local socket only (manual)"
        finding_affects \
            "docker!|Remote Docker contexts and tools that reach Docker over TCP stop working."
    fi

    # Containers that publish ports on every interface: Docker and rootful
    # Podman (their own firewall rules), and rootless Podman (through the
    # firewall, like any program).
    local -a pub=() rootless=() ctr_fix=()
    local name hosts ports pp why ndocker=0
    if _have docker && _unit_active docker.service; then
        out=$(timeout 20 docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)
        while IFS=$'\t' read -r name hosts ports; do
            [[ -n "$name" ]] || continue
            ndocker=$((ndocker + 1))
            if why=$({ _ctr_fixable docker "$name" > /dev/null; } 2>&1); then
                pub+=("docker ${name}: ${hosts}"); ctr_fix+=("docker|${name}")
            else
                pub+=("docker ${name}: ${hosts} (manual: ${why:-cannot be recreated by the tool})")
            fi
        done < <(_published_all_ifaces "$out")
    fi
    if _have podman; then
        out=$(timeout 20 podman ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)
        while IFS=$'\t' read -r name hosts ports; do
            [[ -n "$name" ]] || continue
            if why=$({ _ctr_fixable podman "$name" > /dev/null; } 2>&1); then
                pub+=("podman (root) ${name}: ${hosts}"); ctr_fix+=("podman|${name}")
            else
                pub+=("podman (root) ${name}: ${hosts} (manual: ${why:-cannot be recreated by the tool})")
            fi
        done < <(_published_all_ifaces "$out")
        if [[ -n "$DESKTOP_USER" ]]; then
            out=$(_as_desktop_user timeout 20 podman ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)
            while IFS=$'\t' read -r name hosts ports; do
                [[ -n "$name" ]] || continue
                # Each binding is judged by the firewall rule of its protocol.
                for pp in $ports; do
                    if _reachable "${pp#*/}" "0.0.0.0" "${pp%/*}"; then
                        rootless+=("podman (${DESKTOP_USER}) ${name}: ${hosts}")
                        break
                    fi
                done
            done < <(_published_all_ifaces "$out")
        fi
    fi
    if [[ ${#rootless[@]} -gt 0 ]]; then
        finding "$(_ctx high medium)" "${#rootless[@]} rootless container(s) are reachable from your network" \
"$(printf -- '- %s\n' "${rootless[@]}")
These rootless Podman containers publish ports on every interface, and the
firewall lets other devices reach them. Development databases and admin panels
often run with default passwords." \
"Publish on localhost only: podman run -p 127.0.0.1:8080:80 ... (or \"127.0.0.1:8080:80\" in compose files),
or close the port in the firewall (see the firewall finding)."
        finding_change "${#rootless[@]} rootless container(s) reachable through the firewall" \
            "published on 127.0.0.1 only, or blocked by the firewall (manual)"
        finding_affects \
            "containers!|Other devices can no longer reach these containers. A game server or media server in one stops working for other players and devices." \
            "game_server!|A game server running in one of these containers can no longer be joined from other PCs."
    fi
    if [[ ${#pub[@]} -gt 0 ]]; then
        local daemon_ip="" want_ip=0
        local -a fix=()
        [[ -f "$(_r /etc/docker/daemon.json)" ]] && daemon_ip=$(_pyjson 'd.get("ip", "")' < "$(_r /etc/docker/daemon.json)" 2>/dev/null || true)
        # daemon.json only changes Docker's own containers.
        [[ $ndocker -gt 0 && "$daemon_ip" != "127.0.0.1" ]] && want_ip=1
        [[ ${#ctr_fix[@]} -gt 0 || $want_ip -eq 1 ]] && fix=(fix_containers_localhost "$want_ip" "${ctr_fix[@]}")
        finding "$(_ctx high medium)" "${#pub[@]} container(s) are reachable from your network" \
"$(printf -- '- %s\n' "${pub[@]}")
Docker and rootful Podman publish ports with their own firewall rules, so these
are reachable from other devices even when firewalld would block the port.
Development databases and admin panels often run with default passwords." \
"Publish on localhost only: -p 127.0.0.1:5432:5432 (or \"127.0.0.1:5432:5432\" in compose files),
then recreate the container (docker compose up -d / podman-compose up -d, or run it again).
Make that the default for new Docker containers: set \"ip\": \"127.0.0.1\" in /etc/docker/daemon.json" \
            "${fix[@]}"
        local after="published on 127.0.0.1 only (manual)"
        local -a warns=()
        if [[ ${#ctr_fix[@]} -gt 0 ]]; then
            after="the containers you pick are recreated, published on 127.0.0.1 only"
            [[ ${#ctr_fix[@]} -lt ${#pub[@]} ]] && after+="; the others stay manual"
            warns+=("containers restart|Each container you pick is stopped and created again from the same image and settings; it is unavailable for a few seconds. Named volumes and bind mounts are kept." \
                    "other devices lose access|Other devices on your network can no longer connect to these containers. Programs on this PC still can.")
        fi
        if [[ $want_ip -eq 1 ]]; then
            [[ ${#ctr_fix[@]} -gt 0 ]] && after+="; " || after=""
            after+="daemon.json ip: 127.0.0.1 - new Docker containers publish on this PC only"
            warns+=("restarts Docker|Setting the Docker default restarts Docker, which stops running containers; those with a restart policy come back.")
        fi
        local now="${#pub[@]} container(s) published on all interfaces"
        [[ $want_ip -eq 1 ]] && now+="; daemon.json ip: ${daemon_ip:-not set (all interfaces)}"
        finding_change "$now" "$after" "${warns[@]}"
        finding_affects \
            "containers!|Other devices can no longer reach these containers. A game server or media server in one stops working for other players and devices." \
            "game_server!|A game server running in one of these containers can no longer be joined from other PCs."
    fi
    return 0
}

# fix_leave_group USER GROUP
fix_leave_group() {
    local u="$1" g="$2"
    apply_change "gpasswd -d $(_q "$u") $(_q "$g")" "usermod -aG $(_q "$g") $(_q "$u")"
}

# _docker_ip_script / _docker_ip_undo — set Docker's default publish
# address to 127.0.0.1 in daemon.json (and put it back).
_docker_ip_script() {
    local f=/etc/docker/daemon.json
    printf '%s\n' "mkdir -p /etc/docker" "$(_backup_cmd "$f")" \
        "python3 -I -c 'import json, os; p = \"$f\"; d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}; d[\"ip\"] = \"127.0.0.1\"; open(p, \"w\").write(json.dumps(d, indent=2) + \"\\n\")'" \
        "systemctl try-restart docker.service"
}
# The undo only acts (and restarts Docker) when the fix got as far as
# backing up daemon.json.
_docker_ip_undo() {
    local b
    b=$(_bk_path /etc/docker/daemon.json)
    printf 'if [ -e %s ] || [ -e %s ]; then\n%s\nsystemctl try-restart docker.service\nfi\n' \
        "$(_q "$b")" "$(_q "$b.absent")" "$(_restore_cmd /etc/docker/daemon.json)"
}

fix_docker_default_ip() {
    apply_change "$(_docker_ip_script)" "$(_docker_ip_undo)" \
        "New containers publish on 127.0.0.1 unless you ask for another address (-p 0.0.0.0:PORT:PORT)."
}

# fix_containers_localhost WANT_DOCKER_IP ENGINE|NAME... — recreate the
# containers the person picks so they publish on 127.0.0.1 only, and
# optionally make 127.0.0.1 Docker's default.
# The script checks every picked container first, then changes things in
# this order: Docker's default, compose file edits (each file backed up
# once), compose recreates, podman run replacements. The undo only touches
# what the script got to, so a rollback after an early failure never
# removes or recreates a container the fix did not change:
#   compose: files are restored; the service is recreated only when a
#            marker shows the fix reached its "up".
#   run:     the old container is kept as NAME-before-fix; the undo puts it
#            back only when that is the original container (same ID).
fix_containers_localhost() {
    local want_ip="$1" e engine name plan method f1 f2 f3 f4 f5 f6 f7 f8 f9 f10
    shift
    local -a items=() pick=()
    local -A plans=()
    for e in "$@"; do
        IFS='|' read -r engine name <<< "$e"
        [[ "$engine" =~ ^(docker|podman)$ && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || continue
        plan=$(_ctr_fixable "$engine" "$name" 2>/dev/null) || continue
        plans["$e"]="$plan"
        method="${plan%%"$_CTR_US"*}"
        items+=("$e" "$(ui_item "${name} (${engine}$([[ $engine == podman ]] && echo ", root"))" \
            "$([[ $method == compose ]] && echo "its compose file is changed and it is created again" || echo "a new one is run; the old one is kept, stopped")" \
            medium "Other devices can no longer reach its ports: a game or media server in it stops working for them. It restarts while it is recreated.")" on)
    done
    [[ "$want_ip" == 1 ]] && items=("docker-default" "$(ui_item "Make 127.0.0.1 the default for new Docker containers" "daemon.json gets \"ip\": \"127.0.0.1\"" medium "Docker restarts: running containers without a restart policy stop.")" on "${items[@]}")
    [[ ${#items[@]} -gt 0 ]] || return 1
    mapfile -t pick < <(ui_checklist "Choose the containers to publish on this PC only.
Each one is created again from the same image and settings, with
127.0.0.1 in front of its ports. Leave out a container other devices need." "${items[@]}") || return 1
    [[ ${#pick[@]} -gt 0 && -n "${pick[0]}" ]] || return 1

    local pre="" dflt="" edits="" ups="" runs="" u_dflt="" u_files="" u_ups="" u_runs=""
    local up cmp file home old mark ownarg dcfg
    local -a names=() fl=() edit=() runlist=()
    local -A backed=()
    for e in "${pick[@]}"; do
        if [[ "$e" == docker-default ]]; then
            dflt="$(_docker_ip_script)"$'\n'
            u_dflt="$(_docker_ip_undo)"$'\n'
            names+=("Docker default 127.0.0.1")
            continue
        fi
        [[ -n "${plans[$e]:-}" ]] || continue
        IFS='|' read -r engine name <<< "$e"
        IFS="$_CTR_US" read -r method f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 <<< "${plans[$e]}"
        if [[ "$method" == compose ]]; then
            # f1 owner, f2 workdir, f3 project, f4 service, f5 files, f6 ports,
            # f7 env file, f8 container, f9 container ID, f10 files to edit
            IFS="$_CTR_RS" read -ra fl <<< "$f5"
            IFS="$_CTR_RS" read -ra edit <<< "$f10"
            cmp=$(_compose_cmd "$engine") || continue
            home=$(_home_of "$f1")
            ownarg=""; [[ "$f1" != root ]] && ownarg="$f1"
            # Docker reads CLI plugins from $DOCKER_CONFIG (else ~/.docker):
            # point it at a root-only folder so nothing from the owner's
            # home runs as root.
            dcfg=""; [[ "$engine" == docker ]] && dcfg=" DOCKER_CONFIG=$(_q "$STATE_DIR/docker-config")"
            # PYTHONNOUSERSITE: a Python compose never loads modules from
            # the owner's ~/.local as root.
            up="cd $(_q "$f2") && env HOME=$(_q "$home") USER=$(_q "$f1") PYTHONNOUSERSITE=1${dcfg} ${cmp} -p $(_q "$f3")"
            for file in "${fl[@]}"; do up+=" -f $(_q "$file")"; done
            [[ -n "$f7" ]] && up+=" --env-file $(_q "$f7")"
            up+=" up -d --no-deps --force-recreate $(_q "$f4")"
            pre+="[ \"\$($engine inspect --format '{{.Id}}' $(_q "$f8") 2>/dev/null)\" = $(_q "$f9") ] || { echo $(_sq "$f8 changed since the check; run the check again.") >&2; exit 1; }"$'\n'
            for file in "${edit[@]}"; do
                if [[ -z "${backed[$file]:-}" ]]; then
                    backed["$file"]=1
                    edits+="$(_backup_cmd "$file" "$ownarg")"$'\n'
                    u_files+="$(_restore_cmd "$file" "$ownarg")"$'\n'
                fi
                edits+="$(_compose_edit_cmd "$f1" "$file" "$f6")"$'\n'
            done
            mark="$(_bk_path "/compose-up-${f8}")"
            pre+="rm -f $(_q "$mark")"$'\n'
            pre+="( cd $(_q "$f2") && env PYTHONNOUSERSITE=1${dcfg} ${cmp} version > /dev/null ) || { echo $(_sq "The compose program does not work; nothing was changed.") >&2; exit 1; }"$'\n'
            [[ "$engine" == docker ]] && ups+="mkdir -p $(_q "$STATE_DIR/docker-config") && chmod 700 $(_q "$STATE_DIR/docker-config")"$'\n'
            ups+="mkdir -p $(_q "$(dirname "$mark")") && : > $(_q "$mark")"$'\n'
            ups+="( ${up} )"$'\n'"$(_ctr_verify_cmd "$engine" "$f8")"$'\n'
            u_ups+="if [ -e $(_q "$mark") ]; then ( ${up} ); fi"$'\n'
            names+=("$f8")
        else
            # f1 name, f2 original command, f3 new command, f4 restart policy,
            # f5 container ID
            old="${f1}-before-fix"
            pre+="if podman container exists $(_q "$old"); then echo $(_sq "A container named $old already exists; remove it first.") >&2; exit 1; fi"$'\n'
            pre+="[ \"\$(podman inspect --format '{{.Id}}' $(_q "$f1") 2>/dev/null)\" = $(_q "$f5") ] || { echo $(_sq "$f1 changed since the check; run the check again.") >&2; exit 1; }"$'\n'
            runs+="podman stop -t 15 $(_q "$f1")"$'\n'"podman rename $(_q "$f1") $(_q "$old") || { podman start $(_q "$f1"); exit 1; }"$'\n'
            [[ -n "$f4" && "$f4" != no ]] && runs+="podman update --restart=no $(_q "$old")"$'\n'
            runs+="${f3}"$'\n'"$(_ctr_verify_cmd podman "$f1")"$'\n'
            u_runs+="if [ \"\$(podman inspect --format '{{.Id}}' $(_q "$old") 2>/dev/null)\" = $(_q "$f5") ]; then"$'\n'
            u_runs+="  podman rm -f $(_q "$f1"); podman rename $(_q "$old") $(_q "$f1")"$'\n'
            [[ -n "$f4" && "$f4" != no ]] && u_runs+="  podman update --restart=$(_q "$f4") $(_q "$f1")"$'\n'
            u_runs+="  podman start $(_q "$f1")"$'\n'
            u_runs+="else echo $(_sq "$old is gone (or not the original), so $f1 was left as it is.") >&2; undo_failed=1; fi"$'\n'
            names+=("$f1"); runlist+=("$f1")
        fi
    done
    [[ ${#names[@]} -gt 0 ]] || return 1
    # Undo: Docker's old default comes back before services are recreated,
    # so its restart does not stop them again.
    local script="${pre}${dflt}${edits}${ups}${runs}" undo="undo_failed=0"$'\n'"${u_runs}${u_files}${u_dflt}${u_ups}"
    undo+='[ "$undo_failed" -eq 0 ]'$'\n'
    CHANGE_AFTER="published on 127.0.0.1 only: $(_join ', ' "${names[@]}")"
    [[ ${#runlist[@]} -gt 0 ]] && CHANGE_WARN+=("new container|$(_join ', ' "${runlist[@]}") start as new containers: anything the old ones wrote outside a volume or bind mount is not in the new ones. The old containers are kept, stopped, as NAME-before-fix (undo puts them back); remove them with 'podman rm' once all is well.")
    apply_change "${script%$'\n'}" "${undo%$'\n'}" \
        "Named volumes and bind mounts are kept. To let other devices in again later, publish the port on 0.0.0.0 (or undo this)."
}

# ====================== GAME STREAMING ======================
readonly _SUNSHINE_UNITS=(app-dev.lizardbyte.app.Sunshine.service homebrew.sunshine.service sunshine.service)

_sunshine_installed() {
    local u="$1"
    flatpak info dev.lizardbyte.app.Sunshine >/dev/null 2>&1 && return 0
    _as_user "$u" flatpak info --user dev.lizardbyte.app.Sunshine >/dev/null 2>&1 && return 0
    [[ -e /home/linuxbrew/.linuxbrew/opt/sunshine || -e /home/linuxbrew/.linuxbrew/opt/sunshine-beta ]] && return 0
    _have sunshine
}

# _sunshine_conf_dir USER — the config folder Sunshine uses for USER.
_sunshine_conf_dir() {
    local h
    h=$(_home_of "$1")
    if [[ -d "$h/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine" ]]; then
        printf '%s' "$h/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine"
    else
        printf '%s' "$h/.config/sunshine"
    fi
}

# _sunshine_conf_get USER FILE KEY — read as USER (see _user_cat).
_sunshine_conf_get() {
    _user_cat "$1" "$2" | awk -F= -v k="$3" '{ key = $1; gsub(/^[ \t]+|[ \t]+$/, "", key) } key == k { v = substr($0, index($0, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); val = v } END { print val }' 2>/dev/null || true
}

check_game_streaming() {
    local u="$DESKTOP_USER"
    if [[ -z "$u" ]]; then
        mark_skip "no desktop user to check Sunshine for"
        return 0
    fi
    if ! _sunshine_installed "$u"; then
        mark_na "Sunshine is not installed (Steam Remote Play needs no setup here)"
        return 0
    fi
    local -a units=()
    local unit
    for unit in "${_SUNSHINE_UNITS[@]}"; do
        if [[ "$(_user_unit_state "$u" "$unit")" == "enabled" ]] || _user_unit_active "$u" "$unit"; then
            units+=("$unit")
        fi
    done
    if [[ ${#units[@]} -eq 0 ]]; then
        check_note "Sunshine is installed but not set to start"
        return 0
    fi
    if [[ "$USE_STREAMING" -ne 1 ]]; then
        finding medium "Sunshine starts automatically, but you don't stream games" \
"${units[*]} is enabled for ${u}. Sunshine lets paired devices see and control
this desktop; if you don't use it, it is an unneeded way in." \
"systemctl --user disable --now ${units[*]}   (or: ujust setup-sunshine)" \
            fix_user_units_off "$u" "${units[@]}"
        finding_change "${units[*]} enabled for ${u}" "Sunshine disabled and stopped" \
            "ends streams|A running stream ends, and Moonlight can no longer connect until you turn Sunshine on again."
        finding_affects \
            "sunshine!|Sunshine no longer starts on its own; Moonlight cannot connect until you start it again."
        return 0
    fi

    local dir conf state origin upnp
    dir=$(_sunshine_conf_dir "$u")
    conf="$dir/sunshine.conf"
    state="$dir/sunshine_state.json"
    origin=$(_sunshine_conf_get "$u" "$conf" origin_web_ui_allowed)
    upnp=$(_sunshine_conf_get "$u" "$conf" upnp)
    check_note "Sunshine: ${units[*]}; web UI allowed from: ${origin:-lan (default)}; UPnP: ${upnp:-off (default)}"

    if [[ "${origin,,}" == "wan" ]]; then
        finding high "Sunshine's admin page accepts connections from the internet" \
"origin_web_ui_allowed = wan in ${conf}: the admin page (https://this-pc:47990),
which can run commands as you, accepts visitors from any address." \
"Set origin_web_ui_allowed = lan in ${conf} (Sunshine web UI → Configuration → Network)" \
            fix_sunshine_setting "$u" "$conf" origin_web_ui_allowed lan "${units[0]}"
        finding_change "origin_web_ui_allowed = ${origin}" "origin_web_ui_allowed = lan" \
            "restarts Sunshine|Sunshine restarts; an active stream is interrupted."
        finding_affects \
            "sunshine|The admin page works only from your home network. Streaming itself is not affected."
    fi
    if [[ "${upnp,,}" =~ ^(on|enabled|true|1|yes)$ ]]; then
        finding medium "Sunshine opens ports on your router (UPnP)" \
"upnp is on in ${conf}: Sunshine asks your router to forward its streaming ports
from the internet to this PC. Only needed to stream from outside your home - a
VPN such as Tailscale (ujust enable-tailscale) is the safer way to do that." \
"Set upnp = off in ${conf} (Sunshine web UI → Configuration → Network)" \
            fix_sunshine_setting "$u" "$conf" upnp off "${units[0]}"
        finding_change "upnp = ${upnp}" "upnp = off (stream from outside through a VPN instead)" \
            "restarts Sunshine|Sunshine restarts; an active stream is interrupted." \
            "no streaming from outside|Streaming from outside your home stops working unless you use a VPN such as Tailscale."
        finding_affects \
            "sunshine!|Streaming from outside your home stops unless you use a VPN such as Tailscale. Streaming at home is not affected."
    fi
    if ! _user_cat "$u" "$state" | grep -q '"username"'; then
        finding medium "Sunshine has no admin login yet" \
"Sunshine is running, but no admin user is set. Whoever opens its admin page
first creates the login and can then pair devices and run commands." \
"Open https://localhost:47990 on this PC now and create the admin user."
        finding_change "no admin user" "admin user created on this PC (manual)"
        finding_affects \
            "sunshine|Nothing changes for streaming; you set a login on Sunshine's admin page."
    fi
    if _reachable tcp "0.0.0.0" 47990; then
        finding low "Sunshine's admin page is reachable from your network" \
"The firewall lets other devices reach port 47990. Pairing and settings can be
done on this PC itself; streaming does not need this port." \
"Remove 47990/tcp from the firewall zone (Firewall app), or apply the firewall fix."
        finding_change "47990/tcp open to the network" "47990/tcp closed (pair and configure on this PC)"
        finding_affects \
            "sunshine|Pair devices and change settings on this PC only. Streaming is not affected."
    fi
    return 0
}

# fix_user_units_off USER UNIT... — disable user services.
fix_user_units_off() {
    local u="$1" q="" unit
    shift
    for unit in "$@"; do q+=" $(_q "$unit")"; done
    apply_change "systemctl --user -M $(_q "$u")@ disable --now${q}" \
                 "systemctl --user -M $(_q "$u")@ enable --now${q}"
}

# fix_sunshine_setting USER CONF KEY VALUE UNIT — set KEY = VALUE (as USER).
fix_sunshine_setting() {
    local u="$1" conf="$2" key="$3" val="$4" unit="$5" qu qc
    qu=$(_q "$u"); qc=$(_q "$conf")
    apply_change "$(_backup_cmd "$conf" "$u")
if runuser -u ${qu} -- grep -qE '^[[:space:]]*${key}[[:space:]]*=' ${qc}; then
  runuser -u ${qu} -- sed -i 's/^[[:space:]]*${key}[[:space:]]*=.*/${key} = ${val}/' ${qc}
else
  runuser -u ${qu} -- sh -c 'echo \"${key} = ${val}\" >> \"\$1\"' sh ${qc}
fi
systemctl --user -M ${qu}@ try-restart $(_q "$unit")" \
        "$(_restore_cmd "$conf" "$u")
systemctl --user -M ${qu}@ try-restart $(_q "$unit")"
}
