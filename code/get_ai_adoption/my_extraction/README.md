---
title: "README"
output: html_document
---

# EDGAR 10-K Section Extraction for Item 1 Business and Item 7 MD&A

## Overview

This project extracts two high-value textual sections from SEC EDGAR 10-K filings:

1. **Item 1. Business**
2. **Item 7. Management’s Discussion and Analysis of Financial Condition and Results of Operations** (MD&A)

The goal is to build a **single-download, local-parse, resumable extraction pipeline** that is efficient enough for large-scale panel data work, while remaining transparent, debuggable, and easy to review.

This report documents:

- the full extraction workflow
- the logic used to parse and extract sections from raw filings
- the strengths and limitations of the original `Gunratan/edgar` approach
- the practical failures observed in modern filings
- specific ways to improve heading detection, text normalization, and section boundary matching
- recommendations for publishing, dissemination, and peer review

---

## Why these sections matter

The two target sections capture distinct and complementary information.

### Item 1. Business

This section typically contains:
- company operations
- products and services
- markets served
- competition
- supply chain or production overview
- organizational structure
- strategy and risk context

For empirical research, Item 1 is useful for:
- firm description embeddings
- topic modelling
- strategic positioning
- industry classification refinement
- product market analysis
- AI adoption and innovation language measurement

### Item 7. MD&A

This section typically contains management’s narrative explanation of:
- performance drivers
- changes in revenues, margins, or costs
- capital allocation
- liquidity
- financial condition
- future expectations
- important operational or macroeconomic developments

For research, MD&A is useful for:
- sentiment and forward-looking language
- managerial framing
- disclosure complexity
- uncertainty and risk interpretation
- firm response to shocks and technology change

---

## High-level extraction architecture

The pipeline follows this logic:

1. Build a table of 10-K filing URLs and output destinations.
2. Download each filing **once** into a raw cache.
3. Parse the filing **locally** from disk.
4. Extract:
   - Item 1 Business
   - Item 7 MD&A
5. Save each extracted section as a separate text file.
6. Record row-level status in a progress log.
7. Allow reruns only for incomplete or targeted subsets.
8. Optionally delete raw files after terminal success.

This architecture is preferable to repeated wrapper-based extraction because it avoids downloading the same filing multiple times and makes failures reproducible and inspectable.

---

## Pipeline design

### Inputs

The core input is a filing-level table containing at least:

- `cik`
- `year`
- `url`
- `destination`

A prepared row is then enriched with:

- raw filing path
- business output path
- MD&A output path
- row id
- batch id

### Outputs

The pipeline writes to four main locations:

- `cache/edgar_Raw10k/`
- `cache/edgar_BusDesc/`
- `cache/edgar_MgmtDisc/`
- `cache/logs/`

### Logging

Two log files are especially important:

- `extraction_progress.csv`
- `extraction_failed.csv`

The progress file is the canonical row-level status table for the whole run.  
The failed file is a filtered subset containing only rows with technical failure status.

### Status logic

A filing can be classified as:

- `done`  
  both target sections were extracted

- `done_with_missing`  
  one or both sections were not found, but the run itself did not fail technically

- `incomplete`  
  technical failure, such as download error or parse failure

This distinction is crucial. A row with `done_with_missing` is not a pipeline crash. It is an extraction miss, which may reflect either:

- a genuine absence of the section
- a formatting change
- a heading-detection failure
- an overly strict regular expression
- a normalization step that destroyed heading structure

---

## Why the local single-download approach is better

A common inefficiency in older workflows is to call one function for Business and another for MD&A, where each function downloads and parses the filing independently.

That creates three problems:

### 1. Repeated downloads
The same filing may be downloaded two or more times.

### 2. Slower throughput
Network requests become the bottleneck.

### 3. Harder debugging
When something fails, it is less clear whether the problem is:
- the filing itself
- the download
- the parser
- the section extraction logic

A single-download, local-parse design avoids all three.

---

## The original `Gunratan/edgar` logic

