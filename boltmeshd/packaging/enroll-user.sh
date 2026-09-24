#!/bin/sh
# Enroll a selected desktop user in BoltMesh's privileged-helper group.
#
# Package managers do not reliably preserve the identity of the user who
# started a transaction.  The package post-install uses --auto and falls back
# to one unambiguous local graphical logind session; operators can always use
# --uid for an explicit, root-authorized enrollment.  This is deliberately a
# separate root command: the Flutter application never elevates itself.
set -eu

# Package maintainer environments can contain a caller-controlled PATH and
# locale.  Keep command lookup and loginctl output deterministic.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
# Do not let an inherited test/session bus redirect a root package script's
# system-session query.
unset DBUS_SYSTEM_BUS_ADDRESS DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR

GROUP=boltmesh
PROGRAM=${0##*/}
MODE=none
REQUESTED_UID=

usage() {
  printf '%s\n' "Usage: $PROGRAM (--auto | --uid UID)" >&2
  printf '%s\n' '' >&2
  printf '%s\n' \
    '  --auto    enroll one unique active graphical user, if unambiguous' \
    '  --uid UID enroll exactly this non-root local user'
}

fail() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

info() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
}

# Normalize decimal UID text without invoking a shell or an octal parser.
normalize_uid() {
  uid_text=$1
  case "$uid_text" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "${uid_text#0}" != "$uid_text" ]; do
    uid_text=${uid_text#0}
  done
  [ -n "$uid_text" ] || uid_text=0
  printf '%s\n' "$uid_text"
}

# Resolve a numeric UID to a passwd identity with a login-capable shell.
# The returned username is canonical and is the only value passed to usermod.
user_for_uid() {
  wanted_uid=$1
  wanted_uid=$(normalize_uid "$wanted_uid") || return 1
  [ "$wanted_uid" -ne 0 ] || return 1

  passwd_line=$(getent passwd "$wanted_uid" 2>/dev/null | head -n 1) || return 1
  [ -n "$passwd_line" ] || return 1
  passwd_name=$(printf '%s\n' "$passwd_line" | cut -d: -f1)
  passwd_uid=$(printf '%s\n' "$passwd_line" | cut -d: -f3)
  passwd_shell=$(printf '%s\n' "$passwd_line" | cut -d: -f7)
  [ -n "$passwd_name" ] || return 1
  case "$passwd_name" in
    -*) return 1 ;;
  esac
  [ "$(normalize_uid "$passwd_uid")" = "$wanted_uid" ] || return 1
  case "$passwd_shell" in
    ''|*/nologin|*/false|/bin/sync) return 1 ;;
  esac
  printf '%s\n' "$passwd_name"
}

# Resolve a free-form SUDO_USER only through the passwd database.  The name is
# never passed to usermod; the numeric UID is the identity used for the grant.
uid_for_user() {
  wanted_name=$1
  passwd_line=$(getent passwd -- "$wanted_name" 2>/dev/null | head -n 1) || return 1
  [ -n "$passwd_line" ] || return 1
  passwd_uid=$(printf '%s\n' "$passwd_line" | cut -d: -f3)
  normalize_uid "$passwd_uid"
}

# Keep loginctl from holding a package transaction open if the system bus is
# unhealthy.  timeout is in the base coreutils installation on the target
# distributions; the fallback keeps minimal non-coreutils systems usable.
run_loginctl() {
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout 2s loginctl "$@" 2>/dev/null; then
      :
    fi
  else
    if ! loginctl "$@" 2>/dev/null; then
      :
    fi
  fi
  return 0
}

# Add a UID to a duplicate-free set.  UIDs, rather than names, are the
# identity key: one person can have several graphical sessions.
add_candidate_uid() {
  candidate_uid=$1
  case " $candidate_uids " in
    *" $candidate_uid "*) return 0 ;;
  esac
  candidate_uids="${candidate_uids}${candidate_uids:+ }$candidate_uid"
  candidate_count=$((candidate_count + 1))
  if [ "$candidate_count" -eq 1 ]; then
    selected_uid=$candidate_uid
  fi
  return 0
}

