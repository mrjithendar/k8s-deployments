#!/usr/bin/env bash
# Free disk on the mk4 k3s cluster. A dry run by default: it lists what would go and changes nothing.
#
#   ./disk-cleanup.sh                          preview everything
#   ./disk-cleanup.sh --apply                  remove it (asks for the context name; add --yes without a terminal)
#   ./disk-cleanup.sh --apply --only nodes
#
# pods    Finished pods (Succeeded, Failed, evicted) in every namespace. Their exited containers would keep crictl
#         from removing the images they used.
# nodes   On every node over SSH: k3s crictl rmi --prune (images no container uses), journald down to 200M,
#         apt-get clean; each node's disk, images, journald and apt cache before and after. local-path folders
#         without a PersistentVolume are listed, never deleted.
#
# Ends with a table of each node's disk before and after (in a dry run: now, and what --apply could free).
#
# Cluster: KUBE_CONTEXT, else the current context. SSH: SSH_USER (root), SSH_KEY (~/.ssh/hetzner_k3s), each node's
# ExternalIP. Needs kubectl, jq and ssh.
#
# .github/workflows/disk-cleanup.yml runs --apply --yes every day at 06:00 IST (00:30 UTC), and by hand from the Actions tab.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/scripts/lib"
APPLY=false YES=false ONLY=pods,nodes FAILED=0

usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"; }
while (($#)); do
  case "$1" in
    --apply) APPLY=true ;;
    --yes) YES=true ;;
    --only)
      [[ ${2:-} =~ ^(pods|nodes)(,(pods|nodes))*$ ]] ||
        { echo '--only takes pods and nodes, comma-separated' >&2; exit 2; }
      ONLY=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

for bin in kubectl jq ssh awk; do command -v "$bin" >/dev/null || { echo "Missing: $bin" >&2; exit 1; }; done
CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'echo "Stopped at line $LINENO; anything above marked deleted is gone, the rest is untouched." >&2' ERR

k() { kubectl --context "$CONTEXT" --request-timeout=60s "$@"; }
step() { [[ ",$ONLY," == *",$1,"* ]]; }
section() { printf '\n== %s\n' "$*"; }
fail() { echo "$*" >&2; FAILED=$((FAILED + 1)); }
human() {   # human BYTES (may be negative)
  awk -v b="${1:-0}" 'BEGIN { s = ""; if (b < 0) { s = "-"; b = -b }; split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }; printf "%s%.1f %s", s, b, u[i] }'
}
pct() { echo $((($1 * 100 + $2 / 2) / $2)); }   # pct PART TOTAL, rounded
used_pct() {   # used_pct USED [TOTAL]: "60.0 GiB (83%)"
  if [[ -z ${2:-} || ${2:-0} == 0 ]]; then human "$1"; return; fi
  printf '%s (%s%%)' "$(human "$1")" "$(pct "$1" "$2")"
}
# Summary rows: name, used before, disk size (for the percentage), used after (apply), and the estimate of what
# --apply frees (dry run). Sizes in bytes; empty when unknown.
ROW_NAME=() ROW_BEFORE=() ROW_SIZE=() ROW_AFTER=() ROW_ESTIMATE=()
add_row() { ROW_NAME+=("$1"); ROW_BEFORE+=("$2"); ROW_SIZE+=("$3"); ROW_AFTER+=("$4"); ROW_ESTIMATE+=("$5"); }
row() { printf '  %-34s  %-18s  %-18s  %s\n' "$@"; }

