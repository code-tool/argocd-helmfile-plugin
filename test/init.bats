#!/usr/bin/env bats
# init phase: runs before every generate. Prepares helmfile input and repos.

setup() {
  load helpers
  common_setup
}


@test "init: succeeds for a plain helmfile.yaml" {
  write_helmfile helmfile.yaml
  run_plugin init
  assert_success
  assert_regex "${stderr}" "starting init"
}

@test "init: fails without a phase argument" {
  run_plugin
  assert_failure
  assert_regex "${stderr}" "invalid invocation"
}

@test "init: fails for an unknown phase" {
  run_plugin bogus
  assert_failure
  assert_regex "${stderr}" "invalid invocation"
}

# --- repo cache -------------------------------------------------------------

@test "init: repos update runs every time without HELMFILE_REPO_CACHE_TIMEOUT" {
  write_helmfile helmfile.yaml
  plugin_init
  run_plugin init
  assert_success
  refute_regex "${stderr}" "skipping repos update due to cache"
}

@test "init: repos update is skipped within HELMFILE_REPO_CACHE_TIMEOUT" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELMFILE_REPO_CACHE_TIMEOUT="300"
  plugin_init
  refute_regex "${stderr}" "skipping repos update due to cache"
  run_plugin init
  assert_success
  assert_regex "${stderr}" "skipping repos update due to cache"
}

@test "init: a new revision busts the repo cache" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELMFILE_REPO_CACHE_TIMEOUT="300"
  plugin_init
  export ARGOCD_APP_REVISION="1111111111111111111111111111111111111111"
  run_plugin init
  assert_success
  refute_regex "${stderr}" "skipping repos update due to cache"
}

@test "init: HELMFILE_CACHE_CLEANUP=true succeeds" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELMFILE_CACHE_CLEANUP="true"
  run_plugin init
  assert_success
}

# --- init script ------------------------------------------------------------

@test "init: HELMFILE_INIT_SCRIPT_FILE is executed in the source directory" {
  write_helmfile helmfile.yaml
  cat >init.sh <<'SH'
pwd >init-ran.txt
SH
  export ARGOCD_ENV_HELMFILE_INIT_SCRIPT_FILE="init.sh"
  plugin_init
  assert [ -f init-ran.txt ]
  assert_equal "$(cat init-ran.txt)" "${WORK}"
}

@test "init: HELMFILE_INIT_SCRIPT_FILE path is variable-expanded" {
  write_helmfile helmfile.yaml
  mkdir scripts
  printf 'touch init-ran.txt\n' >scripts/init.sh
  export PROBE_SCRIPTS_DIR="scripts"
  export ARGOCD_ENV_HELMFILE_INIT_SCRIPT_FILE='${PROBE_SCRIPTS_DIR}/init.sh'
  plugin_init
  assert [ -f init-ran.txt ]
}

@test "init: a failing HELMFILE_INIT_SCRIPT_FILE fails init" {
  write_helmfile helmfile.yaml
  printf 'exit 3\n' >init.sh
  export ARGOCD_ENV_HELMFILE_INIT_SCRIPT_FILE="init.sh"
  run_plugin init
  assert_failure
}

# --- HELMFILE_HELMFILE ------------------------------------------------------

@test "init: HELMFILE_HELMFILE defaults to REPLACE and ignores repo helmfile" {
  write_helmfile helmfile.yaml from-repo
  write_helmfile "${BATS_TEST_TMPDIR}/injected.yaml" from-param
  ARGOCD_ENV_HELMFILE_HELMFILE="$(cat "${BATS_TEST_TMPDIR}/injected.yaml")"
  export ARGOCD_ENV_HELMFILE_HELMFILE
  plugin_init
  run ls -A "${INJECTED_DIR}"
  assert_output "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ__argocd__helmfile__.yaml"

  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName from-param)" "from-param"
  assert_equal "$(probe_value releaseName from-repo)" ""
}

