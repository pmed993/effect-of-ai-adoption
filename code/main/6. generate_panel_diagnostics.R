#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Key diagnostics for the final analysis panel
# ------------------------------------------------------------------------------
# This script uses the saved merged and final analysis panel files to:
# 1. summarise panel coverage, EDGAR match rates, and AI-score retention;
# 2. describe score and treatment patterns over time;
# 3. summarise NAICS coverage; and
# 4. assess whether the treatment path is usable for staggered DiD.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(dplyr)
library(ggplot2)
library(patchwork)
library(scales)


# ---- Settings ----------------------------------------------------------------
AI_SCORE_TREATED_THRESHOLD <- 2L

MERGED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_panel.rds")
EDGAR_PANEL_CSV <- file.path(INPUT_DIR, "llm_score", "llm_extraction_firm_year_panel.csv")

PANEL_DIAGNOSTICS_OUTPUT_DIR <- file.path(OUTPUT_DIR, "diagnostics")
PANEL_DIAGNOSTICS_FIGURES_DIR <- file.path(OUTPUT_DIR, "figures")
PANEL_DIAGNOSTICS_BUNDLE_RDS <- file.path(
  PANEL_DIAGNOSTICS_OUTPUT_DIR,
  "panel_diagnostics_bundle.rds"
)

SAVE_PANEL_DIAGNOSTICS <- TRUE
SAVE_PANEL_DIAGNOSTICS_FIGURES <- TRUE

# ---- Helpers -----------------------------------------------------------------
safe_mean <- function(x) {
  if (all(is.na(x))) NA_real_ else mean(x, na.rm = TRUE)
}

round_numeric_cols <- function(data, digits = 3) {
  data |>
    mutate(across(where(is.numeric), ~ round(.x, digits)))
}

normalize_cik <- function(x) {
  out <- suppressWarnings(as.numeric(x))
  ifelse(is.na(out), NA_character_, as.character(as.integer(out)))
}

compress_path <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(integer())
  keep <- c(TRUE, x[-1] != x[-length(x)])
  x[keep]
}

format_path <- function(x) {
  path <- compress_path(x)
  if (length(path) == 0) return(NA_character_)
  paste(path, collapse = " -> ")
}

classify_score_path <- function(x) {
  path <- compress_path(x)
  if (length(path) == 0) return("no_score")
  if (length(path) == 1) return(paste0("constant_", path[1]))

  diffs <- diff(path)
  if (all(diffs > 0)) return("upward_only")
  if (all(diffs < 0)) return("downward_only")
  "mixed_reversal"
}

classify_binary_path <- function(x) {
  path <- compress_path(x)
  if (length(path) == 0) return("no_score")
  if (identical(path, 0L)) return("never_treated")
  if (identical(path, 1L)) return("always_treated")
  if (identical(path, c(0L, 1L))) return("clean_adopter")
  if (identical(path, c(1L, 0L))) return("treated_then_untreated")
  "multiple_switches"
}

transition_count <- function(x) {
  path <- compress_path(x)
  max(length(path) - 1L, 0L)
}

summarise_naics_level <- function(data, code_col, title_cols = character()) {
  data |>
    filter(!is.na(.data[[code_col]]), .data[[code_col]] != "") |>
    group_by(across(all_of(c(code_col, title_cols)))) |>
    summarise(
      n_firm_years = n(),
      n_firms = n_distinct(cik),
      year_min = min(year, na.rm = TRUE),
      year_max = max(year, na.rm = TRUE),
      .groups = "drop"
    ) |>
    mutate(share_firm_years = n_firm_years / sum(n_firm_years)) |>
    arrange(desc(n_firm_years), .data[[code_col]]) |>
    round_numeric_cols()
}


# ---- Load saved panels -------------------------------------------------------
if (!file.exists(MERGED_PANEL_RDS)) {
  stop("Merged panel not found: ", MERGED_PANEL_RDS)
}
if (!file.exists(ANALYSIS_PANEL_RDS)) {
  stop(
    "Final analysis panel not found: ", ANALYSIS_PANEL_RDS,
    ". Run 4. build_or_load_panel_data.R first."
  )
}

