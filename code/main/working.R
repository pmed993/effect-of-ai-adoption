#!/usr/bin/env Rscript

# -------------------------------------------------------------------------------
# Working on the analysis for the merged Compustat + AI panel
# -------------------------------------------------------------------------------


# ---- Build/Load panel with options --------------------------------------------
if (!exists("REBUILD_ANNUAL_PANEL", inherits = FALSE)) {
  REBUILD_ANNUAL_PANEL <- FALSE
}
if (!exists("REFRESH_FROM_WRDS", inherits = FALSE)) {
  REFRESH_FROM_WRDS <- FALSE
}
if (!exists("SAVE_OUTPUTS", inherits = FALSE)) {
  SAVE_OUTPUTS <- FALSE
}
if (!exists("SAVE_MERGED_OUTPUTS", inherits = FALSE)) {
  SAVE_MERGED_OUTPUTS <- FALSE
}

source("code/main/3. get_panel_data/2. build_compustat_ai_panel.R")
source("code/main/helper.R")


# ---- Analysis packages --------------------------------------------------------
library(dplyr)
library(tidyr)
library(ggplot2)
library(scales)
library(patchwork)


# ---- Small helpers ------------------------------------------------------------
round_df <- function(data, digits = 3) {
  data %>%
    mutate(across(where(is.numeric), ~round(.x, digits)))
}


safe_cor <- function(x, y, min_n = 5) {
  keep <- !is.na(x) & !is.na(y)
  if (sum(keep) < min_n) return(NA_real_)
  if (sd(x[keep]) == 0 || sd(y[keep]) == 0) return(NA_real_)
  cor(x[keep], y[keep])
}


