#!/usr/bin/env bash
#
# deployMachine — a whole deployment in one bash script.
# Uploads a build over rsync/SSH into a timestamped release, switches the
# current symlink atomically, prunes old releases, rolls back on failure.
#
# (c) 2026 Philip Stuessel
# https://github.com/philipstuessel/deploy-machine
#
# For the full copyright and license information, please view the LICENSE
# file that was distributed with this source code.
#
set -euo pipefail

VERSION="1.1.0"

usage() {
  printf 'deployMachine %s — deploy a directory to a server over rsync/SSH.\n' "$VERSION"
  cat <<'HELP_TEXT'

USAGE
  .deploy/deployMachine.sh key="value" [key="value" ...]
  .deploy/deployMachine.sh json="config.json" ssh|list|rollback|dry_run
  .deploy/deployMachine.sh json="steps.json" key="value" ...
  .deploy/deployMachine.sh --help
  .deploy/deployMachine.sh --version

Every key="value" becomes a {{key}} placeholder, usable inside the JSON and
inside every command — including keys the script knows nothing about. A
{{placeholder}} without a value aborts the run before the first step executes.

Without json= the built-in steps run. With json= the steps come from that file,
or from inline JSON passed as the value itself.

COMMANDS
  Without one of these it deploys. Each ends the run when it is done, and each
  may be written as a bare word instead of key="true":
  deployMachine.sh json="config.json" rollback

  rollback             put current back one release, or onto a named one with
                       rollback="<release>". Nothing is uploaded, only the
                       symlink moves. A failing healthcheck_url afterwards does
                       not undo it. Needs releases on the target, which only
                       strategy="release" creates
  status               show the releases on the target, newest first: "cu" is
                       the one that is live, "re" one you can roll back to.
                       The name is the last field, so piping it through
                       awk '{print $NF}' gives bare names. list= is the same.
                       Needs releases on the target, same as rollback
  ssh                  open a shell on the target, starting in the directory
                       current points at, in ssh="<dir>" or in ssh_path=

SETTINGS
  json                 path to a config JSON, or inline JSON. Without "steps"
                       it only supplies vars and the built-in steps run
  host                 the machine to deploy to. Leave it out entirely to
                       deploy locally without SSH; passing it empty is an error
  user                 the user to log in as over SSH
  port                 SSH port (22)
  ssh_key              the private key itself, e.g. "$SSH_PRIVATE_KEY" from CI
  ssh_key_file         a file holding the private key; a leading ~/ is
                       expanded. If both are given, ssh_key wins
  known_hosts          the host's public key line, used to verify the server is
                       the one you mean. Without it the host is looked up in
                       known_hosts_file, then in ~/.ssh/known_hosts, and only
                       then taken unverified via ssh-keyscan
  known_hosts_file     a known_hosts file to look the host up in; a leading ~/
                       is expanded. Aborts if the host is not in there
  ssh_path             the directory an ssh session starts in, instead of
                       current (release) or deploy_path (sync). Takes
                       {{placeholders}}. "-" starts in the home directory and
                       sends no command at all
  source               the local directory whose contents get uploaded (dist)
  deploy_path          the directory on the server to deploy into (required)
  strategy             release: upload into a new folder, then move a symlink,
                       so going live is instant and rollback is possible.
                       sync: rsync --delete straight into deploy_path, no
                       releases and no way back (release)
  release              name of this release, used as its folder name
                       (timestamp-short commit sha)
  releases_dir         where the releases are kept ({{deploy_path}}/releases)
  release_path         this release's own folder ({{releases_dir}}/{{release}})
  current_link         the symlink that decides what is live
                       ({{deploy_path}}/current)
  keep_releases        how many releases to keep before the older ones are
                       deleted; this is also how far back you can roll (5)
  healthcheck_url      a URL to call after switching. Adds a health check to
                       the built-in steps and to a rollback
  rollback_on_failure  if a step fails after the symlink was switched, put
                       current back on the previous release (true)
  dry_run              print every command instead of running it. Changes
                       nothing and never touches the network (false)
  deps_install         auto: install rsync, ssh, jq or curl through
                       apk/apt-get/dnf when one of them is missing, which is
                       what lets a bare CI container work. never: stop and say
                       what is missing instead (auto)

STRATEGIES
  release  upload into releases/<release>, switch the current symlink
           atomically, then drop old releases. If a step fails after the
           switch, current is moved back to the previous release.
  sync     rsync --delete straight into deploy_path, which is mirrored:
           files on the server that are not in source are removed. Keeps no
           releases, so status and rollback have nothing to work on.

STEP TYPES
  upload       from, to, delete, exclude[]
  run          cmd, on: remote|local, allow_failure (any type may set it)
  symlink      target, link
  healthcheck  url, expect_status, retries, delay, timeout, on
  cleanup      keep, dir, current_link

JSON FORMAT
  {
    "vars":  { "host": "srv1", "deploy_path": "/srv/app", "source": "dist" },
    "steps": [
      { "name": "Upload", "type": "upload",
        "from": "{{source}}/", "to": "{{release_path}}/" },
      { "name": "Activate", "type": "symlink",
        "target": "{{release_path}}", "link": "{{current_link}}" }
    ]
  }
  {{name}} inserts a value from vars or from an argument. Arguments win over
  vars. Leave out "steps" and the built-in ones run.

REQUIREMENTS
  bash. rsync, ssh, jq and curl are installed on demand (deps_install=never
  turns that off).

CI VARIABLES
  CI_* (GitLab) and GITHUB_* are picked up automatically and are available
  lowercased, e.g. {{ci_commit_branch}} or {{github_ref_name}}.

BOOLEANS
  true/yes/on/1 and false/no/off/0 are accepted; anything else aborts the run.

SECRETS
  Values of keys matching *token*, *secret*, *password*, *credential* or *_key
  are replaced with *** in the log, single- and multi-line. What a step's own
  command prints is NOT filtered — keep secrets out of command output.

EXAMPLES
  .deploy/deployMachine.sh json=".deploy/example.json"
  .deploy/deployMachine.sh json=".deploy/example.json" status
  .deploy/deployMachine.sh json=".deploy/example.json" rollback
  .deploy/deployMachine.sh json=".deploy/example.json" ssh

  Everything through arguments instead, no config file:
  .deploy/deployMachine.sh deploy_path="/var/www/app" host="srv1" \
    user="deploy" ssh_key="$SSH_PRIVATE_KEY" known_hosts="$SSH_KNOWN_HOSTS"

  Try it without a server, into a local folder:
  .deploy/deployMachine.sh deploy_path="/tmp/target" source="dist" dry_run

EXIT CODES
  0  success
  1  aborted
HELP_TEXT
}

