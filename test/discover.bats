#!/usr/bin/env bats
# discover phase: decides whether Argo CD should use this plugin for a source.

setup() {
  load helpers
  common_setup
}

@test "discover: empty directory does not match" {
  run_plugin discover
  assert_failure
}

@test "discover: helmfile.yaml matches" {
  write_helmfile helmfile.yaml
  run_plugin discover
  assert_success
}

@test "discover: helmfile.yaml.gotmpl matches" {
  write_helmfile helmfile.yaml.gotmpl
  run_plugin discover
  assert_success
}

@test "discover: helmfile.d directory matches" {
  write_helmfile helmfile.d/10-probe.yaml
  run_plugin discover
  assert_success
}

@test "discover: helmfile.yaml in a subdirectory only does not match" {
  write_helmfile nested/helmfile.yaml
  run_plugin discover
  assert_failure
}

@test "discover: HELMFILE_HELMFILE set matches without files" {
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  run_plugin discover
  assert_success
}

@test "discover: --file in HELMFILE_GLOBAL_OPTIONS matches without files" {
  export ARGOCD_ENV_HELMFILE_GLOBAL_OPTIONS="--file custom/helmfile.yaml"
  run_plugin discover
  assert_success
}

@test "discover: -f in HELMFILE_GLOBAL_OPTIONS matches without files" {
  export ARGOCD_ENV_HELMFILE_GLOBAL_OPTIONS="-f custom/helmfile.yaml"
  run_plugin discover
  assert_success
}

@test "discover: PARAM_ values are honoured like ARGOCD_ENV_ values" {
  export PARAM_HELMFILE_GLOBAL_OPTIONS="--file custom/helmfile.yaml"
  run_plugin discover
  assert_success
}

@test "discover: option merely containing '-f' does not match" {
  skip "known bug: *-f* glob matches e.g. --kube-context=prod-frontend (fix planned)"
  export ARGOCD_ENV_HELMFILE_GLOBAL_OPTIONS="--kube-context=prod-frontend"
  run_plugin discover
  assert_failure
}

@test "discover: diagnostics do not go to stdout on no match" {
  run_plugin discover
  assert_failure
  assert_output ""
  assert_regex "${stderr}" "no valid helmfile content discovered"
}

# HELMFILE_DISCOVERY_RESPONSE also exercises truthy_test.
@test "discover: forced response is truthy for true/1/yes (any case)" {
  local v
  for v in true TRUE True 1 yes YES Yes; do
    export ARGOCD_ENV_HELMFILE_DISCOVERY_RESPONSE="${v}"
    run_plugin discover
    assert_success
    assert_output --partial "enabled"
  done
}

@test "discover: forced response is falsy for other values even if files exist" {
  write_helmfile helmfile.yaml
  local v
  for v in false FALSE 0 no off random 2; do
    export ARGOCD_ENV_HELMFILE_DISCOVERY_RESPONSE="${v}"
    run_plugin discover
    assert_failure
    assert_output ""
    assert_regex "${stderr}" "forced discovery response: disabled"
  done
}

@test "discover: forced response is not evaluated as arithmetic" {
  # [[ $val -eq 1 ]] used to evaluate the value, running command substitutions
  export ARGOCD_ENV_HELMFILE_DISCOVERY_RESPONSE='a[$(touch pwned)]'
  run_plugin discover
  assert_failure
  refute [ -e pwned ]
}
