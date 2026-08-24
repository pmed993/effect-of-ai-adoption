# Effect of AI Adoption on Firm Outcomes

## Overview
This project studies whether firm-level AI adoption is associated with differences in firm outcomes and characteristics. The workflow combines:

- SEC filing text from EDGAR
- LLM-based AI adoption scores built from those filings
- Compustat annual accounting data
- External AI exposure measures matched by industry

## Overall Process
1. Extract high-recall AI keyword windows from whole SEC 10-K and 10-K/A
   primary documents. The active workflow and run commands are documented in
   [code/main/1. get_edgar_extract/README.md](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/1.%20get_edgar_extract/README.md).

2. Build firm-year AI adoption measures from filings.
   Main scripts live in [code/main/2. get_ai_adoption](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/2.%20get_ai_adoption).

3. Build the annual Compustat panel and merge AI measures.
   Main scripts live in [code/main/3. get_panel_data](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/3.%20get_panel_data):
   [1. build_compustat_annual_panel.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/3.%20get_panel_data/1.%20build_compustat_annual_panel.R)
   [2. build_compustat_ai_panel.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/3.%20get_panel_data/2.%20build_compustat_ai_panel.R)

   The EDGAR merge first uses exact `CIK + report_date` matches. Remaining
   Compustat periods may use the unique nearest SEC report date for the same CIK
   within `-7 <= business-day gap <= +7`. Exact matches take precedence;
   ambiguous matches and reused filings are rejected. The saved
   `data/compustat_ai_match_audit.csv` records the method and date gap for every
   fiscal period.

4. Build or load the final analysis panel.
   See [4. build_or_load_panel_data.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/4.%20build_or_load_panel_data.R).

5. Validate the treatment variables and generate panel diagnostics and summary
   statistics using scripts 5--7 in `code/main`.

6. Estimate the main Callaway--Sant'Anna models using the unbalanced,
   cohort-specific `g-1` doubly robust design.
   See [9. did.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/9.%20did/9.%20did.R).

7. Estimate HHI heterogeneity using the preferred main specification and test
   the difference between high- and low-competition market ATTs.
   See [10. hhi_heterogeneity_did.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/10.%20hhi_hetero/10.%20hhi_heterogeneity_did.R).

   ```bash
   Rscript "code/main/10. hhi_hetero/10. hhi_heterogeneity_did.R"
   Rscript "code/main/10. hhi_hetero/10. hhi_dynamic_plots.R"
   ```

8. Test whether continuous sales-based NAICS3 concentration in `t-1` predicts
   first AI adoption in `t`. The firm-year risk-set model uses the firm's own
   prior-year market HHI and prior-year controls, year and NAICS3 fixed effects,
   and NAICS3-clustered standard errors. Thus, a cohort-`g` event always uses
   HHI measured in `g-1`. Continuous HHI is the primary specification and the
   only competition measure in the main table. A binary high-competition model
   (`HHI <= 1,800`, with low competition as the reference) is retained only as
   a separately labelled robustness check. All control coefficients are saved
   in a separate diagnostic table.
   See [11. hhi_ai_determinant.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/11.%20hhi_ai_determinant.R).

   ```bash
   Rscript "code/main/11. hhi_ai_determinant.R"
   ```

## Main Outputs
- Annual Compustat panel
- Merged Compustat + AI adoption and exposure panel
- Matched AI panel and unmatched observations
- Diagnostics of panel data
- Analysis tables/figures
- Main cohort-specific `g-1` Callaway--Sant'Anna estimates
- HHI subgroup ATTs and formal high-minus-low competition contrasts
- Lagged continuous-NAICS3-HHI first-adoption determinant estimates
- Fixed-2015 continuous-HHI models of first and strong AI adoption

## Current Goal
Use the merged panel to estimate how AI adoption relates to firm outcomes such as size, employment, wages, productivity, investment, share repurchases and other accounting measures.