# --- output ---
if [ -n "${NO_COLOR:-}" ]; then C_R=""; C_G=""; C_Y=""; C_C=""; C_D=""; C_B=""; C_LB=""; C_0=""
else C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_D=$'\033[2m'; C_B=$'\033[1m'; C_LB=$'\033[96m'; C_0=$'\033[0m'; fi

SECRET_VALS=()
mask() {
  local s=$1 v
  if [ ${#SECRET_VALS[@]} -gt 0 ]; then
    for v in "${SECRET_VALS[@]}"; do
      [ ${#v} -ge 6 ] && s=${s//"$v"/'***'}
    done
  fi
  printf '%s' "$s"
}

compact() {
  local s
  s=$(mask "$*")
  s=$(printf '%s' "$s" | tr '\n' ' ' | tr -s ' ')
  [ ${#s} -gt 180 ] && s="${s:0:177}..."
  printf '%s' "$s"
}

CURRENT_STEP=""
MODE=deploy
NL=$'\n' 

step_start() { printf '%s\n' "${C_Y}${C_B}▸ $1${C_0} $2 $3" >&2; }
step_done()  { printf '%s\n' "${C_G}${C_B}✓ $1${C_0} $2" >&2; }
step_stop()  { printf '%s\n' "${C_R}${C_B}✗ $1${C_0} ${2:-stopped}" >&2; }

info() { printf '%s\n' "${C_C}→${C_0} $(mask "$*")" >&2; }
ok()   { printf '%s\n' "${C_G}✓${C_0} $(mask "$*")" >&2; }
warn() { printf '%s\n' "${C_Y}!${C_0} $(mask "$*")" >&2; }
dim()  { printf '%s\n' "${C_D}  $(mask "$*")${C_0}" >&2; }
die()  { printf '%s\n' "${C_R}✗${C_0} $(mask "$*")" >&2; exit 1; }
fail() { printf '%s\n' "${C_R}✗${C_0} $(mask "$*")" >&2; return 1; }

# --- variables ---
VAR_KEYS=()
VAR_VALS=()

var_index() {
  local i=0
  while [ $i -lt ${#VAR_KEYS[@]} ]; do
    [ "${VAR_KEYS[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

var_set() {
  local k=$1 v=$2 i f
  if i=$(var_index "$k"); then VAR_VALS[$i]=$v; else VAR_KEYS+=("$k"); VAR_VALS+=("$v"); fi
  if [ -n "$v" ]; then
    case "$k" in
      *token*|*secret*|*password*|*passwd*|*credential*|*_key|key)
        SECRET_VALS+=("$v")
        f=$(printf '%s' "$v" | tr '\n' ' ' | tr -s ' ')
        if [ "$f" != "$v" ]; then SECRET_VALS+=("$f"); fi
        ;;
    esac
  fi
}

var_get() {
  local i
  if i=$(var_index "$1"); then printf '%s' "${VAR_VALS[$i]}"; else printf '%s' "${2-}"; fi
}

var_default() { [ -n "$(var_get "$1")" ] || var_set "$1" "$2"; }

is_true() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    true|yes|on|1) return 0 ;;
    ''|false|no|off|0) return 1 ;;
    *) die "$2= must be true or false, got: $1" ;;
  esac
}

render() {
  local s=$1 prev k v i pass=0
  while [ $pass -lt 5 ]; do
    prev=$s
    i=0
    while [ $i -lt ${#VAR_KEYS[@]} ]; do
      k=${VAR_KEYS[$i]}; v=${VAR_VALS[$i]}
      s=${s//"{{$k}}"/$v}
      s=${s//"{{ $k }}"/$v}
      i=$((i + 1))
    done
    [ "$s" = "$prev" ] && break
    pass=$((pass + 1))
  done
  if [[ $s =~ \{\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}\} ]]; then
    die "Unknown placeholder {{${BASH_REMATCH[1]}}} — pass it as an argument or set it in \"vars\"."
  fi
  printf '%s' "$s"
}

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

is_reserved() {
  case "$1" in
    json|host|user|port|ssh_key|ssh_key_file|known_hosts|known_hosts_file) return 0 ;;
    source|deploy_path|strategy|release|releases_dir|release_path|current_link) return 0 ;;
    keep_releases|healthcheck_url|rollback_on_failure|dry_run|deps_install) return 0 ;;
    rollback|list|status|ssh|ssh_path|timestamp|ci_*|github_*) return 0 ;;
  esac
  return 1
}

check_arg_keys() {
  local hay k i=0
  hay=$JSON_RAW
  while [ $i -lt ${#VAR_KEYS[@]} ]; do hay="$hay ${VAR_VALS[$i]}"; i=$((i + 1)); done
  for k in $ARG_KEYS; do
    is_reserved "$k" && continue
    case "$hay" in *"{{$k}}"*|*"{{ $k }}"*) continue ;; esac
    die "unknown key $k= — not a setting, and no {{$k}} uses it. Typo? See --help."
  done
}

# --- dependencies ---
PKG_UPDATED=false
ensure_tool() {
  local tool=$1 pkg=$2
  command -v "$tool" >/dev/null 2>&1 && return 0
  [ "$(var_get deps_install auto)" = "auto" ] || die "$tool is missing and deps_install=never."
  info "$tool is missing — installing $pkg"
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$pkg" >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    [ "$PKG_UPDATED" = true ] || { apt-get update -qq >/dev/null; PKG_UPDATED=true; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$pkg" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$pkg" >/dev/null
  else
    die "$tool is missing and no known package manager (apk/apt-get/dnf) is available."
  fi
  command -v "$tool" >/dev/null 2>&1 || die "$tool could not be installed."
}

# --- ssh ---
TMP_KEY=""
TMP_HOSTS=""
SSH_ARGS=()

setup_ssh() {
  [ -n "$HOST" ] || return 0
  ensure_tool ssh openssh-client
  local keyfile
  if [ -n "$(var_get ssh_key)" ]; then
    TMP_KEY=$(mktemp)
    chmod 600 "$TMP_KEY"
    printf '%s\n' "$(var_get ssh_key)" | tr -d '\r' > "$TMP_KEY"
    keyfile=$TMP_KEY
  else
    keyfile=$(var_get ssh_key_file)
    case "$keyfile" in "~/"*) keyfile="$HOME/${keyfile#\~/}" ;; esac
  fi
  if [ -n "$keyfile" ] && [ ! -r "$keyfile" ]; then die "SSH key is not readable: $keyfile"; fi

  TMP_HOSTS=$(mktemp)
  local kh khfile khname
  kh=$(var_get known_hosts)
  khfile=$(var_get known_hosts_file)
  case "$khfile" in "~/"*) khfile="$HOME/${khfile#\~/}" ;; esac
  if [ "$PORT" = "22" ]; then khname=$HOST; else khname="[$HOST]:$PORT"; fi

  if [ -n "$kh" ]; then
    printf '%s\n' "$kh" | tr -d '\r' > "$TMP_HOSTS"
  else
    if [ -n "$khfile" ] && [ ! -r "$khfile" ]; then die "known_hosts_file is not readable: $khfile"; fi
    if [ -z "$khfile" ] && [ -r "$HOME/.ssh/known_hosts" ]; then khfile="$HOME/.ssh/known_hosts"; fi
    if [ -n "$khfile" ] && command -v ssh-keygen >/dev/null 2>&1; then
      ssh-keygen -F "$khname" -f "$khfile" 2>/dev/null | grep -v '^#' > "$TMP_HOSTS" || true
    fi
    if [ -s "$TMP_HOSTS" ]; then
      dim "host key for $khname taken from $khfile"
    elif [ -n "$(var_get known_hosts_file)" ]; then
      die "no host key for $khname in $khfile — add it, or pass known_hosts= directly."
    elif [ "$DRY_RUN" = "true" ]; then
      dim "[dry-run] skipping ssh-keyscan"
    else
      warn "no host key for $khname on this machine — accepting it via ssh-keyscan (no protection against MITM)."
      ssh-keyscan -p "$PORT" -H "$HOST" > "$TMP_HOSTS" 2>/dev/null || die "ssh-keyscan for $HOST:$PORT failed."
      [ -s "$TMP_HOSTS" ] || die "ssh-keyscan returned no host key for $HOST:$PORT."
    fi
  fi

  SSH_ARGS=(-o BatchMode=yes -o LogLevel=ERROR -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$TMP_HOSTS"
            -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p "$PORT")
  if [ -n "$keyfile" ]; then
    SSH_ARGS+=(-i "$keyfile" -o IdentitiesOnly=yes)
  else
    die "no ssh_key= or ssh_key_file= given — set one, or leave host= empty for a local deploy."
  fi
}

run_cmd() {
  dim "\$ $(compact "$@")"
  [ "$DRY_RUN" = "true" ] && return 0
  "$@"
}

remote_exec() {
  if [ -n "$HOST" ]; then
    run_cmd ssh "${SSH_ARGS[@]}" "$USR@$HOST" "$1"
  else
    run_cmd sh -c "$1"
  fi
}

remote_capture() {
  if [ -n "$HOST" ]; then
    ssh "${SSH_ARGS[@]}" "$USR@$HOST" "$1" 2>/dev/null || true
  else
    sh -c "$1" 2>/dev/null || true
  fi
}

# --- steps ---
STEP_I=0
JSON_RAW=""
jq_q() { printf '%s' "$JSON_RAW" | jq "$@"; }
step_get() { jq_q -r --argjson i "$STEP_I" --arg f "$1" '(.steps[$i][$f] // empty) | if type == "boolean" or type == "number" then tostring else . end'; }
step_val() { local v; v=$(step_get "$1"); [ -n "$v" ] && render "$v" || printf '%s' "${2-}"; }
step_list() { jq_q -r --argjson i "$STEP_I" --arg f "$1" '(.steps[$i][$f] // [])[]'; }

step_upload() {
  local from to opts=() ex
  from=$(step_val from); to=$(step_val to)
  [ -n "$from" ] || die "upload step without \"from\"."
  [ -n "$to" ] || die "upload step without \"to\"."
  [ -e "${from%/}" ] || { fail "source not found: ${from%/} (is the build artifact missing?)"; return; }
  ensure_tool rsync rsync
  opts=(-a --human-readable)
  is_true "$(step_val delete)" delete && opts+=(--delete)
  while IFS= read -r ex; do
    [ -n "$ex" ] && opts+=(--exclude="$(render "$ex")")
  done <<< "$(step_list exclude)"
  remote_exec "mkdir -p $(shq "${to%/}")"
  if [ -n "$HOST" ]; then
    run_cmd rsync "${opts[@]}" -e "ssh ${SSH_ARGS[*]}" "$from" "$USR@$HOST:$to"
  else
    run_cmd rsync "${opts[@]}" "$from" "$to"
  fi
}

SWITCHED=false
PREV_TARGET=""

# mv follows a symlink to a directory, so -T (GNU) or -h (BSD) is required
symlink_switch() {
  local target=$1 link=$2
  remote_exec "set -e
if [ ! -e $(shq "$target") ]; then echo 'switch target does not exist' >&2; exit 1; fi
if [ -e $(shq "$link") ] && [ ! -L $(shq "$link") ]; then echo 'link exists and is not a symlink' >&2; exit 1; fi
ln -sfn $(shq "$target") $(shq "$link.tmp")
mv -Tf $(shq "$link.tmp") $(shq "$link") 2>/dev/null \
  || mv -hf $(shq "$link.tmp") $(shq "$link") 2>/dev/null \
  || { rm -f $(shq "$link.tmp"); ln -sfn $(shq "$target") $(shq "$link"); }
[ \"\$(readlink $(shq "$link"))\" = $(shq "$target") ] || { echo 'symlink does not point at the new target' >&2; exit 1; }"
}

step_symlink() {
  local target link
  target=$(step_val target "$RELEASE_PATH")
  link=$(step_val link "$CURRENT_LINK")
  if [ "$link" = "$CURRENT_LINK" ]; then
    if [ "$DRY_RUN" != "true" ]; then
      PREV_TARGET=$(remote_capture "readlink $(shq "$link") 2>/dev/null || true")
      case "$PREV_TARGET" in *"$NL"*) PREV_TARGET="" ;; esac
    fi
    SWITCHED=true
  fi
  symlink_switch "$target" "$link"
}

step_run() {
  local cmd on
  cmd=$(step_val cmd)
  [ -n "$cmd" ] || die "run step without \"cmd\"."
  on=$(step_val on remote)
  if [ "$on" = "local" ]; then run_cmd sh -c "$cmd"; else remote_exec "$cmd"; fi
}

step_healthcheck() {
  local url expect retries delay timeout on i code
  url=$(step_val url "$(var_get healthcheck_url)")
  [ -n "$url" ] || die "healthcheck step without \"url\"."
  expect=$(step_val expect_status 200)
  retries=$(step_val retries 5)
  delay=$(step_val delay 3)
  timeout=$(step_val timeout 10)
  on=$(step_val on local)
  case "$expect$retries$delay$timeout" in
    ''|*[!0-9]*) die "healthcheck: expect_status, retries, delay and timeout must be numbers." ;;
  esac
  if [ "$DRY_RUN" = "true" ]; then dim "[dry-run] healthcheck $url expecting $expect"; return 0; fi
  ensure_tool curl curl
  i=1
  while [ "$i" -le "$retries" ]; do
    if [ "$on" = "remote" ]; then
      code=$(remote_capture "curl -sS -o /dev/null -w '%{http_code}' --max-time $(shq "$timeout") $(shq "$url")")
    else
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$timeout" "$url" 2>/dev/null || true)
    fi
    [ "$code" = "$expect" ] && { dim "HTTP $code from $url"; return 0; }
    dim "attempt $i/$retries: HTTP ${code:-000} (expected $expect)"
    i=$((i + 1))
    [ "$i" -le "$retries" ] && sleep "$delay"
  done
  fail "healthcheck failed: $url returned ${code:-000}, expected $expect"
}

step_cleanup() {
  local keep dir link
  keep=$(step_val keep "$(var_get keep_releases)")
  dir=$(step_val dir "$(var_get releases_dir)")
  link=$(step_val current_link "$CURRENT_LINK")
  case "$keep" in ''|*[!0-9]*) die "cleanup: keep must be a number, got: $keep" ;; esac
  [ "$keep" -lt 1 ] && die "cleanup: keep must be >= 1."
  remote_exec "set -e
cd $(shq "$dir") 2>/dev/null || exit 0
cur=\$(readlink $(shq "$link") 2>/dev/null || true)
cur=\$(basename \"\${cur:-none}\")
ls -1 | sort -r | tail -n +$((keep + 1)) | while IFS= read -r r; do
  [ \"\$r\" = \"\$cur\" ] && continue
  rm -rf -- \"\$r\" || { echo \"could not remove: \$r\" >&2; continue; }
  echo \"removed: \$r\"
done
exit 0"
}

# --- rollback ---
sync_hint() {
  [ "$STRATEGY" = "release" ] && { printf ' — nothing deployed there yet.'; return 0; }
  printf ' — strategy=sync deploys straight into %s and keeps no releases.' "$DEPLOY_PATH"
}

list_releases() { remote_capture "ls -1 $(shq "$(var_get releases_dir)") 2>/dev/null | sort -r"; }

current_release() {
  local t
  t=$(remote_capture "readlink $(shq "$CURRENT_LINK") 2>/dev/null || true")
  printf '%s' "${t##*/}"
}

mode_status() {
  local cur rels r stamp lb="" rst=""
  [ -t 1 ] && { lb=$C_LB; rst=$C_0; }
  cur=$(current_release)
  rels=$(list_releases)
  [ -n "$rels" ] || die "no releases found in $(var_get releases_dir)$(sync_hint)"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
        stamp="${r:0:4}.${r:4:2}.${r:6:2} ${r:8:2}:${r:10:2}" ;;
      *) stamp="---------- -----" ;;
    esac
    if [ "$r" = "$cur" ]; then
      printf '%s\n' "${lb}cu  $stamp  $r${rst}"
    else
      printf '%s\n' "re  $stamp  $r"
    fi
  done <<< "$rels"
}

mode_ssh() {
  local dir rc
  [ -n "$HOST" ] || die "ssh= needs a host= to connect to."
  dir=$(var_get ssh)
  case "$dir" in
    true|yes|on|1)
      dir=$(var_get ssh_path)
      if [ -z "$dir" ]; then
        if [ "$STRATEGY" = "release" ]; then dir=$CURRENT_LINK; else dir=$DEPLOY_PATH; fi
      fi ;;
  esac
  case "$dir" in -|none) dir="" ;; *) dir=$(render "$dir") ;; esac
  info "ssh $USR@$HOST${dir:+ → $dir}"
  if [ "$DRY_RUN" = "true" ]; then
    if [ -n "$dir" ]; then
      dim "[dry-run] ssh -t ${SSH_ARGS[*]} $USR@$HOST cd $(shq "$dir") ... exec \$SHELL -l|-i"
    else
      dim "[dry-run] ssh -t ${SSH_ARGS[*]} $USR@$HOST"
    fi
    return 0
  fi
  set +e
  if [ -n "$dir" ]; then
    ssh -t "${SSH_ARGS[@]}" "$USR@$HOST" "cd $(shq "$dir") || exit 1
