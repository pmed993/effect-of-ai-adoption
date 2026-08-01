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
    def test_central_keyword_dictionary_has_routing_and_ranking_metadata(self) -> None:
        required = {
            "pattern",
            "category",
            "routing_weight",
            "ranking_weight",
            "case_sensitive",
        }
        self.assertTrue(u.AI_KEYWORDS)
        for keyword, metadata in u.AI_KEYWORDS.items():
            with self.subTest(keyword=keyword):
                self.assertTrue(required.issubset(metadata))

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

    def test_ml_abbreviation_is_case_sensitive(self) -> None:
        self.assertEqual(u.count_ai_keywords("The dosage was 5 mL."), 0)
        self.assertEqual(u.count_ai_keywords("The dosage was 10ml."), 0)
        self.assertEqual(u.count_ai_keywords("The page contains html markup."), 0)

        text = "The company uses ML to forecast customer demand."
        matches = u.find_keyword_matches(text)
        self.assertEqual([match.keyword for match in matches], ["ml"])
        candidate = u.create_anchor_candidates(u.normalize_and_segment_text(text))[0]
        self.assertGreater(candidate.operational_score, 0)
        self.assertGreaterEqual(candidate.quality_band, 3)

    def test_ml_initials_do_not_trigger_prefilter(self) -> None:
        text = "Matson Logistics (ML) provides rail intermodal services."
        self.assertEqual(u.count_ai_keywords(text), 0)

    def test_known_ambiguous_terms_do_not_route_without_ai_context(self) -> None:
        examples = [
            "The company implemented a remote learning model during the pandemic.",
            "Heat transfer systems include generator and transformer coolers.",
            "She studied at Universite Claude Bernard in Lyon.",
            "NHW = Non-Hispanic Whites and AI = American Indians.",
            "The aircraft crew includes two experienced copilots.",
        ]
        for text in examples:
            with self.subTest(text=text):
                self.assertEqual(u.count_ai_keywords(text), 0)

    def test_contextual_named_models_and_transformers_still_route(self) -> None:
        examples = [
            "We use a transformer model for language generation.",
            "We use Anthropic Claude in customer support.",
            "We deployed Claude in customer support.",
            "We deployed CLAUDE in customer support.",
            "Our team deployed the Google Gemini model.",
            "Our team uses Gemini for internal research.",
            "Our team uses GEMINI for internal research.",
            "We deployed Microsoft Copilot to our employees.",
        ]
        for text in examples:
            with self.subTest(text=text):
                self.assertGreater(u.count_ai_keywords(text), 0)

    def test_genuine_ai_use_is_a_high_priority_anchor(self) -> None:
        text = (
            "The platform utilizes artificial intelligence to personalise "
            "student learning."
        )
        candidate = u.create_anchor_candidates(u.normalize_and_segment_text(text))[0]
        self.assertEqual(candidate.matched_keyword, "artificial_intelligence")
        self.assertEqual(candidate.quality_band, 4)
        self.assertGreater(candidate.operational_score, 0)

    def test_current_use_ranks_above_future_and_industry_context(self) -> None:
        text = (
            "Artificial intelligence is changing the competitive environment. "
            "We are exploring how artificial intelligence may improve our operations. "
            "We use machine learning models in production to detect fraudulent transactions."
        )
        candidates = u.create_anchor_candidates(u.normalize_and_segment_text(text))
        ranked = u.score_anchor_candidates(candidates)
        self.assertEqual(len(candidates), 3)
        self.assertIn("exploring", " ".join(item.anchor_text for item in candidates))
        self.assertIn(
            "competitive environment", " ".join(item.anchor_text for item in candidates)
        )
        self.assertIn("in production", ranked[0].anchor_text)
        self.assertEqual(ranked[0].quality_band, 4)

    def test_anchor_survives_when_surrounding_window_exceeds_budget(self) -> None:
        previous = "Previous context " + "ordinary disclosure " * 35 + "."
        anchor = (
            "We use machine learning in production to detect fraudulent transactions."
        )
        following = "Following context " + "ordinary disclosure " * 35 + "."
        text = "\n".join([previous, anchor, following])

        snippet = u.extract_relevant_snippets(text, max_chars=180, sentence_window=1)

        self.assertIn(anchor, snippet)
        self.assertLessEqual(len(snippet), 180)

    def test_near_duplicate_anchor_disclosure_is_removed(self) -> None:
        text = (
            "We use machine learning in production to detect fraudulent transactions. "
            "Our company uses machine learning in production to detect fraudulent transactions."
        )
        candidates = u.create_anchor_candidates(u.normalize_and_segment_text(text))
        deduplicated = u.deduplicate_candidates(candidates)

        self.assertEqual(len(candidates), 2)
        self.assertEqual(len(deduplicated), 1)

    def test_newline_bullets_and_long_lists_create_bounded_segments(self) -> None:
        long_product = "Product features " + "component " * 160
        text = (
            "ITEM 1 BUSINESS:\n"
            "Products\n"
            "• First product\n"
            "• Second product; Third product.\n"
            f"{long_product}"
        )
        segments = u.normalize_and_segment_text(text)

        self.assertGreaterEqual(len(segments), 5)
        self.assertTrue(
            all(len(segment.text) <= u.MAX_TEXT_SEGMENT_CHARS for segment in segments)
        )
        self.assertTrue(all(segment.section == "item1" for segment in segments))

    def test_sec_headings_assign_and_end_priority_sections(self) -> None:
        text = (
            "ITEM 1. BUSINESS\n"
            "We use artificial intelligence in our products.\n"
            "ITEM 2. PROPERTIES\n"
            "We maintain offices in several cities.\n"
            "ITEM 7. MANAGEMENT'S DISCUSSION AND ANALYSIS OF FINANCIAL "
            "CONDITION AND RESULTS OF OPERATIONS\n"
            "We use machine learning to forecast demand."
        )

        segments = u.normalize_and_segment_text(text)
        sections = {segment.text: segment.section for segment in segments}

        self.assertEqual(
            sections["We use artificial intelligence in our products."], "item1"
        )
        self.assertEqual(sections["PROPERTIES"], "other")
        self.assertEqual(
            sections["We use machine learning to forecast demand."], "item7"
        )

    def test_keyword_survives_oversized_unpunctuated_segment(self) -> None:
        text = (
            "component " * 120
            + "we use artificial intelligence to optimize operations "
            + "component " * 120
        )

        snippet = u.extract_relevant_snippets(text, max_chars=300, sentence_window=1)

        self.assertIn("artificial intelligence", snippet)
        self.assertLessEqual(len(snippet), 300)

    def test_no_keyword_audit_samples_late_proxy_evidence(self) -> None:
        beginning = "Opening corporate description " + "general information " * 35
        middle = "Middle financial discussion " + "ordinary performance " * 35
        ending = (
            "We deploy intelligent automation and advanced analytics across "
            "our internal operations."
        )
        text = "\n".join([beginning, middle, ending])
        self.assertEqual(u.count_ai_keywords(text), 0)

        snippet = u.extract_relevant_snippets(text, max_chars=500, sentence_window=1)

        self.assertIn("intelligent automation", snippet)
        self.assertLessEqual(len(snippet), 500)

    def test_no_keyword_audit_covers_beginning_middle_and_end(self) -> None:
        text = "\n".join(
            [
                "BEGINMARKER general corporate description.",
                "First intervening section.",
                "MIDDLEMARKER general financial discussion.",
                "Second intervening section.",
                "ENDMARKER concluding corporate discussion.",
            ]
        )

        snippet = u.extract_relevant_snippets(text, max_chars=300, sentence_window=1)

        self.assertIn("BEGINMARKER", snippet)
        self.assertIn("MIDDLEMARKER", snippet)
        self.assertIn("ENDMARKER", snippet)

    def test_student_brands_anchor_is_preserved_with_window_one(self) -> None:
        genuine = (
            "Student Brands utilizes deep data analytics and artificial intelligence "
            "to drive its content management system, the Content Brain."
        )
        remote = (
            "Our results were impacted as schools implemented a remote learning "
            "model and curtailed on-campus activities."
        )
        text = "\n".join([genuine, remote, remote, remote])

        window_zero = u.extract_relevant_snippets(
            text, max_chars=300, sentence_window=0
        )
        window_one = u.extract_relevant_snippets(text, max_chars=300, sentence_window=1)

        self.assertIn(genuine, window_zero)
        self.assertIn(genuine, window_one)
        self.assertLessEqual(window_one.count("remote learning model"), 1)

    def test_window_context_cannot_change_selected_anchors(self) -> None:
        text = "\n".join(
            [
                "Background context about the business and its customers.",
                "We use machine learning in production to detect fraud.",
                "Supporting context about transaction review procedures.",
                "We are exploring how artificial intelligence may improve reporting.",
                "Additional discussion of future reporting plans.",
            ]
        )
        segments = u.normalize_and_segment_text(text)
        selected = u.select_anchor_sentences(
            u.deduplicate_candidates(u.create_anchor_candidates(segments)),
            max_chars=300,
        )
        window_zero = u.extract_relevant_snippets(text, 300, 0)
        window_one = u.extract_relevant_snippets(text, 300, 1)

        for candidate in selected:
            self.assertIn(candidate.anchor_text, window_zero)
            self.assertIn(candidate.anchor_text, window_one)

    def test_distinct_anchors_take_priority_over_supporting_context(self) -> None:
        first_anchor = "We use machine learning in production to detect fraud."
        context = (
            "This supporting operational discussion is useful but contains no direct "
            "artificial-intelligence evidence."
        )
        second_anchor = (
            "We deploy artificial intelligence to automate customer support workflows."
        )
        text = "\n".join([first_anchor, context, second_anchor])

        snippet = u.extract_relevant_snippets(text, max_chars=145, sentence_window=1)

        self.assertIn(first_anchor, snippet)
        self.assertIn(second_anchor, snippet)
        self.assertNotIn(context, snippet)

    def test_short_adjacent_context_is_kept_when_budget_remains(self) -> None:
        anchor = "We use machine learning."
        context = "It is deployed across customer support."

        window_zero = u.extract_relevant_snippets(
            "\n".join([anchor, context]), max_chars=1800, sentence_window=0
        )
        window_one = u.extract_relevant_snippets(
            "\n".join([anchor, context]), max_chars=1800, sentence_window=1
        )

        self.assertNotIn(context, window_zero)
        self.assertIn(anchor, window_one)
        self.assertIn(context, window_one)

    def test_parse_exact_score(self) -> None:
        result = u.parse_model_output_payload("2")
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["ai_score"], 2)
        self.assertEqual(result["ai_score_label"], "limited_or_targeted_adoption")

    def test_prompt_output_contract_remains_one_score_only(self) -> None:
        prompt = u.build_ai_prompt("We use machine learning in production.")
        self.assertIn("Return only one character: 1, 2, or 3.", prompt)
        self.assertNotIn('"evidence"', prompt)

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
