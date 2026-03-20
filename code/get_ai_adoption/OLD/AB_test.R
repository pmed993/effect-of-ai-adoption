library(tidyverse)
library(httr2)
library(readr)
library(glue)

# =========================================================
# SETUP
# =========================================================

setwd("/Users/piomedolla/Desktop/effect-of-genai")

# adjust these paths if needed
source("code/get_ai_adoption/extract_BusDesc_ORIG.R")
source("code/get_ai_adoption/extract_BusDesc_NEW.R")
source("code/get_ai_adoption/extract_MgmtDisc_ORIG.R")
source("code/get_ai_adoption/extract_MgmtDisc_NEW.R")

CACHE <- "cache"
setwd(CACHE)

ROOT <- getwd()

AB_DIR <- file.path(ROOT, "ab_test")
RAW_DIR <- file.path(AB_DIR, "raw")
BUS_ORIG_DIR <- file.path(AB_DIR, "busdesc_orig")
BUS_NEW_DIR <- file.path(AB_DIR, "busdesc_new")
MGMT_ORIG_DIR <- file.path(AB_DIR, "mgmtdisc_orig")
MGMT_NEW_DIR <- file.path(AB_DIR, "mgmtdisc_new")
LOG_DIR <- file.path(AB_DIR, "logs")

