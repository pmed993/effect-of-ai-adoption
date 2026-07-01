from __future__ import annotations

import sys
import unittest
from pathlib import Path


THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

import ai_adoption_utils as u


def qualifying(
    use_case: str,
    *,
    business_area: str = "operations",
    evidence_strength: str = "moderate",
    centrality: str = "operational",
    source_item: str = "item_7",
) -> dict[str, object]:
    return {
        "use_case": use_case,
        "business_area": business_area,
        "current_use": True,
        "firm_itself_uses_or_deploys": True,
        "evidence_strength": evidence_strength,
        "centrality": centrality,
        "source_item": source_item,
    }


def excluded(reason: str, description: str) -> dict[str, str]:
    return {"brief_description": description, "reason": reason}


class ClassifyAiAdoptionFromEvidenceTests(unittest.TestCase):
    def test_no_ai_mention_returns_zero(self) -> None:
        evidence = {"qualifying_ai_use_cases": [], "excluded_mentions": []}
        self.assertEqual(u.classify_ai_adoption_from_evidence(evidence), 0)

    def test_generic_risk_language_returns_zero(self) -> None:
        evidence = {
            "qualifying_ai_use_cases": [],
            "excluded_mentions": [excluded("risk_only", "AI creates cybersecurity and compliance risks.")],
        }
        summary = u.summarize_evidence(evidence)
        self.assertEqual(summary["ai_level_code"], 0)
        self.assertEqual(summary["main_exclusion_reason_if_zero"], "risk_only")

    def test_future_plans_only_return_zero(self) -> None:
        evidence = {
            "qualifying_ai_use_cases": [],
            "excluded_mentions": [excluded("future_only", "The firm plans to explore generative AI next year.")],
        }
        self.assertEqual(u.classify_ai_adoption_from_evidence(evidence), 0)

    def test_one_concrete_current_use_case_returns_one(self) -> None:
        evidence = {
            "qualifying_ai_use_cases": [
                qualifying("Machine-learning fraud detection in card authorization.", business_area="risk_fraud")
            ],
            "excluded_mentions": [],
        }
        summary = u.summarize_evidence(evidence)
        self.assertEqual(summary["ai_level_code"], 1)
        self.assertEqual(summary["n_qualifying_use_cases"], 1)

    def test_multiple_business_areas_return_two(self) -> None:
        evidence = {
            "qualifying_ai_use_cases": [
                qualifying("Recommendation models in the consumer app.", business_area="product_service"),
                qualifying("Demand forecasting models in warehouse planning.", business_area="supply_chain"),
            ],
            "excluded_mentions": [],
        }
        summary = u.summarize_evidence(evidence)
        self.assertEqual(summary["ai_level_code"], 2)
        self.assertEqual(summary["n_business_areas"], 2)

    def test_core_ai_business_model_returns_three(self) -> None:
        evidence = {
            "qualifying_ai_use_cases": [
                qualifying(
                    "Core platform uses proprietary ML models to generate underwriting decisions.",
                    business_area="product_service",
                    evidence_strength="strong",
                    centrality="core",
                    source_item="item_1",
                ),
                qualifying(
                    "The subscription platform continuously retrains models used in the core product.",
                    business_area="r_and_d",
                    evidence_strength="strong",
                    centrality="core",
                    source_item="item_7",
                ),
            ],
            "excluded_mentions": [],
        }
        summary = u.summarize_evidence(evidence)
        self.assertEqual(summary["ai_level_code"], 3)
        self.assertTrue(summary["has_core_ai"])

    def test_enabling_infrastructure_only_returns_zero_unless_embedded(self) -> None:
        enabling_only = {
            "qualifying_ai_use_cases": [],
            "excluded_mentions": [
                excluded(
                    "enabling_infrastructure",
                    "The firm sells chips and cloud capacity used by customers to build AI systems.",
                )
            ],
        }
        embedded_ai_product = {
            "qualifying_ai_use_cases": [
                qualifying(
                    "The firm's software product embeds recommendation models in the user workflow.",
                    business_area="product_service",
                    evidence_strength="moderate",
                    centrality="operational",
                )
            ],
            "excluded_mentions": [],
        }
        self.assertEqual(u.classify_ai_adoption_from_evidence(enabling_only), 0)
        self.assertEqual(u.classify_ai_adoption_from_evidence(embedded_ai_product), 1)

    def test_deduplicates_repeated_mentions_of_same_use_case(self) -> None:
        repeated = qualifying("Computer-vision inspection on the production line.", business_area="operations")
        evidence = {
            "qualifying_ai_use_cases": [repeated, dict(repeated)],
            "excluded_mentions": [],
        }
        summary = u.summarize_evidence(evidence)
        self.assertEqual(summary["n_qualifying_use_cases"], 1)
        self.assertEqual(summary["ai_level_code"], 1)

    def test_parse_valid_evidence_json(self) -> None:
        payload = """
        {
          "qualifying_ai_use_cases": [
            {
              "use_case": "NLP triage of inbound support requests.",
              "business_area": "customer_service",
              "current_use": true,
              "firm_itself_uses_or_deploys": true,
              "evidence_strength": "moderate",
              "centrality": "operational",
              "source_item": "item_7"
            }
          ],
          "excluded_mentions": [
            {
              "brief_description": "General AI market discussion.",
              "reason": "generic_market_discussion"
            }
          ]
        }
        """
        result = u.parse_model_output_payload(payload)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["ai_adoption_level_code"], 1)
        self.assertEqual(result["n_qualifying_use_cases"], 1)


if __name__ == "__main__":
    unittest.main()