for s in \"\$SHELL\" /bin/bash /bin/sh; do
  [ -x \"\$s\" ] || continue
  for p in \"\$HOME/.bash_profile\" \"\$HOME/.bash_login\" \"\$HOME/.profile\"; do
    [ -r \"\$p\" ] && exec \"\$s\" -l
  done
  exec \"\$s\" -i
done
echo 'no usable shell: tried \$SHELL, /bin/bash, /bin/sh' >&2
exit 127"
  else
    ssh -t "${SSH_ARGS[@]}" "$USR@$HOST"
  fi
  rc=$?
  set -e
  [ $rc -eq 255 ] && die "ssh connection to $USR@$HOST:$PORT failed."
  return 0
}

mode_rollback() {
  local want cur rels target
  want=$(var_get rollback)
  cur=$(current_release)
  rels=$(list_releases)
  [ -n "$rels" ] || die "no releases found in $(var_get releases_dir)$(sync_hint)"
  case "$want" in
    ''|true|previous)
      [ -n "$cur" ] || die "$CURRENT_LINK does not point at a release — pass rollback=\"<release>\"."
      target=$(printf '%s\n' "$rels" | awk -v c="$cur" 'seen { print; exit } $0 == c { seen = 1 }')
      [ -n "$target" ] || die "no release older than $cur found."
      ;;
    *)
      target=$want
      printf '%s\n' "$rels" | grep -qxF -- "$target" || die "release not found: $target"
      ;;
  esac
  if [ "$target" = "$cur" ]; then
    ok "current already points at $target — nothing to do."
    return 0
  fi
  info "rollback ${cur:-?} → $target"
  symlink_switch "$(var_get releases_dir)/$target" "$CURRENT_LINK"
  if [ -n "$(var_get healthcheck_url)" ]; then
    ensure_tool jq jq
    JSON_RAW='{"steps":[{"type":"healthcheck","url":"{{healthcheck_url}}"}]}'
    STEP_I=0
    step_healthcheck || die "healthcheck failed after rollback — current still points at $target"
  fi
  ok "rollback done: current → $target"
}

