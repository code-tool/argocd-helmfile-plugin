#!/usr/bin/env bats
# Environment handling: ARGOCD_ENV_/PARAM_ export, binaries, HOME isolation.

setup() {
  load helpers
  common_setup
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

@test "env: HOME is isolated to PLUGIN_APP_HOME for helmfile" {
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
  assert_equal "$(probe_value marker)" "${PLUGIN_APP_HOME}"
  assert [ -d "${PLUGIN_APP_HOME}" ]
}

@test "env: PLUGIN_APP_HOME is variable-expanded" {
  write_helmfile helmfile.yaml
  export PROBE_BASE="${BATS_TEST_TMPDIR}/expanded"
  export PLUGIN_APP_HOME='${PROBE_BASE}/home'
  plugin_init
  assert [ -d "${BATS_TEST_TMPDIR}/expanded/home" ]
  refute_regex "${stderr}" "HELM_HOME is deprecated"
}

@test "env: HELM_HOME still works as deprecated alias with a warning" {
  write_helmfile helmfile.yaml
  unset PLUGIN_APP_HOME
  export PROBE_BASE="${BATS_TEST_TMPDIR}/legacy"
  export HELM_HOME='${PROBE_BASE}/home'
  plugin_init
  assert [ -d "${BATS_TEST_TMPDIR}/legacy/home" ]
  assert_regex "${stderr}" "WARNING: HELM_HOME is deprecated, use PLUGIN_APP_HOME instead"
}

@test "env: HELM_HOME from the application spec is accepted as alias" {
  write_helmfile helmfile.yaml
  unset PLUGIN_APP_HOME
  export ARGOCD_ENV_HELM_HOME="${BATS_TEST_TMPDIR}/legacy-env"
  plugin_init
  assert [ -d "${BATS_TEST_TMPDIR}/legacy-env" ]
  assert_regex "${stderr}" "HELM_HOME is deprecated"
}

@test "env: PLUGIN_APP_HOME wins over HELM_HOME" {
  write_helmfile helmfile.yaml
  export HELM_HOME="${BATS_TEST_TMPDIR}/legacy"
  plugin_init
  assert [ -d "${PLUGIN_APP_HOME}" ]
  refute [ -d "${BATS_TEST_TMPDIR}/legacy" ]
  refute_regex "${stderr}" "HELM_HOME is deprecated"
}

@test "env: HELM_HOME is exported equal to PLUGIN_APP_HOME for init scripts" {
  write_helmfile helmfile.yaml
  cat >init.sh <<'SH'
echo "${HELM_HOME}" >homes.txt
echo "${PLUGIN_APP_HOME}" >>homes.txt
echo "${HOME}" >>homes.txt
SH
  export ARGOCD_ENV_HELMFILE_INIT_SCRIPT_FILE="init.sh"
  plugin_init
  run cat homes.txt
  assert_line --index 0 "${PLUGIN_APP_HOME}"
  assert_line --index 1 "${PLUGIN_APP_HOME}"
  assert_line --index 2 "${PLUGIN_APP_HOME}"
}

@test "env: default PLUGIN_APP_HOME is per application" {
  write_helmfile helmfile.yaml
  unset PLUGIN_APP_HOME
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
  HELM_BINARY="$(make_call_logger helm)"
  export HELM_BINARY
  plugin_init
  run_plugin generate
  assert_success
  run grep -c '^helm template' "${BATS_TEST_TMPDIR}/helm-calls.log"
  assert_success
}

@test "env: HELMFILE_BINARY is used for helmfile calls" {
  write_helmfile helmfile.yaml
  HELMFILE_BINARY="$(make_call_logger helmfile)"
  export HELMFILE_BINARY
  plugin_init
  run_plugin generate
  assert_success
  run grep -c ' template ' "${BATS_TEST_TMPDIR}/helmfile-calls.log"
  assert_success
}

@test "env: PATH from ARGOCD_ENV_ is variable-expanded" {
  write_helmfile helmfile.yaml
  make_call_logger helm >/dev/null
  export PROBE_WRAP="${BATS_TEST_TMPDIR}/wrap"
  export ARGOCD_ENV_PATH="\${PROBE_WRAP}:${PATH}"
  plugin_init
  assert [ -s "${BATS_TEST_TMPDIR}/helm-calls.log" ]
}