print_summary() {
  local i total=0 freed
  ((${#ROW_NAME[@]})) || return 0
  if $APPLY; then
    section 'Summary: used disk before and after'
    row '' before after freed
    for i in "${!ROW_NAME[@]}"; do
      if [[ -n ${ROW_BEFORE[i]} && -n ${ROW_AFTER[i]} ]]; then
        freed=$((ROW_BEFORE[i] - ROW_AFTER[i]))
        total=$((total + freed))
        row "${ROW_NAME[i]}" "$(used_pct "${ROW_BEFORE[i]}" "${ROW_SIZE[i]}")" \
          "$(used_pct "${ROW_AFTER[i]}" "${ROW_SIZE[i]}")" "$(human "$freed")"
      else
        row "${ROW_NAME[i]}" "${ROW_BEFORE[i]:+$(used_pct "${ROW_BEFORE[i]}" "${ROW_SIZE[i]}")}" '?' '?'
      fi
    done
    row 'total freed' '' '' "$(human "$total")"
  else
    section 'Summary: used disk now, and what --apply could free'
    row '' 'used now' 'could free'
    for i in "${!ROW_NAME[@]}"; do
      total=$((total + ${ROW_ESTIMATE[i]:-0}))
      row "${ROW_NAME[i]}" "${ROW_BEFORE[i]:+$(used_pct "${ROW_BEFORE[i]}" "${ROW_SIZE[i]}")}" \
        "${ROW_ESTIMATE[i]:+~$(human "${ROW_ESTIMATE[i]}")}"
    done
    row 'total' '' "~$(human "$total")"
    echo '  Estimates: images count compressed (they free more unpacked).'
  fi
}

# --- finished pods ----------------------------------------------------------------------------------------------------
clean_pods() {
  section 'Finished pods'
  local phase list pod
  for phase in Failed Succeeded; do
    list="$(k get pods -A --field-selector="status.phase==$phase" \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
    if [[ -z $list ]]; then echo "  $phase: none"; continue; fi
    echo "  $phase: $(grep -c . <<<"$list")"
    while IFS= read -r pod; do echo "    $pod"; done <<<"$list"
    if $APPLY; then k delete pods -A --field-selector="status.phase==$phase" --wait=false | sed 's/^/    /'; fi
  done
}

# --- nodes ------------------------------------------------------------------------------------------------------------
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/hetzner_k3s}"
JOURNAL_LIMIT=$((200 * 1024 * 1024))   # journalctl --vacuum-size=200M in node-disk-cleanup.sh

on_node() {   # on_node IP [ARGS...] <script: runs the script on stdin with bash on the node, as root
  local ip=$1 sudo='' args=''
  shift
  if [[ $SSH_USER != root ]]; then sudo='sudo -n'; fi
  if (($#)); then args="$(printf '%q ' "$@")"; fi
  ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$ip" "$sudo bash -s -- $args"
}

clean_nodes() {
  section "Nodes (SSH as $SSH_USER, key $SSH_KEY)"
  local node ip n images pv key a b estimate extra mode=report pvs=()
  local used avail journal apt removed journal_after apt_after used_after avail_after
  if $APPLY; then mode=apply; fi
  while IFS= read -r pv; do [[ -z $pv ]] || pvs+=("$pv"); done \
    < <(k get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  k get nodes -o json | jq -r '.items[] | .metadata.name + "\t" + ([.status.addresses[] | select(.type == "ExternalIP")][0].address // [.status.addresses[] | select(.type == "InternalIP")][0].address)' \
    >"$WORK/nodes"
  while IFS=$'\t' read -r -u 3 node ip; do
    echo
    echo "  -- $node ($ip)"
    if ! on_node "$ip" <<<'k3s crictl images -o json' >"$WORK/images.json" 2>"$WORK/ssh.err" ||
      ! on_node "$ip" <<<'k3s crictl ps -a -o json' >"$WORK/containers.json" 2>"$WORK/ssh.err"; then
      fail "    SSH failed: $(tail -n 1 "$WORK/ssh.err")"
      add_row "$node" '' '' '' ''
      continue
    fi
    jq -n --slurpfile i "$WORK/images.json" --slurpfile c "$WORK/containers.json" -f "$LIB/unused-images.jq" \
      >"$WORK/unused.json"
    n="$(jq length "$WORK/unused.json")"
    images="$(jq 'map(.size) | add // 0' "$WORK/unused.json")"
    if $APPLY; then echo "    removing $n unused images, journald above 200M and apt's cache ..."; fi
    if ! on_node "$ip" "$mode" ${pvs[@]+"${pvs[@]}"} <"$LIB/node-disk-cleanup.sh" >"$WORK/node.out" 2>"$WORK/ssh.err"; then
      fail "    cleanup on $node failed: $(tail -n 1 "$WORK/ssh.err")"
      add_row "$node" '' '' '' ''
      continue
    fi
    used='' avail='' journal=0 apt=0 removed='' journal_after='' apt_after='' used_after='' avail_after=''
    : >"$WORK/node.notes"
    while read -r key a b; do
      case $key in
        disk) used=$a avail=$b ;;
        journal) journal=$a ;;
        apt) apt=$a ;;
        orphan) echo "    no PersistentVolume  $(human "$a")  $b  (left in place)" >>"$WORK/node.notes" ;;
        orphans) echo '    local-path folders  not checked (no PersistentVolume list)' >>"$WORK/node.notes" ;;
        removed) removed=$a ;;
        journal_after) journal_after=$a ;;
        apt_after) apt_after=$a ;;
        disk_after) used_after=$a avail_after=$b ;;
        error) fail "    $node: $a $b" ;;
      esac
    done <"$WORK/node.out"
    if [[ -z $used ]]; then fail "    no disk figures from $node"; add_row "$node" '' '' '' ''; continue; fi

    echo "    disk          $(human "$used") used of $(human $((used + avail))), $(human "$avail") free ($(pct "$used" $((used + avail)))%)"
    echo "    images        $n unused, $(human "$images") compressed (more once unpacked)"
    jq -r '.[:25][] | "\(.size)\t\(.name)"' "$WORK/unused.json" |
      while IFS=$'\t' read -r a b; do printf '                  %10s  %s\n' "$(human "$a")" "$b"; done
    if ((n > 25)); then echo "                  ... and $((n - 25)) more"; fi
    echo "    journald      $(human "$journal")   apt cache  $(human "$apt")"
    cat "$WORK/node.notes"
    if $APPLY; then
      echo "    removed       ${removed:-?} images; journald $(human "$journal") -> $(human "${journal_after:-0}"); apt cache $(human "$apt") -> $(human "${apt_after:-0}")"
      if [[ -n $used_after ]]; then
        echo "    disk after    $(human "$used_after") used, $(human "$avail_after") free: freed $(human $((used - used_after)))"
      fi
      add_row "$node" "$used" $((used + avail)) "$used_after" ''
    else
      extra=$((journal > JOURNAL_LIMIT ? journal - JOURNAL_LIMIT : 0))
      estimate=$((images + extra + apt))
      echo "    could free    ~$(human "$estimate") (images $(human "$images"), journald $(human "$extra"), apt cache $(human "$apt"))"
      add_row "$node" "$used" $((used + avail)) '' "$estimate"
    fi
  done 3<"$WORK/nodes"
}

# --- run --------------------------------------------------------------------------------------------------------------
k get --raw /readyz >/dev/null || { echo "Cannot reach context '$CONTEXT'." >&2; exit 1; }
if $APPLY; then
  echo "APPLY on context '$CONTEXT': $ONLY."
  if ! $YES; then
    [[ -t 0 ]] || { echo 'No terminal to confirm on: add --yes.' >&2; exit 1; }
    read -r -p 'Type the context name to continue: ' answer
    [[ $answer == "$CONTEXT" ]] || { echo 'Cancelled.'; exit 1; }
  fi
else
  echo "DRY RUN on context '$CONTEXT': nothing changes. Add --apply to remove what is listed."
fi

if step pods; then clean_pods; fi
if step nodes; then clean_nodes; fi

print_summary
section Done
if ((FAILED)); then echo "$FAILED problem(s); see the messages above." >&2; exit 1; fi
if ! $APPLY; then echo 'Dry run: nothing was changed. Run again with --apply.'; fi
