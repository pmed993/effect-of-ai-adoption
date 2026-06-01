# ---- Packages ----
packages <- c("DBI", "data.table", "dplyr","edgar", "janitor", "RPostgres", "readxl",
              "tidyverse", "usethis", "stringr")
to_install <- setdiff(packages, rownames(installed.packages()))
if (length(to_install)) install.packages(to_install)
invisible(lapply(packages, require, character.only = TRUE))

# ---- Config ----
INPUT_DIR <- file.path("data/")
