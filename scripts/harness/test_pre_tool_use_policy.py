"""Behavior checks for the project PreToolUse policy."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
import pre_tool_use_policy as policy


class PolicyTests(unittest.TestCase):
    def spawn(self, tool_name="spawn_agent", **args):
        return policy.reason_for({"tool_name": tool_name, "tool_input": args})

    def patch(self, model, target, move_to=None):
        command = f"*** Begin Patch\n*** Update File: {target}\n"
        if move_to:
            command += f"*** Move to: {move_to}\n"
        command += "@@\n"
        return policy.reason_for({
            "tool_name": "apply_patch",
            "model": model,
            "cwd": "/repo",
            "tool_input": {"command": command},
        })

    def test_code_delegate_requires_luna_xhigh_and_explicit_fork_turns(self):
        for turns in ("none", "4"):
            self.assertIsNone(self.spawn(
                task_name="implement",
                model="gpt-6-luna",
                reasoning_effort="xhigh",
                fork_turns=turns,
            ))

    def test_code_delegate_rejects_implicit_or_all_fork_turns_with_retry_guidance(self):
        for turns in (None, "all"):
            args = {
                "task_name": "implement",
                "model": "gpt-6-luna",
                "reasoning_effort": "xhigh",
            }
            if turns is not None:
                args["fork_turns"] = turns
            reason = self.spawn(**args)
            self.assertIn("fork_turns", reason)
            self.assertIn("retry automatically", reason)

    def test_wrong_code_delegate_is_denied_with_retry_guidance(self):
        reason = self.spawn(task_name="implement", model="gpt-6-astra", reasoning_effort="medium")
        self.assertIn("retry automatically", reason)
        self.assertIn("gpt-6-luna", reason)

    def test_review_delegate_requires_fresh_sol_high_session(self):
        self.assertIsNone(self.spawn(
            task_name="review_voice_path",
            model="gpt-6.1-sol",
            reasoning_effort="high",
            fork_turns="none",
        ))

    def test_namespaced_review_delegate_rejects_old_parameters_with_retry_guidance(self):
        reason = self.spawn(
            tool_name="collaboration.spawn_agent",
            task_name="review_voice_path",
            model="gpt-6-astra",
            reasoning_effort="medium",
            fork_turns="none",
        )
        self.assertIn("gpt-6.1-sol", reason)
        self.assertIn("reasoning_effort 'high'", reason)
        self.assertIn("retry automatically", reason)

    def test_namespaced_review_delegate_accepts_sol_high_without_history(self):
        self.assertIsNone(self.spawn(
            tool_name="collaboration.spawn_agent",
            task_name="review_voice_path",
            model="gpt-6.1-sol",
            reasoning_effort="high",
            fork_turns="none",
        ))

    def test_namespaced_code_delegate_rejects_wrong_parameters(self):
        reason = self.spawn(
            tool_name="collaboration.spawn_agent",
            task_name="implement",
            model="gpt-6-astra",
            reasoning_effort="medium",
            fork_turns="none",
        )
        self.assertIn("gpt-6-luna", reason)
        self.assertIn("retry automatically", reason)

    def test_namespaced_code_delegate_accepts_luna_xhigh_with_explicit_fork(self):
        self.assertIsNone(self.spawn(
            tool_name="collaboration.spawn_agent",
            task_name="implement",
            model="gpt-6-luna",
            reasoning_effort="xhigh",
            fork_turns="3",
        ))

    def test_hook_matcher_matches_only_the_supported_spawn_names(self):
        import json
        import re

        config_path = Path(__file__).parents[2] / ".codex" / "hooks.json"
        config = json.loads(config_path.read_text())
        hooks = config["hooks"]["PreToolUse"]
        matcher = hooks[0]["matcher"]
        self.assertEqual(matcher, r"^(spawn_agent|Agent|collaboration\.spawn_agent)$")
        self.assertEqual(hooks[1]["matcher"], r"^(apply_patch|Edit|Write)$")
        pattern = re.compile(matcher)
        for name in ("spawn_agent", "Agent", "collaboration.spawn_agent"):
            with self.subTest(name=name):
                self.assertIsNotNone(pattern.fullmatch(name))
        for name in (
            "xspawn_agent",
            "spawn_agent_extra",
            "collaborationXspawn_agent",
            "collaboration.spawn_agent.extra",
        ):
            with self.subTest(name=name):
                self.assertIsNone(pattern.fullmatch(name))

    def test_review_delegate_rejects_astra_medium_with_retry_guidance(self):
        reason = self.spawn(
            task_name="review_voice_path",
            model="gpt-6-astra",
            reasoning_effort="medium",
            fork_turns="none",
        )
        self.assertIn("gpt-6.1-sol", reason)
        self.assertIn("reasoning_effort 'high'", reason)
        self.assertIn("retry automatically", reason)
        self.assertIn("do not ask the user", reason)

    def test_review_delegate_rejects_inherited_history(self):
        reason = self.spawn(
            task_name="review_voice_path",
            model="gpt-6.1-sol",
            reasoning_effort="high",
            fork_turns="all",
        )
        self.assertIn("fork_turns 'none'", reason)

    def test_main_model_can_patch_planning_document(self):
        self.assertIsNone(self.patch("gpt-6-astra", "docs/harness/design.md"))

    def test_main_model_can_patch_migrated_policy_documents(self):
        for target in (
            "docs/harness/collaboration.md",
            "docs/harness/code-guidance.md",
            ".agents/skills/archive-task/SKILL.md",
        ):
            with self.subTest(target=target):
                self.assertIsNone(self.patch("gpt-6-astra", target))

    def test_main_model_cannot_patch_code(self):
        self.assertIn("Only gpt-6-luna", self.patch("gpt-6-astra", "src/ios/App.swift"))

    def test_luna_can_patch_code(self):
        self.assertIsNone(self.patch("gpt-6-luna", "src/ios/App.swift"))

    def test_main_model_cannot_move_document_into_code_path(self):
        reason = self.patch(
            "gpt-6-astra",
            "docs/harness/design.md",
            move_to="src/ios/App.swift",
        )
        self.assertIn("Only gpt-6-luna", reason)

    def test_patch_outside_repository_is_denied(self):
        self.assertIn("could not be identified", self.patch("gpt-6-luna", "/outside/App.swift"))


if __name__ == "__main__":
    unittest.main()
