library(dplyr)
library(purrr)
library(tibble)
library(readr)
library(glue)
library(lubridate)
library(edgar)

# =========================================================
# CONFIG
# =========================================================

setwd("/Users/piomedolla/Desktop/effect-of-genai")

CACHE <- "cache"
dir.create(CACHE, recursive = TRUE, showWarnings = FALSE)
setwd(CACHE)

ROOT <- getwd()
LOG_DIR <- file.path(ROOT, "logs")
dir.create(LOG_DIR, recursive = TRUE, showWarnings = FALSE)

ua <- "Pio Medolla (pio.medolla@kcl.ac.uk)"

# =========================================================
# INPUT DATA
# =========================================================

# ------- Read cik year data -------
cik <- read_rds(file.path(getwd(), "cik_year.rds")) |> tibble()
years <- unique(cik$year)

# ------- Optional: refresh master index -------
 purrr::map_dfr(years, \(yr) {
   getMasterIndex(filing.year = yr, useragent = ua)
 })

# ------- Build EDGAR link table -------
out <- vector("list", length(years))
names(out) <- years

walk(seq_along(years), \(i) {
  yr <- years[i]
  load(file.path("edgar_MasterIndex", paste0(yr, "master.Rda")))
  
  out[[i]] <<- year.master |>
    as_tibble() |>
    filter(form.type == "10-K") |>
    mutate(
      cik = as.character(cik),
      company_name = company.name,
      form_type = form.type,
      date_filed = lubridate::as_date(date.filed),
      edgar_link = edgar.link,
      year = lubridate::year(date.filed),
      url = glue::glue("https://www.sec.gov/Archives/{edgar_link}")
    )
})

mindex <- bind_rows(out)

# Keep earliest filing in each cik x filing-year
edgar_link <- mindex |>
  group_by(cik, year) |>
  slice_min(date_filed, n = 1, with_ties = FALSE) |>
  ungroup() |>
  mutate(
    destination = glue::glue("edgar_Raw10k/{cik}-{form_type}-{year}.txt")
  ) |>
  select(cik, year, url, destination)

saveRDS(edgar_link, file.path(ROOT, "edgar_link_final.rds"))