The `Gunratan/edgar` package provides convenient section extraction wrappers. Its logic is historically useful because it offered a simple way to identify sections such as Business description and MD&A in 10-K filings.

Broadly, the original approach:

1. reads the filing text
2. optionally restricts parsing to the first `<DOCUMENT>` block
3. parses HTML/XML when present
4. extracts text nodes
5. applies basic normalization
6. uses `grep()` to detect start and end headings
7. pastes the text between them
8. chooses the longest or best candidate span

This is a sensible baseline and remains a strong starting point.

However, it was designed around filing structures that were more regular than many modern EDGAR documents.

---

## Strengths of the original approach

The original approach has several strengths.

### Simplicity

The extraction logic is transparent and inspectable. It is mostly built from:

- line-level text
- regex-based heading detection
- straightforward section boundary rules

That is much easier to audit than black-box NLP segmentation.

### Relevance to classic filings

For many older 10-K filings, especially more standard HTML or plain-text documents, simple heading-based rules work surprisingly well.

### Reproducibility

The extraction is deterministic. If a filing is unchanged, rerunning produces the same result.

### Research-friendly

The outputs are plain text and can feed directly into:
- text analysis
- embeddings
- panel datasets
- downstream manual validation

---

## Core limitations of the original `Gunratan/edgar` approach

The main issue is not that the package is wrong. It is that modern EDGAR filings are messy in ways that older regex assumptions do not fully capture.

### 1. Assumes headings are text-like and line-stable

Many filings no longer expose headings as neat lines such as:

- `Item 1. Business`
- `Item 7. Management’s Discussion and Analysis`

Instead, headings may be fragmented across:
- HTML table cells
- anchors
- font tags
- bold tags
- nested spans
- repeated named anchors
- navigation blocks
- inline cross references

Examples observed in raw filings include:

- `ITEM&nbsp;1.`
- `OUR BUSINESS`
- `Item 7. Management&#146;s Discussion and Analysis`
- `a name="ITEM_1_OUR_BUSINESS"`
- `a name="ITEM_1_BUSINESS"`

If the parser or normalization step collapses these badly, the heading can disappear as a clean searchable unit.

### 2. Weak handling of HTML entities and legacy encodings

SEC filings often contain:

- `&#160;`
- `&nbsp;`
- `&#146;`
- `&#147;`
- `&#148;`
- `&rsquo;`
- `&ldquo;`
- `&rdquo;`

If these are not normalized carefully, headings may fail to match regex patterns even though the human-readable content is clearly present.

### 3. Over-reliance on canonical heading names

Older logic often expects exact or near-exact labels like:

- `Item 1 Business`
- `Item 2 Properties`
- `Item 7 Management's Discussion and Analysis`
- `Item 7A`
- `Item 8`

But real filings may use:

- `OUR BUSINESS`
- `DESCRIPTION OF BUSINESS`
- `Management’s Discussion and Analysis of Financial Condition and Results of Operations`
- heading text split across multiple nodes
- headings without the expected item title on the same line

### 4. Difficulty separating table of contents from real section headings

One of the biggest sources of false matches is the table of contents.

A filing can contain:

- TOC links to `Item 1`
- TOC links to `Item 7`
- cross-references such as `See Item 7`
- repeated anchors before the real heading

If the extractor picks the first match, it may capture a table of contents block or a tiny spurious span rather than the real section.

### 5. Fragility when headings are split across nodes

For example, a parser may yield:

- `ITEM 7.`
- `Management’s Discussion and Analysis of Financial Condition and Results of Operations`

as two separate text nodes.

If the extraction logic only searches single lines, it misses the section start even though both parts are present adjacent to each other.

### 6. Boundary detection may fail in newer filings

For Business, the end is often approximated with:
- `Item 1A Risk Factors`
- `Item 2 Properties`
- `Item 3 Legal Proceedings`

For MD&A, the end is often approximated with:
- `Item 7A`
- `Item 8`

