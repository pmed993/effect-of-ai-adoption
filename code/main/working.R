#REBUILD_ANNUAL_PANEL <- TRUE
#REFRESH_FROM_WRDS <- TRUE
#SAVE_OUTPUTS <- TRUE
#SAVE_MERGED_OUTPUTS <- TRUE

source("code/main/build_compustat_ai_panel.R")

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

View(panel)

View(panel_ai)


# ------------------------------------------------------------
# Check correlation between AI adoption and AI exposure
# ------------------------------------------------------------

# Overall correlation
panel %>%
  summarise(
    n = sum(!is.na(llama_score) & !is.na(aiie)),
    corr_llama_aiie = cor(llama_score, aiie, use = "complete.obs")
  )

# By SIC
corr_by_sic <- panel %>%
  filter(!is.na(sic), !is.na(llama_score), !is.na(aiie)) %>%
  group_by(sic) %>%
  summarise(
    n = n(),
    corr_llama_aiie = ifelse(n() >= 5, cor(llama_score, aiie, use = "complete.obs"), NA_real_),
    mean_llama_score = mean(llama_score, na.rm = TRUE),
    mean_aiie = mean(aiie, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(n))

corr_by_sic

# By NAICS4
corr_by_naics4 <- panel %>%
  filter(!is.na(naics4), !is.na(llama_score), !is.na(aiie)) %>%
  group_by(naics4) %>%
  summarise(
    n = n(),
    corr_llama_aiie = ifelse(n() >= 5, cor(llama_score, aiie, use = "complete.obs"), NA_real_),
    mean_llama_score = mean(llama_score, na.rm = TRUE),
    mean_aiie = mean(aiie, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(desc(n))

corr_by_naics4

# Show the largest sectors only
corr_by_sic %>% slice_head(n = 20)
corr_by_naics4 %>% slice_head(n = 20)





library(ggplot2)
library(dplyr)

# ------------------------------------------------------------
# AI adoption over time
# ------------------------------------------------------------

library(dplyr)
library(tidyr)
library(ggplot2)
library(scales)
library(patchwork)

# Panel A data
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

p1 <- ggplot(trend_levels, aes(x = year, y = value, color = series)) +
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

p2 <- ggplot(ai_trend, aes(x = year, y = share_positive)) +
  geom_line(color = "#7570b3", linewidth = 1) +
  geom_point(color = "#7570b3", size = 2) +
  scale_y_continuous(labels = percent_format(accuracy = 1)) +
  labs(
    title = "Share of Firms with Positive AI Adoption Score",
    x = "Year",
    y = "Share > 0"
  ) +
  theme_minimal(base_size = 12)

p1 / p2

# The filing-based AI adoption measure increases steadily from 2010 to 2025, 
# with the mean score and the share of firms with positive AI-adoption disclosures 
# rising markedly, while the median remains at zero, 
# indicating a highly right-skewed and zero-heavy distribution


