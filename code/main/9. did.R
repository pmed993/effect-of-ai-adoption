#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Callaway-Sant'Anna DiD: firm outcomes after AI adoption
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to:
# 1. build the staggered-adoption DiD sample;
# 2. estimate unconditional, NAICS2-adjusted, conditional, and
#    AIIE-augmented group-time effects with att_gt();
# 3. aggregate them into overall and dynamic effects with aggte(); and
# 4. save machine-readable estimates, publication-style outcome tables,
#    event-study tables, and figures.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(did)
library(dplyr)
library(ggplot2)
library(purrr)
library(readr)
library(tibble)
library(tidyr)


# ---- Settings ----------------------------------------------------------------
DID_OUTPUT_DIR <- file.path(OUTPUT_DIR, "did_firm_outcomes")
DID_ATT_TABLE_CSV <- file.path(DID_OUTPUT_DIR, "did_att_table.csv")
DID_EVENT_STUDY_TABLE_CSV <- file.path(DID_OUTPUT_DIR, "did_event_study_table.csv")
DID_WALD_TEST_CSV <- file.path(DID_OUTPUT_DIR, "did_parallel_trends_wald_test.csv")
DID_CELL_DIAGNOSTICS_CSV <- file.path(DID_OUTPUT_DIR, "did_cell_diagnostics.csv")
DID_RESULTS_TABLE_CSV <- file.path(DID_OUTPUT_DIR, "did_results_by_outcome.csv")
DID_RESULTS_TABLE_MD <- file.path(DID_OUTPUT_DIR, "did_results_by_outcome.md")
DID_BUNDLE_RDS <- file.path(DID_OUTPUT_DIR, "did_firm_outcomes_bundle.rds")

SAVE_DID_OUTPUTS <- TRUE

# Complete covariate support begins in 2015 after loading the required Compustat
# lookback. Treatment cohorts therefore begin in 2016 so every treated firm can
# contribute a genuine g-1 baseline period.
MIN_TREATED_COHORT <- 2016L
DID_EST_METHOD <- "dr"
CONTROL_GROUP <- "notyettreated"

# The did package uses covariates from the earlier period of each 2x2 panel
# comparison when the estimation sample is balanced. For post-treatment
# ATT(g,t), that earlier/base period is g-1. Do not switch this to TRUE without
# first constructing cohort-specific baseline covariates: in an unbalanced
# panel, att_gt() uses period-specific covariates instead.
ALLOW_UNBALANCED_PANEL <- FALSE
CONTROL_TIMING_LABEL <- "Base-period controls (g-1 for post-treatment ATT(g,t))"

# Multiplier-bootstrap iterations for standard errors and uniform bands.
DID_BITERS <- 1000L
DID_BOOTSTRAP_SEED <- 12345L
WINSOR_PROBS <- c(0.01, 0.99)

DID_OUTCOMES <- c(
  "log_emp",
  "log_market_cap",
  "log_labor_productivity",
  "log_sale"
)


# Parsimonious firm-level controls used in the conditional specifications.
# R&D reporting is used instead of R&D intensity to avoid restricting the
# sample to firms that separately disclose R&D expenditure.
FIRM_DID_CONTROLS <- c(
  "log_at_l1",
  "cash_ratio_l1",
  "capx_intensity_l1",
  "rd_reporter_l1",
  "firm_age_l1"
)

# The preferred main conditional specification additionally controls for
# two-digit NAICS industry categories.
MAIN_DID_CONTROLS <- c(
  FIRM_DID_CONTROLS,
  "naics2_f"
)

if (length(MAIN_DID_CONTROLS) > 0L && ALLOW_UNBALANCED_PANEL) {
  stop(
    "Controlled DiD models require ALLOW_UNBALANCED_PANEL = FALSE so ",
    "post-treatment ATT(g,t) comparisons use g-1 covariates."
  )
}

DID_SPECIFICATIONS <- tibble(
  spec_order = 1:4,
  
  spec_name = c(
    "unconditional",
    "naics2",
    "main_controls_naics2",
    "main_controls_naics2_aiie"
  ),
  spec_label = c(
    "Unconditional",
    "NAICS2 controls",
    "Firm controls + NAICS2",
    "Firm controls + NAICS2 + AIIE"
  ),
  controls = list(
    character(),
    c("naics2_f"),
    MAIN_DID_CONTROLS,
    c(MAIN_DID_CONTROLS, "aiie")
  )
)

