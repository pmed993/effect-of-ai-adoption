#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Callaway-Sant'Anna DiD: firm outcomes after AI adoption
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to:
# 1. build the original staggered-adoption sample (ai_score >= 2) and a second
#    sample that treats firms when they first reach ai_score == 3, retains
#    score-1-only firms as controls, and excludes score-2-only firms;
# 2. estimate four transparent control specifications with att_gt();
# 3. report both treatments in publication-ready Panel A/Panel B tables; and
# 4. estimate dynamic effects only for one configurable preferred specification.
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
DID_DYNAMIC_PLOT_DIR <- file.path(DID_OUTPUT_DIR, "dynamic_plots")
DID_RESULTS_RDS <- file.path(DID_OUTPUT_DIR, "did_results.rds")
DID_ATT_CSV <- file.path(DID_OUTPUT_DIR, "did_att_estimates.csv")
DID_EVENT_STUDY_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_event_study_best_spec.csv"
)
DID_WALD_CSV <- file.path(DID_OUTPUT_DIR, "did_parallel_trends_wald.csv")
DID_COHORT_COUNTS_CSV <- file.path(DID_OUTPUT_DIR, "did_cohort_counts.csv")
DID_PUBLICATION_CSV <- file.path(DID_OUTPUT_DIR, "did_publication_tables.csv")
DID_PUBLICATION_MD <- file.path(DID_OUTPUT_DIR, "did_publication_tables.md")

SAVE_DID_OUTPUTS <- TRUE

# Complete covariate support begins in 2015 after loading the required Compustat
# lookback. Treatment cohorts therefore begin in 2016 so every treated firm can
# contribute a genuine g-1 baseline period.
MIN_TREATED_COHORT <- 2016L
DID_EST_METHOD <- "dr"
CONTROL_GROUP <- "notyettreated"
DID_2_COHORT_VAR <- "ai_adoption_year"
DID_3_COHORT_VAR <- "ai_adoption_3_year"
# Dynamic estimates and event-study plots are produced only for this model.
# Specification (3) is the preferred baseline; change this one value if the
# preferred specification changes after the final model review.
BEST_DID_SPEC_NAME <- "main_controls_naics2"

# The did package uses covariates from the earlier period of each 2x2 panel
# comparison when the estimation sample is balanced. For post-treatment
# ATT(g,t), that earlier/base period is g-1. Do not switch this to TRUE without
# first constructing cohort-specific baseline covariates: in an unbalanced
# panel, att_gt() uses period-specific covariates instead.
ALLOW_UNBALANCED_PANEL <- FALSE

# Multiplier-bootstrap iterations for standard errors and uniform bands.
DID_BITERS <- 1000L
DID_BOOTSTRAP_SEED <- 12345L

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
    "Industry controls",
    "Firm + industry controls",
    "Firm + industry controls + AIIE"
  ),
  column_label = paste0(
    "(", 1:4, ") ",
    c(
      "Unconditional",
      "Industry controls",
      "Firm + industry controls",
      "Firm + industry controls + AIIE"
    )
  ),
  naics2_controls = c("No", "Yes", "Yes", "Yes"),
  firm_controls = c("No", "No", "Yes", "Yes"),
  aiie_control = c("No", "No", "No", "Yes"),
  controls = list(
    character(),
    c("naics2_f"),
    MAIN_DID_CONTROLS,
    c(MAIN_DID_CONTROLS, "aiie")
  )
)

# Catch accidental mismatches between names, labels and control lists.
stopifnot(
  nrow(DID_SPECIFICATIONS) == 4L,
  length(DID_SPECIFICATIONS$spec_name) == 4L,
  length(DID_SPECIFICATIONS$spec_label) == 4L,
  length(DID_SPECIFICATIONS$column_label) == 4L,
  length(DID_SPECIFICATIONS$controls) == 4L
)

if (!BEST_DID_SPEC_NAME %in% DID_SPECIFICATIONS$spec_name) {
  stop("BEST_DID_SPEC_NAME is not defined in DID_SPECIFICATIONS.")
}

OUTCOME_LABELS <- c(
  log_emp = "Employment (log)",
  log_market_cap = "Market value (log)",
  log_labor_productivity = "Labour productivity (log)",
  log_sale = "Sales (log)"
)

