#!/usr/bin/env bash
# SecureDesk installer
#   - asks where to install (/appdata, the current folder, or any other folder)
#   - installs Docker if it is missing
#   - checks the host ports (HTTP / HTTPS) and picks a free one if they are busy; nothing running is ever stopped
#   - downloads the compose files, starts SecureDesk and checks that the login page answers
# Everything is written to a log file (shown at the end, copy kept in the install folder as install.log).
#
# Run:   sudo bash SecureDesk-Installation.sh
# Options: --dir PATH   --http-port N   --https-port N   --host NAME_OR_IP   --yes (no questions)   --help

VERSION="1.0"
REPO_RAW="https://raw.githubusercontent.com/shubhamwaghagkmf010/securedesk/main"
LOG="/tmp/securedesk-install-$(date +%Y%m%d-%H%M%S).log"
DIR="${SECUREDESK_DIR:-}"
REQ_HTTP="${SECUREDESK_HTTP_PORT:-}"
REQ_HTTPS="${SECUREDESK_HTTPS_PORT:-}"
HOST_ARG="${SECUREDESK_HOST:-}"
ASSUME_YES=0
SRC_DIR=""
[ -n "${BASH_SOURCE[0]:-}" ] && SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;;
    --http-port) REQ_HTTP="$2"; shift 2;;
    --https-port) REQ_HTTPS="$2"; shift 2;;
    --host) HOST_ARG="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    --help|-h) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown option: $1 (try --help)"; exit 2;;
  esac
done

# ---------- look and feel ----------
TTY=0; [ -t 1 ] && TTY=1
if [ "$TTY" = 1 ]; then
  RST=$'\033[0m'; BLD=$'\033[1m'; DIM=$'\033[2m'
  GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; MAG=$'\033[35m'
else
  RST=""; BLD=""; DIM=""; GRN=""; YEL=""; RED=""; CYN=""; MAG=""
fi

ts()    { date +%H:%M:%S; }
_emit() { printf '%s%s%s %s%s%s %s\n' "$DIM" "$(ts)" "$RST" "$2" "$1" "$RST" "$3"; printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$3" >>"$LOG"; }
ok()    { _emit "[ OK ]" "$GRN" "$*"; }
info()  { _emit "[INFO]" "$CYN" "$*"; }
warn()  { _emit "[WARN]" "$YEL" "$*"; }
fail()  { _emit "[FAIL]" "$RED" "$*"; }
step()  { printf '\n%s%s>> Step %s%s\n' "$BLD" "$MAG" "$*" "$RST"; printf '\n== Step %s\n' "$*" >>"$LOG"; }
die()   { fail "$*"; fail "Full log: $LOG"; exit 1; }
trap 'echo; fail "Interrupted"; exit 130' INT

banner() {
  local colors=(51 45 39 33 69 105) i=0 line
  local art=(
'  ____                          ____            _    '
' / ___|  ___  ___ _   _ _ __ ___|  _ \  ___  ___| | __'
" \\___ \\ / _ \\/ __| | | | '__/ _ \\ | | |/ _ \\/ __| |/ /"
'  ___) |  __/ (__| |_| | | |  __/ |_| |  __/\__ \   < '
' |____/ \___|\___|\__,_|_|  \___|____/ \___||___/_|\_\'
  )
  echo
  for line in "${art[@]}"; do
    if [ "$TTY" = 1 ]; then printf '\033[38;5;%sm%s\033[0m\n' "${colors[$i]}" "$line"; sleep 0.08
    else printf '%s\n' "$line"; fi
    i=$((i+1))
  done
  if [ "$TTY" = 1 ]; then printf '\033[38;5;105m  ----------------------------------------------------\033[0m\n'
  else echo "  ----------------------------------------------------"; fi
  printf '  %sSecure remote support  |  installer v%s  |  %s%s\n\n' "$DIM" "$VERSION" "$(date '+%F %H:%M')" "$RST"
  printf 'SecureDesk installer v%s started %s\n' "$VERSION" "$(date '+%F %T')" >>"$LOG"
}

run_step() {  # run_step "message" command args...   (animated, output goes to the log)
  local msg="$1"; shift
  local pid rc i=0 fr='-\|/'
  printf -- '--- %s: %s\n' "$msg" "$*" >>"$LOG"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  if [ "$TTY" = 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s ' "$CYN" "${fr:i%4:1}" "$RST" "$msg"; i=$((i+1)); sleep 0.15
    done
    printf '\r\033[K'
  fi
  wait "$pid"; rc=$?
  if [ $rc -eq 0 ]; then ok "$msg"; return 0; fi
  fail "$msg (exit code $rc)  last lines of the log:"
  tail -n 12 "$LOG" | sed 's/^/          /'
  return $rc
}

HAVE_TTY=0; (exec </dev/tty) 2>/dev/null && HAVE_TTY=1
ask() {  # ask "prompt" "default"  -> REPLY
  if [ "$ASSUME_YES" = 1 ] || [ "$HAVE_TTY" = 0 ]; then REPLY="$2"; return; fi
  read -r -p "$1" REPLY </dev/tty
  REPLY="${REPLY:-$2}"
}

free_gb() {  # free space (GB) of the nearest existing parent of $1
  local p="$1"
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
  df -Pk "$p" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}'
}

# ---------- ports ----------
port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then ss -H -ltn "( sport = :$p )" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p$"
  else (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}
port_owner() {
  local o=""
  command -v ss >/dev/null 2>&1 && o="$(ss -H -ltnp "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -n1 | cut -d'"' -f2)"
  case "$o" in docker-proxy) o="docker-proxy (a container)";; "") o="another program";; esac
  echo "$o"
}
port_usable() {  # port_usable PORT CURRENT_OWN_PORT AVOID
  [ "$1" = "$3" ] && return 1
  if port_busy "$1"; then [ "$OURS" = 1 ] && [ "$1" = "$2" ] && return 0; return 1; fi
  return 0
}
pick_port() {  # pick_port LABEL PREFERRED CURRENT AVOID ALT_START  -> PICKED
  local label="$1" pref="$2" cur="$3" avoid="$4" alt="$5" q i
  if port_usable "$pref" "$cur" "$avoid"; then
    if [ "$OURS" = 1 ] && [ "$pref" = "$cur" ] && port_busy "$pref"; then ok "$label port $pref is already used by this SecureDesk (kept)"
    else ok "$label port $pref is free"; fi
    PICKED="$pref"; return 0
  fi
  if [ "$pref" = "$avoid" ]; then warn "$label port $pref is the same as the other SecureDesk port"
  else warn "$label port $pref is busy - used by $(port_owner "$pref")"; fi
  for i in $(seq 0 199); do
    q=$((alt + i))
    if port_usable "$q" "$cur" "$avoid"; then
      ok "$label port switched: $pref -> $q (free)"; PICKED="$q"; return 0
    fi
  done
  die "No free $label port found between $alt and $((alt + 199))"
}

