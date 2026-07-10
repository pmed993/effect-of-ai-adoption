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


class BinaryAiAdoptionTests(unittest.TestCase):
    def test_explicit_ai_abbreviation_triggers_prefilter(self) -> None:
        text = "We launched new AI tools and ML workflows in customer support."
        self.assertGreater(u.count_ai_keywords(text), 0)
        self.assertGreater(u.count_ranking_keywords(text), 0)

    def test_ai_ml_trigger_phrase_still_counts(self) -> None:
        text = "The firm launched new AI/ML features in its underwriting workflow."
        self.assertGreater(u.count_ai_keywords(text), 0)

    def test_ranking_only_term_does_not_trigger_prefilter(self) -> None:
        text = "The company expanded predictive analytics across the business."
        self.assertEqual(u.count_ai_keywords(text), 0)
        self.assertGreater(u.count_ranking_keywords(text), 0)

    def test_ml_unit_does_not_trigger_prefilter(self) -> None:
        text = "The company uses a 200 mg/ml formulation in its product."
        self.assertEqual(u.count_ai_keywords(text), 0)

    def test_ml_initials_do_not_trigger_prefilter(self) -> None:
        text = "Matson Logistics (ML) provides rail intermodal services."
        self.assertEqual(u.count_ai_keywords(text), 0)

    def test_no_ai_mention_returns_zero(self) -> None:
        payload = """
        {
          "ai_adoption": 0,
          "evidence_summary": ""
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["ai_adoption"], 0)
        self.assertEqual(result["exclusion_reason_if_zero"], "")

    def test_legacy_zero_reason_is_accepted_but_ignored(self) -> None:
        payload = """
        {
          "ai_adoption": 0,
          "evidence_summary": "",
          "exclusion_reason_if_zero": "risk_only"
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["ai_adoption"], 0)
        self.assertEqual(result["exclusion_reason_if_zero"], "")

    def test_future_ai_plans_only_returns_zero(self) -> None:
        payload = """
        {
          "ai_adoption": 0,
          "evidence_summary": ""
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["ai_adoption"], 0)

    def test_customer_use_only_returns_zero(self) -> None:
        payload = """
        {
          "ai_adoption": 0,
          "evidence_summary": ""
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["ai_adoption"], 0)

    def test_enabling_infrastructure_only_returns_zero(self) -> None:
        payload = """
        {
          "ai_adoption": 0,
          "evidence_summary": ""
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["ai_adoption"], 0)

    def test_one_concrete_current_firm_use_case_returns_one(self) -> None:
        payload = """
        {
          "ai_adoption": 1,
          "evidence_summary": "The firm uses machine-learning fraud detection in card authorization decisions."
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["ai_adoption"], 1)
        self.assertEqual(result["ai_level_code"], 1)
        self.assertEqual(result["ai_adoption_level"], "adopted")

    def test_multiple_concrete_use_cases_still_return_one(self) -> None:
        payload = """
        {
          "ai_adoption": 1,
          "evidence_summary": "The firm uses recommendation models in its app and predictive maintenance models in operations."
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["ai_adoption"], 1)
        self.assertEqual(result["ai_level_code"], 1)

    def test_parser_rejects_invalid_binary_json(self) -> None:
        payload = """
        {
          "ai_adoption": 2,
          "evidence_summary": "bad"
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertIn(result["status"], {"no_valid_score_json", "no_json_found"})

    def test_positive_requires_evidence_summary(self) -> None:
        payload = """
        {
          "ai_adoption": 1,
          "evidence_summary": ""
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertIn(result["status"], {"no_valid_score_json", "no_json_found"})

    def test_firm_year_is_positive_if_any_chunk_is_positive(self) -> None:
        df = pd.DataFrame(
            [
                {
                    "accession_number": "a1",
                    "cik": 1001,
                    "year": 2024,
                    "llama_run_id": "r1",
                    "llama_script_version": "s1",
                    "llama_prompt_version": "p1",
                    "llama_llm_model": "meta-llama/Llama-3.2-3B-Instruct",
                    "llama_llm_checkpoint": "meta-llama/Llama-3.2-3B-Instruct",
                    "llama_temperature": 0.0,
                    "llama_max_new_tokens": 96,
                    "llama_parse_status": "success",
                    "llama_ai_adoption": 0,
                    "llama_evidence_summary": "",
                    "llama_exclusion_reason_if_zero": "future_only",
                },
                {
                    "accession_number": "a2",
                    "cik": 1001,
                    "year": 2024,
                    "llama_run_id": "r1",
                    "llama_script_version": "s1",
                    "llama_prompt_version": "p1",
                    "llama_llm_model": "meta-llama/Llama-3.2-3B-Instruct",
                    "llama_llm_checkpoint": "meta-llama/Llama-3.2-3B-Instruct",
                    "llama_temperature": 0.0,
                    "llama_max_new_tokens": 96,
                    "llama_parse_status": "retry_success",
                    "llama_ai_adoption": 1,
                    "llama_evidence_summary": "The firm embeds recommendation models in its customer platform.",
                    "llama_exclusion_reason_if_zero": "none",
                },
            ]
        )
        panel = m.build_firm_year_panel(df, rule="error", out_dir=".")
        self.assertEqual(int(panel.loc[0, "ai_adoption"]), 1)
        self.assertEqual(int(panel.loc[0, "ai_level_code"]), 1)
        self.assertEqual(str(panel.loc[0, "parse_status"]), "retry_success")

    def test_binary_compatibility_field_matches_ai_adoption(self) -> None:
        payload = """
        {
          "ai_adoption": 1,
          "qualifying_evidence_found": true,
          "evidence_summary": "The firm uses NLP triage in customer support."
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["ai_level_code"], result["ai_adoption"])


if __name__ == "__main__":
    unittest.main()
