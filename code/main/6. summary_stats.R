#!/usr/bin/env Rscript

# -------------------------------------------------------------------------------
# This script generate summary stats for main variables
# -------------------------------------------------------------------------------

# Build/source paneldata
BUILD_PANEL_DATA <- FALSE
REBUILD_ANNUAL_PANEL <- FALSE
REFRESH_FROM_WRDS <- FALSE
source("code/main/4. build_or_load_panel_data.R")
source("code/main/helper.R")

if (!exists("SUMMARY_STATS_OUTPUT_DIR", inherits = FALSE)) {
  SUMMARY_STATS_OUTPUT_DIR <- file.path(OUTPUT_DIR, "summary_stats")
}
if (!exists("SUMMARY_STATS_BUNDLE_RDS", inherits = FALSE)) {
  SUMMARY_STATS_BUNDLE_RDS <- file.path(SUMMARY_STATS_OUTPUT_DIR, "summary_stats_bundle.rds")
}
if (!exists("SAVE_SUMMARY_BUNDLE", inherits = FALSE)) {
  SAVE_SUMMARY_BUNDLE <- TRUE
}


# ---- Analysis packages --------------------------------------------------------
library(dplyr)
library(tidyr)
library(ggplot2)
library(scales)
library(patchwork)

# ---- Small helpers ------------------------------------------------------------
round_df <- function(data, digits = 3) {
  data |>
    mutate(across(where(is.numeric), ~round(.x, digits)))
}


safe_cor <- function(x, y, min_n = 5) {
  keep <- !is.na(x) & !is.na(y)
  if (sum(keep) < min_n) return(NA_real_)
  if (sd(x[keep]) == 0 || sd(y[keep]) == 0) return(NA_real_)
  cor(x[keep], y[keep])
}


firm_char_summary_table <- function(data, vars, labels) {
  data |>
    select(ai_adopted, all_of(vars)) |>
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) |>
    group_by(ai_adopted, characteristic) |>
    summarise(
      n = sum(!is.na(value)),
      mean = safe_mean(value),
      sd = safe_sd(value),
      median = safe_quantile(value, 0.50),
      p25 = safe_quantile(value, 0.25),
      p75 = safe_quantile(value, 0.75),
      .groups = "drop"
    ) |>
    mutate(characteristic = recode(characteristic, !!!labels)) |>
    round_df()
}


firm_char_density_plot <- function(data, vars, labels) {
  plot_data <- data |>
    mutate(ai_adopted_f = factor(ai_adopted, levels = c(0L, 1L), labels = c("0", "1"))) |>
    select(ai_adopted_f, all_of(vars)) |>
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) |>
    filter(!is.na(value)) |>
    mutate(characteristic = recode(characteristic, !!!labels))

  ggplot(plot_data, aes(x = value, fill = ai_adopted_f, colour = ai_adopted_f)) +
    geom_density(alpha = 0.18, linewidth = 0.8) +
    facet_wrap(~ characteristic, scales = "free", ncol = 2) +
    labs(
      title = "Distribution of Firm Characteristics by AI Adoption",
      x = NULL,
      y = "Density",
      fill = "AI adoption",
      colour = "AI adoption"
    ) +
    theme_minimal(base_size = 12)
}


# ---- 1. Sample overview -------------------------------------------------------
sample_overview <- tibble(
  Metric = c(
    "Firm-years",
#    "Unique firms (gvkey)",
    "Unique filers (cik)",
    "Years covered",
    "SIC4 industries",
    "NAICS4 industries",
    "Share of AI adopting cik-year:"
  ),
  Value = c(
    scales::comma(nrow(panel_ai)),
#    scales::comma(n_distinct(panel_ai$gvkey)),
    scales::comma(n_distinct(panel_ai$cik)),
    paste0(min(panel_ai$year, na.rm = TRUE), "-", max(panel_ai$year, na.rm = TRUE)),
    scales::comma(n_distinct(panel_ai$sic)),
    scales::comma(n_distinct(panel_ai$naics4)),
    scales::percent(mean(panel_ai$ai_adopted, na.rm = TRUE), accuracy = 0.1)
  )
)

panel_by_year <- panel_ai |>
  group_by(year) |>
  summarise(n = n(), .groups = "drop") |>
  round_df()

p_panel_by_year <- ggplot(panel_by_year, aes(x = year, y = n)) +
  geom_col(fill = "#4C78A8", alpha = 0.9) +
  scale_y_continuous(labels = comma) +
  labs(
    title = "Matched Compusat-EDGAR Firm-Year Observations",
    x = "Year",
    y = "Number of Firm"
  ) +
  theme_minimal(base_size = 12)


# ---- 2. AI adoption over time -------------------------------------------------
ai_trend <- panel_ai |>
  filter(!is.na(ai_adopted), !is.na(year)) |>
  group_by(year) |>
  summarise(
    n = n(),
    share_ai_adopted = mean(ai_adopted == 1L, na.rm = TRUE),
    .groups = "drop"
  ) |>
  round_df()