# --- json ---
load_json() {
  local src k v
  src=$(var_get json)
  [ -n "$src" ] || return 0
  ensure_tool jq jq
  if [ -f "$src" ]; then JSON_RAW=$(cat "$src"); else JSON_RAW=$src; fi
  printf '%s' "$JSON_RAW" | jq -e 'type == "object" and (if has("steps") then (.steps | type) == "array" else true end)' >/dev/null 2>&1 \
    || die "json= is neither a readable file nor a JSON object (with \"steps\" as an array, if present): $src"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    v=$(jq_q -r --arg k "$k" '.vars[$k] | if type == "boolean" or type == "number" then tostring else . end')
    var_default "$k" "$v"
  done <<< "$(jq_q -r '(.vars // {}) | keys[]')"
}

default_steps() {
  local hc="" steps base
  ensure_tool jq jq
  [ -n "$(var_get healthcheck_url)" ] && hc=',{"name":"Health check","type":"healthcheck","url":"{{healthcheck_url}}"}'
  if [ "$STRATEGY" = "release" ]; then
    steps='[
      {"name":"Upload release","type":"upload","from":"{{source}}/","to":"{{release_path}}/","delete":true},
      {"name":"Activate release","type":"symlink","target":"{{release_path}}","link":"{{current_link}}"}'"$hc"',
      {"name":"Remove old releases","type":"cleanup","keep":"{{keep_releases}}","allow_failure":true}
    ]'
  else
    steps='[
      {"name":"Sync directory","type":"upload","from":"{{source}}/","to":"{{deploy_path}}/","delete":true}'"$hc"'
    ]'
  fi
  base=${JSON_RAW:-}
  [ -n "$base" ] || base='{}'
  JSON_RAW=$(printf '%s' "$base" | jq --argjson s "$steps" '. + {steps: $s}')
}

