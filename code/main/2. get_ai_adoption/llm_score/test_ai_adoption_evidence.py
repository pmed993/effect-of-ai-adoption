from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pandas as pd


THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

import ai_adoption_utils as u
import get_ai_score_bulk as b
import merge_outputs as m


class LlmExtractionScoreTests(unittest.TestCase):
    def test_explicit_ai_abbreviation_triggers_prefilter(self) -> None:
        text = "We launched new AI tools and ML workflows in customer support."
        self.assertGreater(u.count_ai_keywords(text), 0)

    def test_dotted_ai_abbreviation_triggers_prefilter(self) -> None:
        text = "We launched new A.I.-based tools in customer support."
        self.assertGreater(u.count_ai_keywords(text), 0)

    def test_specialized_dictionary_term_triggers_prefilter(self) -> None:
        text = "The product uses OpenCV and computer vision for object detection."
        self.assertGreater(u.count_ai_keywords(text), 0)

    def test_non_dictionary_term_does_not_trigger_prefilter(self) -> None:
        text = "The company expanded analytics across the business."
        self.assertEqual(u.count_ai_keywords(text), 0)

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

    def test_retry_success_updates_retry_status(self) -> None:
        records = [
            {
                "endpoint_attempts": 1,
                "prefilter_audit_sample": False,
                "retry_attempted": False,
            }
        ]
        pending = {"0": {"record_index": 0}}

        u.apply_bulk_results(
            records,
            pending,
            [("0", {"model_response_string": "3"})],
            save_raw_json=False,
            is_retry=True,
        )

        self.assertEqual(records[0]["parse_status"], "retry_success")
        self.assertEqual(records[0]["score_status"], "ok_after_retry")
        self.assertEqual(records[0]["retry_score_status"], "ok")
        self.assertEqual(records[0]["endpoint_attempts"], 2)

    def test_scoring_helper_retries_parser_failure_once(self) -> None:
        records = [
            {
                "endpoint_attempts": 1,
                "prefilter_audit_sample": False,
                "retry_attempted": False,
            }
        ]
        pending = {
            "0": {
                "record_index": 0,
                "prompt": "initial prompt",
                "retry_prompt": "retry prompt",
            }
        }
        args = SimpleNamespace(
            model_id="claude",
            max_workers=1,
            save_raw_json=False,
        )

        with patch.object(
            b,
            "invoke_bedrock",
            side_effect=[
                [("0", {"model_response_string": "2 or 3"})],
                [("0", {"model_response_string": "2"})],
            ],
        ) as invoke:
            b.score_pending_records(
                records,
                pending,
                args=args,
                chunk_name="chunk_1",
            )

        self.assertEqual(invoke.call_count, 2)
        self.assertEqual(records[0]["ai_score"], 2)
        self.assertEqual(records[0]["score_status"], "ok_after_retry")

    def test_snippet_audit_table_keeps_processed_text_and_skipped_rows(self) -> None:
        wide = pd.DataFrame(
            [
                {
                    "accession_number": "a1",
                    "cik": "1001",
                    "year": 2024,
                    "form_type": "10-K",
                    "has_item1": True,
                    "has_item7": True,
                    "item1_chars": 40,
                    "item7_chars": 20,
                    "combined_chars": 60,
                    "combined_text": "We currently use machine learning in customer support.",
                },
                {
                    "accession_number": "a2",
                    "cik": "1002",
                    "year": 2024,
                    "form_type": "10-K",
                    "has_item1": True,
                    "has_item7": True,
                    "item1_chars": 30,
                    "item7_chars": 20,
                    "combined_chars": 50,
                    "combined_text": "We expanded conventional analytics and reporting.",
                },
            ]
        )
        records, pending = u.prepare_records_and_prompts(
            wide,
            run_id="r1",
            chunk_id="extract_df_chunk_00001",
            source_label="test",
            llm_model="claude",
            llm_checkpoint="claude",
            temperature=0.0,
            max_new_tokens=32,
            endpoint="claude",
            prefilter_mode="hard_zero",
            audit_seed="seed",
            prefilter_audit_rate=0.0,
            prefilter_audit_limit=0,
            max_prompt_chars=1800,
            sentence_window=0,
        )
        u.apply_bulk_results(
            records,
            pending,
            [("0", {"model_response_string": "2"})],
            save_raw_json=False,
        )

        audit = u.build_snippet_audit_table(records, pending)
        self.assertEqual(audit.columns.tolist(), u.SNIPPET_AUDIT_COLUMNS)
        self.assertEqual(audit["llm_processed"].tolist(), [True, False])
        self.assertGreater(int(audit.loc[0, "snippet_text_length"]), 0)
        self.assertIn("machine learning", audit.loc[0, "snippet_text"])
        self.assertEqual(int(audit.loc[1, "snippet_text_length"]), 0)
        self.assertEqual(audit.loc[1, "snippet_text"], "")

    def test_csv_boolean_parser_does_not_treat_false_string_as_true(self) -> None:
        parsed = b.boolean_series(
            pd.Series([True, False, "true", "False", "1", "0", None])
        )
        self.assertEqual(
            parsed.tolist(), [True, False, True, False, True, False, False]
        )
        self.assertFalse(u.coerce_bool("False"))

    def test_rebuilt_audit_keeps_only_text_sent_to_llm(self) -> None:
        records = [
            {
                "accession_number": "a1",
                "filing_accession": "a1",
                "cik": "1001",
                "year": 2024,
                "llm_called": "True",
                "max_prompt_chars": 1800,
                "sentence_window": 0,
            },
            {
                "accession_number": "a2",
                "filing_accession": "a2",
                "cik": "1002",
                "year": 2024,
                "llm_called": "False",
                "max_prompt_chars": 1800,
                "sentence_window": 0,
            },
        ]
        wide_by_accession = {
            "a1": pd.Series({"combined_text": "We use machine learning."}),
            "a2": pd.Series({"combined_text": "Conventional analytics only."}),
        }

        audit = b.rebuild_snippet_audit(records, wide_by_accession)

        self.assertEqual(audit["llm_processed"].tolist(), [True, False])
        self.assertIn("machine learning", audit.loc[0, "snippet_text"])
        self.assertEqual(audit.loc[1, "snippet_text"], "")

    def test_aggregate_snippet_audit_concatenates_chunk_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for chunk_id, cik in [(1, 1001), (2, 1002)]:
                pd.DataFrame(
                    [
                        {
                            "cik": cik,
                            "year": 2024,
                            "filing_accession": f"a{chunk_id}",
                            "chunk_id": f"extract_df_chunk_{chunk_id:05d}",
                            "llm_processed": True,
                            "snippet_text_length": 18,
                            "snippet_text": "AI adoption text.",
                        }
                    ]
                ).to_csv(
                    root / f"extract_df_chunk_{chunk_id:05d}_claude_snippet_audit.csv",
                    index=False,
                )

            loaded = m.load_snippet_audit_outputs(str(root), "claude")
            aggregate = m.build_aggregate_snippet_audit(loaded)
            self.assertEqual(len(aggregate), 2)
            self.assertEqual(set(aggregate["model_label"]), {"claude"})
            self.assertEqual(
                set(aggregate["filing_accession"].astype(str)), {"a1", "a2"}
            )

    def test_firm_year_takes_max_score(self) -> None:
        df = pd.DataFrame(
            [
                {
                    "accession_number": "a1",
                    "cik": 1001,
                    "year": 2024,
                    "claude_run_id": "r1",
                    "claude_script_version": "s1",
                    "claude_prompt_version": "p1",
                    "claude_llm_model": "claude",
                    "claude_llm_checkpoint": "claude-4-5",
                    "claude_temperature": 0.0,
                    "claude_max_new_tokens": 32,
                    "claude_parse_status": "success",
                    "claude_ai_score": 1,
                    "claude_ai_score_label": "no_current_adoption",
                    "claude_score_explanation": "Parsed AI adoption score 1.",
                },
                {
                    "accession_number": "a2",
                    "cik": 1001,
                    "year": 2024,
                    "claude_run_id": "r1",
                    "claude_script_version": "s1",
                    "claude_prompt_version": "p1",
                    "claude_llm_model": "claude",
                    "claude_llm_checkpoint": "claude-4-5",
                    "claude_temperature": 0.0,
                    "claude_max_new_tokens": 32,
                    "claude_parse_status": "success",
                    "claude_ai_score": 3,
                    "claude_ai_score_label": "production_or_strategic_adoption",
                    "claude_score_explanation": "Parsed AI adoption score 3.",
                },
            ]
        )

        panel = m.build_firm_year_panel(df, "claude")
        self.assertEqual(int(panel.loc[0, "ai_score"]), 3)
        self.assertEqual(
            panel.loc[0, "ai_score_label"], "production_or_strategic_adoption"
        )

    def test_duplicate_accessions_are_rejected_with_report(self) -> None:
        df = pd.DataFrame(
            [
                {
                    "accession_number": "a1",
                    "cik": 1001,
                    "year": 2024,
                    "has_item1": True,
                    "has_item7": True,
                    "combined_chars": 2000,
                    "snippet_chars": 1800,
                    "claude_llm_called": True,
                    "claude_ai_score": 1,
                },
                {
                    "accession_number": "a1",
                    "cik": 1001,
                    "year": 2024,
                    "has_item1": True,
                    "has_item7": False,
                    "combined_chars": 1000,
                    "snippet_chars": 900,
                    "claude_llm_called": True,
                    "claude_ai_score": 3,
                },
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                m.require_unique_accessions(df, tmp)
            self.assertTrue((Path(tmp) / "filing_accession_duplicates.csv").exists())


if __name__ == "__main__":
    unittest.main()
