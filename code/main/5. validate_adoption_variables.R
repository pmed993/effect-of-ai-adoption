#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Validate filing-based AI adoption variables
# ------------------------------------------------------------------------------
# This script uses the matched Compustat + AI panel to:
# 1. validate mean AI scores against AIIE at the NAICS2 level;
# 2. validate mean AI scores against BTOS Question 7 at the NAICS2 level; and
# 3. describe the filtered final analysis sample used downstream.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(dplyr)
library(ggplot2)
library(patchwork)


# ---- Settings ----------------------------------------------------------------
VALIDATION_START_YEAR <- 2023L
VALIDATION_END_YEAR <- 2025L

MATCHED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_matched_panel.rds")

VALIDATION_OUTPUT_DIR <- file.path(OUTPUT_DIR, "validation_adoption")
VALIDATION_FIGURES_DIR <- file.path(OUTPUT_DIR, "figures")
VALIDATION_BUNDLE_RDS <- file.path(
  VALIDATION_OUTPUT_DIR,
  "validation_adoption_bundle.rds"
)

SAVE_VALIDATION_BUNDLE <- TRUE
SAVE_VALIDATION_FIGURES <- TRUE

VALIDATION_PLOT_BASE_SIZE <- 11
VALIDATION_POINT_SIZE <- 3.5
VALIDATION_LINE_WIDTH <- 1.2
VALIDATION_LABEL_SIZE <- 3.3
VALIDATION_CORR_LABEL_SIZE <- 4
VALIDATION_PANEL_TITLE_SIZE <- 16
VALIDATION_PANEL_SUBTITLE_SIZE <- 12
VALIDATION_AXIS_TITLE_SIZE <- 13
VALIDATION_AXIS_TEXT_SIZE <- 11
VALIDATION_SIDE_BY_SIDE_TITLE_SIZE <- 18
VALIDATION_SIDE_BY_SIDE_SUBTITLE_SIZE <- 13
VALIDATION_SIDE_BY_SIDE_WIDTH <- 9
VALIDATION_SIDE_BY_SIDE_HEIGHT <- 5.5


# ---- Helpers -----------------------------------------------------------------
safe_mean <- function(x) {
  if (all(is.na(x))) NA_real_ else mean(x, na.rm = TRUE)
}

safe_cor <- function(x, y, min_n = 5) {
  keep <- !is.na(x) & !is.na(y)
  if (sum(keep) < min_n) return(NA_real_)
  if (sd(x[keep]) == 0 || sd(y[keep]) == 0) return(NA_real_)
  cor(x[keep], y[keep])
}

round_numeric_cols <- function(data, digits = 3) {
  data |>
    mutate(across(where(is.numeric), ~ round(.x, digits)))
}

format_correlation_label <- function(correlation) {
  value <- if (is.na(correlation)) {
    "NA"
  } else {
    formatC(correlation, format = "f", digits = 2)
  }

  paste0("Corr. mean AI score = ", value)
}

build_industry_validation <- function(data, group_cols, external_col) {
  data |>
    filter(
      if_all(
        all_of(c(group_cols, external_col)),
        ~ !is.na(.x) & (if (is.character(.x)) .x != "" else TRUE)
      )
    ) |>
    group_by(across(all_of(group_cols))) |>
    summarise(
      n = n(),
      mean_ai_score = safe_mean(ai_score),
      mean_ai_adopt = safe_mean(ai_adopted),
      external_value = safe_mean(.data[[external_col]]),
      .groups = "drop"
    ) |>
    rename(!!external_col := external_value) |>
    arrange(desc(mean_ai_score)) |>
    round_numeric_cols()
}

build_validation_overview <- function(data, external_col, sample_label, measure_label) {
  tibble::tibble(
    sample = sample_label,
    validation_window = paste0(VALIDATION_START_YEAR, "-", VALIDATION_END_YEAR),
    external_measure = measure_label,
    corr_mean_ai_score = safe_cor(
      data$mean_ai_score,
      data[[external_col]]
    ),
    corr_mean_ai_adopt = safe_cor(
      data$mean_ai_adopt,
      data[[external_col]]
    ),
    n_industries = nrow(data)
  ) |>
    round_numeric_cols()
}