preflight() {
  local v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    render "$v" >/dev/null
  done <<< "$(jq_q -r '[(.vars // {}), (.steps // [])] | .. | strings')"
}

# --- arguments ---
for a in "$@"; do
  case "$a" in
    -h|--help|help) usage; exit 0 ;;
    -V|--version|version) printf 'deployMachine %s\n' "$VERSION"; exit 0 ;;
  esac
done

ARG_KEYS=""
for a in "$@"; do
  a=${a#--}
  case "$a" in
    [A-Za-z_]*=*)
      arg_k=${a%%=*}; arg_v=${a#*=}
      ARG_KEYS="$ARG_KEYS $arg_k"
      case "$arg_k" in
        host|user|deploy_path|source|json|ssh_key|ssh_key_file|known_hosts_file)
          [ -n "$arg_v" ] || die "$arg_k= was passed but is empty — an unset or unavailable variable?" ;;
      esac
      var_set "$arg_k" "$arg_v"
      ;;
    ssh|list|status|rollback|dry_run) var_set "$a" "true"; ARG_KEYS="$ARG_KEYS $a" ;;
    *) die "Arguments must look like key=\"value\"; the only bare words are ssh, list, status, rollback and dry_run — got: $a" ;;
  esac
done

load_json
check_arg_keys

