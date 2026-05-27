# AXON Testing & Release

> Source: `tests/test-framework.sh`, `tests/run-all-tests.sh`, `release/create-release.sh`, `.github/workflows/release.yml`.

## Contents
- [Test framework](#test-framework)
- [Writing a test](#writing-a-test)
- [Running tests](#running-tests)
- [Release](#release)

## Test framework

Custom, dependency-free, Bash 3.2 compatible. No bats, no node. Source `tests/test-framework.sh`.

**Mocking** — works by prepending a temp dir to `PATH`:
- `setup_mocks` / `teardown_mocks` — create/destroy the mock `PATH` dir. Call `setup_mocks` first or `mock_command` errors.
- `mock_command <name> <exit_code> [output]` — stub a command (e.g. `ssh`, `docker`, `yq`).
- `mock_command_with_capture <name> <exit_code> <capture_file> [output]` — same, but writes the call's args to `capture_file` so you can assert what was invoked.
- `mock_file <path> <content>` — create a fixture file (makes parent dirs).

**Assertions** — `assert_success` / `assert_failure` read `$?`, so call them on the line right after the command under test:
- `assert_success`, `assert_failure` (check `$?`)
- `assert_equals <expected> <actual>`, `assert_contains <haystack> <needle>`
- `assert_file_exists <path>`, `assert_file_not_exists <path>`

**Runner glue** — `run_test <name> <function>` runs a test fn in isolation and records pass/fail; `print_summary` prints totals.

## Writing a test

```bash
test_deploy_calls_ssh() {
    setup_mocks
    mock_command "yq" 0 "production"
    mock_command_with_capture "ssh" 0 "$capture"
    # ... invoke the code under test ...
    assert_success
    teardown_mocks
}
run_test "deploy calls ssh" test_deploy_calls_ssh
```

Mock every external command the path touches (`ssh`, `docker`, `yq`, `curl`) — tests must not hit real servers or registries. Put inline config fixtures in a temp dir via `mock_file`.

## Running tests

```bash
./tests/run-all-tests.sh          # full suite
./tests/run-tests.sh <pattern>    # subset
```

Each suite is a `tests/test-*.sh` file. Run the full suite before finishing any change.

## Release

Maintainer flow — do not run unless asked to cut a release.

1. `./release/create-release.sh` — validates semver (`X.Y.Z`), checks for uncommitted changes, writes `VERSION`, commits, creates annotated tag `vX.Y.Z`, pushes.
2. Pushing a `v*.*.*` tag fires `.github/workflows/release.yml`, which (on `ubuntu-latest`, with the `homebrew-tap` submodule checked out): generates a changelog, creates the GitHub Release, computes the tarball `sha256` (`curl ... | sha256sum`), updates `homebrew-tap/Formula/axon.rb` (version + url + sha256), and commits/pushes the formula.

The Homebrew formula lives in the separate `ezoushen/homebrew-axon` repo, referenced here as the `homebrew-tap` submodule. Do not hand-edit the formula — CI owns it.

## Anti-patterns

- **Calling `assert_success` away from the command** — it reads `$?`; intervening commands clobber it. Assert immediately.
- **Tests that reach real `ssh`/`docker`/registry** — always `mock_command` them; un-mocked, they mutate real infra.
- **Hand-editing `homebrew-tap/Formula/axon.rb` or bumping `VERSION` manually** — use `create-release.sh`; CI regenerates the formula.
