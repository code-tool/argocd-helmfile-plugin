#!/usr/bin/env bats
# Tool version detection: Helm 2 is not supported, Helm >= 3.6 and
# helmfile >= 1 (>= 1.2 with Helm 4) are required. Versions are only checked in init/generate.

setup() {
  load helpers
  common_setup
  write_helmfile helmfile.yaml
}

@test "versions: helm and helmfile versions are logged to stderr" {
  run_plugin init
  assert_success
  assert_regex "${stderr}" "helm version v[0-9]+\.[0-9]+\.[0-9]+"
  assert_regex "${stderr}" "helmfile version v?[0-9]+\.[0-9]+"
  refute_output --partial "version"
}

@test "versions: current helm is accepted in init and generate" {
  plugin_init
  run_plugin generate
  assert_success
}

@test "versions: helm 2 is rejected" {
  HELM_BINARY="$(make_fake_version helm "v2.17.0")"
  export HELM_BINARY
  run_plugin init
  assert_failure
  assert_regex "${stderr}" "helm v2.17.0 is not supported, helm >= 3.6 is required"
}

@test "versions: helm 2 is rejected in generate" {
  HELM_BINARY="$(make_fake_version helm "v2.17.0")"
  export HELM_BINARY
  run_plugin generate
  assert_failure
  assert_output ""
  assert_regex "${stderr}" "helm >= 3.6 is required"
}

@test "versions: helm 3 and 4 versions are accepted" {
  local v
  # fake a helm 4 compatible helmfile so the real helmfile version does not matter
  HELMFILE_BINARY="$(make_fake_version helmfile "helmfile version 1.2.0")"
  export HELMFILE_BINARY
  for v in v3.6.0 v3.19.4 v4.0.0 v4.2.3; do
    HELM_BINARY="$(make_fake_version helm "${v}")"
    export HELM_BINARY
    run_plugin init
    assert_success
    assert_regex "${stderr}" "helm version ${v}"
  done
}

@test "versions: helm older than 3.6 is rejected" {
  local v
  for v in v3.0.0 v3.5.4; do
    HELM_BINARY="$(make_fake_version helm "${v}")"
    export HELM_BINARY
    run_plugin init
    assert_failure
    assert_regex "${stderr}" "helm ${v} is not supported, helm >= 3.6 is required"
  done
}

@test "versions: helmfile older than 1.2 is rejected with helm 4" {
  HELM_BINARY="$(make_fake_version helm "v4.0.0")"
  HELMFILE_BINARY="$(make_fake_version helmfile "helmfile version 1.1.9")"
  export HELM_BINARY HELMFILE_BINARY
  run_plugin init
  assert_failure
  assert_regex "${stderr}" "helmfile >= 1.2 is required for helm 4"
}

@test "versions: helmfile 1.2 is accepted with helm 4" {
  HELM_BINARY="$(make_fake_version helm "v4.0.0")"
  HELMFILE_BINARY="$(make_fake_version helmfile "helmfile version 1.2.0")"
  export HELM_BINARY HELMFILE_BINARY
  run_plugin init
  assert_success
}

@test "versions: helmfile older than 1.2 is accepted with helm 3" {
  HELM_BINARY="$(make_fake_version helm "v3.19.4")"
  HELMFILE_BINARY="$(make_fake_version helmfile "helmfile version 1.1.9")"
  export HELM_BINARY HELMFILE_BINARY
  run_plugin init
  assert_success
}

@test "versions: unparsable helm version is rejected" {
  HELM_BINARY="$(make_fake_version helm "<no value>")"
  export HELM_BINARY
  run_plugin init
  assert_failure
  assert_regex "${stderr}" "unable to parse helm version"
}

@test "versions: failing helm binary is rejected" {
  export HELM_BINARY="${BATS_TEST_TMPDIR}/does-not-exist/helm"
  run_plugin init
  assert_failure
  assert_regex "${stderr}" "failed to run .* version"
}

@test "versions: helmfile 0.x is rejected" {
  HELMFILE_BINARY="$(make_fake_version helmfile "helmfile version v0.171.0")"
  export HELMFILE_BINARY
  run_plugin init
  assert_failure
  assert_regex "${stderr}" "helmfile >= 1 is required"
}

@test "versions: helmfile 1.x is accepted with and without v prefix" {
  local v
  for v in "helmfile version 1.5.2" "helmfile version v1.2.0"; do
    HELMFILE_BINARY="$(make_fake_version helmfile "${v}")"
    export HELMFILE_BINARY
    run_plugin init
    assert_success
  done
}

@test "versions: unparsable helmfile version is rejected" {
  HELMFILE_BINARY="$(make_fake_version helmfile "something else")"
  export HELMFILE_BINARY
  run_plugin init
  assert_failure
  assert_regex "${stderr}" "unable to parse helmfile version"
}

@test "versions: discover and parameters do not run helm or helmfile" {
  HELM_BINARY="$(make_call_logger helm)"
  HELMFILE_BINARY="$(make_call_logger helmfile)"
  export HELM_BINARY HELMFILE_BINARY
  run_plugin discover
  assert_success
  run_plugin parameters
  assert_success
  refute [ -e "${BATS_TEST_TMPDIR}/helm-calls.log" ]
  refute [ -e "${BATS_TEST_TMPDIR}/helmfile-calls.log" ]
}

@test "versions: discover and parameters work even with helm 2" {
  HELM_BINARY="$(make_fake_version helm "v2.17.0")"
  export HELM_BINARY
  run_plugin discover
  assert_success
  run_plugin parameters
  assert_success
}

@test "versions: plugin queries the helm version once per phase" {
  HELM_BINARY="$(make_call_logger helm)"
  export HELM_BINARY
  plugin_init
  # helmfile runs its own "helm version --short"; only count the plugin's query
  run grep -c '^helm version --template' "${BATS_TEST_TMPDIR}/helm-calls.log"
  assert_output "1"
}

@test "versions: helm init is never called" {
  HELM_BINARY="$(make_call_logger helm)"
  export HELM_BINARY
  plugin_init
  run grep '^helm init' "${BATS_TEST_TMPDIR}/helm-calls.log"
  assert_failure
}

@test "versions: HELMFILE_HELM3 is not exported" {
  cat >helmfile.yaml.gotmpl <<YAML
releases:
  - name: probe
    chart: ${WORK}/chart
    set:
      - name: marker
        value: helm3-[{{ env "HELMFILE_HELM3" }}]
YAML
  rm helmfile.yaml
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "helm3-[]"
}
