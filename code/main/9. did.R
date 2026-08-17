#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Callaway-Sant'Anna DiD: firm outcomes after AI adoption
# ------------------------------------------------------------------------------
# This script uses the saved post-validation final analysis panel to:
# 1. build the original staggered-adoption sample (ai_score >= 2) and a second
#    sample that treats firms when they first reach ai_score == 3, retains
#    score-1-only firms as controls, and excludes score-2-only firms;
# 2. estimate four transparent control specifications with cohort-specific,
#    two-period att_gt() comparisons;
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
DID_COVARIATE_TIMING_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_pre_treatment_covariate_audit.csv"
)
DID_COHORT_BASELINE_QA_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_cohort_specific_baseline_qa.csv"
)
DID_BALANCED_SAMPLE_LOSS_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_balanced_panel_sample_loss.csv"
)
DID_ATT_COMPARISON_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_corrected_vs_previous_att.csv"
)
DID_MODEL_WARNINGS_CSV <- file.path(
  DID_OUTPUT_DIR,
  "did_model_warnings.csv"
)
DID_PUBLICATION_CSV <- file.path(DID_OUTPUT_DIR, "did_publication_tables.csv")
DID_PUBLICATION_MD <- file.path(DID_OUTPUT_DIR, "did_publication_tables.md")

SAVE_DID_OUTPUTS <- TRUE

# Complete covariate support begins in 2015 after loading the required Compustat
# lookback. Treatment cohorts therefore begin in 2016 so every treated firm can
# contribute a genuine g-1 baseline period.
MIN_TREATED_COHORT <- 2016L
DID_EST_METHOD <- "dr"
CONTROL_GROUP <- "notyettreated"
DID_BASE_PERIOD <- "varying"
DID_2_COHORT_VAR <- "ai_adoption_year"
DID_3_COHORT_VAR <- "ai_adoption_3_year"
# Dynamic estimates and event-study plots are produced only for this model.
# Specification (3) is the preferred baseline; change this one value if the
# preferred specification changes after the final model review.
BEST_DID_SPEC_NAME <- "main_controls_naics2"

# did::att_gt() guarantees earlier-period covariates in a balanced panel, but a
# globally balanced 2015-2025 panel discards a large share of this sample. The
# main implementation below therefore constructs each ATT(g,t) as its own--
# balanced two-period panel. For every post-treatment cell, the earlier period
# and every covariate are fixed to g-1 for both cohort-g firms and their eligible
# comparison firms. This retains the panel DR estimator while avoiding both
# global balancing loss and the period-specific covariates used by att_gt()'s
# unbalanced/repeated-cross-section path.
PAIR_ALLOW_UNBALANCED_PANEL <- FALSE

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
# These are intentionally not pre-lagged in the source panel. The estimator
# explicitly copies each cohort's g-1 values into both rows of every relevant
# treated/comparison two-period panel.
FIRM_DID_CONTROLS <- c(
  "log_at",
  "roa",
  "cash_ratio"
)

# The preferred main conditional specification additionally controls for
# two-digit NAICS industry categories.
MAIN_DID_CONTROLS <- c(
  FIRM_DID_CONTROLS,
  "naics2_f"
)

if (PAIR_ALLOW_UNBALANCED_PANEL) {
  stop(
    "PAIR_ALLOW_UNBALANCED_PANEL must remain FALSE. Each cohort-time cell ",
    "must be balanced across its baseline and target periods."
  )
}

if (DID_BASE_PERIOD != "varying") {
  stop(
    "DID_BASE_PERIOD must remain 'varying' unless the pre-treatment event-study ",
    "normalization is deliberately redesigned. Post-treatment ATT(g,t) uses ",
    "g-1 under either supported base-period setting."
  )
}

