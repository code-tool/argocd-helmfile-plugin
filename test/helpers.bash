# shellcheck shell=bash
# Variables set here are used by the .bats files; $output/$stderr are set by bats.
# shellcheck disable=SC2034,SC2154
# Shared setup for all bats tests.
#
# Every test gets its own work directory (a fake Argo CD source checkout) and
# its own PLUGIN_APP_HOME, so tests never share caches, repos or helmfile state.

bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
PLUGIN="${REPO_ROOT}/src/argocd-helmfile-plugin.sh"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

# Name of the directory the plugin generates for HELMFILE_HELMFILE.
INJECTED_DIR=".__argocd-helmfile-plugin.sh__helmfile.d"

common_setup() {
  WORK="${BATS_TEST_TMPDIR}/src"
  mkdir -p "${WORK}"
  cp -r "${FIXTURES}/chart-probe" "${WORK}/chart"
  cd "${WORK}" || return 1

  # Standard Argo CD build environment.
  export ARGOCD_APP_NAME="test-app"
  export ARGOCD_APP_NAMESPACE="test-ns"
  export ARGOCD_APP_REVISION="0000000000000000000000000000000000000000"
  export ARGOCD_APP_SOURCE_PATH="."
  export ARGOCD_APP_SOURCE_REPO_URL="https://example.invalid/repo.git"
  export ARGOCD_APP_SOURCE_TARGET_REVISION="main"

  # Isolate helm/helmfile state per test.
  unset HELM_HOME
  export PLUGIN_APP_HOME="${BATS_TEST_TMPDIR}/home"
  export HELM_CACHE_HOME="${BATS_TEST_TMPDIR}/helm/cache"
  export HELM_CONFIG_HOME="${BATS_TEST_TMPDIR}/helm/config"
  export HELM_DATA_HOME="${BATS_TEST_TMPDIR}/helm/data"

  # Make sure nothing from the developer's shell leaks into the plugin.
  unset DEBUG KUBE_VERSION KUBE_API_VERSIONS \
    HELM_BINARY HELMFILE_BINARY \
    HELM_TEMPLATE_OPTIONS HELMFILE_TEMPLATE_OPTIONS HELMFILE_GLOBAL_OPTIONS \
    HELMFILE_HELMFILE HELMFILE_HELMFILE_STRATEGY HELMFILE_INIT_SCRIPT_FILE \
    HELMFILE_ENV_FILE HELMFILE_CACHE_CLEANUP HELMFILE_REPO_CACHE_TIMEOUT \
    HELMFILE_USE_CONTEXT_NAMESPACE HELMFILE_DISCOVERY_RESPONSE
  # No cluster is available in tests.
  export KUBECONFIG="${BATS_TEST_TMPDIR}/no-kubeconfig"
}

# Write a helmfile.yaml with a single release pointing at the probe chart.
# Usage: write_helmfile [file] [release-name]
write_helmfile() {
  local file="${1:-helmfile.yaml}" name="${2:-probe}"
  mkdir -p "$(dirname "${file}")"
  cat >"${file}" <<YAML
releases:
  - name: ${name}
    chart: ${WORK}/chart
YAML
}

# Run a plugin phase. stdout and stderr are kept apart because Argo CD
# treats stdout of "generate" as the manifests.
#   $status  exit code
#   $output  stdout
#   $stderr  stderr
run_plugin() {
  run --separate-stderr bash "${PLUGIN}" "$@"
}

# Run init and fail the test if it fails.
plugin_init() {
  run_plugin init
  assert_success
}

# Create a fake binary that answers version queries with fixed output and
# passes everything else to the real binary. Prints the path of the fake.
# Usage: make_fake_version <helm|helmfile> <version output>
make_fake_version() {
  local tool="$1" version_output="$2" real dir
  real="$(command -v "${tool}")"
  dir="${BATS_TEST_TMPDIR}/fake-${tool}"
  mkdir -p "${dir}"
  cat >"${dir}/${tool}" <<SH
#!/bin/bash
case "\$*" in
  "version --template {{.Version}}" | "--version") echo "${version_output}" ;;
  *) exec "${real}" "\$@" ;;
esac
SH
  chmod +x "${dir}/${tool}"
  echo "${dir}/${tool}"
}

# Create a wrapper for a real binary that records each call to
# ${BATS_TEST_TMPDIR}/<tool>-calls.log. Prints the path of the wrapper.
# Usage: make_call_logger <helm|helmfile>
make_call_logger() {
  local tool="$1" real dir
  real="$(command -v "${tool}")"
  dir="${BATS_TEST_TMPDIR}/wrap"
  mkdir -p "${dir}"
  cat >"${dir}/${tool}" <<SH
#!/bin/bash
echo "${tool} \$*" >>"${BATS_TEST_TMPDIR}/${tool}-calls.log"
exec "${real}" "\$@"
SH
  chmod +x "${dir}/${tool}"
  echo "${dir}/${tool}"
}

# Print the value of a key from the rendered probe ConfigMap(s).
# Usage: probe_value <key> [release-name]
probe_value() {
  local key="$1" name="${2:-probe}"
  printf '%s\n' "${output}" |
    awk -v name="${name}" -v key="${key}" '
      /^---/                          { in_doc = 0 }
      $1 == "name:" && $2 == name     { in_doc = 1 }
      in_doc && $1 == key ":"         { v = $2; gsub(/"/, "", v); print v; exit }
    '
}