#catch accidental mismatches between names, labels and control lists
stopifnot(
  nrow(DID_SPECIFICATIONS) == 4L,
  length(DID_SPECIFICATIONS$spec_name) == 4L,
  length(DID_SPECIFICATIONS$spec_label) == 4L,
  length(DID_SPECIFICATIONS$controls) == 4L
)

OUTCOME_LABELS <- c(
  log_emp = "Employment (log)",
  log_market_cap = "Market value (log)",
  log_labor_productivity = "Labour productivity (log)",
  log_sale = "Sales (log)"
)

# ---- Helpers -----------------------------------------------------------------
sanitize_name <- function(x) {
  gsub("[^A-Za-z0-9]+", "_", x)
}

significance_stars <- function(p_value) {
  case_when(
    is.na(p_value) ~ "",
    p_value < 0.01 ~ "***",
    p_value < 0.05 ~ "**",
    p_value < 0.10 ~ "*",
    TRUE ~ ""
  )
}

winsorize_vec <- function(x, probs = WINSOR_PROBS) {
  if (all(is.na(x))) return(x)
  bounds <- quantile(x, probs = probs, na.rm = TRUE, names = FALSE)
  pmin(pmax(x, bounds[[1]]), bounds[[2]])
}

build_xformla <- function(controls) {
  if (length(controls) == 0L) {
    ~1
  } else {
    as.formula(paste("~", paste(controls, collapse = " + ")))
  }
}

build_did_sample <- function(data) {
  data |>
    mutate(
      cik = as.character(cik),
      year = as.integer(year),
      ai_adoption_year = as.integer(ai_adoption_year)
    ) |>
    filter(
      !is.na(cik), cik != "",
      !is.na(year),
      !is.na(ai_adoption_year),
      ai_adoption_year == 0L | ai_adoption_year >= MIN_TREATED_COHORT
    ) |>
    arrange(cik, year) |>
    group_by(cik) |>
    mutate(firm_id = cur_group_id()) |>
    ungroup()
}