if (any(grepl("_l[0-9]+$", FIRM_DID_CONTROLS))) {
  stop(
    "FIRM_DID_CONTROLS must name the source variables, not pre-lagged ",
    "variables. Cohort-specific g-1 values are constructed explicitly."
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

baseline_control_names <- function(controls) {
  if (length(controls) == 0L) {
    character()
  } else {
    paste0(controls, "_cohort_baseline")
  }
}

scalar_or_na <- function(value) {
  if (length(value) == 0L || !is.finite(value[[1]])) {
    NA_real_
  } else {
    as.numeric(value[[1]])
  }
}

run_balanced_reference <- function(
    sample,
    outcome,
    controls,
    cohort_var) {
  input_n_obs <- nrow(sample)
  input_n_firms <- n_distinct(sample$firm_id)

  reference_model <- suppressWarnings(
    att_gt(
      yname = outcome,
      tname = "year",
      idname = "firm_id",
      gname = cohort_var,
      xformla = build_xformla(controls),
      data = sample,
      panel = TRUE,
      allow_unbalanced_panel = FALSE,
      control_group = CONTROL_GROUP,
      base_period = DID_BASE_PERIOD,
      est_method = DID_EST_METHOD,
      bstrap = FALSE,
      cband = FALSE,
      clustervars = "firm_id",
      faster_mode = TRUE
    )
  )

  reference_sample <- reference_model$DIDparams$data
  reference_id <- reference_model$DIDparams$idname
  reference_aggregate <- aggte(
    reference_model,
    type = "group",
    na.rm = TRUE,
    bstrap = FALSE,
    cband = FALSE
  )

  balanced_n_obs <- nrow(reference_sample)
  balanced_n_firms <- n_distinct(reference_sample[[reference_id]])

  list(
    model = reference_model,
    overall_att = as.numeric(reference_aggregate$overall.att),
    overall_se = as.numeric(reference_aggregate$overall.se),
    sample_loss = tibble(
      input_n_obs = input_n_obs,
      balanced_n_obs = balanced_n_obs,
      observations_lost = input_n_obs - balanced_n_obs,
      observation_loss_pct = 100 * (input_n_obs - balanced_n_obs) / input_n_obs,
      input_n_firms = input_n_firms,
      balanced_n_firms = balanced_n_firms,
      firms_lost = input_n_firms - balanced_n_firms,
      firm_loss_pct = 100 * (input_n_firms - balanced_n_firms) / input_n_firms
    )
  )
}

run_cohort_time_att <- function(
    sample,
    outcome,
    controls,
    cohort_var,
    cohort,
    target_year) {
  post_treatment <- target_year >= cohort
  baseline_year <- if (post_treatment) cohort - 1L else target_year - 1L
  synthetic_cohort_var <- ".cell_treatment_year"
  baseline_controls <- baseline_control_names(controls)

  baseline_lookup <- sample |>
    filter(year == baseline_year) |>
    select(firm_id, all_of(controls)) |>
    distinct(firm_id, .keep_all = TRUE)

  if (length(controls) > 0L) {
    baseline_lookup <- baseline_lookup |>
      rename_with(
        ~ paste0(.x, "_cohort_baseline"),
        all_of(controls)
      ) |>
      filter(if_all(all_of(baseline_controls), ~ !is.na(.x)))
  }

  eligible_firms <- sample |>
    distinct(firm_id, .data[[cohort_var]]) |>
    filter(
      .data[[cohort_var]] == cohort |
        .data[[cohort_var]] == 0L |
        (.data[[cohort_var]] > target_year & .data[[cohort_var]] != cohort)
    ) |>
    inner_join(baseline_lookup, by = "firm_id")

  pair_candidates <- sample |>
    filter(year %in% c(baseline_year, target_year)) |>
    semi_join(eligible_firms, by = "firm_id") |>
    select(cik, firm_id, year, all_of(cohort_var), all_of(outcome)) |>
    inner_join(eligible_firms, by = c("firm_id", cohort_var)) |>
    filter(!is.na(.data[[outcome]])) |>
    distinct(firm_id, year, .keep_all = TRUE)

  balanced_firms <- pair_candidates |>
    count(firm_id, name = "n_periods") |>
    filter(n_periods == 2L) |>
    select(firm_id)

  pair_sample <- pair_candidates |>
    semi_join(balanced_firms, by = "firm_id") |>
    mutate(
      "{synthetic_cohort_var}" := if_else(
        .data[[cohort_var]] == cohort,
        as.integer(target_year),
        0L
      )
    ) |>
    arrange(firm_id, year)

  if (length(controls) > 0L) {
    pair_sample[baseline_controls] <- lapply(
      pair_sample[baseline_controls],
      function(value) {
        if (is.factor(value)) droplevels(value) else value
      }
    )
  }

  treated_firms <- pair_sample |>
    filter(.data[[cohort_var]] == cohort) |>
    distinct(firm_id)
  comparison_firms <- pair_sample |>
    filter(.data[[cohort_var]] != cohort) |>
    distinct(firm_id)

  if (nrow(treated_firms) < 1L || nrow(comparison_firms) < 1L) {
    stop(
      "Cohort-time cell g=", cohort, ", t=", target_year,
      " has no treated or comparison firms after pair balancing."
    )
  }

  captured_warnings <- character()
  cell_model <- withCallingHandlers(
    att_gt(
      yname = outcome,
      tname = "year",
      idname = "firm_id",
      gname = synthetic_cohort_var,
      xformla = build_xformla(baseline_controls),
      data = pair_sample,
      panel = TRUE,
      allow_unbalanced_panel = PAIR_ALLOW_UNBALANCED_PANEL,
      control_group = "nevertreated",
      base_period = "varying",
      est_method = DID_EST_METHOD,
      bstrap = FALSE,
      cband = FALSE,
      clustervars = "firm_id",
      faster_mode = TRUE
    ),
    warning = function(warning_condition) {
      warning_text <- conditionMessage(warning_condition)
      if (!grepl("No pre-treatment periods available", warning_text, fixed = TRUE)) {
        captured_warnings <<- c(captured_warnings, warning_text)
      }
      invokeRestart("muffleWarning")
    }
  )

  cell_index <- which(
    cell_model$group == target_year & cell_model$t == target_year
  )
  if (length(cell_index) != 1L) {
    stop(
      "Expected one att_gt() estimate for g=", cohort,
      ", t=", target_year, "; found ", length(cell_index), "."
    )
  }

  cell_ids <- cell_model$DIDparams$data |>
    distinct(firm_id) |>
    pull(firm_id)
  influence_function <- as.numeric(cell_model$inffunc[, cell_index])
  if (length(cell_ids) != length(influence_function)) {
    stop("Influence-function rows do not match panel IDs in a cohort-time cell.")
  }

  fixed_within_firm <- if (length(baseline_controls) == 0L) {
    TRUE
  } else {
    pair_sample |>
      group_by(firm_id) |>
      summarise(
        across(all_of(baseline_controls), ~ n_distinct(.x) == 1L),
        .groups = "drop"
      ) |>
      select(-firm_id) |>
      unlist(use.names = FALSE) |>
      all()
  }

  treated_baseline_year <- if (nrow(treated_firms) > 0L) baseline_year else NA_integer_
  comparison_baseline_year <- if (nrow(comparison_firms) > 0L) baseline_year else NA_integer_

  qa <- tibble(
    cohort = as.integer(cohort),
    target_year = as.integer(target_year),
    cell_type = if_else(post_treatment, "post-treatment", "pre-treatment"),
    required_baseline_year = as.integer(baseline_year),
    treated_baseline_year = as.integer(treated_baseline_year),
    comparison_baseline_year = as.integer(comparison_baseline_year),
    treated_and_controls_same_baseline =
      treated_baseline_year == comparison_baseline_year,
    baseline_matches_g_minus_1 = if_else(
      post_treatment,
      baseline_year == cohort - 1L,
      NA
    ),
    covariates_fixed_within_firm = fixed_within_firm,
    any_post_treatment_covariate_source = if_else(
      post_treatment & length(controls) > 0L,
      baseline_year >= cohort,
      FALSE
    ),
    allow_unbalanced_panel = PAIR_ALLOW_UNBALANCED_PANEL,
    n_pair_observations = nrow(pair_sample),
    n_pair_firms = n_distinct(pair_sample$firm_id),
    n_treated_firms = nrow(treated_firms),
    n_comparison_firms = nrow(comparison_firms),
    n_unpaired_firms_removed =
      n_distinct(pair_candidates$firm_id) - nrow(balanced_firms),
    att_is_finite = is.finite(cell_model$att[[cell_index]])
  )

  list(
    cohort = as.integer(cohort),
    target_year = as.integer(target_year),
    att = as.numeric(cell_model$att[[cell_index]]),
    se = as.numeric(cell_model$se[[cell_index]]),
    influence_function = influence_function,
    ids = cell_ids,
    treated_ids = treated_firms$firm_id,
    used_firm_years = pair_sample |>
      distinct(firm_id, year),
    qa = qa,
    warnings = unique(captured_warnings),
    did_params = cell_model$DIDparams
  )
}

assemble_cohort_specific_mp <- function(
    cell_results,
    sample,
    cohort_var,
    bootstrap_seed) {
  master_ids <- sort(unique(unlist(map(cell_results, "ids"))))
  n_master <- length(master_ids)

  influence_columns <- map(
    cell_results,
    function(cell_result) {
      influence_column <- numeric(n_master)
      matched_rows <- match(cell_result$ids, master_ids)
      influence_column[matched_rows] <-
        cell_result$influence_function * n_master / length(cell_result$ids)
      influence_column
    }
  )
  combined_influence_function <- do.call(cbind, influence_columns)

  treated_membership <- map_dfr(
    cell_results,
    function(cell_result) {
      if (cell_result$target_year < cell_result$cohort) {
        return(tibble(firm_id = integer(), cohort = integer()))
      }
      tibble(
        firm_id = cell_result$treated_ids,
        cohort = cell_result$cohort
      )
    }
  ) |>
    distinct(firm_id, cohort)

  conflicting_membership <- treated_membership |>
    count(firm_id) |>
    filter(n > 1L)
  if (nrow(conflicting_membership) > 0L) {
    stop("A firm was assigned to more than one treatment cohort during assembly.")
  }

  aggregation_data <- tibble(firm_id = master_ids) |>
    left_join(treated_membership, by = "firm_id") |>
    mutate(
      cohort = replace_na(cohort, 0L),
      # aggte() reads one row per panel unit at the first value in tlist.
      year = min(map_dbl(cell_results, "target_year")),
      .w = 1
    ) |>
    rename("{cohort_var}" := cohort)

  group <- map_dbl(cell_results, "cohort")
  target_year <- map_dbl(cell_results, "target_year")
  att <- map_dbl(cell_results, "att")
  analytical_variance <-
    crossprod(combined_influence_function) / n_master
  analytical_se <- sqrt(diag(analytical_variance) / n_master)

  pre_treatment_cells <-
    group > target_year & is.finite(att) & is.finite(analytical_se)
  wald_statistic <- NA_real_
  wald_p_value <- NA_real_
  if (sum(pre_treatment_cells) > 0L) {
    pre_att <- att[pre_treatment_cells]
    pre_variance <-
      analytical_variance[pre_treatment_cells, pre_treatment_cells, drop = FALSE] /
      n_master
    inverse_pre_variance <- tryCatch(
      solve(pre_variance),
      error = function(error_condition) MASS::ginv(pre_variance)
    )
    wald_statistic <- as.numeric(
      t(pre_att) %*% inverse_pre_variance %*% pre_att
    )
    wald_p_value <- pchisq(
      wald_statistic,
      df = sum(pre_treatment_cells),
      lower.tail = FALSE
    )
  }

  did_params <- cell_results[[1]]$did_params
  did_params$data <- aggregation_data
  did_params$gname <- cohort_var
  did_params$tname <- "year"
  did_params$idname <- "firm_id"
  did_params$panel <- TRUE
  did_params$allow_unbalanced_panel <- FALSE
  did_params$faster_mode <- FALSE
  did_params$tlist <- sort(unique(target_year))
  did_params$glist <- sort(unique(group))
  did_params$bstrap <- TRUE
  did_params$biters <- DID_BITERS
  did_params$cband <- TRUE
  did_params$alp <- 0.05
  did_params$clustervars <- "firm_id"
  did_params$cluster_vector <- NULL
  did_params$cluster_vector_var <- NULL

  set.seed(bootstrap_seed)
  combined_model <- did:::MP(
    group = group,
    t = target_year,
    att = att,
    V_analytical = analytical_variance,
    se = analytical_se,
    c = qnorm(0.975),
    inffunc = combined_influence_function,
    n = n_master,
    W = wald_statistic,
    Wpval = wald_p_value,
    alp = 0.05,
    DIDparams = did_params
  )

  used_firm_years <- cell_results |>
    map("used_firm_years") |>
    bind_rows() |>
    distinct(firm_id, year)

  list(
    model = combined_model,
    n_firms = n_master,
    n_obs = nrow(used_firm_years),
    used_firm_years = used_firm_years
  )
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
    select(all_of(sample_vars)) |>
    filter(if_all(all_of(sample_vars), ~ !is.na(.x))) |>
    distinct(firm_id, year, .keep_all = TRUE)

  balanced_reference <- run_balanced_reference(
    sample = sample,
    outcome = outcome,
    controls = controls,
    cohort_var = cohort_var
  )

  cohorts <- sample |>
    distinct(.data[[cohort_var]]) |>
    filter(.data[[cohort_var]] > 0L) |>
    arrange(.data[[cohort_var]]) |>
    pull(.data[[cohort_var]])
  target_years <- sort(unique(sample$year))
  target_years <- target_years[target_years > min(target_years)]
  cell_grid <- crossing(
    cohort = as.integer(cohorts),
    target_year = as.integer(target_years)
  )

  cell_results <- map2(
    cell_grid$cohort,
    cell_grid$target_year,
    ~ run_cohort_time_att(
      sample = sample,
      outcome = outcome,
      controls = controls,
      cohort_var = cohort_var,
      cohort = .x,
      target_year = .y
    )
  )

  assembled <- assemble_cohort_specific_mp(
    cell_results = cell_results,
    sample = sample,
    cohort_var = cohort_var,
    bootstrap_seed = bootstrap_seed
  )
  cs_model <- assembled$model

  cohort_baseline_qa_tbl <- cell_results |>
    map("qa") |>
    bind_rows() |>
    mutate(
      spec_order = .env$spec_order,
      spec_name = .env$spec_name,
      spec_label = .env$spec_label,
      outcome = .env$outcome,
      cohort_var = .env$cohort_var,
      .before = 1L
    )

  failed_post_qa <- cohort_baseline_qa_tbl |>
    filter(cell_type == "post-treatment") |>
    filter(
      required_baseline_year != cohort - 1L |
        treated_baseline_year != cohort - 1L |
        comparison_baseline_year != cohort - 1L |
        !treated_and_controls_same_baseline |
        !baseline_matches_g_minus_1 |
        !covariates_fixed_within_firm |
        any_post_treatment_covariate_source |
        allow_unbalanced_panel
    )
  if (nrow(failed_post_qa) > 0L) {
    stop(
      "Cohort-specific baseline QA failed for ", nrow(failed_post_qa),
      " post-treatment ATT(g,t) cells."
    )
  }

  set.seed(bootstrap_seed)
  overall_att <- aggte(
    cs_model,
    type = "group",
    na.rm = TRUE,
    bstrap = TRUE,
    biters = DID_BITERS,
    cband = TRUE,
    clustervars = "firm_id"
  )

  pre_treatment_cells <-
    cs_model$group > cs_model$t &
    is.finite(cs_model$att) &
    is.finite(cs_model$se) &
    cs_model$se > 0

  wald_statistic <- scalar_or_na(cs_model$W)
  wald_p_value <- scalar_or_na(cs_model$Wpval)
  wald_test_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    outcome = outcome,
    Outcome = sub(" \\(log\\)$", "", outcome_label),
    `Wald statistic` = wald_statistic,
    df = sum(pre_treatment_cells),
    `p-value` = wald_p_value,
    Assessment = case_when(
      is.na(wald_p_value) ~ "Not available",
      wald_p_value < 0.05 ~ "Reject",
      TRUE ~ "Do not reject"
    )
  )

  overall_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    outcome = outcome,
    outcome_label = outcome_label,
    controls = if (length(controls) == 0L) "None (~1)" else paste(controls, collapse = ", "),
    covariate_reference_period = if_else(
      length(controls) == 0L,
      "No covariates",
      "cohort-specific g-1 for every post-treatment ATT(g,t)"
    ),
    base_period = DID_BASE_PERIOD,
    n_obs = assembled$n_obs,
    n_firms = assembled$n_firms,
    estimate = as.numeric(overall_att$overall.att),
    std_error = as.numeric(overall_att$overall.se),
    p_value = 2 * pnorm(-abs(overall_att$overall.att / overall_att$overall.se)),
    ci_low = overall_att$overall.att - 1.96 * overall_att$overall.se,
    ci_high = overall_att$overall.att + 1.96 * overall_att$overall.se
  )

  dynamic_tbl <- tibble()
  if (compute_dynamic) {
    set.seed(bootstrap_seed)
    dynamic_att <- aggte(
      cs_model,
      type = "dynamic",
      na.rm = TRUE,
      min_e = -4,
      max_e = 6,
      bstrap = TRUE,
      biters = DID_BITERS,
      cband = TRUE,
      clustervars = "firm_id"
    )
    dynamic_tbl <- tibble(
      spec_order = spec_order,
      spec_name = spec_name,
      spec_label = spec_label,
      outcome = outcome,
      outcome_label = outcome_label,
      n_obs = assembled$n_obs,
      n_firms = assembled$n_firms,
      event_time = dynamic_att$egt,
      estimate = dynamic_att$att.egt,
      std_error = dynamic_att$se.egt,
      ci_low = dynamic_att$att.egt - dynamic_att$crit.val * dynamic_att$se.egt,
      ci_high = dynamic_att$att.egt + dynamic_att$crit.val * dynamic_att$se.egt
    ) |>
      arrange(event_time)
  }

  covariate_timing_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    outcome = outcome,
    cohort_var = cohort_var,
    panel = TRUE,
    allow_unbalanced_panel = PAIR_ALLOW_UNBALANCED_PANEL,
    base_period = DID_BASE_PERIOD,
    covariate_reference_period = if_else(
      length(controls) == 0L,
      "No covariates",
      "cohort-specific g-1 for every post-treatment ATT(g,t)"
    ),
    firm_controls = if_else(
      any(controls %in% FIRM_DID_CONTROLS),
      paste(intersect(controls, FIRM_DID_CONTROLS), collapse = ", "),
      "None"
    ),
    naics2_control = "naics2_f" %in% controls,
    aiie_control = "aiie" %in% controls,
    n_post_treatment_cells = sum(cohort_baseline_qa_tbl$cell_type == "post-treatment"),
    n_post_treatment_cells_passing_qa = sum(
      cohort_baseline_qa_tbl$cell_type == "post-treatment" &
        cohort_baseline_qa_tbl$baseline_matches_g_minus_1 &
        cohort_baseline_qa_tbl$treated_and_controls_same_baseline &
        cohort_baseline_qa_tbl$covariates_fixed_within_firm &
        !cohort_baseline_qa_tbl$any_post_treatment_covariate_source
    ),
    n_post_treatment_cells_estimable = sum(
      cohort_baseline_qa_tbl$cell_type == "post-treatment" &
        cohort_baseline_qa_tbl$att_is_finite
    ),
    aggte_group_succeeded =
      is.finite(overall_att$overall.att) & is.finite(overall_att$overall.se),
    aggte_dynamic_succeeded = if (compute_dynamic) {
      nrow(dynamic_tbl) > 0L & all(is.finite(dynamic_tbl$estimate))
    } else {
      TRUE
    }
  )

  balance_loss_tbl <- balanced_reference$sample_loss |>
    mutate(
      spec_order = .env$spec_order,
      spec_name = .env$spec_name,
      spec_label = .env$spec_label,
      outcome = .env$outcome,
      cohort_var = .env$cohort_var,
      .before = 1L
    )

  comparison_tbl <- tibble(
    spec_order = spec_order,
    spec_name = spec_name,
    spec_label = spec_label,
    outcome = outcome,
    cohort_var = cohort_var,
    previous_specification = "global balanced panel",
    previous_n_obs = balanced_reference$sample_loss$balanced_n_obs,
    previous_n_firms = balanced_reference$sample_loss$balanced_n_firms,
    previous_att = balanced_reference$overall_att,
    previous_std_error = balanced_reference$overall_se,
    corrected_specification = "cohort-specific balanced g-1 comparisons",
    corrected_n_obs = assembled$n_obs,
    corrected_n_firms = assembled$n_firms,
    corrected_att = as.numeric(overall_att$overall.att),
    corrected_std_error = as.numeric(overall_att$overall.se),
    att_difference = as.numeric(overall_att$overall.att) - balanced_reference$overall_att
  )

  warning_tbl <- bind_rows(
    tibble(
      spec_order = integer(),
      spec_name = character(),
      spec_label = character(),
      outcome = character(),
      cohort_var = character(),
      cohort = integer(),
      target_year = integer(),
      warning = character()
    ),
    map_dfr(
      cell_results,
      function(cell_result) {
        if (length(cell_result$warnings) == 0L) {
          return(tibble())
        }
        tibble(
          spec_order = spec_order,
          spec_name = spec_name,
          spec_label = spec_label,
          outcome = outcome,
          cohort_var = cohort_var,
          cohort = cell_result$cohort,
          target_year = cell_result$target_year,
          warning = cell_result$warnings
        )
      }
    )
  )

  list(
    covariate_timing_tbl = covariate_timing_tbl,
    cohort_baseline_qa_tbl = cohort_baseline_qa_tbl,
    balance_loss_tbl = balance_loss_tbl,
    comparison_tbl = comparison_tbl,
    warning_tbl = warning_tbl,
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
      "(3) additionally includes firm size, ROA, and the cash ratio measured ",
      "at the cohort-specific last pre-treatment year (g-1); specification (4) ",
      "additionally includes AIIE. NAICS2 is modeled as a separate categorical ",
      "control. No post-treatment firm characteristics enter the conditional ",
      "ATT(g,t) estimates. * p < 0.10; ** p < 0.05; *** p < 0.01."
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

  covariate_timing_table <- model_results |>
    map("covariate_timing_tbl") |>
    bind_rows() |>
    order_model_table()

  cohort_baseline_qa_table <- model_results |>
    map("cohort_baseline_qa_tbl") |>
    bind_rows() |>
    arrange(
      match(outcome, DID_OUTCOMES),
      spec_order,
      cohort,
      target_year
    )

  balance_loss_table <- model_results |>
    map("balance_loss_tbl") |>
    bind_rows() |>
    order_model_table()

  att_comparison_table <- model_results |>
    map("comparison_tbl") |>
    bind_rows() |>
    order_model_table()

  model_warning_table <- model_results |>
    map("warning_tbl") |>
    bind_rows()

  list(
    cohort_counts = cohort_counts,
    att_table = att_table,
    event_study_table = event_study_table,
    wald_test_table = wald_test_table,
    covariate_timing_table = covariate_timing_table,
    cohort_baseline_qa_table = cohort_baseline_qa_table,
    balance_loss_table = balance_loss_table,
    att_comparison_table = att_comparison_table,
    model_warning_table = model_warning_table
  )
}

