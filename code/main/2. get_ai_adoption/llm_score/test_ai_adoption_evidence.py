from __future__ import annotations

import sys
import unittest
from pathlib import Path

import pandas as pd


THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

import ai_adoption_utils as u
import merge_outputs as m


class LlmExtractionScoreTests(unittest.TestCase):
    def test_explicit_ai_abbreviation_triggers_prefilter(self) -> None:
        text = "We launched new AI tools and ML workflows in customer support."
        self.assertGreater(u.count_ai_keywords(text), 0)
        self.assertGreater(u.count_ranking_keywords(text), 0)

    def test_specialized_dictionary_term_triggers_prefilter(self) -> None:
        text = "The product uses OpenCV and computer vision for object detection."
        self.assertGreater(u.count_ai_keywords(text), 0)
        self.assertGreater(u.count_ranking_keywords(text), 0)

    def test_non_dictionary_term_does_not_trigger_prefilter(self) -> None:
        text = "The company expanded analytics across the business."
        self.assertEqual(u.count_ai_keywords(text), 0)
        self.assertEqual(u.count_ranking_keywords(text), 0)

    def test_ml_unit_does_not_trigger_prefilter(self) -> None:
        text = "The company uses a 200 mg/ml formulation in its product."
        self.assertEqual(u.count_ai_keywords(text), 0)

    def test_ml_initials_do_not_trigger_prefilter(self) -> None:
        text = "Matson Logistics (ML) provides rail intermodal services."
        self.assertEqual(u.count_ai_keywords(text), 0)

    def test_parse_exact_score(self) -> None:
        result = u.parse_model_output_payload("2")
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["ai_score"], 2)
        self.assertEqual(result["ai_score_label"], "limited_or_targeted_adoption")

    def test_parse_json_score_fallback(self) -> None:
        payload = """
        {
          "score": 3
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["ai_score"], 3)
        self.assertEqual(result["ai_score_label"], "production_or_strategic_adoption")

    def test_parse_conflicting_scores_fails(self) -> None:
        result = u.parse_model_output_payload("The answer could be 2 or 3.")
        self.assertEqual(result["status"], "conflicting_scores")
        self.assertTrue(pd.isna(result["ai_score"]))

    def test_parse_missing_output_fails(self) -> None:
        result = u.parse_model_output_payload("")
        self.assertEqual(result["status"], "missing_output")
        self.assertTrue(pd.isna(result["ai_score"]))

    def test_firm_year_takes_max_score(self) -> None:
        df = pd.DataFrame(
            [
                {
                    "accession_number": "a1",
                    "cik": 1001,
                    "year": 2024,
                    "llama_run_id": "r1",
                    "llama_script_version": "s1",
                    "llama_prompt_version": "p1",
                    "llama_llm_model": "claude",
                    "llama_llm_checkpoint": "claude-4-5",
                    "llama_temperature": 0.0,
                    "llama_max_new_tokens": 32,
                    "llama_parse_status": "success",
                    "llama_ai_score": 1,
                    "llama_ai_score_label": "no_current_adoption",
                    "llama_score_explanation": "Parsed AI adoption score 1.",
                },
                {
                    "accession_number": "a2",
                    "cik": 1001,
                    "year": 2024,
                    "llama_run_id": "r1",
                    "llama_script_version": "s1",
                    "llama_prompt_version": "p1",
                    "llama_llm_model": "claude",
                    "llama_llm_checkpoint": "claude-4-5",
                    "llama_temperature": 0.0,
                    "llama_max_new_tokens": 32,
                    "llama_parse_status": "success",
                    "llama_ai_score": 3,
                    "llama_ai_score_label": "production_or_strategic_adoption",
                    "llama_score_explanation": "Parsed AI adoption score 3.",
                },
            ]
        )

        panel = m.build_firm_year_panel(df, rule="max_llama", out_dir=".")
        self.assertEqual(int(panel.loc[0, "ai_score"]), 3)
        self.assertEqual(panel.loc[0, "ai_score_label"], "production_or_strategic_adoption")


if __name__ == "__main__":
    unittest.main()
