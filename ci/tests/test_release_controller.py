"""Phase 6J safety tests. All simulated; no AWS, ECS or Woodpecker requests."""
import json
from pathlib import Path
from subprocess import CompletedProcess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_controller as rc  # noqa: E402

SHA = "a" * 40
TAG = f"{SHA}-17"
PIPELINE = {"number": 17, "commit": SHA, "status": "success"}
OK_PREVIEW = '\n'.join([
    f'ECR verified: slice-sip-frontend tag {TAG}',
    f'ECR verified: slice-sip-backend tag {TAG}',
    'READ-ONLY PREVIEW COMPLETE: No AWS resources were modified',
])


class ReleaseTests(unittest.TestCase):
    def test_candidate_number_must_match(self):
        self.assertEqual(rc.validate_candidate(PIPELINE, TAG), 17)
        with self.assertRaises(rc.ReleaseError):
            rc.validate_candidate(PIPELINE, f"{SHA}-18")

    def test_failed_ansible_preflight_is_blocked(self):
        with self.assertRaises(rc.ReleaseError):
            rc.classify_preview(CompletedProcess([], 1, OK_PREVIEW, ""), TAG)

    def test_missing_ecr_image_is_blocked(self):
        with self.assertRaises(rc.ReleaseError):
            rc.classify_preview(CompletedProcess([], 0, f"ECR verified: slice-sip-frontend tag {TAG}", ""), TAG)

    def test_not_ready_is_not_reported_as_ready(self):
        result = CompletedProcess([], 0, OK_PREVIEW + "\nNOT READY: no cluster", "")
        self.assertEqual(rc.classify_preview(result, TAG), "not_ready")

    def test_ready_requires_both_images_and_completion(self):
        self.assertEqual(rc.classify_preview(CompletedProcess([], 0, OK_PREVIEW, ""), TAG), "ready")

    def test_previous_attempt_fails_closed(self):
        pending = {"version": 1, "last_attempt": {"number": 16, "status": "awaiting_verification"}}
        self.assertNotEqual(rc.determine_decision(17, pending), "new")
        self.assertEqual(rc.determine_decision(17, {"version": 1, "last_attempt": None}), "new")

    def test_malformed_state_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bad.json"
            path.write_text(json.dumps({"version": 1, "last_attempt": {"number": "bad"}}))
            with self.assertRaises(rc.ReleaseError):
                rc.load_state(path)

    def test_live_gate_absent(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(rc.ReleaseError):
                rc.check_live_gate(Path(folder) / "missing")

    def test_preview_makes_no_write_calls(self):
        fake = CompletedProcess([], 0, OK_PREVIEW + "\nNOT READY: no ECS cluster", "")
        with (patch.object(rc.os, "geteuid", return_value=0),
              patch.object(rc, "exclusive_lock"),
              patch.object(rc, "load_state", return_value={"version": 1, "last_attempt": None}),
              patch.object(rc, "read_token", return_value="fake"),
              patch.object(rc, "find_candidate", return_value=(PIPELINE, TAG)),
              patch.object(rc, "run_process", return_value=fake) as process,
              patch.object(rc, "write_state") as writer):
            self.assertEqual(rc.release(preview=True), 0)
            writer.assert_not_called()
            self.assertEqual(process.call_count, 1)
            self.assertNotIn("deploy_enabled=true", process.call_args.args[0])

    def test_deploy_requires_authorization_before_aws(self):
        with (patch.object(rc.os, "geteuid", return_value=0),
              patch.object(rc, "exclusive_lock"),
              patch.object(rc, "load_state", return_value={"version": 1, "last_attempt": None}),
              patch.object(rc, "read_token") as reader,
              patch.object(rc, "check_live_gate") as gate):
            with self.assertRaises(rc.ReleaseError):
                rc.release(preview=False)
            reader.assert_not_called()
            gate.assert_not_called()

    def test_deploy_approval_file_required(self):
        with (patch.object(rc.os, "geteuid", return_value=0),
              patch.object(rc, "exclusive_lock"),
              patch.object(rc, "load_state", return_value={"version": 1, "last_attempt": None}),
              patch.object(rc, "check_live_gate", side_effect=rc.ReleaseError("disabled")),
              patch.object(rc, "read_token") as reader):
            with self.assertRaises(rc.ReleaseError):
                rc.release(preview=False, expected_tag=TAG, confirm=rc.APPROVAL)
            reader.assert_not_called()

    def test_deploy_refuses_changed_candidate(self):
        fake = CompletedProcess([], 0, OK_PREVIEW, "")
        with (patch.object(rc.os, "geteuid", return_value=0),
              patch.object(rc, "exclusive_lock"),
              patch.object(rc, "load_state", return_value={"version": 1, "last_attempt": None}),
              patch.object(rc, "check_live_gate"),
              patch.object(rc, "read_token", return_value="fake"),
              patch.object(rc, "find_candidate", side_effect=[(PIPELINE, TAG),
                          ({"number": 18}, f"{'b'*40}-18")]),
              patch.object(rc, "run_process", return_value=fake),
              patch.object(rc, "healthy_service", return_value=True),
              patch.object(rc, "write_state") as writer):
            with self.assertRaises(rc.ReleaseError):
                rc.release(preview=False, expected_tag=TAG, confirm=rc.APPROVAL)
            writer.assert_not_called()

    def test_deploy_records_attempt_before_write(self):
        calls = []
        def recorded_write(state):
            calls.append(("state", state["last_attempt"]["status"]))
        def mock_process(command, **kwargs):
            if 'deploy_enabled=true' in command:
                calls.append(("deploy", "issued"))
                return CompletedProcess(command, 0, "Requested ECS deployment:", "")
            return CompletedProcess(command, 0, OK_PREVIEW, "")
        with (patch.object(rc.os, "geteuid", return_value=0),
              patch.object(rc, "exclusive_lock"),
              patch.object(rc, "load_state", return_value={"version": 1, "last_attempt": None}),
              patch.object(rc, "check_live_gate"),
              patch.object(rc, "read_token", return_value="fake"),
              patch.object(rc, "find_candidate", return_value=(PIPELINE, TAG)),
              patch.object(rc, "run_process", side_effect=mock_process),
              patch.object(rc, "healthy_service", return_value=True),
              patch.object(rc, "write_state", side_effect=recorded_write)):
            self.assertEqual(rc.release(preview=False, expected_tag=TAG, confirm=rc.APPROVAL), 0)
            self.assertEqual(calls, [("state", "started"), ("deploy", "issued"),
                                     ("state", "awaiting_verification")])

    def test_failure_records_requires_review(self):
        records = []
        def mock_process(command, **kwargs):
            if 'deploy_enabled=true' in command:
                return CompletedProcess(command, 1, "", "redacted")
            return CompletedProcess(command, 0, OK_PREVIEW, "")
        with (patch.object(rc.os, "geteuid", return_value=0),
              patch.object(rc, "exclusive_lock"),
              patch.object(rc, "load_state", return_value={"version": 1, "last_attempt": None}),
              patch.object(rc, "check_live_gate"),
              patch.object(rc, "read_token", return_value="fake"),
              patch.object(rc, "find_candidate", return_value=(PIPELINE, TAG)),
              patch.object(rc, "run_process", side_effect=mock_process),
              patch.object(rc, "healthy_service", return_value=True),
              patch.object(rc, "write_state", side_effect=lambda x: records.append(x["last_attempt"]["status"]))):
            with self.assertRaises(rc.ReleaseError):
                rc.release(preview=False, expected_tag=TAG, confirm=rc.APPROVAL)
            self.assertEqual(records, ["started", "failed_requires_review"])


if __name__ == "__main__":
    unittest.main()