add_sector_labels <- function(data) {
  data |>
    mutate(
      label = if_else(
        !is.na(naics2_title) & naics2_title != "",
        stringr::str_trunc(naics2_title, 26),
        naics2
      )
    )
}


# ---- Load matched panel -------------------------------------------------------
if (!file.exists(MATCHED_PANEL_RDS)) {
  stop(
    "Matched panel not found: ", MATCHED_PANEL_RDS,
    ". Build the panel data first."
  )
}

panel_ai <- readRDS(MATCHED_PANEL_RDS)


# ---- Validation sample -------------------------------------------------------
panel_validation <- panel_ai |>
  filter(
    !is.na(year),
    year >= VALIDATION_START_YEAR,
    year <= VALIDATION_END_YEAR,
    !is.na(ai_adopted)
  )

validation_sample_overview <- tibble::tibble(
  metric = c(
    "Validation sample",
    "Validation window",
    "Firm-years",
    "Unique firms",
    "NAICS2 sectors represented",
    "NAICS3 subsectors represented",
    "NAICS4 industries represented",
    "Mean AI score",
    "Share AI adopted"
  ),
  value = c(
    "Matched Compustat + AI panel only",
    paste0(VALIDATION_START_YEAR, "-", VALIDATION_END_YEAR),
    format(nrow(panel_validation), big.mark = ","),
    format(dplyr::n_distinct(panel_validation$cik), big.mark = ","),
    dplyr::n_distinct(panel_validation$naics2[!is.na(panel_validation$naics2) & panel_validation$naics2 != ""]),
    dplyr::n_distinct(panel_validation$naics3[!is.na(panel_validation$naics3) & panel_validation$naics3 != ""]),
    dplyr::n_distinct(panel_validation$naics4[!is.na(panel_validation$naics4) & panel_validation$naics4 != ""]),
    round(safe_mean(panel_validation$ai_score), 3),
    sprintf("%.1f%%", 100 * safe_mean(panel_validation$ai_adopted))
  )
)


# ---- AIIE validation at NAICS2 -----------------------------------------------
naics2_aiie_validation <- build_industry_validation(
  panel_validation,
  group_cols = c("naics2", "naics2_title"),
  external_col = "aiie"
)

aiie_validation_overview <- build_validation_overview(
  naics2_aiie_validation,
  external_col = "aiie",
  sample_label = "NAICS2 industries in matched Compustat + AI panel",
  measure_label = "AIIE"
)

aiie_correlation_label <- format_correlation_label(
  aiie_validation_overview$corr_mean_ai_score
)

naics2_aiie_labels <- add_sector_labels(naics2_aiie_validation)

p_aiie_validation_naics2 <- ggplot(
  naics2_aiie_labels,
  aes(x = aiie, y = mean_ai_score)
) +
  geom_point(size = VALIDATION_POINT_SIZE, alpha = 0.9, color = "#2C7FB8") +
  geom_smooth(
    method = "lm",
    formula = y ~ x,
    se = FALSE,
    color = "black",
    linewidth = VALIDATION_LINE_WIDTH
  ) +
  geom_text(
    aes(label = label),
    size = VALIDATION_LABEL_SIZE,
    vjust = -0.7,
    check_overlap = TRUE,
    color = "gray20"
  ) +
  annotate(
    "label",
    x = -Inf,
    y = Inf,
    label = aiie_correlation_label,
    hjust = -0.05,
    vjust = 1.1,
    size = VALIDATION_CORR_LABEL_SIZE,
    linewidth = 0.3,
    fill = "white",
    color = "gray20"
  ) +
  scale_x_continuous(
    breaks = scales::pretty_breaks(n = 6)
  ) +
  scale_y_continuous(
    breaks = c(1, 1.5, 2, 2.5, 3),
    expand = expansion(mult = c(0.02, 0.12))
  ) +
  labs(
    title = "Industries with higher AIIE exposure also have higher AI scores",
    subtitle = "Each point is a NAICS2 industry, averaged over 2023-2025",
    x = "Mean industry AI exposure (AIIE)",
    y = "Mean filing-based AI score (1-3)"
  ) +
  theme_minimal(base_size = VALIDATION_PLOT_BASE_SIZE) +
  theme(
    panel.grid.minor = element_blank(),
    legend.position = "none",
    plot.title = element_text(size = VALIDATION_PANEL_TITLE_SIZE, face = "bold"),
    plot.subtitle = element_text(size = VALIDATION_PANEL_SUBTITLE_SIZE),
    axis.title = element_text(size = VALIDATION_AXIS_TITLE_SIZE),
    axis.text = element_text(size = VALIDATION_AXIS_TEXT_SIZE)
  )