var_default port "22"
var_default source "dist"
var_default strategy "release"
var_default keep_releases "5"
var_default rollback_on_failure "true"
var_default dry_run "false"
var_default deps_install "auto"
var_default timestamp "$(date -u +%Y%m%d%H%M%S)"
for e in CI_COMMIT_SHA CI_COMMIT_SHORT_SHA CI_COMMIT_BRANCH CI_COMMIT_TAG CI_JOB_ID CI_PROJECT_NAME CI_PIPELINE_ID \
         GITHUB_SHA GITHUB_REF_NAME GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_REPOSITORY GITHUB_ACTOR; do
  eval "val=\${$e:-}"
  [ -n "$val" ] && var_default "$(printf '%s' "$e" | tr 'A-Z' 'a-z')" "$val"
done
if [ -n "$(var_get ci_commit_short_sha)" ]; then
  var_default release "$(var_get timestamp)-$(var_get ci_commit_short_sha)"
elif [ -n "$(var_get github_sha)" ]; then
  var_default release "$(var_get timestamp)-$(printf '%s' "$(var_get github_sha)" | cut -c1-8)"
else
  var_default release "$(var_get timestamp)"
fi
var_default releases_dir "{{deploy_path}}/releases"
var_default release_path "{{releases_dir}}/{{release}}"
var_default current_link "{{deploy_path}}/current"

