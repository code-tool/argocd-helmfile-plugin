#!/usr/bin/env bats
# generate phase: renders manifests to stdout.

setup() {
  load helpers
  common_setup
}

@test "generate: renders helmfile.yaml" {
  write_helmfile helmfile.yaml
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName)" "probe"
}

@test "generate: renders helmfile.yaml.gotmpl with templating" {
  cat >helmfile.yaml.gotmpl <<YAML
releases:
  - name: {{ "probe" }}
    chart: ${WORK}/chart
    set:
      - name: marker
        value: {{ printf "%s-%s" "from" "gotmpl" }}
YAML
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-gotmpl"
}

@test "generate: renders all files in helmfile.d" {
  write_helmfile helmfile.d/10-one.yaml one
  write_helmfile helmfile.d/20-two.yaml two
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName one)" "one"
  assert_equal "$(probe_value releaseName two)" "two"
}

@test "generate: stdout contains only manifests" {
  write_helmfile helmfile.yaml
  plugin_init
  run_plugin generate
  assert_success
  refute_output --partial "starting generate"
  refute_output --partial "helm version"
  refute_output --partial "helmfile version"
  # Output starts with a YAML document marker.
  assert_line --index 0 "---"
  # Diagnostics go to stderr.
  assert_regex "${stderr}" "starting generate"
}

@test "generate: uses ARGOCD_APP_NAMESPACE as release namespace" {
  write_helmfile helmfile.yaml
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseNamespace)" "test-ns"
}

@test "generate: HELMFILE_USE_CONTEXT_NAMESPACE=true does not force ARGOCD_APP_NAMESPACE" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELMFILE_USE_CONTEXT_NAMESPACE="true"
  plugin_init
  run_plugin generate
  assert_success
  refute [ "$(probe_value releaseNamespace)" = "test-ns" ]
}

@test "generate: namespace set on a release wins with HELMFILE_USE_CONTEXT_NAMESPACE" {
  cat >helmfile.yaml <<YAML
releases:
  - name: probe
    namespace: other-ns
    chart: ${WORK}/chart
YAML
  export ARGOCD_ENV_HELMFILE_USE_CONTEXT_NAMESPACE="true"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseNamespace)" "other-ns"
}

@test "generate: HELM_TEMPLATE_OPTIONS is passed to helm template" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELM_TEMPLATE_OPTIONS="--set marker=from-helm-options"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-helm-options"
}

@test "generate: HELMFILE_TEMPLATE_OPTIONS is passed to helmfile template" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELMFILE_TEMPLATE_OPTIONS="--set marker=from-helmfile-options"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-helmfile-options"
}

@test "generate: HELMFILE_GLOBAL_OPTIONS selects the environment" {
  cat >helmfile.yaml.gotmpl <<YAML
environments:
  default: {}
  staging: {}
---
releases:
  - name: probe
    chart: ${WORK}/chart
    set:
      - name: marker
        value: env-{{ .Environment.Name }}
YAML
  export ARGOCD_ENV_HELMFILE_GLOBAL_OPTIONS="--environment staging"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "env-staging"
}

@test "generate: HELMFILE_GLOBAL_OPTIONS selector limits releases" {
  write_helmfile helmfile.d/10-one.yaml one
  write_helmfile helmfile.d/20-two.yaml two
  export ARGOCD_ENV_HELMFILE_GLOBAL_OPTIONS="--selector name=two"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName one)" ""
  assert_equal "$(probe_value releaseName two)" "two"
}

@test "generate: selector without matches is not an error" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELMFILE_GLOBAL_OPTIONS="--selector name=does-not-exist"
  plugin_init
  run_plugin generate
  assert_success
}

@test "generate: helmfile errors fail the phase" {
  printf 'releases: [this is: not valid\n' >helmfile.yaml
  run_plugin generate
  assert_failure
}

@test "generate: HELMFILE_ENV_FILE is sourced" {
  write_helmfile helmfile.yaml
  cat >custom.env <<'ENV'
HELM_TEMPLATE_OPTIONS="--set marker=from-env-file"
ENV
  export ARGOCD_ENV_HELMFILE_ENV_FILE="custom.env"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-env-file"
}

@test "generate: default env file .argo-cd-helmfile-env is sourced" {
  write_helmfile helmfile.yaml
  cat >.argo-cd-helmfile-env <<'ENV'
HELM_TEMPLATE_OPTIONS="--set marker=from-default-env-file"
ENV
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-default-env-file"
}

@test "generate: variables in HELM_TEMPLATE_OPTIONS are expanded" {
  write_helmfile helmfile.yaml
  export PROBE_MARKER="from-expansion"
  export ARGOCD_ENV_HELM_TEMPLATE_OPTIONS='--set marker=${PROBE_MARKER}'
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-expansion"
}

@test "generate: options are not glob-expanded" {
  write_helmfile helmfile.yaml
  touch "marker=globbed"
  export ARGOCD_ENV_HELMFILE_TEMPLATE_OPTIONS="--set marker=*"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "*"
}

@test "generate: multi-line HELMFILE_GLOBAL_OPTIONS are all applied" {
  cat >helmfile.yaml.gotmpl <<YAML
environments:
  default: {}
  staging: {}
---
releases:
  - name: one
    chart: ${WORK}/chart
    set:
      - name: marker
        value: env-{{ .Environment.Name }}
  - name: two
    chart: ${WORK}/chart
YAML
  export ARGOCD_ENV_HELMFILE_GLOBAL_OPTIONS=$'--environment staging\n--selector name=one'
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker one)" "env-staging"
  assert_equal "$(probe_value releaseName two)" ""
}

@test "generate: failures report the phase once" {
  printf 'releases: [this is: not valid\n' >helmfile.yaml
  run_plugin generate
  assert_failure
  assert_output ""
  run grep -c "generate failed" <<<"${stderr}"
  assert_output "1"
}