p_ai_trend_levels <- ggplot(ai_trend, aes(x = year, y = share_ai_adopted)) +
  geom_line(color = "#1b9e77", linewidth = 1) +
  geom_point(color = "#1b9e77", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "Share of AI-Adopting Firm-Years Over Time",
    x = "Year",
    y = "Share of firm-years"
  ) +
  theme_minimal(base_size = 12)

p_ai_trend <- p_ai_trend_levels

p_ai_adoption_status <- panel_ai |>
  filter(!is.na(ai_adopted)) |>
  mutate(ai_adopted_f = factor(ai_adopted, levels = c(0L, 1L), labels = c("No adoption", "Adopted"))) |>
  ggplot(aes(x = ai_adopted_f, fill = ai_adopted_f)) +
  geom_bar(alpha = 0.9) +
  scale_fill_manual(values = c("No adoption" = "#BDBDBD", "Adopted" = "#1b9e77")) +
  scale_y_continuous(labels = comma) +
  labs(
    title = "Distribution of AI Adoption Status",
    x = NULL,
    y = "Number of firm-year observations",
    fill = NULL
  ) +
  theme_minimal(base_size = 12)

# ---- 3. AI adoption status ----------------------------------------------------

ai_level_summary <- panel_ai |>
  filter(!is.na(ai_adoption_level)) |>
  group_by(ai_adoption_level) |>
  summarise(
    n = n(),
    n_firms = n_distinct(gvkey),
    .groups = "drop"
  ) |>
  mutate(share = n / sum(n)) |>
  round_df()

ai_level_by_year <- panel_ai |>
  filter(!is.na(ai_adoption_level)) |>
  count(year, ai_adoption_level, name = "n") |>
  group_by(year) |>
  mutate(share = n / sum(n)) |>
  ungroup() |>
  round_df()

p_ai_level_share <- ggplot(ai_level_by_year
                           |> filter(ai_adoption_level != "No adoption"),
                           aes(x = year, y = share, color = ai_adoption_level)) +
  geom_line(color = "#1b9e77", linewidth = 1) +
  geom_point(color = "#1b9e77", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "Share of Adopting Firm-Years Over Time",
    x = "Year",
    y = "Share of firms",
  ) +
  theme_minimal(base_size = 12)

# ---- 3. Firm characteristics by AI adoption VS no adoption---------------------
firm_chars <- c(
  "firm_size_at",
  "avg_wage_log",
  "firm_size_emp",
  "labor_productivity_log"
)

firm_char_labels <- c(
  firm_size_at = "Firm size (log assets)",
  avg_wage_log = "Average wage (log)",
  firm_size_emp = "Employment (log)",
  labor_productivity_log = "Labour productivity (log)"
)

overall_var_labels <- c(
  ai_adopted = "AI adopted (binary)",
  aiie = "AI exposure (AIOE)",
  firm_size_at = "Firm size (log assets)",
  firm_size_emp = "Employment (log)",
  avg_wage_log = "Average wage (log)",
  labor_productivity_log = "Labour productivity (log)",
  rd_intensity_y = "R&D intensity",
  capx_intensity_y = "CAPX intensity",
  roa = "ROA"
)

overall_summary <- panel_ai |>
  select(all_of(names(overall_var_labels))) |>
  pivot_longer(
    cols = everything(),
    names_to = "variable",
    values_to = "value"
  ) |>
  group_by(variable) |>
  summarise(
    n = sum(!is.na(value)),
    mean = safe_mean(value),
    median = safe_quantile(value, 0.50),
    p25 = safe_quantile(value, 0.25),
    p75 = safe_quantile(value, 0.75),
    .groups = "drop"
  ) |>
  mutate(variable = recode(variable, !!!overall_var_labels)) |>
  rename(Variable = variable, N = n, Mean = mean, Median = median, P25 = p25, P75 = p75) |>
  round_df()

if (nrow(panel_ai) == 0) {
  ai_adoption_summary <- tibble(
    n_obs = 0,
    n_ai_adopted = NA_real_,
    share_ai_adopted = NA_real_,
    n_never_adopted = NA_real_,
    share_never_adopted = NA_real_
  )
} else {
  ai_adoption_summary <- panel_ai |>
    summarise(
      n_obs = n(),
      n_ai_adopted = sum(ai_adopted == 1L, na.rm = TRUE),
      share_ai_adopted = mean(ai_adopted == 1L, na.rm = TRUE),
      n_never_adopted = sum(ai_adopted == 0L, na.rm = TRUE),
      share_never_adopted = mean(ai_adopted == 0L, na.rm = TRUE)
    ) |>
    round_df()
}

analysis_panel <- panel_ai |>
  filter(!is.na(ai_adopted))

ai_adoption_counts <- analysis_panel |>
  group_by(ai_adopted) |>
  summarise(
    n_firm_years = n(),
    n_firms = n_distinct(gvkey),
    .groups = "drop"
  ) |>
  mutate(ai_status = if_else(ai_adopted == 1L, "Adopted", "No adoption")) |>
  round_df()

firm_char_summary <- firm_char_summary_table(analysis_panel, firm_chars, firm_char_labels)

