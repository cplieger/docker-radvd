#!/usr/bin/env bash
# The signal suite must sit at CI's image-test slot (tracked executable, with a shebang, outside every image), and the Dockerfile must preserve its test-stage and package-refresh edges.
# SC2015: lib.sh verdict helpers return 0. SC2016: the literal ${...} and backticked
# strings ARE the assertion subjects -- they are patterns read out of the tree, not
# expressions to expand.
# shellcheck disable=SC2015,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

SUITE="$REPO_ROOT/tests/image-test.sh"
DOCKERFILE="$REPO_ROOT/Dockerfile"

if [ ! -f "$SUITE" ] && [ ! -f "$DOCKERFILE" ]; then
  skip "the signal suite sits at CI's image-test slot, outside every image" "tests/image-test.sh and the Dockerfile are absent (the image build does not copy them)"
  report
  exit
fi

if [ ! -f "$SUITE" ]; then
  no "signal suite present" "$SUITE is missing: CI's Image test suite step would skip and the signal contract would go unexercised"
  report
  exit
fi

# CI executes the suite directly, so the committed mode decides; outside a git
# checkout the file's own mode is the closest evidence.
fix="commit it executable: git update-index --chmod=+x tests/image-test.sh"
if [ "$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$REPO_ROOT" ]; then
  suite_mode=$(git -C "$REPO_ROOT" ls-files -s -- tests/image-test.sh | cut -d' ' -f1)
  [ "$suite_mode" = "100755" ] \
    && ok "tests/image-test.sh is tracked 100755" \
    || no "signal suite tracked executable" "git records mode '$suite_mode'; CI's Image test suite step fails on a non-executable suite; $fix"
else
  [ -x "$SUITE" ] \
    && ok "tests/image-test.sh is executable" \
    || no "signal suite executable" "$SUITE is not executable; $fix"
fi

[ "$(head -c 2 "$SUITE")" = '#!' ] \
  && ok "tests/image-test.sh names its interpreter in a shebang" \
  || no "signal suite shebang" "line 1 of $SUITE is not a shebang; CI executes it directly"

# One Dockerfile instruction per line: comment lines dropped, backslash
# continuations joined, heredoc bodies skipped.
dockerfile_instructions() {
  local line trimmed joined="" rest word
  local heredoc_re='<<-?["'\'']?([A-Za-z_][A-Za-z0-9_]*)["'\'']?(.*)$'
  local -a ends=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "${#ends[@]}" -gt 0 ]; then
      trimmed=${line#"${line%%[![:space:]]*}"}
      [ "$trimmed" = "${ends[0]}" ] && ends=("${ends[@]:1}")
      continue
    fi
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in '#'* | '') continue ;; esac
    trimmed=${line%"${line##*[![:space:]]}"}
    if [ "${trimmed%\\}" != "$trimmed" ]; then
      joined+="${trimmed%\\} "
      continue
    fi
    printf '%s\n' "$joined$line"
    rest="$joined$line"
    joined=""
    while [[ $rest =~ $heredoc_re ]]; do
      word=${BASH_REMATCH[1]}
      rest=${BASH_REMATCH[2]}
      ends+=("$word")
    done
  done <"$1"
  [ -z "$joined" ] || printf '%s\n' "$joined"
}

# Every context source of one COPY/ADD, one per line, still escaped; nothing for
# COPY --from. A malformed JSON form falls back to whitespace splitting, as
# BuildKit does.
copy_sources() {
  local rest=$1 json word
  local array_re='^\[(.*)\][[:space:]]*$'
  local element_re='^[[:space:]]*"(([^"\]|\\.)*)"[[:space:]]*(,(.*))?$'
  local -a args=()
  read -r word rest <<<"$rest"
  while [[ $rest == --* ]]; do
    read -r word rest <<<"$rest"
    [[ $word == --from=* ]] && return 0
  done
  json=$rest
  if [[ $json =~ $array_re ]]; then
    json=${BASH_REMATCH[1]}
    while [[ $json =~ $element_re ]]; do
      args+=("${BASH_REMATCH[1]}")
      json=${BASH_REMATCH[4]}
      [ -n "${BASH_REMATCH[3]}" ] || {
        json=""
        break
      }
    done
    [[ $json =~ ^[[:space:]]*$ ]] || args=()
  fi
  [ "${#args[@]}" -gt 0 ] || read -r -a args <<<"$rest"
  [ "${#args[@]}" -ge 2 ] || return 0
  printf '%s\n' "${args[@]:0:${#args[@]}-1}"
}

# Can this source, after path cleaning and glob matching per path component,
# name the suite, tests/ or the whole context? A variable, a quote or an escape
# is not resolved here, so each counts as a match.
source_reaches_suite() {
  local src=$1 part i
  local -a raw=() parts=() target=(tests image-test.sh)
  case "$src" in '<<'* | *://* | git@*) return 1 ;; *[\$\"\'\\]*) return 0 ;; esac
  IFS=/ read -r -a raw <<<"$src"
  for part in "${raw[@]}"; do
    case "$part" in
      '' | .) ;;
      ..) [ "${#parts[@]}" -eq 0 ] || unset 'parts[-1]' ;;
      *) parts+=("$part") ;;
    esac
  done
  [ "${#parts[@]}" -le "${#target[@]}" ] || return 1
  for i in "${!parts[@]}"; do
    # shellcheck disable=SC2053
    [[ ${target[i]} == ${parts[i]} ]] || return 1
  done
  return 0
}