run_cs_did <- function(
    data,
    outcome,
    controls,
    spec_name,
    spec_label,
    bootstrap_seed) {
  outcome_label <- if (outcome %in% names(OUTCOME_LABELS)) {
    unname(OUTCOME_LABELS[[outcome]])
  } else {
    outcome
  }

  sample_vars <- unique(c(
    "cik",
    "firm_id",
    "year",
    "ai_adoption_year",
    outcome,
    controls
  ))

  missing_vars <- setdiff(sample_vars, names(data))
  if (length(missing_vars) > 0L) {
    stop(
      "DiD variables not found in the analysis panel: ",
      paste(missing_vars, collapse = ", ")
    )
  }

  sample <- data |>
    filter(if_all(all_of(sample_vars), ~ !is.na(.x)))

  set.seed(bootstrap_seed)
  cs_model <- att_gt(
    yname = outcome,
    tname = "year",
    idname = "firm_id",
    gname = "ai_adoption_year",
    xformla = build_xformla(controls),
    data = sample,
    panel = TRUE,
    allow_unbalanced_panel = ALLOW_UNBALANCED_PANEL,
    control_group = CONTROL_GROUP,
    est_method = DID_EST_METHOD,
    bstrap = TRUE,
    cband = TRUE,
    biters = DID_BITERS,
    clustervars = "firm_id",
    faster_mode = TRUE
  )

  # att_gt() standardizes the panel after the initial complete-case filter
  # (for example, it removes treated cohorts with no usable pre-period).
  # Report the sample that the estimator actually retained.
  standardized_sample <- cs_model$DIDparams$data
  standardized_id <- cs_model$DIDparams$idname
  n_obs_standardized <- nrow(standardized_sample)
  n_firms_standardized <- n_distinct(standardized_sample[[standardized_id]])

  missing_treated_baselines <- standardized_sample |>
    filter(is.finite(ai_adoption_year), ai_adoption_year > 0L) |>
    distinct(firm_id, ai_adoption_year) |>
    mutate(
      has_g_minus_1 = map2_lgl(
        firm_id,
        ai_adoption_year,
        ~ any(
          standardized_sample$firm_id == .x &
            standardized_sample$year == .y - 1L
        )
      )
    ) |>
    filter(!has_g_minus_1)

  if (nrow(missing_treated_baselines) > 0L) {
    stop(
      "The standardized DiD sample contains treated firms without a g-1 ",
      "control baseline."
    )
  }

  overall_att <- aggte(cs_model, type = "group", na.rm = TRUE)
  dynamic_att <- aggte(
    cs_model,
    type = "dynamic",
    na.rm = TRUE,
    min_e = -4,
    max_e = 6
  )

  # att_gt() reports a joint Wald pre-test of whether all usable
  # pre-treatment group-time pseudo-ATT estimates are zero.
  pre_treatment_cells <-
    cs_model$group > cs_model$t &
    is.finite(cs_model$att) &
    is.finite(cs_model$se) &
    cs_model$se > 0

  wald_test_tbl <- tibble(
    spec_name = spec_name,
    spec_label = spec_label,
    outcome = outcome,
    Outcome = sub(" \\(log\\)$", "", outcome_label),
    `Wald statistic` = as.numeric(cs_model$W),
    df = sum(pre_treatment_cells),
    `p-value` = as.numeric(cs_model$Wpval),
    Assessment = if_else(
      as.numeric(cs_model$Wpval) < 0.05,
      "Reject",
      "Do not reject"
    )
  )

  overall_tbl <- tibble(
    spec_name = spec_name,
    spec_label = spec_label,
    outcome = outcome,
    outcome_label = outcome_label,
    controls = if (length(controls) == 0L) "None (~1)" else paste(controls, collapse = ", "),
    n_obs = n_obs_standardized,
    n_firms = n_firms_standardized,
    estimate = overall_att$overall.att,
    std_error = overall_att$overall.se,
    p_value = 2 * pnorm(-abs(overall_att$overall.att / overall_att$overall.se)),
    ci_low = overall_att$overall.att - 1.96 * overall_att$overall.se,
    ci_high = overall_att$overall.att + 1.96 * overall_att$overall.se,
    r_squared = NA_real_,
    firm_effects = "Yes (implicit)",
    year_effects = "Yes (implicit)"
  )

  dynamic_tbl <- tibble(
    spec_name = spec_name,
    spec_label = spec_label,
    outcome = outcome,
    outcome_label = outcome_label,
    n_obs = n_obs_standardized,
    n_firms = n_firms_standardized,
    event_time = dynamic_att$egt,
    estimate = dynamic_att$att.egt,
    std_error = dynamic_att$se.egt,
    ci_low = dynamic_att$att.egt - dynamic_att$crit.val * dynamic_att$se.egt,
    ci_high = dynamic_att$att.egt + dynamic_att$crit.val * dynamic_att$se.egt
  ) |>
    arrange(event_time)

  event_study_plot <- ggdid(dynamic_att) +
    labs(
      title = paste("Event study:", outcome_label),
      subtitle = spec_label,
      y = paste("ATT on", outcome_label)
    )

  list(
    cs_model = cs_model,
    wald_test_tbl = wald_test_tbl,
    overall_tbl = overall_tbl,
    dynamic_tbl = dynamic_tbl,
    event_study_plot = event_study_plot
  )
}