env_get() { [ -f "$DIR/.env" ] && grep -E "^$1=" "$DIR/.env" | tail -n1 | cut -d= -f2-; }
env_set() {
  if grep -qE "^$1=" "$DIR/.env"; then sed -i "s|^$1=.*|$1=$2|" "$DIR/.env"; else echo "$1=$2" >>"$DIR/.env"; fi
}

# ======================================================================
banner

step "1/8  Checking this server"
SU=""
if [ "$(id -u)" != 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SU="sudo"; warn "Not running as root - using sudo where needed"; else warn "Not running as root and sudo is missing"; fi
fi
[ -r /etc/os-release ] && . /etc/os-release
ok "System: ${PRETTY_NAME:-$(uname -sr)}  ($(uname -m))"
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "curl or wget is needed. Install one (apt install curl) and run again."
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/docker-compose.yml" ]; then ok "Using the files next to this script"
elif curl -fsI --max-time 8 "$REPO_RAW/docker-compose.yml" >/dev/null 2>&1; then ok "GitHub is reachable (files will be downloaded)"
else die "Cannot reach GitHub ($REPO_RAW). Check the internet connection / proxy."; fi
HOSTIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$HOSTIP" ] && ok "Server IP: $HOSTIP"

step "2/8  Install location"
if [ -z "$DIR" ]; then
  if [ -d /appdata ]; then DEF=1; N1="found"; else DEF=2; N1="not found - will be created"; fi
  CUR_TARGET="$PWD/securedesk"
  if [ -f "$PWD/docker-compose.yml" ] && grep -q securedesk "$PWD/docker-compose.yml" 2>/dev/null; then CUR_TARGET="$PWD"; fi
  echo
  printf '   %s1)%s /appdata/securedesk      %s(/appdata %s, free %s GB)%s\n' "$BLD" "$RST" "$DIM" "$N1" "$(free_gb /appdata/securedesk)" "$RST"
  printf '   %s2)%s %s      %s(current folder, free %s GB)%s\n' "$BLD" "$RST" "$CUR_TARGET" "$DIM" "$(free_gb "$CUR_TARGET")" "$RST"
  printf '   %s3)%s Other location           %s(you type the folder)%s\n\n' "$BLD" "$RST" "$DIM" "$RST"
  while :; do
    ask "   Choose 1, 2 or 3 [$DEF]: " "$DEF"
    case "$REPLY" in
      1) DIR="/appdata/securedesk"; break;;
      2) DIR="$CUR_TARGET"; break;;
      3) ask "   Full folder path: " ""
         [ -z "$REPLY" ] && { warn "No path typed"; continue; }
         DIR="$REPLY"; break;;
      *) warn "Please type 1, 2 or 3";;
    esac
  done