panel_all <- readRDS(MERGED_PANEL_RDS)
panel_analysis <- readRDS(ANALYSIS_PANEL_RDS)


# ---- Prepare analysis panels --------------------------------------------------
panel_window <- panel_all |>
  mutate(
    cik = as.character(cik),
    year = as.integer(year),
    ai_score = as.integer(ai_score),
    ai_adopted = as.integer(ai_adopted)
  ) |>
  filter(!is.na(cik), cik != "", !is.na(year)) |>
  arrange(cik, year)

panel_diag <- panel_analysis |>
  mutate(
    cik = as.character(cik),
    year = as.integer(year),
    ai_score = as.integer(ai_score),
    ai_score_treated = as.integer(ai_score >= AI_SCORE_TREATED_THRESHOLD),
    ai_adopted = as.integer(ai_adopted),
    ai_adoption_year = as.integer(ai_adoption_year)
  ) |>
  filter(!is.na(cik), cik != "", !is.na(year), !is.na(ai_adopted)) |>
  arrange(cik, year)

panel_filtered_compustat <- build_final_analysis_panel(panel_window) |>
  mutate(
    cik = as.character(cik),
    year = as.integer(year),
    ai_score = as.integer(ai_score)
  ) |>
  filter(!is.na(cik), cik != "", !is.na(year)) |>
  arrange(cik, year)

if (!file.exists(EDGAR_PANEL_CSV)) {
  stop("EDGAR panel not found: ", EDGAR_PANEL_CSV)
}

edgar_year_min <- min(panel_filtered_compustat$year, na.rm = TRUE)
edgar_year_max <- max(panel_filtered_compustat$year, na.rm = TRUE)

edgar_filtered <- fread(EDGAR_PANEL_CSV, select = c("cik", "year")) |>
  tibble::as_tibble() |>
  mutate(
    cik = normalize_cik(cik),
    year = as.integer(year)
  ) |>
  filter(
    !is.na(cik),
    cik != "",
    !is.na(year),
    year >= edgar_year_min,
    year <= edgar_year_max
  ) |>
  semi_join(
    panel_filtered_compustat |>
      distinct(cik),
    by = "cik"
  ) |>
  arrange(cik, year)

filtered_compustat_match_rate <- mean(!is.na(panel_filtered_compustat$ai_score))


# ---- Merge process overview ---------------------------------------------------
merge_process_overview <- tibble::tibble(
  sample = c("Compustat", "EDGAR", "Matched", "Match rate"),
  n_observations = c(
    scales::comma(nrow(panel_filtered_compustat)),
    scales::comma(nrow(edgar_filtered)),
    scales::comma(nrow(panel_diag)),
    ""
  ),
  unique_firms = c(
    scales::comma(dplyr::n_distinct(panel_filtered_compustat$cik)),
    scales::comma(dplyr::n_distinct(edgar_filtered$cik)),
    scales::comma(dplyr::n_distinct(panel_diag$cik)),
    ""
  ),
  match_rate = c(
    NA_character_,
    NA_character_,
    NA_character_,
    scales::percent(filtered_compustat_match_rate, accuracy = 0.1)
  )
)


