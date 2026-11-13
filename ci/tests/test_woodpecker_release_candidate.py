"""Offline tests: no AWS or Woodpecker API calls."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from woodpecker_release_candidate import CandidateError, select_candidate  # noqa: E402


SHA_A = "a" * 40
SHA_B = "b" * 40


def pipeline(n, sha=SHA_A, status="success", branch="devops/woodpecker-fargate", event="push", **extras):
    return {"number": n, "commit": sha, "status": status, "branch": branch, "event": event, **extras}


class CandidateTests(unittest.TestCase):
    def test_success_tag(self):
        _, tag = select_candidate([pipeline(12)])
        self.assertEqual(tag, f"{SHA_A}-12")

    def test_latest_branch_push_wins(self):
        _, tag = select_candidate([pipeline(9), pipeline(11, sha=SHA_B)])
        self.assertEqual(tag, f"{SHA_B}-11")

    def test_latest_failed_push_is_not_replaced_with_stale_success(self):
        with self.assertRaises(CandidateError):
            select_candidate([pipeline(9), pipeline(10, status="failure")])

    def test_manual_or_wrong_branch_not_used(self):
        _, tag = select_candidate([
            pipeline(50, event="manual"),
            pipeline(40, branch="main"),
            pipeline(12),
        ])
        self.assertEqual(tag, f"{SHA_A}-12")

    def test_fork_rejected(self):
        with self.assertRaises(CandidateError):
            select_candidate([pipeline(10, from_fork=True)])

    def test_short_sha_rejected(self):
        with self.assertRaises(CandidateError):
            select_candidate([pipeline(12, sha="abc1234")])

    def test_invalid_pipeline_number_rejected(self):
        with self.assertRaises(CandidateError):
            select_candidate([pipeline("12")])

    def test_unexpected_response_rejected(self):
        with self.assertRaises(CandidateError):
            select_candidate({"pipelines": []})


if __name__ == "__main__":
    unittest.main()