# ---- BTOS validation at NAICS2 -----------------------------------------------
naics2_btos_validation <- build_industry_validation(
  panel_validation,
  group_cols = c("naics2", "naics2_title"),
  external_col = "btos_q7_ai_share_validation"
)

btos_validation_overview <- build_validation_overview(
  naics2_btos_validation,
  external_col = "btos_q7_ai_share_validation",
  sample_label = "NAICS2 industries in matched Compustat + AI panel",
  measure_label = "BTOS Q7 mean yes-share (2023-2025)"
)

btos_correlation_label <- format_correlation_label(
  btos_validation_overview$corr_mean_ai_score
)

naics2_btos_labels <- add_sector_labels(naics2_btos_validation)

p_btos_validation_naics2 <- ggplot(
  naics2_btos_labels,
  aes(x = btos_q7_ai_share_validation, y = mean_ai_score)
) +
  geom_point(size = VALIDATION_POINT_SIZE, alpha = 0.9, color = "#2C7FB8") +
  geom_smooth(
    method = "lm",
    formula = y ~ x,
    se = FALSE,
    color = "black",
    linewidth = VALIDATION_LINE_WIDTH
  ) +
  geom_text(
    aes(label = label),
    size = VALIDATION_LABEL_SIZE,
    vjust = -0.7,
    check_overlap = TRUE,
    color = "gray20"
  ) +
  annotate(
    "label",
    x = -Inf,
    y = Inf,
    label = btos_correlation_label,
    hjust = -0.05,
    vjust = 1.1,
    size = VALIDATION_CORR_LABEL_SIZE,
    linewidth = 0.3,
    fill = "white",
    color = "gray20"
  ) +
  scale_x_continuous(
    labels = scales::percent_format(accuracy = 1),
    breaks = scales::pretty_breaks(n = 6)
  ) +
  scale_y_continuous(
    breaks = c(1, 1.5, 2, 2.5, 3),
    expand = expansion(mult = c(0.02, 0.12))
  ) +
  labs(
    title = "Industries with higher BTOS AI adoption also have higher AI scores",
    subtitle = "Each point is a NAICS2 industry, averaged over 2023-2025",
    x = "BTOS Question 7 AI adoption share",
  ) +
  theme_minimal(base_size = VALIDATION_PLOT_BASE_SIZE) +
  theme(
    panel.grid.minor = element_blank(),
    legend.position = "none",
    plot.title = element_text(size = VALIDATION_PANEL_TITLE_SIZE, face = "bold"),
    plot.subtitle = element_text(size = VALIDATION_PANEL_SUBTITLE_SIZE),
    axis.title = element_text(size = VALIDATION_AXIS_TITLE_SIZE),
    axis.text = element_text(size = VALIDATION_AXIS_TEXT_SIZE)
  )

