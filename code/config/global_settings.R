# ---- Packages ----
packages <- c("DBI", "data.table", "dplyr","edgar", "janitor", "RPostgres", "readxl",
              "tidyverse", "usethis", "stringr")
to_install <- setdiff(packages, rownames(installed.packages()))
if (length(to_install)) install.packages(to_install)
invisible(lapply(packages, require, character.only = TRUE))

# ---- Config ----
INPUT_DIR <- file.path("data/")
OUTPUT_DIR <- file.path("output/")
ANALYSIS_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_analysis_panel.rds")

FINAL_ANALYSIS_EXCLUDED_NAICS2 <- c("22", "52", "53", "99")
FINAL_ANALYSIS_INCLUDED_EXCHG <- c(11L, 12L, 14L, 17L, 21L)

build_final_analysis_panel <- function(data) {
  data |>
    mutate(
      naics2 = as.character(naics2),
      exchg = as.integer(exchg)
    ) |>
    filter(
      !naics2 %in% FINAL_ANALYSIS_EXCLUDED_NAICS2,
      exchg %in% FINAL_ANALYSIS_INCLUDED_EXCHG
    )
}