This is reasonable, but modern filings can:
- omit one expected boundary
- restructure section order
- present headings differently
- repeat boundary headings in navigation blocks

### 7. Modern filing formats changed substantially after about 2020

In the observed diagnostics, missingness rose sharply from 2020 onward, with especially high failure rates in 2024 to 2026. That pattern strongly suggests a **format shift** rather than true section absence.

---

## The improved local extraction logic

The revised pipeline keeps the spirit of `Gunratan/edgar`, but strengthens it in several places.

### Common helper functions

The improved implementation introduces reusable helpers for:

- HTML entity decoding
- vector normalization
- filing text normalization
- text-node extraction
- item-heading line merging
- TOC filtering
- best-pair section selection

These changes are important because they separate:
- text cleaning
- heading detection
- boundary selection
- output writing

That makes the extraction much easier to debug and improve.

---

## Business description extraction

### Objective

Extract the content between the true start of Item 1 Business and the next valid downstream section boundary.

### Core logic

The improved `extract_BusDesc()` function:

1. reads the raw filing from disk
2. restricts parsing to the first `<DOCUMENT>` block when present
3. extracts visible text nodes from HTML/XML
4. normalizes entities and whitespace
5. merges split heading lines such as `ITEM 1.` followed by `Business`
6. searches for candidate start headings
7. searches for candidate end headings
8. filters probable table-of-contents lines
9. chooses the best start/end pair
10. writes the extracted section if it exceeds a minimum word count

### Candidate start patterns

The improved extractor allows variants such as:

- `ITEM 1 BUSINESS`
- `ITEM 1 DESCRIPTION OF BUSINESS`
- `ITEM 1 OUR BUSINESS`
- `OUR BUSINESS`
- `BUSINESS`
- `ITEM 1.`

This is a major improvement over exact-title matching.

### Candidate end patterns

The extractor looks for likely downstream boundaries, such as:

- `ITEM 1A RISK FACTORS`
- `ITEM 2 PROPERTIES`
- `ITEM 2 DESCRIPTION OF PROPERTY`
- `ITEM 2 REAL ESTATE`
- `ITEM 3 LEGAL PROCEEDINGS`

### Why this helps

This broader pattern set captures cases where the filing presents the section title differently, especially:

- when the section is called `OUR BUSINESS`
- when `ITEM 1.` appears separately from the descriptive title
- when the parser splits heading fragments into adjacent lines

---

## MD&A extraction

### Objective

Extract the content between the true start of Item 7 MD&A and the next valid downstream boundary.

### Core logic

The improved `extract_MgmtDisc()` function:

1. reads the filing locally
2. restricts to the first `<DOCUMENT>` block if available
3. extracts text nodes from HTML/XML
4. normalizes encoding and whitespace
5. merges split heading lines
6. infers the filing type from filename
7. identifies candidate MD&A starts
8. identifies candidate boundaries at Item 7A or Item 8
9. filters TOC-like lines
10. chooses the highest quality valid span
11. writes the result if the word count threshold is met

### Candidate MD&A start patterns

The improved MD&A detection includes patterns such as:

- `ITEM 7 MANAGEMENT'S DISCUSSION AND ANALYSIS`
- `ITEM 7.`
- `MANAGEMENT'S DISCUSSION AND ANALYSIS`

This is important because many filings store the heading in a split or entity-encoded form.

### Candidate end patterns

The default end boundaries remain aligned to the original logic:

- `ITEM 7A`
- `ITEM 8`

This preserves compatibility with the original package design while making start detection more flexible.

---

## Why the helper functions matter

### `decode_html_basic()`

This function decodes common HTML entities and legacy numeric encodings that frequently break regex matching.

Without it, strings like `Management&#146;s` may never match a pattern expecting `Management's`.

### `normalize_text_vec()`

This converts parsed text to a more search-friendly form:
- transliteration to ASCII
- whitespace cleanup
- removal of empty nodes

### `extract_text_nodes()`