score_corr_by_group <- function(data, group_var) {
  data %>%
    filter(
      !is.na(.data[[group_var]]),
      !is.na(llama_score),
      !is.na(aiie)
    ) %>%
    group_by(.data[[group_var]]) %>%
    summarise(
      n = n(),
      corr_llama_aiie = safe_cor(llama_score, aiie),
      mean_llama_score = mean(llama_score, na.rm = TRUE),
      mean_aiie = mean(aiie, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(desc(n)) %>%
    round_df()
}


firm_char_summary_table <- function(data, vars, labels) {
  data %>%
    select(ai_adoption, all_of(vars)) %>%
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) %>%
    group_by(ai_adoption, characteristic) %>%
    summarise(
      n = sum(!is.na(value)),
      mean = safe_mean(value),
      sd = safe_sd(value),
      median = safe_quantile(value, 0.50),
      p25 = safe_quantile(value, 0.25),
      p75 = safe_quantile(value, 0.75),
      .groups = "drop"
    ) %>%
    mutate(characteristic = recode(characteristic, !!!labels)) %>%
    round_df()
}


firm_char_density_plot <- function(data, vars, labels) {
  plot_data <- data %>%
    select(ai_adoption_f, all_of(vars)) %>%
    pivot_longer(
      cols = all_of(vars),
      names_to = "characteristic",
      values_to = "value"
    ) %>%
    filter(!is.na(value)) %>%
    mutate(characteristic = recode(characteristic, !!!labels))

  ggplot(plot_data, aes(x = value, fill = ai_adoption_f, colour = ai_adoption_f)) +
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


# ------------------------ Variable definitions ---------------------------------#
# As per https://wrds-www.wharton.upenn.edu/pages/get-data/compustat-capital-iq-standard-poors/compustat/north-america-daily/fundamentals-annual/
# Dataset ----> funda
# act: Current Assets - Total
# at: Assets - Total
# che: Cash and Short-Term Investments
# csho: Common Shares Outstanding
# dlc: Debt in current Liabilities - Total
# dltt: Long-Term Debt - Total
# dv: Cash Dividends (Cash Flow)
# intan:Intangible Assets - Total
# ni: Net Income (Loss)
# xrd: Research and Developmnent Expense
# xsga: Selling, General and Administrative Expense
# capx: Capital Expenditure
# oancf: Operating Activities - Net Cash Flow
# prstkc: Purchase of Common and Preferred Stock
# prcc_f: Price Close - Annual - Fiscal
# tstk: Treasury Stock - Total (All Capital)

# ---- 1. Correlation between AI adoption and AI exposure -----------------------
overall_corr <- panel %>%
  summarise(
    n = sum(!is.na(llama_score) & !is.na(aiie)),
    corr_llama_aiie = cor(llama_score, aiie, use = "complete.obs")
  ) %>%
  round_df()

corr_by_sic <- score_corr_by_group(panel, "sic")
corr_by_naics4 <- score_corr_by_group(panel, "naics4")

top_corr_by_sic <- corr_by_sic %>% slice_head(n = 20)
top_corr_by_naics4 <- corr_by_naics4 %>% slice_head(n = 20)


# ---- 2. AI adoption over time -------------------------------------------------
ai_trend <- panel_ai %>%
  filter(!is.na(llama_score), !is.na(year)) %>%
  group_by(year) %>%
  summarise(
    n = n(),
    mean_llama = mean(llama_score, na.rm = TRUE),
    median_llama = median(llama_score, na.rm = TRUE),
    p75_llama = safe_quantile(llama_score, 0.75),
    p90_llama = safe_quantile(llama_score, 0.90),
    share_positive = mean(llama_score > 0, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  round_df()

trend_levels <- ai_trend %>%
  select(year, mean_llama, p90_llama) %>%
  pivot_longer(
    cols = c(mean_llama, p90_llama),
    names_to = "series",
    values_to = "value"
  ) %>%
  mutate(
    series = recode(
      series,
      mean_llama = "Mean",
      p90_llama = "90th percentile"
    )
  )

p_ai_trend_levels <- ggplot(trend_levels, aes(x = year, y = value, color = series)) +
  geom_line(linewidth = 1) +
  geom_point(size = 2) +
  scale_color_manual(values = c("Mean" = "#1b9e77", "90th percentile" = "#d95f02")) +
  labs(
    title = "AI Adoption Score Over Time",
    x = "Year",
    y = "Score",
    color = NULL
  ) +
  theme_minimal(base_size = 12)

p_ai_trend_share <- ggplot(ai_trend, aes(x = year, y = share_positive)) +
  geom_line(color = "#7570b3", linewidth = 1) +
  geom_point(color = "#7570b3", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "Share of Firms with Positive AI Adoption Score",
    x = "Year",
    y = "Share > 0"
  ) +
  theme_minimal(base_size = 12)

p_ai_trend <- p_ai_trend_levels / p_ai_trend_share


# ---- 3. Firm characteristics by AI adoption ----------------------------------
ai_threshold <- 0

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

analysis_panel <- panel_ai %>%
  filter(!is.na(llama_score)) %>%
  mutate(
    ai_adoption = if_else(llama_score > ai_threshold, 1L, 0L),
    ai_adoption_f = factor(ai_adoption, levels = c(0, 1), labels = c("0", "1"))
  )

ai_adoption_counts <- analysis_panel %>%
  group_by(ai_adoption) %>%
  summarise(
    n_firm_years = n(),
    n_firms = n_distinct(gvkey),
    mean_llama_score = mean(llama_score, na.rm = TRUE),
    median_llama_score = median(llama_score, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  round_df()

firm_char_summary <- firm_char_summary_table(analysis_panel, firm_chars, firm_char_labels)

firm_char_summary_wide <- firm_char_summary %>%
  pivot_wider(
    names_from = ai_adoption,
    values_from = c(n, mean, sd, median, p25, p75),
    names_glue = "ai_{ai_adoption}_{.value}"
  )

p_firm_char_dist <- firm_char_density_plot(analysis_panel, firm_chars, firm_char_labels)