# Find local graphical sessions through logind.  This is the fallback for a
# root shell and for package managers such as PackageKit that expose neither
# SUDO_UID nor PKEXEC_UID.  A zero or multiple result is intentionally not
# guessed: granting every active account would turn a package install into a
# privilege grant for unrelated users.
discover_graphical_uids() {
  command -v loginctl >/dev/null 2>&1 || return 0
  session_list=$(run_loginctl list-sessions --no-legend --no-pager)
  [ -n "$session_list" ] || return 0

  discovered_uids=$(
    while IFS= read -r session_line; do
      # list-sessions is a formatted table: leading and repeated whitespace
      # are normal, so let read split fields rather than using literal-space
      # parameter expansion.
      IFS="$(printf ' \t')" read -r session_id session_uid _ <<EOF
$session_line
EOF
      case "$session_id" in
        ''|*[!A-Za-z0-9_.:-]*) continue ;;
      esac
      if ! session_uid=$(normalize_uid "$session_uid" 2>/dev/null); then
        continue
      fi
      [ -n "$session_uid" ] || continue
      [ "$session_uid" -ne 0 ] || continue

      session_type=$(run_loginctl show-session "$session_id" --property=Type --value)
      case "$session_type" in
        x11|wayland) ;;
        *) continue ;;
      esac
      session_state=$(run_loginctl show-session "$session_id" --property=State --value)
      case "$session_state" in
        active|online) ;;
        *) continue ;;
      esac
      session_class=$(run_loginctl show-session "$session_id" --property=Class --value)
      [ "$session_class" = user ] || continue
      session_remote=$(run_loginctl show-session "$session_id" --property=Remote --value)
      [ "$session_remote" = no ] || continue
      printf '%s\n' "$session_uid"
    done <<EOF
$session_list
EOF
  )
  [ -n "$discovered_uids" ] || return 0

  while IFS= read -r discovered_uid; do
    [ -n "$discovered_uid" ] || continue
    # Ignore greeter/service identities and malformed passwd entries.  The
    # explicit hint path below treats an invalid identity as an error instead.
    if user_for_uid "$discovered_uid" >/dev/null 2>&1; then
      add_candidate_uid "$discovered_uid"
    fi
  done <<EOF
$(printf '%s\n' "$discovered_uids" | sort -n -u)
EOF
}

# Read and validate the elevation hints set by sudo/pkexec.  A malformed or
# conflicting trusted hint is an error rather than an invitation to guess from
# an unrelated graphical session.  SUDO_USER is only a name-based fallback.
resolve_elevation_uid() {
  hint_uids=
  hint_count=0
  add_hint() {
    hint_value=${1:-}
    [ -n "$hint_value" ] || return 0
    normalized_hint=$(normalize_uid "$hint_value") ||
      fail "invalid elevation UID hint: $hint_value"
    [ "$normalized_hint" -ne 0 ] || return 0
    case " $hint_uids " in
      *" $normalized_hint "*) return 0 ;;
    esac
    hint_uids="${hint_uids}${hint_uids:+ }$normalized_hint"
    hint_count=$((hint_count + 1))
  }

  add_hint "${SUDO_UID:-}"
  add_hint "${PKEXEC_UID:-}"

  # SUDO_USER is retained only as a compatibility fallback for sudo wrappers
  # that preserve the name but not SUDO_UID.  Resolve it through NSS and use
  # only the resulting numeric UID; never pass the environment name to
  # usermod.  A valid numeric hint remains authoritative; a conflicting
  # resolved name is rejected below.
  name_hint=${SUDO_USER:-}
  if [ -n "$name_hint" ]; then
    if name_uid=$(uid_for_user "$name_hint"); then
      if [ "$name_uid" -ne 0 ]; then
        case " $hint_uids " in
          *" $name_uid "*) ;;
          *)
            hint_uids="${hint_uids}${hint_uids:+ }$name_uid"
            hint_count=$((hint_count + 1))
            ;;
        esac
      fi
    elif [ "$hint_count" -eq 0 ]; then
      fail "SUDO_USER does not resolve to a passwd user: $name_hint"
    fi
  fi

  case "$hint_count" in
    0) return 0 ;;
    1) printf '%s\n' "$hint_uids"; return 0 ;;
    *)
      fail "elevation hints identify different users ($hint_uids); use --uid explicitly"
      ;;
  esac
}