This is where visible text is extracted from HTML/XML while excluding:
- script
- style
- noscript
- form

This is a sensible compromise between keeping document text and discarding structural clutter.

### `merge_item_heading_lines()`

This helper is critical.  
It repairs cases where a heading is split, for example:

- `ITEM 7.`
- `Management’s Discussion and Analysis`

After merging, the extractor can match the heading as a single logical unit.

### `is_probable_toc_line()`

This helps reject false positives from:
- table of contents
- cross-references
- repeated navigation headings

This is one of the most important improvements over naive `grep()` matching.

### `choose_largest_valid_pair()` or equivalent pair selector

This function compares candidate start/end combinations and selects the span that looks most like a real section rather than a tiny TOC fragment.

That is much better than blindly taking the first match.

---

## What the diagnostics showed

The diagnostics on the sample panel showed three broad failure modes.

### 1. Both sections missing

This likely indicates:
- a modern formatting regime the parser is not handling well
- headings present only in anchor/name structures
- excessive flattening during normalization
- table-heavy layout that destroys line structure

This failure type becomes much more common after 2020.

### 2. Business missing, MD&A found

This suggests the Business extractor is missing:
- `OUR BUSINESS`
- `BUSINESS` as a standalone title
- Item 1 headings split across tags or lines
- newer anchor-based section structures

One CIK showed a nearly complete repeated pattern of Business failure across many years, which strongly suggests a systematic heading mismatch rather than random absence.

### 3. MD&A missing, Business found

This suggests the MD&A extractor is missing:
- Item 7 headings split into separate nodes
- curly apostrophes or legacy encodings
- filings where `ITEM 7.` is present but the full title is on the next node
- boundary detection issues around Item 7A and Item 8

---

## A critical structural issue: over-flattening the parsed text

One likely weakness in the improved code is the use of full-string flattening after node extraction.

If the parser already returns a useful vector of text nodes, then applying a broad normalization like:

- tag stripping
- whole-string collapsing
- line structure removal

can destroy the very heading boundaries the regex is trying to detect.

In practice, section extraction often works best when:

- HTML is parsed into visible text nodes
- node boundaries are preserved as much as possible
- only minimal normalization is applied before regex matching

This point matters especially for 2020+ filings.

---

## How to improve the extraction further

### 1. Preserve node structure longer

Do not aggressively collapse the parsed text into one flattened sequence too early.

Prefer:
- node extraction
- light normalization
- heading search on node-level text

Only collapse to a single string after the section span has been identified.

### 2. Expand heading vocabularies

For Business, consider accepting:

- `OUR BUSINESS`
- `BUSINESS`
- `OVERVIEW`
- `GENERAL`
- `COMPANY OVERVIEW`

For MD&A, consider accepting:

- `MANAGEMENT'S DISCUSSION`
- `MANAGEMENT DISCUSSION`
- `DISCUSSION AND ANALYSIS OF FINANCIAL CONDITION`
- section titles where `ITEM 7.` and the long title are separated

### 3. Add anchor-aware detection

Many newer filings encode headings in anchors such as:

- `ITEM_1_BUSINESS`
- `ITEM_1_OUR_BUSINESS`
- `ITEM_7_MDA`

You should explicitly search raw HTML for anchor names and ids before or alongside visible text-node matching.

### 4. Use paired raw-text and parsed-text heuristics

A strong improvement is to search both:

- parsed visible text
- the raw HTML source

The parsed text is easier to read, but the raw HTML may preserve anchor names and section ids that disappear after parsing.

### 5. Improve TOC rejection

Current TOC detection is useful but can be made stronger by rejecting lines that:
- contain multiple item references
- end in page numbers
- appear near the beginning of the filing
- are part of repeated navigation structures

### 6. Use local context windows around candidate headings

When a candidate heading is found, inspect the nearby lines:
- does it appear after a table of contents?
- does it have enough body text before the next heading?
- does the next heading appear at a plausible distance?

This is often more robust than regex alone.