firm_char_summary_wide <- firm_char_summary |>
  pivot_wider(
    names_from = ai_adopted,
    values_from = c(n, mean, sd, median, p25, p75),
    names_glue = "ai_{ai_adopted}_{.value}"
  )

p_firm_char_dist <- firm_char_density_plot(analysis_panel, firm_chars, firm_char_labels)

# ---- 4. AI adoption and AI exposure correlations -----------------------------

panel_corr <- panel_ai |>
  filter(!is.na(aiie))

overall_corr <- panel_corr |> 
  summarise(
    n = n(),
    corr_ai_adopt_exp = safe_cor(ai_adopted, aiie),
    mean_ai_adopt = safe_mean(ai_adopted),
    mean_exp = safe_mean(aiie),
    .groups = "drop"
  ) |>
  round_df() |> 
  mutate(  sample = "Firm-year observations")

corr_by_year <- panel_corr |>
  group_by(year) |>
  summarise(
    n = n(),
    corr_ai_adopt_exp = safe_cor(ai_adopted, aiie),
    mean_ai_adopt = safe_mean(ai_adopted),
    mean_exp = safe_mean(aiie),
    .groups = "drop"
  ) |>
  round_df()

naics4_summary <- panel_corr |>
  filter(!is.na(naics4), naics4 != "") |>
  group_by(naics4) |>
  summarise(
    n = n(),
    mean_ai_adopt = safe_mean(ai_adopted),
    aiie = dplyr::first(aiie),
    .groups = "drop"
  ) |>
  arrange(desc(mean_ai_adopt)) |>
  round_df()

naics4_corr_overview <- tibble(
  `Industry level` = "NAICS4",
  Metric = "AI exposure vs AI adoption across all firms",
  Correlation = safe_cor(naics4_summary$mean_ai_adopt, naics4_summary$aiie),
  `Number of industry groups` = nrow(naics4_summary)
) |>
  round_df()

p_corr_by_naics4 <- ggplot(
  naics4_summary,
  aes(x = aiie, y = mean_ai_adopt)
) +
  geom_point(aes(size = n), alpha = 0.7, color = "#2C7FB8") +
  geom_smooth(method = "lm", se = TRUE, color = "black", linewidth = 0.8) +
  labs(
    title = "AI Adoption and AI Exposure by NAICS4",
    x = "AI exposure (aiie)",
    y = "Mean AI adoption",
    size = "N"
  ) +
  theme_minimal(base_size = 12)

sic_summary <- panel_corr |>
  filter(!is.na(sic)) |>
  group_by(sic) |>
  summarise(
    n = n(),
    mean_ai_adopt = safe_mean(ai_adopted),
    mean_aiie = safe_mean(aiie),
    .groups = "drop"
  ) |>
  arrange(desc(mean_ai_adopt)) |>
  round_df()

sic_corr_overview <- tibble(
  `Industry level` = "SIC4",
  Metric = "Mean AI exposure vs AI adoption across all firms",
  Correlation = safe_cor(sic_summary$mean_ai_adopt, sic_summary$mean_aiie),
  `Number of industry groups` = nrow(sic_summary)
) |>
  round_df()

p_corr_by_sic <- ggplot(
  sic_summary |>
    filter(!is.na(mean_aiie), !is.na(mean_ai_adopt)),
  aes(x = mean_aiie, y = mean_ai_adopt)
) +
  geom_point(aes(size = n), alpha = 0.7, color = "#59A14F") +
  geom_smooth(method = "lm", se = TRUE, color = "black", linewidth = 0.8) +
  labs(
    title = "AI Adoption and AI Exposure by SIC4",
    x = "Mean AI exposure (aiie)",
    y = "Mean AI adoption",
    size = "N"
  ) +
  theme_minimal(base_size = 12)

# ---- Save report bundle -------------------------------------------------------
summary_stats_bundle <- list(
  sample_overview = sample_overview,
  panel_by_year = panel_by_year,
  overall_summary = overall_summary,
  ai_adoption_summary = ai_adoption_summary,
  ai_trend = ai_trend,
  ai_level_summary = ai_level_summary,
  ai_level_by_year = ai_level_by_year,
  ai_adoption_counts = ai_adoption_counts,
  firm_char_summary = firm_char_summary,
  firm_char_summary_wide = firm_char_summary_wide,
  p_panel_by_year = p_panel_by_year,
  p_ai_trend_levels = p_ai_trend_levels,
  p_ai_trend = p_ai_trend,
  p_ai_adoption_status = p_ai_adoption_status,
  p_ai_level_share = p_ai_level_share,
  p_firm_char_dist = p_firm_char_dist,
  overall_corr = overall_corr,
  corr_by_year = corr_by_year,
  naics4_corr_overview = naics4_corr_overview,
  p_corr_by_naics4 = p_corr_by_naics4,
  sic_corr_overview = sic_corr_overview,
  p_corr_by_sic = p_corr_by_sic
)

if (SAVE_SUMMARY_BUNDLE) {
  dir.create(SUMMARY_STATS_OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)
  saveRDS(summary_stats_bundle, SUMMARY_STATS_BUNDLE_RDS)
  cat("Saved summary stats bundle to:", SUMMARY_STATS_BUNDLE_RDS, "\n")
}