# Create the group when needed, then validate it before using it as a
# capability.  In particular, a pre-existing GID-0 group is not acceptable.
ensure_group() {
  if ! getent group "$GROUP" >/dev/null 2>&1; then
    command -v groupadd >/dev/null 2>&1 ||
      fail "groupadd is required to create the $GROUP group"
    # A concurrent package process may win the create race; the validation
    # below decides whether the resulting group is usable.
    if ! groupadd --system "$GROUP"; then
      getent group "$GROUP" >/dev/null 2>&1 ||
        fail "could not create the $GROUP group"
    fi
  fi

  group_line=$(getent group "$GROUP" 2>/dev/null | head -n 1) ||
    fail "could not look up the $GROUP group"
  [ -n "$group_line" ] || fail "could not look up the $GROUP group"
  group_name=$(printf '%s\n' "$group_line" | cut -d: -f1)
  group_gid=$(printf '%s\n' "$group_line" | cut -d: -f3)
  [ "$group_name" = "$GROUP" ] || fail "the $GROUP group name is invalid"
  normalized_gid=$(normalize_uid "$group_gid") ||
    fail "the $GROUP group has a non-numeric GID: $group_gid"
  [ "$normalized_gid" -ne 0 ] || fail "the $GROUP group must not have GID 0"
}

is_group_member() {
  id -nG -- "$1" 2>/dev/null |
    tr ' ' '\n' |
    grep -Fqx -- "$GROUP"
}

enroll_user() {
  user_name=$1
  if is_group_member "$user_name"; then
    info "$user_name is already a member of $GROUP"
    return 0
  fi

  command -v usermod >/dev/null 2>&1 ||
    fail "usermod is required to enroll $user_name"
  if ! usermod -aG "$GROUP" -- "$user_name"; then
    fail "usermod could not add $user_name to $GROUP"
  fi
  is_group_member "$user_name" ||
    fail "usermod returned success but $user_name is not in $GROUP"
  info "added $user_name to $GROUP; log out and back in before starting BoltMesh"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --auto|--discover)
      [ "$MODE" = none ] || fail "--auto and --uid are mutually exclusive"
      MODE=auto
      shift
      ;;
    --uid)
      [ "$#" -ge 2 ] || fail "--uid requires a numeric UID"
      [ "$MODE" = none ] || fail "--auto and --uid are mutually exclusive"
      MODE=uid
      REQUESTED_UID=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ "$MODE" != none ] || fail "specify --auto or --uid UID"
current_uid=$(id -u 2>/dev/null) || fail "could not determine the effective user"
[ "$current_uid" -eq 0 ] || fail "must be run as root"

ensure_group

candidate_uids=
selected_uid=
candidate_count=0

if [ "$MODE" = uid ]; then
  selected_uid=$(normalize_uid "$REQUESTED_UID") ||
    fail "--uid must be a decimal UID"
  [ "$selected_uid" -ne 0 ] || fail "refusing to enroll UID 0"
  user_for_uid "$selected_uid" >/dev/null 2>&1 ||
    fail "UID $selected_uid is not a login-capable local user"
  add_candidate_uid "$selected_uid"
else
  hint_uid=$(resolve_elevation_uid)
  if [ -n "$hint_uid" ]; then
    user_for_uid "$hint_uid" >/dev/null 2>&1 ||
      fail "elevation UID $hint_uid is not a login-capable local user"
    add_candidate_uid "$hint_uid"
  else
    discover_graphical_uids
  fi
fi

if [ "$candidate_count" -eq 0 ]; then
  info "no unambiguous active graphical desktop user was found; run '$PROGRAM --uid UID' as root to enroll explicitly"
  exit 0
fi
if [ "$candidate_count" -ne 1 ]; then
  info "multiple active graphical users found ($candidate_uids); run '$PROGRAM --uid UID' as root to choose one"
  exit 0
fi

selected_user=$(user_for_uid "$selected_uid") ||
  fail "could not resolve the selected desktop user"
enroll_user "$selected_user"
