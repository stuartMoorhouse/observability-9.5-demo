#!/usr/bin/env bash
# Scenario 5: export a dashboard from Kibana into dashboards/ for commit.
#
#   scripts/export-dashboard.sh <dashboard-id|title> [--slug NAME] [--out-dir DIR]
#
# Fetches the dashboard through the Kibana Dashboards API (the same API the
# Terraform deploy uses), strips server-managed noise (meta, version,
# timestamps, managed flags), sorts keys with jq -S and writes
# dashboards/<slug>.json. If the argument is not an existing id it is treated
# as a title and looked up with the Dashboards API search endpoint.
#
# File format: {"id": "<dashboard id>", "data": { ...dashboard definition... }}
# The Terraform deploy sends .data to PUT ${DASHBOARDS_API}/<id>.
set -euo pipefail

# Kibana Dashboards API base path (GA in 9.5). MUST match the endpoint used in
# terraform/modules/kibana-content/dashboards.tf.
DASHBOARDS_API="/api/dashboards"

# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  print_header "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Fetch by id. Prints the body; returns 1 on 404, dies on other errors.
fetch_by_id() {
  local id="$1" tmp code
  tmp="$(mktemp)"
  code="$(kb_fetch GET "${DASHBOARDS_API}/$(uri_encode "${id}")" "${tmp}")"
  case "${code}" in
    200)
      cat "${tmp}"
      rm -f "${tmp}"
      ;;
    404 | 400)
      rm -f "${tmp}"
      return 1
      ;;
    000)
      rm -f "${tmp}"
      die "Kibana unreachable at ${KB_URL}."
      ;;
    *)
      error "GET ${DASHBOARDS_API}/${id} returned HTTP ${code}: $(head -c 500 "${tmp}")"
      rm -f "${tmp}"
      exit 1
      ;;
  esac
}

# Resolve a title to an id using the search endpoint.
resolve_title() {
  local title="$1" resp matches n
  if ! resp="$(kb_api GET "${DASHBOARDS_API}?query=$(uri_encode "${title}")&per_page=100")"; then
    die "Dashboard search failed: ${resp}"
  fi
  # Tolerate the possible list shapes (dashboards/items/data/saved_objects).
  matches="$(jq -c --arg t "${title}" '
    (.dashboards // .items // .data // .saved_objects // .results // [])
    | map({id: .id, title: (.data.title // .title // .attributes.title // "")})
    | map(select((.title | ascii_downcase) == ($t | ascii_downcase)))' <<<"${resp}")"
  n="$(jq 'length' <<<"${matches}")"
  if ((n == 0)); then
    local near
    near="$(jq -r '(.dashboards // .items // .data // .saved_objects // .results // [])
      | map("  \(.id)  \(.data.title // .title // .attributes.title // "")") | .[:20] | join("\n")' <<<"${resp}")"
    die "No dashboard with id or exact title '${title}'. Search results:
${near:-  (none)}"
  fi
  if ((n > 1)); then
    die "Title '${title}' matches ${n} dashboards; pass an id instead:
$(jq -r '.[] | "  \(.id)  \(.title)"' <<<"${matches}")"
  fi
  jq -r '.[0].id' <<<"${matches}"
}

normalise() {
  local id="$1"
  jq -S --arg id "${id}" '
    def clean: if type == "object" then
      del(.meta, .version, .updated_at, .updatedAt, .updated_by, .updatedBy,
          .created_at, .createdAt, .created_by, .createdBy, .managed,
          .namespaces, .coreMigrationVersion, .typeMigrationVersion,
          .migrationVersion, .error)
      else . end;
    if has("data") then {id: (.id // $id), data: (.data | clean)}
    elif has("attributes") then {id: (.id // $id), data: (.attributes | clean)}
    else {id: (.id // $id), data: (clean | del(.id))}
    end'
}

main() {
  local target="" slug="" out_dir="${REPO_ROOT}/dashboards"
  while (($# > 0)); do
    case "$1" in
      --slug) slug="${2:?--slug needs a value}"; shift 2 ;;
      --out-dir) out_dir="${2:?--out-dir needs a value}"; shift 2 ;;
      -h | --help) usage 0 ;;
      -*) error "Unknown option: $1"; usage 1 ;;
      *)
        [[ -z "${target}" ]] || die "Only one dashboard id or title may be given."
        target="$1"
        shift
        ;;
    esac
  done
  [[ -n "${target}" ]] || usage 1

  require_cmd jq curl terraform
  load_env
  check_endpoint "Kibana" "${KB_URL}/api/status"

  local id="${target}" body
  if ! body="$(fetch_by_id "${target}")"; then
    info "'${target}' is not a dashboard id; searching by title..."
    id="$(resolve_title "${target}")"
    body="$(fetch_by_id "${id}")" || die "Dashboard ${id} disappeared between search and fetch."
  fi

  local normalised title out_file
  normalised="$(normalise "${id}" <<<"${body}")"
  title="$(jq -r '.data.title // empty' <<<"${normalised}")"
  [[ -n "${slug}" ]] || slug="$(slugify "${title:-${id}}")"
  [[ -n "${slug}" ]] || die "Could not derive a file name; pass --slug NAME."

  mkdir -p "${out_dir}"
  out_file="${out_dir}/${slug}.json"
  if [[ -f "${out_file}" ]]; then
    local existing_id
    existing_id="$(jq -r '.id // empty' "${out_file}" 2>/dev/null || true)"
    if [[ -n "${existing_id}" && "${existing_id}" != "${id}" ]]; then
      warn "${out_file} currently holds dashboard ${existing_id}; overwriting with ${id}."
    fi
  fi
  printf '%s\n' "${normalised}" >"${out_file}"
  jq -e . "${out_file}" >/dev/null || die "Written file is not valid JSON: ${out_file}"
  info "Exported '${title:-${id}}' (${id}) -> ${out_file}"

  if [[ "${out_dir}" == "${REPO_ROOT}/dashboards" ]]; then
    local rel="dashboards/${slug}.json"
    printf '\nNext steps:\n'
    printf '  git -C %s status --short -- %s\n' "${REPO_ROOT}" "${rel}"
    printf '  git -C %s diff --stat -- %s\n' "${REPO_ROOT}" "${rel}"
    printf '  git add %s && git commit -m "dashboards: update %s" && terraform apply\n' "${rel}" "${slug}"
  fi
}

main "$@"