# The parse models the default `\` escape; a parser directive can change it.
escape_char="\\"
while IFS= read -r line; do
  [[ ${line%$'\r'} =~ ^#[[:space:]]*([A-Za-z][A-Za-z0-9]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || break
  [ "${BASH_REMATCH[1],,}" = escape ] && escape_char=${BASH_REMATCH[2]}
done <"$DOCKERFILE"
[ "$escape_char" = "\\" ] \
  && ok "the Dockerfile keeps the default escape character the parse models" \
  || no "Dockerfile escape directive" "escape=$escape_char; the COPY/ADD parse below models only the default backslash"

image_copies=""
context_sources=0
while IFS= read -r instruction; do
  read -r word _ <<<"$instruction"
  case "${word^^}" in COPY | ADD) ;; *) continue ;; esac
  while IFS= read -r src; do
    context_sources=$((context_sources + 1))
    source_reaches_suite "$src" && image_copies+="${image_copies:+, }$src"
  done < <(copy_sources "$instruction")
done < <(dockerfile_instructions "$DOCKERFILE")
# Zero parsed sources would make the verdict below vacuous.
[ "$context_sources" -gt 0 ] \
  && ok "the Dockerfile parse found its context COPY/ADD sources ($context_sources)" \
  || no "Dockerfile parse" "no context COPY or ADD source parsed out of $DOCKERFILE"
[ -z "$image_copies" ] \
  && ok "no Dockerfile COPY or ADD pulls tests/image-test.sh into a stage" \
  || no "signal suite outside every image" "Dockerfile copies '$image_copies' from the context, which carries tests/image-test.sh"

last_stage=$(awk '
  toupper($1) == "FROM" {
    name = ""
    for (i = 1; i < NF; i++) {
      if (toupper($i) == "AS") { name = $(i + 1) }
    }
  }
  END { print name }
' "$DOCKERFILE")
marker_edges=$(awk '
  toupper($1) == "FROM" {
    in_final = 0
    for (i = 1; i < NF; i++) {
      if (toupper($i) == "AS" && tolower($(i + 1)) == "final") { in_final = 1 }
    }
    next
  }
  in_final && toupper($1) == "COPY" && $0 ~ /--from=test([[:space:]]|$)/ { edges++ }
  END { print edges + 0 }
' "$DOCKERFILE")
[ "$last_stage" = "final" ] && [ "$marker_edges" -ge 1 ] \
  && ok "the default Docker target is final and final depends on the test stage" \
  || no "default build reaches tests" "last stage='$last_stage', final COPY --from=test edges=$marker_edges"

base_stage=$(awk '
  toupper($1) == "FROM" {
    if (in_base) { exit }
    in_base = 0
    for (i = 1; i < NF; i++) {
      if (toupper($i) == "AS" && tolower($(i + 1)) == "base") { in_base = 1 }
    }
  }
  in_base { print }
' "$DOCKERFILE")
upgrade_run=$(printf '%s\n' "$base_stage" | awk '
  function flush() {
    if (instruction ~ /apk upgrade --no-cache/) { print instruction }
    instruction = ""
  }
  /^[A-Z][A-Z]*[[:space:]]/ {
    flush()
    instruction = $0
    next
  }
  instruction != "" { instruction = instruction " " $0 }
  END { flush() }
')
printf '%s\n' "$base_stage" | grep -q '^ARG PKG_REFRESH=' \
  && [ -n "$upgrade_run" ] \
  && printf '%s\n' "$upgrade_run" | grep -Fq '${PKG_REFRESH}' \
  && ok "the base-stage apk upgrade RUN consumes PKG_REFRESH for its cache key" \
  || no "package refresh cache key" 'base-stage ARG or same-RUN ${PKG_REFRESH} expansion is missing'

COMPOSE="$REPO_ROOT/compose.yaml"
README="$REPO_ROOT/README.md"
compose_restart=$(awk '
  /^  [[:alnum:]_-]+:[[:space:]]*$/ { in_radvd = ($1 == "radvd:") }
  in_radvd && $1 == "restart:" { print $2; exit }
' "$COMPOSE" 2>/dev/null)
reload_section=$(sed -n '/^## Reloading configuration$/,/^## /p' "$README")
reload_command=$(printf '%s\n' "$reload_section" \
  | grep -E '^docker (kill -s HUP|restart) radvd$' | head -n 1)

# Asserted for every README shape: the caveat is the published consequence of a
# Docker behaviour that holds whichever command the section leads with.
printf '%s\n' "$reload_section" | grep -Fq 'prefer `docker restart` where it matters' \
  && printf '%s\n' "$reload_section" \
  | grep -Fq '`unless-stopped` is disarmed by the kill regardless' \
  && ok "the reload section keeps both published docker-kill restart-policy caveats" \
  || no "restart-policy caveat" "a published caveat phrase is missing from the Reloading section"

# compose.yaml is not copied into the image test stage, so this assertion states its
# own input instead of resting on the guard at the top of this file. The two
# phrase checks above need no guard: README.md IS copied.
if [ ! -f "$COMPOSE" ]; then
  skip "the published reload procedure leads with the command that preserves restart-policy recovery" "compose.yaml is absent (the image build does not copy it)"
elif [ "$reload_command" = "docker restart radvd" ]; then
  ok "the published reload procedure leads with the command that preserves restart-policy recovery"
elif [ "$reload_command" = "docker kill -s HUP radvd" ] && [ "$compose_restart" = "unless-stopped" ]; then
  ok "the published reload procedure leads with the HUP form, whose consequence the caveat states"
else
  no "reload/restart-policy contract" "compose restart='$compose_restart', published reload='$reload_command'"
fi

report