# ---- Basic panel diagnostics --------------------------------------------------
panel_overview <- tibble::tibble(
  metric = c(
    "Merged firm-years",
    "Merged firms",
    "Compustat firm-years",
    "Compustat firms",
    "Matched firm-years",
    "Matched firms",
    "Years covered",
    "Dropped firm-years",
    "Share kept",
    "Final sample restrictions",
    "Match rate",
    "Treatment rule",
    "Treated share",
    "Average AI score"
  ),
  value = c(
    scales::comma(nrow(panel_window)),
    scales::comma(dplyr::n_distinct(panel_window$cik)),
    scales::comma(nrow(panel_filtered_compustat)),
    scales::comma(dplyr::n_distinct(panel_filtered_compustat$cik)),
    scales::comma(nrow(panel_diag)),
    scales::comma(dplyr::n_distinct(panel_diag$cik)),
    paste0(min(panel_diag$year, na.rm = TRUE), "-", max(panel_diag$year, na.rm = TRUE)),
    scales::comma(nrow(panel_window) - nrow(panel_diag)),
    scales::percent(nrow(panel_diag) / nrow(panel_window), accuracy = 0.1),
    paste0(
      "Exclude NAICS2 ", paste(FINAL_ANALYSIS_EXCLUDED_NAICS2, collapse = ", "),
      "; keep exchg ", paste(FINAL_ANALYSIS_INCLUDED_EXCHG, collapse = ", ")
    ),
    scales::percent(filtered_compustat_match_rate, accuracy = 0.1),
    paste0("ai_score >= ", AI_SCORE_TREATED_THRESHOLD),
    scales::percent(mean(panel_diag$ai_adopted == 1L, na.rm = TRUE), accuracy = 0.1),
    round(mean(panel_diag$ai_score, na.rm = TRUE), 3)
  )
)

score_distribution_overall <- panel_diag |>
  count(ai_score, name = "n_firm_years") |>
  mutate(
    share_firm_years = n_firm_years / sum(n_firm_years),
    ai_score_label = dplyr::case_when(
      ai_score == 1L ~ "No current adoption",
      ai_score == 2L ~ "Limited / targeted adoption",
      ai_score == 3L ~ "Production / strategic adoption",
      TRUE ~ "Other"
    )
  ) |>
  select(ai_score, ai_score_label, everything()) |>
  round_numeric_cols()

treated_share_by_year <- panel_diag |>
  group_by(year) |>
  summarise(
    n_firm_years = n(),
    share_treated = mean(ai_adopted == 1L, na.rm = TRUE),
    mean_ai_score = mean(ai_score, na.rm = TRUE),
    share_score_1 = mean(ai_score == 1L, na.rm = TRUE),
    share_score_2 = mean(ai_score == 2L, na.rm = TRUE),
    share_score_3 = mean(ai_score == 3L, na.rm = TRUE),
    .groups = "drop"
  ) |>
  round_numeric_cols()


# ---- Industry coverage --------------------------------------------------------
naics_overview <- tibble::tibble(
  metric = c(
    "Unique NAICS2 sectors",
    "Unique NAICS3 subsectors",
    "Unique NAICS4 groups",
    "Firm-years with missing NAICS2 title",
    "Firm-years with missing NAICS3 title",
    "Firm-years with missing NAICS4 code"
  ),
  value = c(
    scales::comma(dplyr::n_distinct(panel_diag$naics2[!is.na(panel_diag$naics2) & panel_diag$naics2 != ""])),
    scales::comma(dplyr::n_distinct(panel_diag$naics3[!is.na(panel_diag$naics3) & panel_diag$naics3 != ""])),
    scales::comma(dplyr::n_distinct(panel_diag$naics4[!is.na(panel_diag$naics4) & panel_diag$naics4 != ""])),
    scales::comma(sum(!is.na(panel_diag$naics2) & panel_diag$naics2 != "" & is.na(panel_diag$naics2_title))),
    scales::comma(sum(!is.na(panel_diag$naics3) & panel_diag$naics3 != "" & is.na(panel_diag$naics3_title))),
    scales::comma(sum(is.na(panel_diag$naics4) | panel_diag$naics4 == ""))
  )
)

naics2_summary <- summarise_naics_level(
  panel_diag,
  code_col = "naics2",
  title_cols = "naics2_title"
)

naics3_summary <- summarise_naics_level(
  panel_diag,
  code_col = "naics3",
  title_cols = "naics3_title"
)

naics4_summary <- summarise_naics_level(
  panel_diag,
  code_col = "naics4"
)