### 7. Add section quality scoring

A real section usually has:
- many words
- relatively few heading-like lines internally
- reasonable distance between start and end
- domain-relevant vocabulary

You can score spans on these characteristics.

### 8. Build firm-specific or era-specific diagnostics

Because failures cluster by:
- CIK
- year
- filing era

it may be worth maintaining:
- a recent-filings mode
- a legacy-filings mode
- special-case regex additions for persistently problematic issuers

### 9. Save small heading panels for failed rows

For each `done_with_missing` row, save a compact diagnostic panel showing:
- candidate Item 1 lines
- candidate Item 7 lines
- candidate Item 7A and Item 8 lines
- nearby context windows

This will dramatically speed up debugging and peer review.

### 10. Validate against hand-labeled samples

A strong paper or software note should include manual validation:
- random sample of successful extractions
- random sample of missed extractions
- precision and recall by period
- failure decomposition by cause

---

## Suggested next-stage methodological improvements

If the project matures beyond regex rules, there are three realistic extensions.

### Rule-based plus anchor-based hybrid

Keep regex extraction, but supplement it with:
- HTML anchor inspection
- id/name attribute matching
- nearby visible text confirmation

This is the best next step because it stays interpretable.

### Structural parser approach

Instead of treating filings as flat text, parse them as document trees and identify headings by:
- font emphasis
- anchor tags
- table cell patterns
- heading order

This is more work but likely best for modern filings.

### ML-assisted section boundary detection

A classifier could be trained to identify:
- true Item 1 starts
- true Item 7 starts
- true section boundaries

This may improve recall, but it is harder to audit and may be less attractive for methodological transparency unless carefully validated.

---

## Recommendations for the GitHub repository

To make the project reviewable and publishable, the repository should include:

### Repository structure

- `R/` or `code/` for functions
- `data-raw/` only for metadata generation scripts, not full SEC payloads
- `cache/` excluded from version control
- `tests/` for unit and regression tests
- `README.md`
- `LICENSE`
- `CITATION.cff`
- `CONTRIBUTING.md`
- `NEWS.md` or change log

### README should include

- project objective
- data source
- extraction logic summary
- setup instructions
- example workflow
- output structure
- known limitations
- validation summary
- citation instructions

### Essential reproducibility files

- `renv.lock` or similar dependency lockfile
- sample filing set for testing
- deterministic test script
- diagnostic examples

### Important documentation additions

Document:
- status definitions
- rerun logic
- difference between `done_with_missing` and `incomplete`
- why raw files may be deleted or retained
- what kinds of filings are expected to fail

---

## Recommended validation section for the repo or paper

A review-ready validation section should report:

### Coverage
What share of filings produce:
- both sections
- one section only
- neither section
- technical failure

### Time trend
Coverage by filing year, especially pre-2020 versus post-2020.

### Issuer concentration
Whether failures cluster by CIK.

### Manual audit
A hand-checked sample of:
- successes
- misses
- false positives
- false boundaries

### Error taxonomy
Classify misses into:
- TOC confusion
- heading split across nodes
- anchor-only heading
- novel title variant
- boundary not found
- parser collapse
- genuinely absent section

This would make the project much more persuasive.

---

## Suggested language for the project contribution

A fair and accurate framing is:

> This project extends the section extraction logic popularized in the `Gunratan/edgar` workflow by adapting it to a local, single-download, resumable pipeline and improving heading normalization and boundary detection for modern SEC 10-K filings.

That gives appropriate credit while making clear that your contribution is not just packaging, but a methodological improvement.

---

## Limitations of the current improved version

Even with the enhancements described above, the current extractor still has limitations.

### 1. Regex remains brittle
No matter how many heading patterns are added, some filings will always present unexpected structures.

### 2. Modern HTML complexity remains a challenge
Table-based layouts, repeated anchors, inline navigation, and entity noise can still defeat regex heuristics.

### 3. Recent filings may need a separate strategy
The sharp deterioration in 2020+ suggests that one unified extraction rule set may not be optimal across all years.

