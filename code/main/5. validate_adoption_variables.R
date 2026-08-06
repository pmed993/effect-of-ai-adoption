#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Validate filing-based AI adoption variables
# ------------------------------------------------------------------------------
# This script uses the matched Compustat + AI panel to:
# 1. validate 2022 filing-based AI adoption against the 2023 Annual Business
#    Survey (ABS) at the NAICS2 level;
# 2. validate mean AI scores against BTOS Question 7 at the NAICS2 level; and
# 3. describe the filtered final analysis sample used downstream.
# ------------------------------------------------------------------------------

source("code/config/global_settings.R")

library(dplyr)
library(ggplot2)


# ---- Settings ----------------------------------------------------------------
ABS_REFERENCE_YEAR <- 2022L
ABS_QDESC <- "B70"
ABS_QDESC_LABEL <- "TECHADOPT"
ABS_BUSCHAR <- "T01A04"

BTOS_VALIDATION_START_YEAR <- 2023L
BTOS_VALIDATION_END_YEAR <- 2025L

MATCHED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_matched_panel.rds")
ABS_MCB_DAT <- file.path(INPUT_DIR, "AB2200MCB01.dat")

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
VALIDATION_LABEL_SIZE <- 2.7
VALIDATION_CORR_LABEL_SIZE <- 4
VALIDATION_AXIS_TITLE_SIZE <- 13
VALIDATION_AXIS_TEXT_SIZE <- 11
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
      external_value = safe_mean(.data[[external_col]]),
      .groups = "drop"
    ) |>
    rename(!!external_col := external_value) |>
    arrange(desc(mean_ai_score))
}

build_validation_overview <- function(
  data,
  external_col,
  sample_label,
  measure_label,
  validation_window
) {
  tibble::tibble(
    sample = sample_label,
    validation_window = validation_window,
    external_measure = measure_label,
    corr_mean_ai_score = safe_cor(
      data$mean_ai_score,
      data[[external_col]]
    ),
    n_industries = nrow(data)
  ) |>
    round_numeric_cols()
}