# ---- Firm treatment paths -----------------------------------------------------
firm_paths <- panel_diag |>
  group_by(cik) |>
  summarise(
    first_year = min(year, na.rm = TRUE),
    last_year = max(year, na.rm = TRUE),
    n_years = n(),
    score_path = format_path(ai_score),
    score_path_type = classify_score_path(ai_score),
    n_score_transitions = transition_count(ai_score),
    binary_path = format_path(ai_adopted),
    binary_path_type = classify_binary_path(ai_adopted),
    n_binary_transitions = transition_count(ai_adopted),
    .groups = "drop"
  ) |>
  arrange(cik)

ever_treated_summary <- panel_diag |>
  group_by(cik) |>
  summarise(
    ever_treated = any(ai_adopted == 1L, na.rm = TRUE),
    .groups = "drop"
  ) |>
  mutate(
    treatment_status = if_else(ever_treated, "Ever treated", "Never treated")
  ) |>
  count(treatment_status, name = "n_firms") |>
  mutate(share_firms = n_firms / sum(n_firms)) |>
  arrange(match(treatment_status, c("Ever treated", "Never treated"))) |>
  round_numeric_cols()

score_path_counts <- firm_paths |>
  count(score_path, score_path_type, sort = TRUE, name = "n_firms") |>
  mutate(share_firms = n_firms / sum(n_firms)) |>
  round_numeric_cols()

top_score_paths <- score_path_counts |>
  slice_head(n = 20)

score_consistency_summary <- firm_paths |>
  count(score_path_type, sort = TRUE, name = "n_firms") |>
  mutate(share_firms = n_firms / sum(n_firms)) |>
  round_numeric_cols()

binary_path_summary <- firm_paths |>
  count(binary_path_type, sort = TRUE, name = "n_firms") |>
  mutate(share_firms = n_firms / sum(n_firms)) |>
  round_numeric_cols()

did_readiness_summary <- tibble::tibble(
  metric = c(
    "Never treated firms",
    "Clean adopters (0 -> 1 only)",
    "Always treated firms",
    "Treated then untreated",
    "Multiple binary switches",
    "Potentially usable for staggered DiD",
    "Share potentially usable for staggered DiD"
  ),
  value = c(
    scales::comma(sum(firm_paths$binary_path_type == "never_treated", na.rm = TRUE)),
    scales::comma(sum(firm_paths$binary_path_type == "clean_adopter", na.rm = TRUE)),
    scales::comma(sum(firm_paths$binary_path_type == "always_treated", na.rm = TRUE)),
    scales::comma(sum(firm_paths$binary_path_type == "treated_then_untreated", na.rm = TRUE)),
    scales::comma(sum(firm_paths$binary_path_type == "multiple_switches", na.rm = TRUE)),
    scales::comma(sum(firm_paths$binary_path_type %in% c("never_treated", "clean_adopter"), na.rm = TRUE)),
    scales::percent(
      mean(firm_paths$binary_path_type %in% c("never_treated", "clean_adopter"), na.rm = TRUE),
      accuracy = 0.1
    )
  )
)


# ---- Plots -------------------------------------------------------------------
p_treated_share_by_year <- ggplot(treated_share_by_year, aes(x = year, y = share_treated)) +
  geom_line(color = "#2C7FB8", linewidth = 1) +
  geom_point(color = "#2C7FB8", size = 2) +
  scale_y_continuous(
    labels = scales::percent_format(accuracy = 1),
    limits = c(0, 1),
    breaks = seq(0, 1, by = 0.2),
    expand = c(0, 0)
  ) +
  labs(
    title = NULL,
    x = "Year",
    y = "Share treated"
  ) +
  theme_minimal(base_size = 12)

