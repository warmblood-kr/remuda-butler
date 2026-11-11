# Fast and deep verification

Pull requests and pushes to `main` run the daemon-free fast checks in
`tests/fast_tests.sh` plus repository policy checks. The fast set exercises
permission rules, native identity resolution, inbox and relay storage logic,
delivery and notification decisions, scheduling, guidance parity, lifecycle
recovery, and private-test-envelope admission and cleanup. These are focused
logic and contract tests; they do not prove real daemon integration.

Run the complete private-daemon shell suite, Rust integration tests, guidance
goldens, Windows path tests, and the Butler/core contract gate on demand using
the **tests** workflow's `workflow_dispatch` action. Locally,
`tests/shell_tests.sh` still runs the full shell suite by default. Race,
restart, upgrade, stress, and live integration scenarios remain in that deep
suite. Run it before releases and when changes affect these boundaries.

The target for default CI is three minutes of workflow execution, not a hard
guarantee about GitHub runner queueing or package download latency. Measure
both cold and warm runs after changing the workflow. A passing fast suite is
not evidence that the on-demand deep suite passed.