### 4. “No section found” is not the same as “section absent”
This label should always be interpreted cautiously.

### 5. Validation is still essential
A high extraction rate is not enough. Boundary correctness matters.

---

## Recommended roadmap

### Phase 1
Stabilize the local pipeline:
- logging
- reruns
- progress integrity
- diagnostic sampling

### Phase 2
Improve extraction rules:
- anchor-aware logic
- preserve node boundaries
- stronger TOC rejection
- broaden heading variants

### Phase 3
Evaluate systematically:
- hand-labeled validation sample
- year-by-year performance
- issuer-level clustering
- precision/recall reporting

### Phase 4
Package and publish:
- clean GitHub repo
- reproducible release
- archived DOI
- preprint or software note

---

## Where to publish and seek review

A good dissemination strategy is to publish in layers.

### 1. GitHub plus Zenodo DOI
This should be your baseline release.

Zenodo supports GitHub integration and can automatically archive GitHub releases, creating a citable research object with versioning and a DOI. :contentReference[oaicite:0]{index=0}

This is ideal for:
- code preservation
- citation
- reproducible versioned releases

### 2. JOSS for the software contribution
If the repository is polished and the contribution is framed as research software, the **Journal of Open Source Software** is a strong option. JOSS publishes papers about research software, but not all software is eligible, so the package needs clear research utility, documentation, and software substance. :contentReference[oaicite:1]{index=1}

This is probably the best venue if your main contribution is:
- a robust extractor
- reproducible code
- software methodology

### 3. OSF Preprints for a methods note
OSF Preprints is a good place to post a methods paper or technical report quickly, especially if you want early feedback before journal submission. OSF also supports broader research project sharing and community-facing preprint dissemination. :contentReference[oaicite:2]{index=2}

This is useful for:
- early visibility
- feedback from empirical researchers
- a citable methods note alongside the code

### 4. arXiv, if the paper is methodological and clearly positioned
arXiv includes economics and quantitative finance categories, and submissions are moderated for topical fit. It can work if the project is framed as a computational methods contribution for financial text analysis. :contentReference[oaicite:3]{index=3}

This is best if your paper emphasizes:
- computational text extraction methodology
- large-scale financial disclosure data construction
- downstream empirical applications

---

## Best publication recommendation

If the goal is attention, reuse, and review, the strongest sequence is:

1. **GitHub repository**
2. **Zenodo DOI release**
3. **OSF Preprint or arXiv methods note**
4. **JOSS submission** if the software package is sufficiently polished

That combination gives:
- visibility
- citability
- feedback
- software credit
- a formal review pathway

If you want the single best home for the code itself, choose **GitHub + Zenodo**.  
If you want the best formal peer-review venue for the software, choose **JOSS**.  
If you want the fastest public research feedback on the methodology, choose **OSF Preprints**.

---

## Closing assessment

The original `Gunratan/edgar` logic remains a useful and defensible starting point for section extraction from 10-K filings. Its main advantages are transparency, simplicity, and compatibility with classic filing structures.

However, modern EDGAR filings expose several structural weaknesses in the older regex-first approach:

- headings are often fragmented
- entities and encodings disrupt matching
- tables of contents create false positives
- section titles vary more than expected
- modern filings frequently require anchor-aware or structure-aware parsing

Your local single-download, resumable pipeline is a substantial improvement because it makes the process faster, more reproducible, and much easier to diagnose. The next major gains will come from:

- preserving parsed node structure longer
- adding anchor-aware heading detection
- improving TOC rejection
- validating extraction quality systematically

If packaged well, this work is publishable as both:
- a practical research software contribution
- a methods note for large-scale SEC text extraction

---

## Suggested citation note for the repository

> This repository builds on ideas from the `Gunratan/edgar` approach to section extraction from SEC filings, extending them into a local, resumable, single-download workflow with enhanced parsing and heading-detection logic for modern 10-K documents.

---