fi
case "$DIR" in "~"*) DIR="$HOME${DIR#\~}";; esac
case "$DIR" in /*) ;; *) DIR="$PWD/$DIR";; esac
DIR="${DIR%/}"
if [ -z "$DIR" ] || [ "$DIR" = "/" ]; then die "Refusing to install into /"; fi
mkdir -p "$DIR" 2>>"$LOG" || $SU mkdir -p "$DIR" 2>>"$LOG" || die "Cannot create $DIR (permissions?). Run with sudo or choose another folder."
if [ -n "$SU" ] && [ ! -w "$DIR" ]; then $SU chown "$(id -u):$(id -g)" "$DIR" 2>>"$LOG"; fi
[ -w "$DIR" ] || die "$DIR is not writable for $(id -un)."
ok "Install folder: $DIR   (free: $(free_gb "$DIR") GB)"
FREE_INT="$(free_gb "$DIR" | cut -d. -f1)"
if [ "${FREE_INT:-0}" -lt 5 ]; then
  warn "Less than 5 GB free here. The image needs about 2.5 GB."
  ask "   Continue anyway? [y/N]: " "n"
  case "$REPLY" in y|Y|yes) ;; *) die "Stopped - choose a folder with more space.";; esac
fi
cd "$DIR" || die "Cannot enter $DIR"

step "3/8  Docker"
if ! command -v docker >/dev/null 2>&1; then
  warn "Docker is not installed - installing it now"
  if command -v apt-get >/dev/null 2>&1; then
    run_step "apt update" $SU apt-get update -y || die "apt update failed"
    run_step "Installing docker.io" $SU apt-get install -y docker.io || die "Docker installation failed"
    if ! $SU docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
      run_step "Installing Docker Compose" $SU apt-get install -y docker-compose-v2 \
        || run_step "Installing Docker Compose (plugin)" $SU apt-get install -y docker-compose-plugin \
        || run_step "Installing Docker Compose (classic)" $SU apt-get install -y docker-compose \
        || die "Could not install Docker Compose"
    fi
  else
    run_step "Installing Docker (get.docker.com)" $SU bash -c 'curl -fsSL https://get.docker.com | sh' || die "Docker installation failed"
  fi
  $SU systemctl enable --now docker >>"$LOG" 2>&1 || true
else
  ok "Docker is already installed ($(docker --version 2>/dev/null | cut -d, -f1))"
fi
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if [ -n "$SU" ] && $SU docker info >/dev/null 2>&1; then DOCKER="$SU docker"
  else
    $SU systemctl start docker >>"$LOG" 2>&1; sleep 3
    if ! docker info >/dev/null 2>&1; then
      if [ -n "$SU" ] && $SU docker info >/dev/null 2>&1; then DOCKER="$SU docker"
      else die "The Docker service is not running or not allowed for this user. Try: sudo bash $0"; fi
    fi
  fi
fi
if $DOCKER compose version >/dev/null 2>&1; then COMPOSE="$DOCKER compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE="${SU:+$SU }docker-compose"
else die "Docker Compose is missing. Install it (apt install docker-compose-v2) and run again."; fi
ok "Compose command: $COMPOSE"
DROOT="$($DOCKER info --format '{{.DockerRootDir}}' 2>/dev/null)"
if [ -n "$DROOT" ]; then
  ok "Docker stores images in: $DROOT   (free: $(free_gb "$DROOT") GB)"
  if [ -d /appdata ] && [ "${DROOT#/appdata}" = "$DROOT" ]; then warn "Docker data is NOT on /appdata - images and volumes will fill $DROOT"; fi
fi

step "4/8  Ports"
OURS=0
if [ -f "$DIR/docker-compose.yml" ] && [ -n "$($COMPOSE ps -q 2>/dev/null)" ]; then
  OURS=1; info "A SecureDesk stack is already running here - its own ports are not counted as busy"
fi
CUR_HTTP="$(env_get SECUREDESK_HTTP_PORT)"; CUR_HTTPS="$(env_get SECUREDESK_HTTPS_PORT)"
PICKED=""; pick_port "HTTP " "${REQ_HTTP:-${CUR_HTTP:-80}}" "${CUR_HTTP:-0}" "0" 8080;   HTTP_PORT="$PICKED"
PICKED=""; pick_port "HTTPS" "${REQ_HTTPS:-${CUR_HTTPS:-443}}" "${CUR_HTTPS:-0}" "$HTTP_PORT" 5443; HTTPS_PORT="$PICKED"

step "5/8  Files"
fetch() {
  local f="$1" dest="$DIR/$1" tmp
  mkdir -p "$(dirname "$dest")"
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/docker-compose.yml" ] && [ -f "$SRC_DIR/$f" ]; then
    if [ "$(readlink -f "$SRC_DIR/$f")" = "$(readlink -f "$dest")" ]; then ok "$f (already in place)"; return 0; fi
    tmp="$SRC_DIR/$f"
  else
    tmp="$dest.download"
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 "$REPO_RAW/$f" -o "$tmp" 2>>"$LOG"
    else wget -q -O "$tmp" "$REPO_RAW/$f" 2>>"$LOG"; fi
    [ -s "$tmp" ] || { rm -f "$tmp"; die "Download failed: $f"; }
  fi
  if [ -f "$dest" ] && ! cmp -s "$tmp" "$dest"; then cp "$dest" "$dest.bak-$(date +%Y%m%d%H%M%S)"; warn "$f changed - old copy saved as .bak"; fi
  if [ "$tmp" = "$dest.download" ]; then mv "$tmp" "$dest"; else cp "$tmp" "$dest"; fi
  ok "$f"
}
for f in docker-compose.yml Caddyfile .env.example apply-ad.sh ad/ad-config.env.example ad/ad-users.txt.example; do fetch "$f"; done
chmod +x "$DIR/apply-ad.sh" 2>/dev/null

if [ ! -f "$DIR/.env" ]; then
  cp "$DIR/.env.example" "$DIR/.env"
  HOST_DEF="${HOST_ARG:-${HOSTIP:-localhost}}"
  if [ -z "$HOST_ARG" ]; then
    ask "   Name or IP people will type in the browser [$HOST_DEF]: " "$HOST_DEF"; HOST_ARG="$REPLY"
  fi
  env_set SECUREDESK_HOST "$HOST_ARG"
  ok "Created .env (host: $HOST_ARG)"
else
  cp "$DIR/.env" "$DIR/.env.bak-$(date +%Y%m%d%H%M%S)"
  [ -n "$HOST_ARG" ] && env_set SECUREDESK_HOST "$HOST_ARG"
  ok "Existing .env kept (a backup copy was saved)"
fi
env_set SECUREDESK_HTTP_PORT "$HTTP_PORT"
env_set SECUREDESK_HTTPS_PORT "$HTTPS_PORT"
HOST_FINAL="$(env_get SECUREDESK_HOST)"; HOST_FINAL="${HOST_FINAL:-localhost}"
ok "Ports written to .env: HTTP $HTTP_PORT, HTTPS $HTTPS_PORT"

step "6/8  Downloading SecureDesk (this is the long step)"
run_step "Pulling images" $COMPOSE pull || die "Image download failed (internet / Docker Hub?)"

step "7/8  Starting"
run_step "Starting containers" $COMPOSE up -d || die "Could not start the containers"
wait_ready() {
  local i code
  for i in $(seq 1 60); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:$HTTPS_PORT/" 2>/dev/null)"
    case "$code" in 2*|3*) return 0;; esac
    sleep 3
  done
  return 1
}

step "8/8  Checking that it works"
if run_step "Waiting for the SecureDesk login page" wait_ready; then
  ok "SecureDesk answers on https://127.0.0.1:$HTTPS_PORT"
else
  fail "No answer after 3 minutes. Container status and last log lines:"
  $COMPOSE ps 2>&1 | tee -a "$LOG" | sed 's/^/          /'
  $COMPOSE logs --tail 15 2>&1 | tee -a "$LOG" | sed 's/^/          /'
  die "SecureDesk did not become ready."
fi

URL="https://$HOST_FINAL"; [ "$HTTPS_PORT" != "443" ] && URL="$URL:$HTTPS_PORT"
cp "$LOG" "$DIR/install.log" 2>/dev/null && FINAL_LOG="$DIR/install.log" || FINAL_LOG="$LOG"
line() { printf '  %s|%s %-76s %s|%s\n' "$CYN" "$RST" "$1" "$CYN" "$RST"; }
echo
printf '  %s+------------------------------------------------------------------------------+%s\n' "$CYN" "$RST"
line "SecureDesk is ready"
line ""
line "Open      : $URL"
line "Login     : admin@securedesk.local"
line "Password  : SecureDesk@123   (change it after the first login)"
line ""
line "Folder    : $DIR"
line "Ports     : HTTP $HTTP_PORT  |  HTTPS $HTTPS_PORT"
line "Log       : $FINAL_LOG"
line ""
line "Active Directory login: edit ad/ad-config.env, then ./apply-ad.sh"
line "Stop / start : cd $DIR && $COMPOSE down | up -d"
printf '  %s+------------------------------------------------------------------------------+%s\n' "$CYN" "$RST"
echo
info "The browser shows a certificate warning for an IP / localhost (Caddy's own CA) - that is expected."
info "If a firewall is active, allow TCP $HTTPS_PORT (and $HTTP_PORT)."
exit 0