read_abs_naics2_ai_use <- function(path) {
  if (!file.exists(path)) {
    stop("2023 ABS module file not found: ", path)
  }

  # AB2200MCB01.dat is several GB. Read only B70/T01A04 rows instead of
  # loading the complete Census table into memory.
  marker <- paste0("|", ABS_QDESC, "|", ABS_QDESC_LABEL, "|", ABS_BUSCHAR, "|")
  header_marker <- "#GEO_ID|GEO_LABEL|"
  quoted_path <- shQuote(path)
  search_command <- if (nzchar(Sys.which("rg"))) {
    paste(
      "rg -F --no-heading --color never -e",
      shQuote(header_marker),
      "-e",
      shQuote(marker),
      quoted_path
    )
  } else {
    paste(
      "grep -F -e",
      shQuote(header_marker),
      "-e",
      shQuote(marker),
      quoted_path
    )
  }

  abs_raw <- data.table::fread(
    cmd = search_command,
    sep = "|",
    colClasses = "character",
    showProgress = FALSE
  )

  required_cols <- c(
    "GEOTYPE", "ST", "NAICS2022", "NAICS2022_LABEL",
    "SEX", "ETH_GROUP", "RACE_GROUP", "VET_GROUP",
    "QDESC", "QDESC_LABEL", "BUSCHAR", "YEAR",
    "FIRMPDEMP", "FIRMPDEMP_F", "FIRMPDEMP_PCT",
    "FIRMPDEMP_PCT_F", "FIRMPDEMP_S", "FIRMPDEMP_PCT_S"
  )
  missing_cols <- setdiff(required_cols, names(abs_raw))
  if (length(missing_cols) > 0L) {
    stop(
      "Required columns missing from the ABS module file: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  abs_naics2 <- abs_raw |>
    filter(
      GEOTYPE == "01",
      ST == "00",
      nchar(NAICS2022) == 2L |
        NAICS2022 %in% c("31-33", "44-45", "48-49"),
      SEX == "001",
      ETH_GROUP == "001",
      RACE_GROUP == "00",
      VET_GROUP == "001",
      QDESC == ABS_QDESC,
      QDESC_LABEL == ABS_QDESC_LABEL,
      BUSCHAR == ABS_BUSCHAR,
      YEAR == as.character(ABS_REFERENCE_YEAR),
      is.na(FIRMPDEMP_PCT_F) | FIRMPDEMP_PCT_F == ""
    ) |>
    transmute(
      naics2 = NAICS2022,
      abs_naics2_title = NAICS2022_LABEL,
      abs_ai_adopting_firms = suppressWarnings(as.numeric(FIRMPDEMP)),
      abs_ai_adopting_firms_se = suppressWarnings(as.numeric(FIRMPDEMP_S)),
      abs_ai_adoption_share = suppressWarnings(as.numeric(FIRMPDEMP_PCT)) / 100,
      abs_ai_adoption_share_se = suppressWarnings(as.numeric(FIRMPDEMP_PCT_S)) / 100,
      abs_firm_estimate_flag = FIRMPDEMP_F,
      abs_share_estimate_flag = FIRMPDEMP_PCT_F
    ) |>
    filter(!is.na(abs_ai_adoption_share)) |>
    arrange(naics2)

  duplicate_naics2 <- abs_naics2 |>
    count(naics2) |>
    filter(n > 1L)
  if (nrow(duplicate_naics2) > 0L) {
    stop("The filtered ABS benchmark contains duplicated NAICS2 rows.")
  }

  abs_naics2
}


# ---- Load matched panel -------------------------------------------------------
if (!file.exists(MATCHED_PANEL_RDS)) {
  stop(
    "Matched panel not found: ", MATCHED_PANEL_RDS,
    ". Build the panel data first."
  )
}

panel_ai <- readRDS(MATCHED_PANEL_RDS) |>
  mutate(year = as.integer(year)) |>
  filter(
    !is.na(year),
    year >= ANALYSIS_START_YEAR,
    year <= ANALYSIS_END_YEAR
  )


# ---- Validation samples ------------------------------------------------------
panel_btos_validation <- panel_ai |>
  filter(
    !is.na(year),
    year >= BTOS_VALIDATION_START_YEAR,
    year <= BTOS_VALIDATION_END_YEAR,
    !is.na(ai_score)
  )

panel_abs_validation <- panel_ai |>
  filter(
    !is.na(year),
    year == ABS_REFERENCE_YEAR,
    !is.na(ai_score)
  )

validation_sample_overview <- tibble::tibble(
  metric = c(
    "BTOS validation sample",
    "BTOS validation window",
    "BTOS firm-years",
    "BTOS unique firms",
    "ABS validation sample",
    "ABS validation year",
    "ABS firm-years",
    "ABS unique firms",
    "ABS NAICS2 sectors represented",
    "ABS mean AI score"
  ),
  value = c(
    "Matched Compustat + AI panel only",
    paste0(BTOS_VALIDATION_START_YEAR, "-", BTOS_VALIDATION_END_YEAR),
    format(nrow(panel_btos_validation), big.mark = ","),
    format(dplyr::n_distinct(panel_btos_validation$cik), big.mark = ","),
    "Matched Compustat + AI panel only",
    ABS_REFERENCE_YEAR,
    format(nrow(panel_abs_validation), big.mark = ","),
    format(dplyr::n_distinct(panel_abs_validation$cik), big.mark = ","),
    dplyr::n_distinct(panel_abs_validation$naics2[!is.na(panel_abs_validation$naics2) & panel_abs_validation$naics2 != ""]),
    round(safe_mean(panel_abs_validation$ai_score), 3)
  )
)


# ---- Census ABS validation at NAICS2 -----------------------------------------
abs_ai_use_naics2 <- read_abs_naics2_ai_use(ABS_MCB_DAT)

panel_abs_naics2 <- panel_abs_validation |>
  filter(!is.na(naics2), naics2 != "") |>
  group_by(naics2, naics2_title) |>
  summarise(
    n = n(),
    n_firms = n_distinct(cik),
    mean_ai_score = safe_mean(ai_score),
    .groups = "drop"
  )

naics2_abs_validation <- panel_abs_naics2 |>
  inner_join(abs_ai_use_naics2, by = "naics2") |>
  mutate(
    naics2_title = coalesce(naics2_title, abs_naics2_title)
  ) |>
  arrange(desc(mean_ai_score))

abs_validation_overview <- build_validation_overview(
  naics2_abs_validation,
  external_col = "abs_ai_adoption_share",
  sample_label = "NAICS2 sectors in the 2022 matched Compustat + AI panel",
  measure_label = paste0(
    "2023 ABS: ", ABS_QDESC, "/", ABS_QDESC_LABEL, ", ", ABS_BUSCHAR,
    " (AI used in processes or methods)"
  ),
  validation_window = as.character(ABS_REFERENCE_YEAR)
)


# ---- BTOS validation at NAICS2 -----------------------------------------------
naics2_btos_validation <- build_industry_validation(
  panel_btos_validation,
  group_cols = c("naics2", "naics2_title"),
  external_col = "btos_q7_ai_share_validation"
)

btos_validation_overview <- build_validation_overview(
  naics2_btos_validation,
  external_col = "btos_q7_ai_share_validation",
  sample_label = "NAICS2 industries in matched Compustat + AI panel",
  measure_label = "BTOS Q7 mean yes-share (2023-2025)",
  validation_window = paste0(
    BTOS_VALIDATION_START_YEAR,
    "-",
    BTOS_VALIDATION_END_YEAR
  )
)


# ---- Side-by-side public benchmark figure -----------------------------------
validation_plot_data <- bind_rows(
  naics2_btos_validation |>
    transmute(
      benchmark = "BTOS (2023-2025)",
      naics2,
      naics2_title,
      external_ai_adoption_share = btos_q7_ai_share_validation,
      mean_ai_score
    ),
  naics2_abs_validation |>
    transmute(
      benchmark = "Census ABS (2022)",
      naics2,
      naics2_title,
      external_ai_adoption_share = abs_ai_adoption_share,
      mean_ai_score
    )
) |>
  mutate(
    benchmark = factor(
      benchmark,
      levels = c("BTOS (2023-2025)", "Census ABS (2022)")
    )
  )

validation_plot_labels <- validation_plot_data |>
  filter(naics2 %in% c("22", "44-45", "51", "54", "56", "61", "62")) |>
  mutate(
    sector_label = case_when(
      naics2 == "22" ~ "Utilities",
      naics2 == "44-45" ~ "Retail trade",
      naics2 == "51" ~ "Information",
      naics2 == "54" ~ "Professional and technical services",
      naics2 == "56" ~ "Administrative services",
      naics2 == "61" ~ "Education",
      naics2 == "62" ~ "Health care"
    ),
    label_hjust = case_when(
      naics2 %in% c("22", "51", "54", "62") ~ 1.05,
      TRUE ~ -0.05
    ),
    label_vjust = case_when(
      naics2 %in% c("22", "56") ~ 1.3,
      TRUE ~ -0.65
    )
  )

validation_correlation_labels <- bind_rows(
  tibble::tibble(
    benchmark = "BTOS (2023-2025)",
    correlation = btos_validation_overview$corr_mean_ai_score
  ),
  tibble::tibble(
    benchmark = "Census ABS (2022)",
    correlation = abs_validation_overview$corr_mean_ai_score
  )
) |>
  mutate(
    benchmark = factor(
      benchmark,
      levels = c("BTOS (2023-2025)", "Census ABS (2022)")
    ),
    label = paste0(
      "Pearson r = ",
      formatC(correlation, format = "f", digits = 2)
    )
  )

validation_correlation_table <- bind_rows(
  tibble::tibble(
    benchmark = "BTOS Q7",
    reference_period = paste0(
      BTOS_VALIDATION_START_YEAR,
      "-",
      BTOS_VALIDATION_END_YEAR
    ),
    naics_level = "NAICS2",
    n_sectors = btos_validation_overview$n_industries,
    corr_mean_ai_score = btos_validation_overview$corr_mean_ai_score
  ),
  tibble::tibble(
    benchmark = "Census ABS",
    reference_period = as.character(ABS_REFERENCE_YEAR),
    naics_level = "NAICS2",
    n_sectors = abs_validation_overview$n_industries,
    corr_mean_ai_score = abs_validation_overview$corr_mean_ai_score
  )
)

p_validation_side_by_side <- ggplot(
  validation_plot_data,
  aes(x = external_ai_adoption_share, y = mean_ai_score)
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
    data = validation_plot_labels,
    aes(
      label = sector_label,
      hjust = label_hjust,
      vjust = label_vjust
    ),
    size = VALIDATION_LABEL_SIZE,
    color = "gray20"
  ) +
  geom_label(
    data = validation_correlation_labels,
    aes(x = -Inf, y = Inf, label = label),
    inherit.aes = FALSE,
    hjust = 0,
    vjust = 1.1,
    size = VALIDATION_CORR_LABEL_SIZE,
    linewidth = 0.3,
    fill = "white",
    color = "gray20"
  ) +
  facet_wrap(~ benchmark, ncol = 2, scales = "free_x") +
  scale_x_continuous(
    labels = scales::percent_format(accuracy = 1),
    breaks = scales::pretty_breaks(n = 5),
    expand = expansion(mult = c(0.04, 0.08))
  ) +
  scale_y_continuous(
    breaks = c(1, 1.5, 2, 2.5, 3),
    expand = expansion(mult = c(0.03, 0.12))
  ) +
  labs(
    x = "External AI adoption share",
    y = "Mean filing-based AI score (1-3)",
    caption = paste0(
      "Census ABS: ", ABS_QDESC, "/", ABS_QDESC_LABEL, ", ", ABS_BUSCHAR,
      "; 2023 collection, reference year 2022."
    )
  ) +
  theme_minimal(base_size = VALIDATION_PLOT_BASE_SIZE) +
  theme(
    panel.grid.minor = element_blank(),
    legend.position = "none",
    axis.title = element_text(size = VALIDATION_AXIS_TITLE_SIZE),
    axis.text = element_text(size = VALIDATION_AXIS_TEXT_SIZE),
    strip.text = element_text(size = 14, face = "bold"),
    panel.spacing = grid::unit(1.2, "lines"),
    plot.caption = element_text(hjust = 0, color = "gray35")
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
    file.path(VALIDATION_FIGURES_DIR, "validation_abs_btos_naics2.png"),
    p_validation_side_by_side,
    width = VALIDATION_SIDE_BY_SIDE_WIDTH,
    height = VALIDATION_SIDE_BY_SIDE_HEIGHT,
    dpi = 300
  )

  ggsave(
    file.path(VALIDATION_FIGURES_DIR, "validation.png"),
    p_validation_side_by_side,
    width = VALIDATION_SIDE_BY_SIDE_WIDTH,
    height = VALIDATION_SIDE_BY_SIDE_HEIGHT,
    dpi = 300
  )
}


# ---- Save bundle --------------------------------------------------------------
validation_bundle <- list(
  validation_sample_overview = validation_sample_overview,
  analysis_sample_overview = analysis_sample_overview,
  abs_ai_use_naics2 = abs_ai_use_naics2,
  naics2_abs_validation = naics2_abs_validation,
  abs_validation_overview = abs_validation_overview,
  naics2_btos_validation = naics2_btos_validation,
  btos_validation_overview = btos_validation_overview,
  validation_correlation_table = validation_correlation_table,
  validation_plot_data = validation_plot_data,
  p_validation_side_by_side = p_validation_side_by_side
)

if (SAVE_VALIDATION_BUNDLE) {
  dir.create(VALIDATION_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(validation_bundle, VALIDATION_BUNDLE_RDS)
}


# ---- Console output -----------------------------------------------------------
cat("\nValidated AI adoption measures.\n")
cat("ABS validation sample rows:", format(nrow(panel_abs_validation), big.mark = ","), "\n")
cat("BTOS validation sample rows:", format(nrow(panel_btos_validation), big.mark = ","), "\n")
cat("Final analysis sample rows:", format(nrow(panel_analysis), big.mark = ","), "\n")
cat("ABS NAICS2 sectors:", nrow(naics2_abs_validation), "\n")
cat("ABS correlation (mean AI score):", abs_validation_overview$corr_mean_ai_score, "\n")
cat("BTOS NAICS2 sectors:", nrow(naics2_btos_validation), "\n")
cat("BTOS correlation (mean AI score):", btos_validation_overview$corr_mean_ai_score, "\n")

if (SAVE_VALIDATION_BUNDLE) {
  cat("Saved validation bundle to:", VALIDATION_BUNDLE_RDS, "\n")
}