STRATEGY=$(var_get strategy)
DRY_RUN=false
is_true "$(var_get dry_run)" dry_run && DRY_RUN=true
ROLLBACK_ON_FAILURE=false
is_true "$(var_get rollback_on_failure)" rollback_on_failure && ROLLBACK_ON_FAILURE=true

[ -n "$(var_get deploy_path)" ] || die "deploy_path= is missing."
case "$STRATEGY" in release|sync) ;; *) die "strategy= must be release or sync, got: $STRATEGY" ;; esac

for k in deploy_path releases_dir release_path current_link source host user port known_hosts known_hosts_file ssh_key_file; do
  var_set "$k" "$(render "$(var_get "$k")")"
done
HOST=$(var_get host)
USR=$(var_get user)
PORT=$(var_get port)
DEPLOY_PATH=$(var_get deploy_path)
RELEASE_PATH=$(var_get release_path)
CURRENT_LINK=$(var_get current_link)

[ -n "$HOST" ] && [ -z "$USR" ] && die "user= is missing (host=\"$HOST\" was given)."
case "$PORT" in ''|*[!0-9]*) die "port= must be a number, got: $PORT" ;; esac

# --- main ---
on_exit() {
  local rc=$?
  trap - EXIT
  [ $rc -ne 0 ] && [ -n "$CURRENT_STEP" ] && step_stop "$CURRENT_STEP"
  if [ $rc -ne 0 ] && [ "$SWITCHED" = "true" ] && [ "$ROLLBACK_ON_FAILURE" = "true" ] && [ -n "$PREV_TARGET" ]; then
    warn "deploy failed — moving $CURRENT_LINK back to $PREV_TARGET"
    symlink_switch "$PREV_TARGET" "$CURRENT_LINK" && warn "rollback done." || warn "rollback failed — please check manually."
  fi
  if [ $rc -ne 0 ] && [ "$MODE" = "deploy" ]; then
    warn "release $(var_get release) · symlink switched: $SWITCHED"
    if [ "$SWITCHED" = "true" ] && [ -z "$PREV_TARGET" ]; then
      warn "$CURRENT_LINK points at this failed release, and there is no earlier one to fall back to."
      warn "next: deploy a fix, or run with list=\"true\" to see what is on the server."
    fi
  fi
  [ -n "$TMP_KEY" ] && rm -f "$TMP_KEY"
  [ -n "$TMP_HOSTS" ] && rm -f "$TMP_HOSTS"
  [ $rc -eq 0 ] || printf '%s\n' "${C_R}✗ aborted (exit $rc).${C_0}" >&2
  exit $rc
}
trap on_exit EXIT