build_results_table <- function(att_data) {
  spec_levels <- DID_SPECIFICATIONS$spec_label

  att_display <- att_data |>
    mutate(
      spec_label = factor(spec_label, levels = spec_levels),
      stars = significance_stars(p_value)
    )

  bind_rows(
    att_display |>
      transmute(
        outcome,
        outcome_label,
        spec_label,
        statistic = "Overall ATT",
        value = paste0(sprintf("%.3f", estimate), stars)
      ),
    att_display |>
      transmute(
        outcome,
        outcome_label,
        spec_label,
        statistic = "Standard error",
        value = sprintf("(%.3f)", std_error)
      ),
    att_display |>
      transmute(
        outcome,
        outcome_label,
        spec_label,
        statistic = "Observations",
        value = format(n_obs, big.mark = ",", scientific = FALSE)
      ),
    att_display |>
      transmute(
        outcome,
        outcome_label,
        spec_label,
        statistic = "Firms",
        value = format(n_firms, big.mark = ",", scientific = FALSE)
      ),
    att_display |>
      transmute(
        outcome,
        outcome_label,
        spec_label,
        statistic = "R²",
        value = "N/A"
      ),
    att_display |>
      transmute(
        outcome,
        outcome_label,
        spec_label,
        statistic = "Firm FE",
        value = firm_effects
      ),
    att_display |>
      transmute(
        outcome,
        outcome_label,
        spec_label,
        statistic = "Year FE",
        value = year_effects
      )
  ) |>
    mutate(
      statistic = factor(
        statistic,
        levels = c(
          "Overall ATT",
          "Standard error",
          "Observations",
          "Firms",
          "R²",
          "Firm FE",
          "Year FE"
        )
      )
    ) |>
    arrange(match(outcome, DID_OUTCOMES), statistic, spec_label) |>
    pivot_wider(names_from = spec_label, values_from = value) |>
    mutate(statistic = as.character(statistic)) |>
    select(outcome, outcome_label, statistic, all_of(spec_levels))
}

markdown_row <- function(values) {
  values <- gsub("\\|", "\\\\|", as.character(values))
  paste0("| ", paste(values, collapse = " | "), " |")
}

write_results_markdown <- function(results_table, path) {
  spec_levels <- DID_SPECIFICATIONS$spec_label
  lines <- c(
    "# Callaway-Sant'Anna DiD: firm outcomes",
    ""
  )

  for (outcome_name in DID_OUTCOMES) {
    outcome_table <- results_table |>
      filter(outcome == outcome_name) |>
      select(statistic, all_of(spec_levels))

    lines <- c(
      lines,
      paste0("## ", unique(results_table$outcome_label[results_table$outcome == outcome_name])),
      "",
      markdown_row(names(outcome_table)),
      markdown_row(rep("---", ncol(outcome_table))),
      apply(outcome_table, 1L, markdown_row),
      ""
    )
  }

  lines <- c(
    lines,
    paste0(
      "Notes: The first specification is unconditional. The second controls ",
      "for two-digit NAICS industry categories. The third additionally controls ",
      "for lagged firm size, cash ratio, capital expenditure intensity, R&D ",
      "reporting status, and firm age. The fourth additionally controls for ",
      "industry AI exposure (AIIE). "
    ),
    paste0(
      "Overall group-aggregated ATT estimates use Callaway-Sant'Anna ",
      "att_gt()/aggte(), not a two-way fixed-effects OLS regression. Standard ",
      "errors are firm-clustered multiplier-bootstrap standard errors. Firm ",
      "effects are removed by within-firm outcome differencing; common year ",
      "shocks are removed using contemporaneous not-yet-treated/never-treated ",
      "comparison changes. A conventional regression R-squared is therefore ",
      "not defined. * p < 0.10; ** p < 0.05; *** p < 0.01."
    )
  )

  writeLines(lines, path, useBytes = TRUE)
}

# ---- Load final analysis panel ------------------------------------------------
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_ai <- readRDS(ANALYSIS_PANEL_RDS)

# ---- Build DiD sample ---------------------------------------------------------
panel_did <- build_did_sample(panel_ai) |>
  mutate(
    leverage_l1_w = winsorize_vec(leverage_l1),
    rd_reporter_l1 = as.integer(rd_reporter_l1),
    naics2_f = factor(naics2)
  )

aiie_naics_check <- panel_did |>
  filter(!is.na(aiie), !is.na(naics2_f)) |>
  distinct(naics2_f, aiie) |>
  count(naics2_f, name = "n_aiie_values")

print(aiie_naics_check)

cohort_counts <- panel_did |>
  distinct(cik, ai_adoption_year) |>
  count(ai_adoption_year, name = "n_firms") |>
  arrange(ai_adoption_year)

