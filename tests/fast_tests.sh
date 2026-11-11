#!/usr/bin/env bash
# Fast, daemon-free logic and contract checks for every change.
set -euo pipefail
cd "$(dirname "$0")/.."

for test in \
  butler_inbox_db.lua relay_receipts_db.lua matrix_request_queue.lua \
  butler_lifecycle_reload.lua isolated_test_guard_test.lua \
  butler_permissions.lua butler_permissions_effective.lua butler_native_identity.lua \
  butler_guidance_parity.lua butler_guidance_blocks.lua butler_schedule.lua \
  butler_delivery_journal.lua butler_notice_native.lua butler_notice_send.lua \
  butler_notice_modal.lua butler_notice_retry.lua butler_notice_deferred.lua \
  butler_notice_refresh_policy.lua butler_notice_refresh_end_to_end.lua; do
  luajit "tests/$test"
  echo "PASS $test"
done
bash tests/isolated_env_admission_test.sh
bash tests/isolated_env_cleanup_test.sh
echo 'fast tests: PASS'
