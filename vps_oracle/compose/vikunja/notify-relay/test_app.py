import os

os.environ.setdefault("VIKUNJA_BASE_URL", "https://vikunja.example")
os.environ.setdefault("APPRISE_BASE_URL", "http://apprise:8000")

import unittest

import app


class TestAppriseTargetUrl(unittest.TestCase):
    def test_lowercases_and_prefixes_username(self):
        self.assertEqual(
            app.apprise_target_url("Jerome"),
            "http://apprise:8000/notify/vikunja-tg-jerome",
        )


class TestSingleEventRecipient(unittest.TestCase):
    def test_assignee_created_reads_assignee_field(self):
        data = {"assignee": {"username": "bridget"}, "doer": {"username": "jerome"}}
        self.assertEqual(app.single_event_recipient("task.assignee.created", data), "bridget")

    def test_reminder_fired_reads_user_field(self):
        data = {"user": {"username": "jerome"}}
        self.assertEqual(app.single_event_recipient("task.reminder.fired", data), "jerome")

    def test_overdue_reads_user_field(self):
        data = {"user": {"username": "jerome"}}
        self.assertEqual(app.single_event_recipient("task.overdue", data), "jerome")

    def test_unknown_event_returns_none(self):
        data = {"doer": {"username": "jerome"}}
        self.assertIsNone(app.single_event_recipient("task.updated", data))

    def test_missing_user_object_returns_none(self):
        self.assertIsNone(app.single_event_recipient("task.assignee.created", {}))


class TestIsTaskJustCompleted(unittest.TestCase):
    def test_true_when_done_and_done_at_matches_event_time(self):
        task = {"done": True, "done_at": "2026-08-12T09:00:02.123456789+08:00"}
        self.assertTrue(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))

    def test_false_when_not_done(self):
        task = {"done": False, "done_at": "2026-08-12T09:00:00+08:00"}
        self.assertFalse(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))

    def test_false_when_done_at_far_from_event_time(self):
        task = {"done": True, "done_at": "2026-08-01T09:00:00+08:00"}
        self.assertFalse(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))

    def test_false_when_done_at_missing(self):
        task = {"done": True}
        self.assertFalse(app.is_task_just_completed("2026-08-12T09:00:00+08:00", task))


class TestCompletedAssigneeUsernames(unittest.TestCase):
    def test_extracts_usernames_from_assignee_list(self):
        task = {"assignees": [{"username": "jerome"}, {"username": "Bridget"}]}
        self.assertEqual(app.completed_assignee_usernames(task), ["jerome", "Bridget"])

    def test_empty_when_no_assignees(self):
        self.assertEqual(app.completed_assignee_usernames({}), [])

    def test_skips_entries_without_username(self):
        task = {"assignees": [{"id": 1}, {"username": "jerome"}]}
        self.assertEqual(app.completed_assignee_usernames(task), ["jerome"])


class TestBuildBody(unittest.TestCase):
    def test_escapes_html_and_formats_lines(self):
        body = app.build_body("<Proj>", "Buy milk & eggs", "https://vikunja.example/tasks/5")
        self.assertIn("Project: <b>&lt;Proj&gt;</b>", body)
        self.assertIn("Buy milk &amp; eggs", body)
        self.assertIn('href="https://vikunja.example/tasks/5"', body)


if __name__ == "__main__":
    unittest.main()