@test "init: HELMFILE_HELMFILE with INCLUDE renders repo helmfile.yaml and param" {
  write_helmfile helmfile.yaml from-repo
  write_helmfile "${BATS_TEST_TMPDIR}/injected.yaml" from-param
  ARGOCD_ENV_HELMFILE_HELMFILE="$(cat "${BATS_TEST_TMPDIR}/injected.yaml")"
  export ARGOCD_ENV_HELMFILE_HELMFILE
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="INCLUDE"
  plugin_init
  assert [ -f "${INJECTED_DIR}/helmfile.yaml" ]

  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName from-param)" "from-param"
  assert_equal "$(probe_value releaseName from-repo)" "from-repo"
}

@test "init: INCLUDE copies helmfile.yaml.gotmpl" {
  write_helmfile helmfile.yaml.gotmpl from-repo
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="INCLUDE"
  plugin_init
  assert [ -f "${INJECTED_DIR}/helmfile.yaml.gotmpl" ]
}

@test "init: INCLUDE copies the contents of helmfile.d" {
  write_helmfile helmfile.d/10-one.yaml one
  write_helmfile helmfile.d/20-two.yaml two
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="INCLUDE"
  plugin_init
  assert [ -f "${INJECTED_DIR}/10-one.yaml" ]
  assert [ -f "${INJECTED_DIR}/20-two.yaml" ]

  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName one)" "one"
  assert_equal "$(probe_value releaseName two)" "two"
}

@test "init: INCLUDE warns when more than one helmfile source exists" {
  # Current behaviour is a warning only; planned to become a hard failure.
  write_helmfile helmfile.yaml
  write_helmfile helmfile.d/10-one.yaml one
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="INCLUDE"
  run_plugin init
  assert_regex "${stderr}" "but not more than one"
}

@test "init: invalid HELMFILE_HELMFILE_STRATEGY fails" {
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="MERGE"
  run_plugin init
  assert_failure
  assert_regex "${stderr}" "invalid .HELMFILE_HELMFILE_STRATEGY"
}

@test "init: re-running init removes stale injected files" {
  write_helmfile helmfile.yaml
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="INCLUDE"
  plugin_init
  assert [ -f "${INJECTED_DIR}/helmfile.yaml" ]
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="REPLACE"
  plugin_init
  refute [ -f "${INJECTED_DIR}/helmfile.yaml" ]
}

@test "init: INCLUDE keeps relative chart paths working" {
  # INCLUDE copies the repo helmfile into ${INJECTED_DIR}. With a directory of
  # helmfiles, helmfile >= 1.2 resolves relative chart paths against the
  # working directory, older versions against the copied file (known bug).
  local version
  version="$(helmfile --version | sed -E 's/.*version v?([0-9]+\.[0-9]+).*/\1/')"
  if [[ "$(printf '%s\n' "${version}" 1.2 | sort -V | head -1)" != "1.2" ]]; then
    skip "known bug: relative chart paths break with INCLUDE on helmfile ${version} < 1.2 (fix planned)"
  fi
  cat >helmfile.yaml <<'YAML'
releases:
  - name: probe
    chart: ./chart
YAML
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="INCLUDE"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName)" "probe"
}

@test "init: INCLUDE keeps relative values paths working" {
  skip "known bug: files are copied into ${INJECTED_DIR}, relative values paths break (fix planned)"
  printf 'marker: from-values-file\n' >values-probe.yaml
  cat >helmfile.yaml <<YAML
releases:
  - name: probe
    chart: ${WORK}/chart
    values:
      - values-probe.yaml
YAML
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases: []"
  export ARGOCD_ENV_HELMFILE_HELMFILE_STRATEGY="INCLUDE"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value marker)" "from-values-file"
}

@test "init: templated HELMFILE_HELMFILE is rendered" {
  skip "known bug: injected file is written as .yaml, helmfile v1 only templates .gotmpl (fix planned)"
  export ARGOCD_ENV_HELMFILE_HELMFILE="releases:
  - name: {{ \"probe\" }}
    chart: ${WORK}/chart"
  plugin_init
  run_plugin generate
  assert_success
  assert_equal "$(probe_value releaseName)" "probe"
}