did_sample_overview <- tibble(
  metric = c(
    "Input panel",
    "Methodology",
    "Specifications",
    "Candidate firm-years before outcome filtering/standardization",
    "Candidate firms before outcome filtering/standardization",
    "Never-treated firms",
    "Treated firms",
    "Years covered",
    "First treated cohort",
    "Last treated cohort",
    "Control group",
    "Control timing",
    "Balanced panel required",
    "Estimator",
    "Bootstrap seed",
    "Outcomes",
    "Controls"
  ),
  value = c(
    "Post-validation final analysis panel",
    "Callaway-Sant'Anna att_gt / aggte",
    paste(DID_SPECIFICATIONS$spec_label, collapse = "; "),
    format(nrow(panel_did), big.mark = ","),
    format(n_distinct(panel_did$cik), big.mark = ","),
    format(sum(cohort_counts$n_firms[cohort_counts$ai_adoption_year == 0L], na.rm = TRUE), big.mark = ","),
    format(sum(cohort_counts$n_firms[cohort_counts$ai_adoption_year > 0L], na.rm = TRUE), big.mark = ","),
    paste0(min(panel_did$year, na.rm = TRUE), "-", max(panel_did$year, na.rm = TRUE)),
    min(panel_did$ai_adoption_year[panel_did$ai_adoption_year > 0L], na.rm = TRUE),
    max(panel_did$ai_adoption_year[panel_did$ai_adoption_year > 0L], na.rm = TRUE),
    CONTROL_GROUP,
    CONTROL_TIMING_LABEL,
    if_else(ALLOW_UNBALANCED_PANEL, "No", "Yes"),
    DID_EST_METHOD,
    DID_BOOTSTRAP_SEED,
    paste(DID_OUTCOMES, collapse = ", "),
    paste0(
      "Specification 1: none; ",
      "Specification 2: naics2_f; ",
      "Specification 3: ",
      paste(MAIN_DID_CONTROLS, collapse = ", "),
      "; Specification 4 additionally includes aiie"
    )
  )
)

# ---- Estimate models ----------------------------------------------------------
model_grid <- map_dfr(
  seq_len(nrow(DID_SPECIFICATIONS)),
  function(spec_index) {
    tibble(
      spec_order = DID_SPECIFICATIONS$spec_order[[spec_index]],
      spec_name = DID_SPECIFICATIONS$spec_name[[spec_index]],
      spec_label = DID_SPECIFICATIONS$spec_label[[spec_index]],
      controls = rep(
        list(DID_SPECIFICATIONS$controls[[spec_index]]),
        length(DID_OUTCOMES)
      ),
      outcome = DID_OUTCOMES
    )
  }
) |>
  arrange(match(outcome, DID_OUTCOMES), spec_order) |>
  mutate(
    model_id = paste(outcome, spec_name, sep = "__"),
    bootstrap_seed = DID_BOOTSTRAP_SEED + row_number() - 1L
  )

did_results <- pmap(
  model_grid,
  function(
      spec_order,
      spec_name,
      spec_label,
      controls,
      outcome,
      model_id,
      bootstrap_seed) {
    run_cs_did(
      data = panel_did,
      outcome = outcome,
      controls = controls,
      spec_name = spec_name,
      spec_label = spec_label,
      bootstrap_seed = bootstrap_seed
    )
  }
  ) |>
  set_names(model_grid$model_id)

cell_diagnostics <- imap_dfr(
  did_results,
  function(model_result, model_id) {
    cs_model <- model_result$cs_model
    post_cell <- cs_model$group <= cs_model$t

    tibble(
      model_id = model_id,
      outcome = model_result$overall_tbl$outcome[[1]],
      spec_name = model_result$overall_tbl$spec_name[[1]],
      n_att_gt_cells = length(cs_model$att),
      n_finite_att_gt_cells = sum(is.finite(cs_model$att)),
      n_post_treatment_cells = sum(post_cell),
      n_finite_post_treatment_cells = sum(post_cell & is.finite(cs_model$att))
    )
  }
)

if (any(
  cell_diagnostics$n_post_treatment_cells !=
    cell_diagnostics$n_finite_post_treatment_cells
)) {
  failed_models <- cell_diagnostics |>
    filter(n_post_treatment_cells != n_finite_post_treatment_cells) |>
    pull(model_id)

  stop(
    "At least one model has missing post-treatment ATT(g,t) cells: ",
    paste(failed_models, collapse = ", ")
  )
}