dir.create(AB_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(BUS_ORIG_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(BUS_NEW_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(MGMT_ORIG_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(MGMT_NEW_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(LOG_DIR, recursive = TRUE, showWarnings = FALSE)

ua <- "Pio Medolla (pio.medolla@kcl.ac.uk)"

# =========================================================
# LOAD DATA
# =========================================================

# assumes edgar_link already exists as an .rds or is created elsewhere
# replace this with your actual load step if needed
# edgar_link <- readRDS("path_to_edgar_link.rds")

# example sample: choose a fresh window, not one already used in pipeline tests
test_start <- 101
test_end <- 200

edgar_link_ab <- edgar_link[test_start:test_end, ] %>%
  mutate(
    destination = file.path(RAW_DIR, basename(destination))
  )

# =========================================================
# HELPERS
# =========================================================

save_both <- function(df, name, dir = LOG_DIR) {
  saveRDS(df, file.path(dir, paste0(name, ".rds")))
  write_csv(df, file.path(dir, paste0(name, ".csv")))
}

download_file_logged <- function(url, dest, cik, year, ua) {
  start_time <- Sys.time()
  
  tryCatch(
    {
      dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
      
      if (!file.exists(dest)) {
        request(url) |>
          req_user_agent(ua) |>
          req_perform(path = dest)
      }
      
      tibble(
        cik = cik,
        year = year,
        url = url,
        destination = dest,
        raw_exists = file.exists(dest),
        success = file.exists(dest),
        status = ifelse(file.exists(dest), "ok", "missing_after_download"),
        error_message = NA_character_,
        timestamp = start_time
      )
    },
    error = function(e) {
      tibble(
        cik = cik,
        year = year,
        url = url,
        destination = dest,
        raw_exists = file.exists(dest),
        success = FALSE,
        status = "error",
        error_message = conditionMessage(e),
        timestamp = start_time
      )
    }
  )
}

safe_extract <- function(fun, dest, out_dir, label) {
  start_time <- Sys.time()
  
  tryCatch(
    {
      out <- fun(dest = dest, out_dir = out_dir)
      
      out_norm <- dplyr::case_when(
        is.null(out) ~ NA_character_,
        length(out) == 0 ~ NA_character_,
        is.na(out) ~ NA_character_,
        TRUE ~ as.character(out)
      )
      
      tibble(
        extractor = label,
        input_file = dest,
        output_file = out_norm,
        success = !is.na(out_norm),
        status = ifelse(is.na(out_norm), "no_section_found", "ok"),
        error_message = NA_character_,
        timestamp = start_time
      )
    },
    error = function(e) {
      tibble(
        extractor = label,
        input_file = dest,
        output_file = NA_character_,
        success = FALSE,
        status = "error",
        error_message = conditionMessage(e),
        timestamp = start_time
      )
    }
  )
}

get_text_if_exists <- function(path) {
  if (is.na(path) || !file.exists(path)) return(NA_character_)
  readr::read_file(path)
}

word_count <- function(x) {
  if (is.na(x)) return(NA_integer_)
  stringr::str_count(x, "\\S+")
}

# =========================================================
# 1. DOWNLOAD RAW FILES ONCE
# =========================================================

download_log <- purrr::pmap_dfr(
  list(edgar_link_ab$url, edgar_link_ab$destination, edgar_link_ab$cik, edgar_link_ab$year),
  function(url, destination, cik, year) {
    download_file_logged(url, destination, cik, year, ua)
  }
)

save_both(download_log, "download_log")

raw_ok <- download_log %>%
  filter(success)

cat("Downloaded / available raw files:", nrow(raw_ok), "of", nrow(edgar_link_ab), "\n")

# =========================================================
# 2. RUN BUS DESC A/B TEST
# =========================================================

busdesc_orig_log <- purrr::map_dfr(
  raw_ok$destination,
  \(x) safe_extract(extract_BusDesc_ORIG, x, BUS_ORIG_DIR, "orig")
)

busdesc_new_log <- purrr::map_dfr(
  raw_ok$destination,
  \(x) safe_extract(extract_BusDesc_NEW, x, BUS_NEW_DIR, "new")
)

save_both(busdesc_orig_log, "busdesc_orig_log")
save_both(busdesc_new_log, "busdesc_new_log")

busdesc_compare <- raw_ok %>%
  select(cik, year, destination) %>%
  left_join(
    busdesc_orig_log %>%
      rename(
        orig_output = output_file,
        orig_success = success,
        orig_status = status,
        orig_error = error_message
      ) %>%
      select(input_file, orig_output, orig_success, orig_status, orig_error),
    by = c("destination" = "input_file")
  ) %>%
  left_join(
    busdesc_new_log %>%
      rename(
        new_output = output_file,
        new_success = success,
        new_status = status,
        new_error = error_message
      ) %>%
      select(input_file, new_output, new_success, new_status, new_error),
    by = c("destination" = "input_file")
  ) %>%
  mutate(
    orig_text = purrr::map_chr(orig_output, get_text_if_exists),
    new_text = purrr::map_chr(new_output, get_text_if_exists),
    orig_words = purrr::map_int(orig_text, word_count),
    new_words = purrr::map_int(new_text, word_count),
    comparison = case_when(
      orig_success & new_success ~ "both_success",
      orig_success & !new_success ~ "orig_only",
      !orig_success & new_success ~ "new_only",
      TRUE ~ "neither"
    )
  )

save_both(busdesc_compare, "busdesc_compare")

busdesc_summary <- busdesc_compare %>%
  summarise(
    n_files = n(),
    orig_success_n = sum(orig_success, na.rm = TRUE),
    new_success_n = sum(new_success, na.rm = TRUE),
    both_success_n = sum(comparison == "both_success", na.rm = TRUE),
    orig_only_n = sum(comparison == "orig_only", na.rm = TRUE),
    new_only_n = sum(comparison == "new_only", na.rm = TRUE),
    neither_n = sum(comparison == "neither", na.rm = TRUE),
    avg_orig_words = mean(orig_words, na.rm = TRUE),
    avg_new_words = mean(new_words, na.rm = TRUE)
  )

save_both(busdesc_summary, "busdesc_summary")

cat("\nBusDesc summary:\n")
print(busdesc_summary)

# =========================================================
# 3. RUN MGMT DISC A/B TEST
# =========================================================

mgmt_orig_log <- purrr::map_dfr(
  raw_ok$destination,
  \(x) safe_extract(extract_MgmtDisc_ORIG, x, MGMT_ORIG_DIR, "orig")
)

mgmt_new_log <- purrr::map_dfr(
  raw_ok$destination,
  \(x) safe_extract(extract_MgmtDisc_NEW, x, MGMT_NEW_DIR, "new")
)

save_both(mgmt_orig_log, "mgmt_orig_log")
save_both(mgmt_new_log, "mgmt_new_log")

mgmt_compare <- raw_ok %>%
  select(cik, year, destination) %>%
  left_join(
    mgmt_orig_log %>%
      rename(
        orig_output = output_file,
        orig_success = success,
        orig_status = status,
        orig_error = error_message
      ) %>%
      select(input_file, orig_output, orig_success, orig_status, orig_error),
    by = c("destination" = "input_file")
  ) %>%
  left_join(
    mgmt_new_log %>%
      rename(
        new_output = output_file,
        new_success = success,
        new_status = status,
        new_error = error_message
      ) %>%
      select(input_file, new_output, new_success, new_status, new_error),
    by = c("destination" = "input_file")
  ) %>%
  mutate(
    orig_text = purrr::map_chr(orig_output, get_text_if_exists),
    new_text = purrr::map_chr(new_output, get_text_if_exists),
    orig_words = purrr::map_int(orig_text, word_count),
    new_words = purrr::map_int(new_text, word_count),
    comparison = case_when(
      orig_success & new_success ~ "both_success",
      orig_success & !new_success ~ "orig_only",
      !orig_success & new_success ~ "new_only",
      TRUE ~ "neither"
    )
  )

save_both(mgmt_compare, "mgmt_compare")

mgmt_summary <- mgmt_compare %>%
  summarise(
    n_files = n(),
    orig_success_n = sum(orig_success, na.rm = TRUE),
    new_success_n = sum(new_success, na.rm = TRUE),
    both_success_n = sum(comparison == "both_success", na.rm = TRUE),
    orig_only_n = sum(comparison == "orig_only", na.rm = TRUE),
    new_only_n = sum(comparison == "new_only", na.rm = TRUE),
    neither_n = sum(comparison == "neither", na.rm = TRUE),
    avg_orig_words = mean(orig_words, na.rm = TRUE),
    avg_new_words = mean(new_words, na.rm = TRUE)
  )

save_both(mgmt_summary, "mgmt_summary")

cat("\nMgmtDisc summary:\n")
print(mgmt_summary)

# =========================================================
# 4. CASES TO INSPECT MANUALLY
# =========================================================

busdesc_new_only <- busdesc_compare %>%
  filter(comparison == "new_only") %>%
  select(cik, year, destination, orig_status, new_status, orig_words, new_words, orig_output, new_output)

busdesc_orig_only <- busdesc_compare %>%
  filter(comparison == "orig_only") %>%
  select(cik, year, destination, orig_status, new_status, orig_words, new_words, orig_output, new_output)

mgmt_new_only <- mgmt_compare %>%
  filter(comparison == "new_only") %>%
  select(cik, year, destination, orig_status, new_status, orig_words, new_words, orig_output, new_output)

mgmt_orig_only <- mgmt_compare %>%
  filter(comparison == "orig_only") %>%
  select(cik, year, destination, orig_status, new_status, orig_words, new_words, orig_output, new_output)

save_both(busdesc_new_only, "busdesc_new_only")
save_both(busdesc_orig_only, "busdesc_orig_only")
save_both(mgmt_new_only, "mgmt_new_only")
save_both(mgmt_orig_only, "mgmt_orig_only")

cat("\nBusDesc new-only cases:", nrow(busdesc_new_only), "\n")
cat("BusDesc orig-only cases:", nrow(busdesc_orig_only), "\n")
cat("MgmtDisc new-only cases:", nrow(mgmt_new_only), "\n")
cat("MgmtDisc orig-only cases:", nrow(mgmt_orig_only), "\n")

# =========================================================
# 5. OPTIONAL: PREVIEW A FEW DIFFERENCES
# =========================================================

# Example:
# read_file(busdesc_new_only$new_output[1])
# read_file(busdesc_new_only$orig_output[1])

# Example:
# read_file(mgmt_new_only$new_output[1])
# read_file(mgmt_new_only$orig_output[1])