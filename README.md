# Effect of AI Adoption on Firm Outcomes

## Overview
This project studies whether firm-level AI adoption is associated with differences in firm outcomes and characteristics. The workflow combines:

- SEC filing text from EDGAR
- LLM-based AI adoption scores built from those filings
- Compustat annual accounting data
- External AI exposure measures matched by industry

## Overall Process
1. Extract and assemble EDGAR filing text.
   Main scripts live in [code/main/1. get_edgar_extract](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/1.%20get_edgar_extract).

2. Build firm-year AI adoption measures from filings.
   Main scripts live in [code/main/2. get_ai_adoption](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/2.%20get_ai_adoption).

3. Build the annual Compustat panel and merge AI measures.
   Main scripts live in [code/main/3. get_panel_data](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/3.%20get_panel_data):
   [1. build_compustat_annual_panel.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/3.%20get_panel_data/1.%20build_compustat_annual_panel.R)
   [2. build_compustat_ai_panel.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/3.%20get_panel_data/2.%20build_compustat_ai_panel.R)

4. Generate diagnostics and summary statistics for the final panel.
   See [generate_panel_diagnostics.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/generate_panel_diagnostics.R).

5. Run exploratory analysis of AI adoption, exposure, and firm outcomes.
   See [working.R](/Users/piomedolla/Desktop/effect-of-ai-adoption/code/main/working.R).

## Main Outputs
- Annual Compustat panel
- Merged Compustat + AI adoption and exposure panel
- Matched AI panel and unmatched observations
- Diagnostics of panel data
- Analysis tables/figures

## Current Goal
Use the merged panel to estimate how AI adoption relates to firm outcomes such as size, employment, wages, productivity, investment, share repurchases and other accounting measures.
