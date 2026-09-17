#!/usr/bin/env bats
# parameters phase: dynamic parameter announcement for the Argo CD UI.

setup() {
  load helpers
  common_setup
}

@test "parameters: prints valid JSON array on stdout" {
  run_plugin parameters
  assert_success
  run jq -e 'type == "array" and length > 0' <<<"${output}"
  assert_success
}

@test "parameters: every entry has name, title and tooltip" {
  run_plugin parameters
  assert_success
  run jq -e 'all(.[]; has("name") and has("title") and has("tooltip"))' <<<"${output}"
  assert_success
}

@test "parameters: announces the expected parameter names" {
  run_plugin parameters
  assert_success
  run jq -r '.[].name' <<<"${output}"
  assert_success
  assert_output "$(printf '%s\n' \
    HELM_TEMPLATE_OPTIONS \
    HELMFILE_TEMPLATE_OPTIONS \
    HELMFILE_GLOBAL_OPTIONS \
    HELMFILE_HELMFILE \
    HELMFILE_HELMFILE_STRATEGY \
    HELMFILE_INIT_SCRIPT_FILE \
    HELMFILE_CACHE_CLEANUP \
    HELMFILE_USE_CONTEXT_NAMESPACE)"
}

@test "parameters: boolean parameters are typed as boolean" {
  run_plugin parameters
  assert_success
  run jq -r '.[] | select(.itemType == "boolean") | .name' <<<"${output}"
  assert_output "$(printf '%s\n' HELMFILE_CACHE_CLEANUP HELMFILE_USE_CONTEXT_NAMESPACE)"
}