p_validation_naics2_side_by_side <- (
  p_btos_validation_naics2 +
    labs(
      title = "BTOS",
      subtitle = NULL,
      y = "Mean filing-based AI score (1-3)"
    )
) + (
  p_aiie_validation_naics2 +
    labs(
      title = "AIIE",
      subtitle = NULL,
      y = NULL
    )
) +
  plot_layout(ncol = 2) &
  theme(
    plot.title = element_text(size = 15, face = "plain"),
    axis.title = element_text(size = VALIDATION_AXIS_TITLE_SIZE),
    axis.text = element_text(size = VALIDATION_AXIS_TEXT_SIZE)
  )



# ---- Final analysis panel ----------------------------------------------------
panel_analysis <- build_final_analysis_panel(panel_ai)

analysis_sample_overview <- tibble::tibble(
  metric = c(
    "Final analysis sample",
    "Firm-years",
    "Unique firms",
    "Years covered",
    "Share of matched panel retained",
    "Excluded NAICS2 sectors",
    "Included exchanges"
  ),
  value = c(
    "Main non-financial, non-utility sectors on major exchanges",
    format(nrow(panel_analysis), big.mark = ","),
    format(dplyr::n_distinct(panel_analysis$cik), big.mark = ","),
    paste0(min(panel_analysis$year, na.rm = TRUE), "-", max(panel_analysis$year, na.rm = TRUE)),
    sprintf("%.1f%%", 100 * nrow(panel_analysis) / nrow(panel_ai)),
    paste(FINAL_ANALYSIS_EXCLUDED_NAICS2, collapse = ", "),
    paste(FINAL_ANALYSIS_INCLUDED_EXCHG, collapse = ", ")
  )
)


# ---- Save figures -------------------------------------------------------------
if (SAVE_VALIDATION_FIGURES) {
  dir.create(VALIDATION_FIGURES_DIR, recursive = TRUE, showWarnings = FALSE)

  ggsave(
    file.path(VALIDATION_FIGURES_DIR, "validation_ai_score_vs_aiie_naics2_2023_2025.png"),
    p_aiie_validation_naics2,
    width = 8,
    height = 6,
    dpi = 300
  )

  ggsave(
    file.path(VALIDATION_FIGURES_DIR, "validation_ai_score_vs_btos_q7_naics2_2023_2025.png"),
    p_btos_validation_naics2,
    width = 9,
    height = 6,
    dpi = 300
  )

  ggsave(
    file.path(VALIDATION_FIGURES_DIR, "validation.png"),
    p_validation_naics2_side_by_side,
    width = VALIDATION_SIDE_BY_SIDE_WIDTH,
    height = VALIDATION_SIDE_BY_SIDE_HEIGHT,
    dpi = 300
  )
}


# ---- Save bundle --------------------------------------------------------------
validation_bundle <- list(
  validation_sample_overview = validation_sample_overview,
  analysis_sample_overview = analysis_sample_overview,
  naics2_aiie_validation = naics2_aiie_validation,
  aiie_validation_overview = aiie_validation_overview,
  naics2_btos_validation = naics2_btos_validation,
  btos_validation_overview = btos_validation_overview,
  p_aiie_validation_naics2 = p_aiie_validation_naics2,
  p_btos_validation_naics2 = p_btos_validation_naics2,
  p_validation_naics2_side_by_side = p_validation_naics2_side_by_side
)

if (SAVE_VALIDATION_BUNDLE) {
  dir.create(VALIDATION_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(validation_bundle, VALIDATION_BUNDLE_RDS)
}


# ---- Console output -----------------------------------------------------------
cat("\nValidated AI adoption measures.\n")
cat("Validation sample rows:", format(nrow(panel_validation), big.mark = ","), "\n")
cat("Final analysis sample rows:", format(nrow(panel_analysis), big.mark = ","), "\n")
cat("AIIE industries:", nrow(naics2_aiie_validation), "\n")
cat("BTOS industries:", nrow(naics2_btos_validation), "\n")

if (SAVE_VALIDATION_BUNDLE) {
  cat("Saved validation bundle to:", VALIDATION_BUNDLE_RDS, "\n")
}