MODE=deploy
is_true "$(var_get list)" list && MODE=status
case "$(var_get rollback)" in ''|false|no) ;; *) MODE=rollback ;; esac
case "$(var_get ssh)" in ''|false|no) ;; *) MODE=ssh ;; esac
is_true "$(var_get status)" status && MODE=status

if [ "$MODE" = "deploy" ]; then
  if [ -z "$JSON_RAW" ] || ! printf '%s' "$JSON_RAW" | jq -e 'has("steps")' >/dev/null 2>&1; then
    default_steps
  fi
  STEP_COUNT=$(jq_q '.steps | length')
  [ "$STEP_COUNT" -gt 0 ] || die "no steps defined."
  info "deploy $(var_get release)"
  dim "target     ${HOST:+$USR@$HOST:}$DEPLOY_PATH"
  dim "strategy   $STRATEGY$([ "$STRATEGY" = release ] && printf ' → %s' "$RELEASE_PATH")"
  dim "source     $(var_get source)"
  dim "steps      $STEP_COUNT"
else
  info "$MODE"
  dim "target     ${HOST:+$USR@$HOST:}$DEPLOY_PATH"
  dim "strategy   $STRATEGY"
  if [ "$STRATEGY" = "release" ]; then dim "releases   $(var_get releases_dir)"; fi
fi
[ "$DRY_RUN" = "true" ] && warn "dry_run=true — nothing will be executed."

[ "$MODE" = "deploy" ] && preflight
setup_ssh
[ -n "$HOST" ] && [ "$DRY_RUN" != "true" ] && [ "$MODE" != "ssh" ] && {
  ssh "${SSH_ARGS[@]}" "$USR@$HOST" true 2>/dev/null || die "SSH connection to $USR@$HOST:$PORT failed."
}

case "$MODE" in
  status) mode_status; exit 0 ;;
  rollback) mode_rollback; exit 0 ;;
  ssh) mode_ssh; exit 0 ;;
esac

STEP_I=0
while [ "$STEP_I" -lt "$STEP_COUNT" ]; do
  NAME=$(step_val name "step $((STEP_I + 1))")
  TYPE=$(step_val type run)
  ALLOW=$(step_val allow_failure false)
  CURRENT_STEP=$NAME
  step_start "$NAME" "$TYPE" "$((STEP_I + 1))/$STEP_COUNT"
  T0=$SECONDS
  RC=0
  case "$TYPE" in
    upload)      step_upload || RC=$? ;;
    run)         step_run || RC=$? ;;
    symlink)     step_symlink || RC=$? ;;
    healthcheck) step_healthcheck || RC=$? ;;
    cleanup)     step_cleanup || RC=$? ;;
    *)           die "unknown step type: $TYPE (upload|run|symlink|healthcheck|cleanup)" ;;
  esac
  if [ $RC -ne 0 ] && ! is_true "$ALLOW" allow_failure; then
    step_stop "$NAME" "exit $RC · stopped at step $((STEP_I + 1))/$STEP_COUNT, nothing after it runs"
    CURRENT_STEP=""
    exit "$RC"
  fi
  CURRENT_STEP=""
  if [ $RC -ne 0 ]; then
    warn "step \"$NAME\" failed (exit $RC) — allow_failure is set, continuing."
  else
    step_done "$NAME" "$((SECONDS - T0))s"
  fi
  STEP_I=$((STEP_I + 1))
done

ok "deploy finished: $(var_get release) → ${HOST:+$USR@$HOST:}$([ "$STRATEGY" = release ] && printf '%s' "$CURRENT_LINK" || printf '%s' "$DEPLOY_PATH")"