p_mean_ai_score_by_year <- ggplot(treated_share_by_year, aes(x = year, y = mean_ai_score)) +
  geom_line(color = "#E15759", linewidth = 1) +
  geom_point(color = "#E15759", size = 2) +
  scale_y_continuous(breaks = c(1, 2, 3)) +
  coord_cartesian(ylim = c(1, 3)) +
  labs(
    title = NULL,
    x = "Year",
    y = "Mean AI score"
  ) +
  theme_minimal(base_size = 12)

p_panel_trends_side_by_side <- (
  p_treated_share_by_year +
    labs(title = "Treated share")
) + (
  p_mean_ai_score_by_year +
    labs(title = "AI score")
) +
  plot_layout(ncol = 2) &
  theme(
    plot.title = element_text(size = 15, face = "plain"),
    axis.title = element_text(size = 15),
    axis.text = element_text(size = 13)
  )

score_distribution_by_year <- panel_diag |>
  count(year, ai_score, name = "n_firm_years") |>
  group_by(year) |>
  mutate(share_firm_years = n_firm_years / sum(n_firm_years)) |>
  ungroup() |>
  round_numeric_cols()

p_score_mix_by_year <- ggplot(
  score_distribution_by_year,
  aes(x = year, y = share_firm_years, fill = factor(ai_score))
) +
  geom_col(width = 0.75) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  scale_fill_brewer(palette = "RdYlBu", direction = -1, name = "AI score") +
  labs(
    x = "Year",
    y = "Share of firm-years"
  ) +
  theme_minimal(base_size = 12)


# ---- Save figures ------------------------------------------------------------
if (SAVE_PANEL_DIAGNOSTICS_FIGURES) {
  dir.create(PANEL_DIAGNOSTICS_FIGURES_DIR, recursive = TRUE, showWarnings = FALSE)

  ggsave(
    file.path(PANEL_DIAGNOSTICS_FIGURES_DIR, "p_score_mix_by_year.png"),
    p_score_mix_by_year,
    width = 8,
    height = 5,
    dpi = 300
  )

  ggsave(
    file.path(PANEL_DIAGNOSTICS_FIGURES_DIR, "p_panel_trends_side_by_side.png"),
    p_panel_trends_side_by_side,
    width = 9,
    height = 6,
    dpi = 300
  )
}


# ---- Save bundle --------------------------------------------------------------
panel_diagnostics <- list(
  panel_overview = panel_overview,
  merge_process_overview = merge_process_overview,
  score_distribution_overall = score_distribution_overall,
  treated_share_by_year = treated_share_by_year,
  score_distribution_by_year = score_distribution_by_year,
  naics_overview = naics_overview,
  naics2_summary = naics2_summary,
  naics3_summary = naics3_summary,
  naics4_summary = naics4_summary,
  ever_treated_summary = ever_treated_summary,
  firm_paths = firm_paths,
  score_path_counts = score_path_counts,
  top_score_paths = top_score_paths,
  score_consistency_summary = score_consistency_summary,
  binary_path_summary = binary_path_summary,
  did_readiness_summary = did_readiness_summary,
  p_treated_share_by_year = p_treated_share_by_year,
  p_mean_ai_score_by_year = p_mean_ai_score_by_year,
  p_score_mix_by_year = p_score_mix_by_year,
  p_panel_trends_side_by_side = p_panel_trends_side_by_side
)

if (SAVE_PANEL_DIAGNOSTICS) {
  dir.create(PANEL_DIAGNOSTICS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(panel_diagnostics, PANEL_DIAGNOSTICS_BUNDLE_RDS)
}


# ---- Console output -----------------------------------------------------------
cat("\nGenerated panel diagnostics.\n")
cat("Merged panel rows:", scales::comma(nrow(panel_window)), "\n")
cat("Final analysis panel rows:", scales::comma(nrow(panel_diag)), "\n")
cat("Final analysis firms:", scales::comma(dplyr::n_distinct(panel_diag$cik)), "\n")

if (SAVE_PANEL_DIAGNOSTICS) {
  cat("Saved diagnostics bundle to:", PANEL_DIAGNOSTICS_BUNDLE_RDS, "\n")
}