prepare_did_sample <- function(data) {
  data |>
    mutate(
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

covariate_timing_table <- bind_rows(
  tag_treatment(did_bundle_2$covariate_timing_table, treatment_2),
  tag_treatment(did_bundle_3$covariate_timing_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

cohort_baseline_qa_table <- bind_rows(
  tag_treatment(did_bundle_2$cohort_baseline_qa_table, treatment_2),
  tag_treatment(did_bundle_3$cohort_baseline_qa_table, treatment_3)
) |>
  arrange(
    treatment_order,
    match(outcome, DID_OUTCOMES),
    spec_order,
    cohort,
    target_year
  )

balance_loss_table <- bind_rows(
  tag_treatment(did_bundle_2$balance_loss_table, treatment_2),
  tag_treatment(did_bundle_3$balance_loss_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

att_comparison_table <- bind_rows(
  tag_treatment(did_bundle_2$att_comparison_table, treatment_2),
  tag_treatment(did_bundle_3$att_comparison_table, treatment_3)
) |>
  arrange(treatment_order, match(outcome, DID_OUTCOMES), spec_order)

model_warning_table <- bind_rows(
  tag_treatment(did_bundle_2$model_warning_table, treatment_2),
  tag_treatment(did_bundle_3$model_warning_table, treatment_3)
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
  covariate_timing = list(
    panel = TRUE,
    allow_unbalanced_panel = PAIR_ALLOW_UNBALANCED_PANEL,
    base_period = DID_BASE_PERIOD,
    firm_controls = FIRM_DID_CONTROLS,
    interpretation = paste0(
      "Every post-treatment ATT(g,t) is estimated as a balanced two-period ",
      "att_gt() comparison. Covariates for treated and comparison firms are ",
      "copied from cohort-specific year g-1 and held fixed across both rows."
    )
  ),
  treatment_definitions = TREATMENT_DEFINITIONS,
  cohort_counts = cohort_counts,
  att_table = att_table,
  publication_tables = publication_tables,
  event_study_table = event_study_table,
  wald_test_table = wald_test_table,
  covariate_timing_table = covariate_timing_table,
  cohort_baseline_qa_table = cohort_baseline_qa_table,
  balance_loss_table = balance_loss_table,
  att_comparison_table = att_comparison_table,
  model_warning_table = model_warning_table
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
  write_csv(covariate_timing_table, DID_COVARIATE_TIMING_CSV)
  write_csv(cohort_baseline_qa_table, DID_COHORT_BASELINE_QA_CSV)
  write_csv(balance_loss_table, DID_BALANCED_SAMPLE_LOSS_CSV)
  write_csv(att_comparison_table, DID_ATT_COMPARISON_CSV)
  write_csv(model_warning_table, DID_MODEL_WARNINGS_CSV)
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
  cat("Saved pre-treatment covariate audit to:\n", DID_COVARIATE_TIMING_CSV, "\n")
  cat("Saved cohort-specific baseline QA to:\n", DID_COHORT_BASELINE_QA_CSV, "\n")
  cat("Saved global-balance sample-loss audit to:\n", DID_BALANCED_SAMPLE_LOSS_CSV, "\n")
  cat("Saved corrected-versus-previous ATT comparison to:\n", DID_ATT_COMPARISON_CSV, "\n")
  cat("Saved preferred-specification dynamic plots to:\n", DID_DYNAMIC_PLOT_DIR, "\n")
}