att_table <- bind_rows(map(did_results, "overall_tbl")) |>
  mutate(
    outcome_order = match(outcome, DID_OUTCOMES),
    spec_order = match(spec_name, DID_SPECIFICATIONS$spec_name)
  ) |>
  arrange(outcome_order, spec_order) |>
  select(-outcome_order, -spec_order)

event_study_table <- bind_rows(map(did_results, "dynamic_tbl")) |>
  mutate(
    outcome_order = match(outcome, DID_OUTCOMES),
    spec_order = match(spec_name, DID_SPECIFICATIONS$spec_name)
  ) |>
  arrange(outcome_order, spec_order, event_time) |>
  select(-outcome_order, -spec_order)

wald_test_table <- bind_rows(map(did_results, "wald_test_tbl")) |>
  mutate(
    outcome_order = match(outcome, DID_OUTCOMES),
    spec_order = match(spec_name, DID_SPECIFICATIONS$spec_name)
  ) |>
  arrange(outcome_order, spec_order) |>
  select(-outcome_order, -spec_order)

results_table <- build_results_table(att_table)

did_bundle <- list(
  did_sample_overview = did_sample_overview,
  specifications = DID_SPECIFICATIONS,
  cohort_counts = cohort_counts,
  model_grid = model_grid,
  cell_diagnostics = cell_diagnostics,
  att_table = att_table,
  results_table = results_table,
  event_study_table = event_study_table,
  wald_test_table = wald_test_table,
  did_results = did_results
)


# ---- Save outputs -------------------------------------------------------------
if (SAVE_DID_OUTPUTS) {
  dir.create(DID_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

  write_csv(att_table, DID_ATT_TABLE_CSV)
  write_csv(event_study_table, DID_EVENT_STUDY_TABLE_CSV)
  write_csv(wald_test_table, DID_WALD_TEST_CSV)
  write_csv(cell_diagnostics, DID_CELL_DIAGNOSTICS_CSV)
  write_csv(results_table, DID_RESULTS_TABLE_CSV)
  write_results_markdown(results_table, DID_RESULTS_TABLE_MD)

  walk(
    DID_OUTCOMES,
    function(outcome_name) {
      results_table |>
        filter(outcome == outcome_name) |>
        select(-outcome, -outcome_label) |>
        write_csv(
          file.path(
            DID_OUTPUT_DIR,
            paste0("did_results_", sanitize_name(outcome_name), ".csv")
          )
        )
    }
  )

  saveRDS(did_bundle, DID_BUNDLE_RDS)

  iwalk(
    did_results,
    function(model_result, model_name) {
      ggsave(
        filename = file.path(
          DID_OUTPUT_DIR,
          paste0("event_study_", sanitize_name(model_name), ".png")
        ),
        plot = model_result$event_study_plot,
        width = 8,
        height = 5,
        dpi = 300
      )
    }
  )
}

# ---- Console output -----------------------------------------------------------
cat("\nEstimated firm-outcomes DiD models.\n")
cat("Methodology: Callaway-Sant'Anna att_gt / aggte\n")
cat("Bootstrap seed:", DID_BOOTSTRAP_SEED, "\n")
cat("Candidate rows before outcome filtering/standardization:", format(nrow(panel_did), big.mark = ","), "\n")
cat("Candidate firms before outcome filtering/standardization:", format(n_distinct(panel_did$cik), big.mark = ","), "\n")
cat("Never-treated firms:", format(sum(cohort_counts$n_firms[cohort_counts$ai_adoption_year == 0L], na.rm = TRUE), big.mark = ","), "\n")
cat("Finite post-treatment ATT(g,t) cells: all models passed\n")

cat("\nATT table (n_obs and n_firms are post-standardization):\n")
print(att_table)

cat("\nPublication-style tables by outcome:\n")
print(results_table)

cat("\nJoint Wald pre-test of parallel trends (5% assessment):\n")
print(
  wald_test_table |>
    mutate(
      `Wald statistic` = round(`Wald statistic`, 2),
      `p-value` = round(`p-value`, 4)
    )
)

if (SAVE_DID_OUTPUTS) {
  cat("\nSaved DiD outputs to:", DID_OUTPUT_DIR, "\n")
}