# ---- Helpers -----------------------------------------------------------------
significance_stars <- function(p_value) {
  case_when(
    is.na(p_value) ~ "",
    p_value < 0.01 ~ "***",
    p_value < 0.05 ~ "**",
    p_value < 0.10 ~ "*",
    TRUE ~ ""
  )
}

format_estimate <- function(value) {
  sub("^-0\\.000$", "0.000", sprintf("%.3f", value))
}

build_xformla <- function(controls) {
  if (length(controls) == 0L) {
    ~1
  } else {
    as.formula(paste("~", paste(controls, collapse = " + ")))
  }
}

add_ai_adoption_3_year <- function(data) {
  data |>
    mutate(
      cik = as.character(cik),
      year = as.integer(year),
      ai_score = as.integer(ai_score)
    ) |>
    group_by(cik) |>
    mutate(
      ai_adoption_3_year = {
        treated_3_years <- year[!is.na(ai_score) & ai_score == 3L]
        observed_years <- year[!is.na(ai_score)]

        if (length(treated_3_years) > 0L) {
          min(treated_3_years)
        } else if (length(observed_years) > 0L) {
          0L
        } else {
          NA_integer_
        }
      }
    ) |>
    ungroup()
}

build_did_sample <- function(data, cohort_var) {
  required_vars <- c("cik", "year", cohort_var)
  missing_vars <- setdiff(required_vars, names(data))
  if (length(missing_vars) > 0L) {
    stop(
      "Variables required to build the DiD sample are missing: ",
      paste(missing_vars, collapse = ", ")
    )
  }

  data |>
    mutate(
      cik = as.character(cik),
      year = as.integer(year),
      "{cohort_var}" := as.integer(.data[[cohort_var]])
    ) |>
    filter(
      !is.na(cik), cik != "",
      !is.na(year),
      !is.na(.data[[cohort_var]]),
      .data[[cohort_var]] == 0L |
        .data[[cohort_var]] >= MIN_TREATED_COHORT
    ) |>
    arrange(cik, year) |>
    group_by(cik) |>
    mutate(firm_id = cur_group_id()) |>
    ungroup()
}

build_did_3_sample <- function(data) {
  required_vars <- c("cik", "year", "ai_score")
  missing_vars <- setdiff(required_vars, names(data))
  if (length(missing_vars) > 0L) {
    stop(
      "Variables required to build the score-3 DiD sample are missing: ",
      paste(missing_vars, collapse = ", ")
    )
  }

  data |>
    add_ai_adoption_3_year() |>
    group_by(cik) |>
    mutate(
      score_3_treated_firm = any(ai_score == 3L, na.rm = TRUE),
      score_1_control_firm = all(!is.na(ai_score) & ai_score == 1L)
    ) |>
    filter(score_3_treated_firm | score_1_control_firm) |>
    ungroup() |>
    select(-score_3_treated_firm, -score_1_control_firm) |>
    build_did_sample(cohort_var = DID_3_COHORT_VAR)
}

