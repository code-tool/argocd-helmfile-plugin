#!/usr/bin/env bats
# Environment handling: ARGOCD_ENV_/PARAM_ export, binaries, HOME isolation.

setup() {
  load helpers
  common_setup
}

# Create a wrapper for a real binary that records each call.
# Usage: make_wrapper <tool> <dir>
make_wrapper() {
  local tool="$1" dir="$2" real
  real="$(command -v "${tool}")"
  mkdir -p "${dir}"
  cat >"${dir}/${tool}" <<SH
#!/bin/bash
echo "${tool} \$*" >>"${BATS_TEST_TMPDIR}/${tool}-calls.log"
exec "${real}" "\$@"
SH
  chmod +x "${dir}/${tool}"
}

@test "env: ARGOCD_ENV_ variables are available unprefixed to helmfile" {
  cat >helmfile.yaml.gotmpl <<YAML
releases:
  - name: probe
    chart: ${WORK}/chart
    set:
      - name: marker
        value: {{ requiredEnv "PROBE_MARKER" }}
YAML
  export ARGOCD_ENV_PROBE_MARKER="from-argocd-env"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-argocd-env"
}

@test "env: PARAM_ variables take precedence over ARGOCD_ENV_" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELM_TEMPLATE_OPTIONS="--set marker=from-env"
  export PARAM_HELM_TEMPLATE_OPTIONS="--set marker=from-param"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-param"
}

@test "env: HOME is isolated to HELM_HOME for helmfile" {
  cat >helmfile.yaml.gotmpl <<YAML
releases:
  - name: probe
    chart: ${WORK}/chart
    set:
      - name: marker
        value: {{ env "HOME" | quote }}
YAML
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "${HELM_HOME}"
  assert [ -d "${HELM_HOME}" ]
}

@test "env: HELM_HOME is variable-expanded" {
  write_helmfile helmfile.yaml
  export PROBE_BASE="${BATS_TEST_TMPDIR}/expanded"
  export HELM_HOME='${PROBE_BASE}/home'
  plugin_init
  assert [ -d "${BATS_TEST_TMPDIR}/expanded/home" ]
}

@test "env: default HELM_HOME is per application" {
  write_helmfile helmfile.yaml
  unset HELM_HOME
  export ARGOCD_APP_NAME="bats-$$-${BATS_TEST_NUMBER}"
  local expected="/tmp/__argocd-helmfile-plugin.sh__/apps/${ARGOCD_APP_NAME}"
  plugin_init
  assert [ -d "${expected}" ]
  rm -rf "${expected}"
}

@test "env: HELM_CACHE_HOME is variable-expanded and exported" {
  cat >helmfile.yaml.gotmpl <<YAML
releases:
  - name: probe
    chart: ${WORK}/chart
    set:
      - name: marker
        value: {{ env "HELM_CACHE_HOME" | quote }}
YAML
  export PROBE_BASE="${BATS_TEST_TMPDIR}/cachebase"
  export ARGOCD_ENV_HELM_CACHE_HOME='${PROBE_BASE}/cache'
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "${BATS_TEST_TMPDIR}/cachebase/cache"
}

@test "env: HELM_BINARY is used for helm calls" {
  write_helmfile helmfile.yaml
  make_wrapper helm "${BATS_TEST_TMPDIR}/wrap"
  export HELM_BINARY="${BATS_TEST_TMPDIR}/wrap/helm"
  plugin_init
  run_plugin generate
  assert_success
  run grep -c '^helm template' "${BATS_TEST_TMPDIR}/helm-calls.log"
  assert_success
}

@test "env: HELMFILE_BINARY is used for helmfile calls" {
  write_helmfile helmfile.yaml
  make_wrapper helmfile "${BATS_TEST_TMPDIR}/wrap"
  export HELMFILE_BINARY="${BATS_TEST_TMPDIR}/wrap/helmfile"
  plugin_init
  run_plugin generate
  assert_success
  run grep -c ' template ' "${BATS_TEST_TMPDIR}/helmfile-calls.log"
  assert_success
}

@test "env: PATH from ARGOCD_ENV_ is variable-expanded" {
  write_helmfile helmfile.yaml
  make_wrapper helm "${BATS_TEST_TMPDIR}/wrap"
  export PROBE_WRAP="${BATS_TEST_TMPDIR}/wrap"
  export ARGOCD_ENV_PATH="\${PROBE_WRAP}:${PATH}"
  plugin_init
  assert [ -s "${BATS_TEST_TMPDIR}/helm-calls.log" ]
}