run_cs_did <- function(
    data,
    outcome,
    controls,
    spec_order,
    spec_name,
    spec_label,
    bootstrap_seed,
    cohort_var,
    compute_dynamic) {
  outcome_label <- if (outcome %in% names(OUTCOME_LABELS)) {
    unname(OUTCOME_LABELS[[outcome]])
  } else {
    outcome
  }

  sample_vars <- unique(c(
    "cik",
    "firm_id",
    "year",
    cohort_var,
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
    gname = cohort_var,
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
    filter(
      is.finite(.data[[cohort_var]]),
      .data[[cohort_var]] > 0L
    ) |>
    distinct(firm_id, .data[[cohort_var]]) |>
    transmute(
      firm_id,
      baseline_year = .data[[cohort_var]] - 1L
    ) |>
    anti_join(
      standardized_sample |>
        distinct(firm_id, year),
      by = c("firm_id", "baseline_year" = "year")
    )

  if (nrow(missing_treated_baselines) > 0L) {
    stop(
      "The standardized DiD sample contains treated firms without a g-1 ",
      "control baseline."
    )
  }

  post_treatment_cell <- cs_model$group <= cs_model$t
  if (any(post_treatment_cell & !is.finite(cs_model$att))) {
    stop(
      "Missing post-treatment ATT(g,t) cells for ", outcome,
      " in the ", spec_name, " specification."
    )
  }

  overall_att <- aggte(cs_model, type = "group", na.rm = TRUE)

  # att_gt() reports a joint Wald pre-test of whether all usable
  # pre-treatment group-time pseudo-ATT estimates are zero.
  pre_treatment_cells <-
    cs_model$group > cs_model$t &
    is.finite(cs_model$att) &
    is.finite(cs_model$se) &
    cs_model$se > 0

  wald_test_tbl <- tibble(
    spec_order = spec_order,
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
    spec_order = spec_order,
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
    ci_high = overall_att$overall.att + 1.96 * overall_att$overall.se
  )

  dynamic_tbl <- tibble()
  if (compute_dynamic) {
    dynamic_att <- aggte(
      cs_model,
      type = "dynamic",
      na.rm = TRUE,
      min_e = -4,
      max_e = 6
    )

    dynamic_tbl <- tibble(
      spec_order = spec_order,
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
  }

  list(
    wald_test_tbl = wald_test_tbl,
    overall_tbl = overall_tbl,
    dynamic_tbl = dynamic_tbl
  )
}

format_count <- function(value) {
  format(
    as.integer(value),
    big.mark = ",",
    scientific = FALSE,
    trim = TRUE
  )
}

build_panel_rows <- function(att_data, panel_label, row_offset) {
  spec_columns <- DID_SPECIFICATIONS$column_label
  display <- att_data |>
    left_join(
      select(DID_SPECIFICATIONS, spec_order, column_label),
      by = "spec_order"
    ) |>
    arrange(spec_order) |>
    mutate(stars = significance_stars(p_value))

  if (
    nrow(display) != nrow(DID_SPECIFICATIONS) ||
      n_distinct(display$spec_order) != nrow(DID_SPECIFICATIONS) ||
      any(is.na(display$column_label))
  ) {
    stop("Publication table does not contain exactly one estimate per specification.")
  }

  bind_rows(
    tibble(
      row_order = row_offset,
      row_type = "panel",
      row_label = panel_label,
      column_label = spec_columns,
      value = ""
    ),
    display |>
      transmute(
        row_order = row_offset + 1L,
        row_type = "estimate",
        row_label = "ATT",
        column_label,
        value = paste0(format_estimate(estimate), stars)
      ),
    display |>
      transmute(
        row_order = row_offset + 2L,
        row_type = "standard_error",
        row_label = "",
        column_label,
        value = sprintf("(%.3f)", std_error)
      ),
    display |>
      transmute(
        row_order = row_offset + 3L,
        row_type = "observations",
        row_label = "Observations",
        column_label,
        value = format_count(n_obs)
      ),
    display |>
      transmute(
        row_order = row_offset + 4L,
        row_type = "firms",
        row_label = "Firms",
        column_label,
        value = format_count(n_firms)
      )
  )
}

build_control_rows <- function(row_offset) {
  bind_rows(
    DID_SPECIFICATIONS |>
      transmute(
        row_order = row_offset,
        row_type = "control",
        row_label = "NAICS2 controls",
        column_label,
        value = naics2_controls
      ),
    DID_SPECIFICATIONS |>
      transmute(
        row_order = row_offset + 1L,
        row_type = "control",
        row_label = "Firm controls",
        column_label,
        value = firm_controls
      ),
    DID_SPECIFICATIONS |>
      transmute(
        row_order = row_offset + 2L,
        row_type = "control",
        row_label = "AIIE",
        column_label,
        value = aiie_control
      )
  )
}

build_publication_table <- function(att_2, att_3, outcome_name) {
  spec_columns <- DID_SPECIFICATIONS$column_label
  outcome_label <- unname(OUTCOME_LABELS[[outcome_name]])

  bind_rows(
    build_panel_rows(
      filter(att_2, outcome == outcome_name),
      "Panel A: AI adoption ≥ 2",
      1L
    ),
    build_panel_rows(
      filter(att_3, outcome == outcome_name),
      "Panel B: Strong AI adoption = 3",
      7L
    ),
    build_control_rows(13L)
  ) |>
    mutate(column_label = factor(column_label, levels = spec_columns)) |>
    arrange(row_order, column_label) |>
    pivot_wider(names_from = column_label, values_from = value) |>
    mutate(
      outcome = outcome_name,
      outcome_label = outcome_label,
      .before = 1L
    ) |>
    select(
      outcome,
      outcome_label,
      row_order,
      row_type,
      row_label,
      all_of(spec_columns)
    )
}

markdown_row <- function(values) {
  escaped <- gsub("|", "\\\\|", as.character(values), fixed = TRUE)
  paste0("| ", paste(escaped, collapse = " | "), " |")
}

write_publication_markdown <- function(publication_tables, path) {
  spec_columns <- DID_SPECIFICATIONS$column_label
  lines <- c(
    "# Callaway-Sant'Anna estimates",
    ""
  )

  for (outcome_name in DID_OUTCOMES) {
    table <- publication_tables |>
      filter(outcome == outcome_name) |>
      arrange(row_order) |>
      mutate(
        row_label = if_else(
          row_type == "panel",
          paste0("**", row_label, "**"),
          row_label
        )
      ) |>
      select(row_label, all_of(spec_columns))

    lines <- c(
      lines,
      paste0("## ", unname(OUTCOME_LABELS[[outcome_name]])),
      "",
      markdown_row(names(table)),
      markdown_row(rep("---", ncol(table))),
      apply(table, 1L, markdown_row),
      ""
    )
  }

  best_spec_label <- DID_SPECIFICATIONS |>
    filter(spec_name == BEST_DID_SPEC_NAME) |>
    pull(column_label)

  lines <- c(
    lines,
    paste0(
      "Notes: Estimates are group-aggregated Callaway-Sant'Anna ATT estimates. ",
      "Parentheses contain firm-clustered multiplier-bootstrap standard errors. ",
      "Specification (2) includes two-digit NAICS indicators; specification ",
      "(3) additionally includes lagged firm controls; specification (4) ",
      "additionally includes AIIE. * p < 0.10; ** p < 0.05; *** p < 0.01."
    ),
    paste0("Dynamic estimates use the configured preferred model: ", best_spec_label, ".")
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

# ---- Build model grid ---------------------------------------------------------
model_grid <- crossing(
  outcome = DID_OUTCOMES,
  spec_order = DID_SPECIFICATIONS$spec_order
) |>
  left_join(DID_SPECIFICATIONS, by = "spec_order") |>
  arrange(match(outcome, DID_OUTCOMES), spec_order) |>
  mutate(
    bootstrap_seed = DID_BOOTSTRAP_SEED + row_number() - 1L,
    compute_dynamic = spec_name == BEST_DID_SPEC_NAME
  )

order_model_table <- function(data) {
  ordered <- data |>
    mutate(
      outcome_order = match(outcome, DID_OUTCOMES),
      spec_sort_order = match(spec_name, DID_SPECIFICATIONS$spec_name)
    )

  if ("event_time" %in% names(ordered)) {
    ordered <- arrange(ordered, outcome_order, spec_sort_order, event_time)
  } else {
    ordered <- arrange(ordered, outcome_order, spec_sort_order)
  }

  select(ordered, -outcome_order, -spec_sort_order)
}

estimate_did_bundle <- function(data, cohort_var) {
  cohort_counts <- data |>
    distinct(cik, .data[[cohort_var]]) |>
    count(.data[[cohort_var]], name = "n_firms") |>
    arrange(.data[[cohort_var]]) |>
    transmute(cohort_year = .data[[cohort_var]], n_firms)

  model_results <- pmap(
    select(
      model_grid,
      outcome,
      controls,
      spec_order,
      spec_name,
      spec_label,
      bootstrap_seed,
      compute_dynamic
    ),
    function(
        outcome,
        controls,
        spec_order,
        spec_name,
        spec_label,
        bootstrap_seed,
        compute_dynamic) {
      run_cs_did(
        data = data,
        outcome = outcome,
        controls = controls,
        spec_order = spec_order,
        spec_name = spec_name,
        spec_label = spec_label,
        bootstrap_seed = bootstrap_seed,
        cohort_var = cohort_var,
        compute_dynamic = compute_dynamic
      )
    }
  )

  att_table <- model_results |>
    map("overall_tbl") |>
    bind_rows() |>
    order_model_table()

  event_study_table <- model_results |>
    map("dynamic_tbl") |>
    bind_rows() |>
    order_model_table()

  wald_test_table <- model_results |>
    map("wald_test_tbl") |>
    bind_rows() |>
    order_model_table()

  list(
    cohort_counts = cohort_counts,
    att_table = att_table,
    event_study_table = event_study_table,
    wald_test_table = wald_test_table
  )
}

prepare_did_sample <- function(data) {
  data |>
    mutate(
      rd_reporter_l1 = as.integer(rd_reporter_l1),
      naics2_f = factor(naics2)
    )
}

# Original treatment definition: first ai_score >= 2.
did_bundle_2 <- panel_ai |>
  build_did_sample(cohort_var = DID_2_COHORT_VAR) |>
  prepare_did_sample() |>
  estimate_did_bundle(cohort_var = DID_2_COHORT_VAR)

# Stricter treatment: first ai_score == 3; score-2-only firms are excluded.
did_bundle_3 <- panel_ai |>
  build_did_3_sample() |>
  prepare_did_sample() |>
  estimate_did_bundle(cohort_var = DID_3_COHORT_VAR)


# ---- Combine treatment definitions -------------------------------------------
TREATMENT_DEFINITIONS <- tibble(
  treatment_order = 1:2,
  treatment_id = c("ai_adoption_ge_2", "strong_ai_adoption_3"),
  treatment_label = c("AI adoption ≥ 2", "Strong AI adoption = 3"),
  cohort_var = c(DID_2_COHORT_VAR, DID_3_COHORT_VAR)
)

tag_treatment <- function(data, treatment_row) {
  data |>
    mutate(
      treatment_order = treatment_row$treatment_order,
      treatment_id = treatment_row$treatment_id,
      treatment_label = treatment_row$treatment_label,
      cohort_var = treatment_row$cohort_var,
      .before = 1L
    )
}

treatment_2 <- slice(TREATMENT_DEFINITIONS, 1L)
treatment_3 <- slice(TREATMENT_DEFINITIONS, 2L)

att_table <- bind_rows(
  tag_treatment(did_bundle_2$att_table, treatment_2),
  tag_treatment(did_bundle_3$att_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

event_study_table <- bind_rows(
  tag_treatment(did_bundle_2$event_study_table, treatment_2),
  tag_treatment(did_bundle_3$event_study_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), event_time)

wald_test_table <- bind_rows(
  tag_treatment(did_bundle_2$wald_test_table, treatment_2),
  tag_treatment(did_bundle_3$wald_test_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

cohort_counts <- bind_rows(
  tag_treatment(did_bundle_2$cohort_counts, treatment_2),
  tag_treatment(did_bundle_3$cohort_counts, treatment_3)
) |>
  arrange(treatment_order, cohort_year)

publication_tables <- map_dfr(
  DID_OUTCOMES,
  ~ build_publication_table(
    did_bundle_2$att_table,
    did_bundle_3$att_table,
    .x
  )
)

did_results <- list(
  specifications = DID_SPECIFICATIONS,
  preferred_event_study_specification = BEST_DID_SPEC_NAME,
  treatment_definitions = TREATMENT_DEFINITIONS,
  cohort_counts = cohort_counts,
  att_table = att_table,
  publication_tables = publication_tables,
  event_study_table = event_study_table,
  wald_test_table = wald_test_table
)


# ---- Save outputs -------------------------------------------------------------
validate_best_dynamic_output <- function(plot_data) {
  unexpected_specs <- setdiff(unique(plot_data$spec_name), BEST_DID_SPEC_NAME)
  if (length(unexpected_specs) > 0L) {
    stop(
      "Dynamic output contains non-preferred specifications: ",
      paste(unexpected_specs, collapse = ", ")
    )
  }

  expected_plots <- crossing(
    treatment_id = TREATMENT_DEFINITIONS$treatment_id,
    outcome = DID_OUTCOMES
  )
  observed_plots <- plot_data |>
    distinct(treatment_id, outcome)
  missing_plots <- anti_join(
    expected_plots,
    observed_plots,
    by = c("treatment_id", "outcome")
  )

  if (nrow(missing_plots) > 0L) {
    stop(
      "Preferred-specification dynamic estimates are missing for: ",
      paste0(missing_plots$treatment_id, "/", missing_plots$outcome, collapse = ", ")
    )
  }

  invisible(expected_plots)
}

save_best_dynamic_plots <- function(plot_data) {
  expected_plots <- validate_best_dynamic_output(plot_data)

  dir.create(DID_DYNAMIC_PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

  pwalk(
    expected_plots,
    function(treatment_id, outcome) {
      outcome_data <- plot_data |>
        filter(
          .data$treatment_id == .env$treatment_id,
          .data$outcome == .env$outcome
        )

      dynamic_plot <- ggplot(
        outcome_data,
        aes(x = event_time, y = estimate)
      ) +
        geom_hline(yintercept = 0, color = "gray45", linewidth = 0.4) +
        geom_vline(
          xintercept = -0.5,
          color = "gray55",
          linetype = "dashed",
          linewidth = 0.4
        ) +
        geom_ribbon(
          aes(ymin = ci_low, ymax = ci_high),
          fill = "#2C7FB8",
          alpha = 0.18
        ) +
        geom_line(color = "#1D5A85", linewidth = 0.7) +
        geom_point(color = "#1D5A85", size = 2) +
        scale_x_continuous(breaks = sort(unique(outcome_data$event_time))) +
        labs(
          title = paste("Dynamic treatment effects:", outcome_data$outcome_label[[1]]),
          subtitle = paste0(
            outcome_data$treatment_label[[1]],
            " | ", outcome_data$spec_label[[1]]
          ),
          x = "Years relative to treatment",
          y = "ATT",
          caption = "Shaded area: simultaneous 95% confidence band."
        ) +
        theme_minimal(base_size = 12) +
        theme(
          panel.grid.minor = element_blank(),
          plot.title = element_text(face = "bold"),
          plot.caption = element_text(color = "gray40")
        )

      ggsave(
        filename = file.path(
          DID_DYNAMIC_PLOT_DIR,
          paste0("did_", treatment_id, "_dynamic_", outcome, ".png")
        ),
        plot = dynamic_plot,
        width = 8,
        height = 5,
        dpi = 300
      )
    }
  )
}

validate_best_dynamic_output(event_study_table)

if (SAVE_DID_OUTPUTS) {
  dir.create(DID_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  write_csv(att_table, DID_ATT_CSV)
  write_csv(event_study_table, DID_EVENT_STUDY_CSV)
  write_csv(wald_test_table, DID_WALD_CSV)
  write_csv(cohort_counts, DID_COHORT_COUNTS_CSV)
  write_csv(publication_tables, DID_PUBLICATION_CSV)
  write_publication_markdown(publication_tables, DID_PUBLICATION_MD)
  saveRDS(did_results, DID_RESULTS_RDS)
  save_best_dynamic_plots(event_study_table)
}


# ---- Console output -----------------------------------------------------------
cat("\nEstimated Callaway-Sant'Anna models for both treatments.\n")
cat(
  "Preferred event-study specification:",
  DID_SPECIFICATIONS$column_label[
    DID_SPECIFICATIONS$spec_name == BEST_DID_SPEC_NAME
  ],
  "\n"
)

walk(
  DID_OUTCOMES,
  function(outcome_name) {
    cat("\n", unname(OUTCOME_LABELS[[outcome_name]]), "\n", sep = "")
    print(
      publication_tables |>
        filter(outcome == outcome_name) |>
        select(-outcome, -outcome_label, -row_order, -row_type)
    )
  }
)

if (SAVE_DID_OUTPUTS) {
  cat("\nSaved consolidated DiD outputs to:\n", DID_OUTPUT_DIR, "\n")
  cat("Saved preferred-specification dynamic plots to:\n", DID_DYNAMIC_PLOT_DIR, "\n")
}
