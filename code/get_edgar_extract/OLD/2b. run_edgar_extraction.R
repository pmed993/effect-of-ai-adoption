library(tidyverse)
library(httr2)
library(edgar)
library(readr)
library(glue)
library(lubridate)

# =========================================================
# PROJECT SETUP
# =========================================================

setwd("/Users/piomedolla/Desktop/effect-of-genai")

# Keep original extractor functions
source("code/get_ai_adoption/extract_BusDesc_ORIG.R")
source("code/get_ai_adoption/extract_MgmtDisc_ORIG.R")

CACHE <- "cache"
dir.create(CACHE, recursive = TRUE, showWarnings = FALSE)
setwd(CACHE)

ROOT <- getwd()
RAW_DIR <- file.path(ROOT, "edgar_Raw10k")
BUS_DIR <- file.path(ROOT, "edgar_BusDesc")
MGMT_DIR <- file.path(ROOT, "edgar_MgmtDisc")
LOG_DIR <- file.path(ROOT, "logs")
FAILED_DIR <- file.path(LOG_DIR, "failed_batches")

dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(BUS_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(MGMT_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(LOG_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(FAILED_DIR, recursive = TRUE, showWarnings = FALSE)

ua <- "Pio Medolla (pio.medolla@kcl.ac.uk)"

# =========================================================
# PRODUCTION TUNING
# =========================================================

DEFAULT_BATCH_SIZE <- 100L
SLEEP_BETWEEN_BATCHES_SEC <- 2L
COOLDOWN_EVERY_N_BATCHES <- 10L
COOLDOWN_SECONDS <- 30L
RUN_GC_AFTER_BATCH <- TRUE
DELETE_RAW_AFTER_SUCCESS <- TRUE

# =========================================================
# HELPERS: PATHS
# =========================================================

get_raw_path <- function(dest) {
  file.path(RAW_DIR, basename(dest))
}

get_busdesc_path <- function(raw_dest) {
  file.path(
    BUS_DIR,
    paste0(tools::file_path_sans_ext(basename(raw_dest)), "_BusDesc.txt")
  )
}

get_mgmtdisc_path <- function(raw_dest) {
  file.path(
    MGMT_DIR,
    paste0(tools::file_path_sans_ext(basename(raw_dest)), "_MgmtDisc.txt")
  )
}

add_pipeline_paths <- function(df) {
  df |>
    mutate(
      raw_file = purrr::map_chr(destination, get_raw_path),
      busdesc_file = purrr::map_chr(raw_file, get_busdesc_path),
      mgmtdisc_file = purrr::map_chr(raw_file, get_mgmtdisc_path)
    )
}

add_batch_ids <- function(df, batch_size) {
  df |>
    mutate(
      row_id = row_number(),
      batch_id = ceiling(row_id / batch_size)
    )
}

add_batch_file_status <- function(df) {
  df |>
    mutate(
      raw_exists = file.exists(raw_file),
      busdesc_exists = file.exists(busdesc_file),
      mgmtdisc_exists = file.exists(mgmtdisc_file),
      fully_done = busdesc_exists & mgmtdisc_exists
    )
}

# =========================================================
# HELPERS: REGISTRY
# =========================================================

registry_path_rds <- function() file.path(LOG_DIR, "batch_registry.rds")
registry_path_csv <- function() file.path(LOG_DIR, "batch_registry.csv")

read_batch_registry <- function() {
  path <- registry_path_rds()
  if (!file.exists(path)) return(tibble())
  readRDS(path)
}

write_batch_registry <- function(registry) {
  saveRDS(registry, registry_path_rds())
  readr::write_csv(registry, registry_path_csv())
  invisible(registry)
}

update_batch_registry <- function(batch_summary_row) {
  registry <- read_batch_registry()
  
  if (nrow(registry) == 0) {
    registry <- batch_summary_row
  } else {
    registry <- registry |>
      filter(batch_id != batch_summary_row$batch_id[[1]]) |>
      bind_rows(batch_summary_row) |>
      arrange(batch_id)
  }
  
  write_batch_registry(registry)
}

failed_batch_path_rds <- function(batch_id) {
  file.path(FAILED_DIR, paste0("failed_batch_", batch_id, ".rds"))
}

failed_batch_path_csv <- function(batch_id) {
  file.path(FAILED_DIR, paste0("failed_batch_", batch_id, ".csv"))
}

write_failed_rows <- function(batch_id, df) {
  saveRDS(df, failed_batch_path_rds(batch_id))
  readr::write_csv(df, failed_batch_path_csv(batch_id))
  invisible(df)
}

remove_failed_rows_file <- function(batch_id) {
  rds <- failed_batch_path_rds(batch_id)
  csv <- failed_batch_path_csv(batch_id)
  if (file.exists(rds)) file.remove(rds)
  if (file.exists(csv)) file.remove(csv)
  invisible(TRUE)
}

# =========================================================
# HELPERS: DOWNLOAD / EXTRACT / CLEANUP
# =========================================================

download_one <- function(url, dest, ua) {
  tryCatch(
    {
      if (!file.exists(dest)) {
        dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
        request(url) |>
          req_user_agent(ua) |>
          req_perform(path = dest)
      }
      
      tibble(
        raw_exists_after = file.exists(dest),
        download_success = file.exists(dest),
        download_status = ifelse(file.exists(dest), "ok", "missing_after_download"),
        download_error = NA_character_
      )
    },
    error = function(e) {
      tibble(
        raw_exists_after = file.exists(dest),
        download_success = FALSE,
        download_status = "error",
        download_error = conditionMessage(e)
      )
    }
  )
}

extract_one <- function(raw_file, out_file, extractor, out_dir, section_name) {
  if (file.exists(out_file)) {
    return(
      tibble(
        attempted = FALSE,
        success = TRUE,
        status = "already_exists",
        error_message = NA_character_,
        output_file = out_file
      )
    )
  }
  
  if (!file.exists(raw_file)) {
    return(
      tibble(
        attempted = FALSE,
        success = FALSE,
        status = "raw_file_missing",
        error_message = NA_character_,
        output_file = NA_character_
      )
    )
  }
  
  tryCatch(
    {
      out <- extractor(dest = raw_file, out_dir = out_dir)
      out_norm <- if (is.null(out) || length(out) == 0 || is.na(out)) NA_character_ else as.character(out)[1]
      
      if (!is.na(out_norm) && file.exists(out_file)) {
        tibble(
          attempted = TRUE,
          success = TRUE,
          status = "ok",
          error_message = NA_character_,
          output_file = out_norm
        )
      } else {
        tibble(
          attempted = TRUE,
          success = FALSE,
          status = "no_section_found",
          error_message = NA_character_,
          output_file = NA_character_
        )
      }
    },
    error = function(e) {
      tibble(
        attempted = TRUE,
        success = FALSE,
        status = "error",
        error_message = conditionMessage(e),
        output_file = NA_character_
      )
    }
  )
}

delete_raw_if_complete <- function(raw_file, can_delete, delete_enabled = TRUE) {
  if (!file.exists(raw_file)) {
    return(
      tibble(
        deleted = FALSE,
        delete_status = "file_missing",
        delete_error = NA_character_
      )
    )
  }
  
  if (!delete_enabled) {
    return(
      tibble(
        deleted = FALSE,
        delete_status = "deletion_disabled",
        delete_error = NA_character_
      )
    )
  }
  
  if (!can_delete) {
    return(
      tibble(
        deleted = FALSE,
        delete_status = "kept_due_to_incomplete_extraction",
        delete_error = NA_character_
      )
    )
  }
  
  tryCatch(
    {
      ok <- file.remove(raw_file)
      tibble(
        deleted = ok && !file.exists(raw_file),
        delete_status = ifelse(ok && !file.exists(raw_file), "deleted", "delete_failed"),
        delete_error = NA_character_
      )
    },
    error = function(e) {
      tibble(
        deleted = FALSE,
        delete_status = "error",
        delete_error = conditionMessage(e)
      )
    }
  )
}

# =========================================================
# PROCESS ONE BATCH
# =========================================================

process_batch <- function(batch_df,
                          ua,
                          delete_raw_after_success = TRUE) {
  
  stopifnot(n_distinct(batch_df$batch_id) == 1)
  
  batch_id <- batch_df$batch_id[[1]]
  batch_start <- Sys.time()
  
  batch_df <- add_batch_file_status(batch_df)
  
  n_total <- nrow(batch_df)
  n_already_complete_before <- sum(batch_df$fully_done, na.rm = TRUE)
  
  cat("\n========================================\n")
  cat("Starting batch", batch_id, "\n")
  cat("Files in batch:", n_total, "\n")
  cat("Already complete before batch:", n_already_complete_before, "\n")
  cat("Need processing:", n_total - n_already_complete_before, "\n")
  cat("Started at:", format(batch_start), "\n")
  cat("========================================\n")
  
  if (n_already_complete_before == n_total) {
    batch_summary <- tibble(
      batch_id = batch_id,
      n_total = n_total,
      n_already_complete_before = n_already_complete_before,
      n_needed_processing = 0L,
      n_download_attempted = 0L,
      n_download_failed = 0L,
      n_busdesc_attempted = 0L,
      n_busdesc_failed = 0L,
      n_mgmtdisc_attempted = 0L,
      n_mgmtdisc_failed = 0L,
      n_raw_deleted = 0L,
      n_remaining_after = 0L,
      batch_status = "complete",
      batch_started = batch_start,
      batch_finished = Sys.time()
    )
    
    update_batch_registry(batch_summary)
    remove_failed_rows_file(batch_id)
    
    cat("Batch already complete.\n")
    return(batch_summary)
  }
  
  # -------------------------
  # 1. Download only where raw is missing
  # -------------------------
  
  to_download <- batch_df |>
    filter(!fully_done, !raw_exists)
  
  cat("Downloading missing raw files:", nrow(to_download), "\n")
  
  download_res <- if (nrow(to_download) > 0) {
    purrr::pmap_dfr(
      list(to_download$url, to_download$raw_file),
      \(url, raw_file) download_one(url, raw_file, ua)
    )
  } else {
    tibble(
      raw_exists_after = logical(),
      download_success = logical(),
      download_status = character(),
      download_error = character()
    )
  }
  
  if (nrow(to_download) > 0) {
    download_df <- bind_cols(
      to_download |> select(cik, year, batch_id, url, raw_file),
      download_res
    )
  } else {
    download_df <- tibble(
      cik = character(),
      year = numeric(),
      batch_id = numeric(),
      url = character(),
      raw_file = character(),
      raw_exists_after = logical(),
      download_success = logical(),
      download_status = character(),
      download_error = character()
    )
  }
  
  # refresh only current batch status
  batch_df <- add_batch_file_status(batch_df)
  
  # -------------------------
  # 2. Extract BusDesc only where missing
  # -------------------------
  
  bus_todo <- batch_df |>
    filter(!busdesc_exists)
  
  cat("Extracting BusDesc for missing outputs:", nrow(bus_todo), "\n")
  
  bus_res <- if (nrow(bus_todo) > 0) {
    purrr::pmap_dfr(
      list(bus_todo$raw_file, bus_todo$busdesc_file),
      \(raw_file, busdesc_file) {
        extract_one(
          raw_file = raw_file,
          out_file = busdesc_file,
          extractor = extract_BusDesc,
          out_dir = BUS_DIR,
          section_name = "BusDesc"
        )
      }
    )
  } else {
    tibble(
      attempted = logical(),
      success = logical(),
      status = character(),
      error_message = character(),
      output_file = character()
    )
  }
  
  if (nrow(bus_todo) > 0) {
    bus_df <- bind_cols(
      bus_todo |> select(cik, year, batch_id, raw_file, busdesc_file),
      bus_res
    )
  } else {
    bus_df <- tibble(
      cik = character(),
      year = numeric(),
      batch_id = numeric(),
      raw_file = character(),
      busdesc_file = character(),
      attempted = logical(),
      success = logical(),
      status = character(),
      error_message = character(),
      output_file = character()
    )
  }
  
  batch_df <- add_batch_file_status(batch_df)
  
  # -------------------------
  # 3. Extract MgmtDisc only where missing
  # -------------------------
  
  mgmt_todo <- batch_df |>
    filter(!mgmtdisc_exists)
  
  cat("Extracting MgmtDisc for missing outputs:", nrow(mgmt_todo), "\n")
  
  mgmt_res <- if (nrow(mgmt_todo) > 0) {
    purrr::pmap_dfr(
      list(mgmt_todo$raw_file, mgmt_todo$mgmtdisc_file),
      \(raw_file, mgmtdisc_file) {
        extract_one(
          raw_file = raw_file,
          out_file = mgmtdisc_file,
          extractor = extract_MgmtDisc,
          out_dir = MGMT_DIR,
          section_name = "MgmtDisc"
        )
      }
    )
  } else {
    tibble(
      attempted = logical(),
      success = logical(),
      status = character(),
      error_message = character(),
      output_file = character()
    )
  }
  
  if (nrow(mgmt_todo) > 0) {
    mgmt_df <- bind_cols(
      mgmt_todo |> select(cik, year, batch_id, raw_file, mgmtdisc_file),
      mgmt_res
    )
  } else {
    mgmt_df <- tibble(
      cik = character(),
      year = numeric(),
      batch_id = numeric(),
      raw_file = character(),
      mgmtdisc_file = character(),
      attempted = logical(),
      success = logical(),
      status = character(),
      error_message = character(),
      output_file = character()
    )
  }
  
  batch_df <- add_batch_file_status(batch_df)
  
  # -------------------------
  # 4. Delete raw only if both outputs now exist
  # -------------------------
  
  delete_candidates <- batch_df |>
    mutate(can_delete = busdesc_exists & mgmtdisc_exists & raw_exists)
  
  delete_res <- if (nrow(delete_candidates) > 0) {
    purrr::map_dfr(
      seq_len(nrow(delete_candidates)),
      \(i) {
        delete_raw_if_complete(
          raw_file = delete_candidates$raw_file[[i]],
          can_delete = delete_candidates$can_delete[[i]],
          delete_enabled = delete_raw_after_success
        )
      }
    )
  } else {
    tibble(
      deleted = logical(),
      delete_status = character(),
      delete_error = character()
    )
  }
  
  delete_df <- bind_cols(
    delete_candidates |> select(cik, year, batch_id, raw_file),
    delete_res
  )
  
  # final batch status
  batch_df <- add_batch_file_status(batch_df)
  
  failed_rows <- batch_df |>
    filter(!fully_done) |>
    select(
      batch_id, row_id, cik, year, url,
      raw_file, busdesc_file, mgmtdisc_file,
      raw_exists, busdesc_exists, mgmtdisc_exists, fully_done
    ) |>
    left_join(
      download_df |> select(cik, year, raw_file, download_status, download_error),
      by = c("cik", "year", "raw_file")
    ) |>
    left_join(
      bus_df |> select(cik, year, raw_file, bus_status = status, bus_error = error_message),
      by = c("cik", "year", "raw_file")
    ) |>
    left_join(
      mgmt_df |> select(cik, year, raw_file, mgmt_status = status, mgmt_error = error_message),
      by = c("cik", "year", "raw_file")
    )
  
  if (nrow(failed_rows) > 0) {
    write_failed_rows(batch_id, failed_rows)
  } else {
    remove_failed_rows_file(batch_id)
  }
  
  batch_summary <- tibble(
    batch_id = batch_id,
    n_total = n_total,
    n_already_complete_before = n_already_complete_before,
    n_needed_processing = n_total - n_already_complete_before,
    n_download_attempted = sum(download_df$download_status != "already_exists", na.rm = TRUE),
    n_download_failed = sum(download_df$download_success == FALSE, na.rm = TRUE),
    n_busdesc_attempted = sum(bus_df$attempted, na.rm = TRUE),
    n_busdesc_failed = sum(bus_df$success == FALSE, na.rm = TRUE),
    n_mgmtdisc_attempted = sum(mgmt_df$attempted, na.rm = TRUE),
    n_mgmtdisc_failed = sum(mgmt_df$success == FALSE, na.rm = TRUE),
    n_raw_deleted = sum(delete_df$deleted, na.rm = TRUE),
    n_remaining_after = sum(!batch_df$fully_done, na.rm = TRUE),
    batch_status = if_else(sum(!batch_df$fully_done, na.rm = TRUE) == 0, "complete", "incomplete"),
    batch_started = batch_start,
    batch_finished = Sys.time()
  )
  
  update_batch_registry(batch_summary)
  
  cat("Batch", batch_id, "status:", batch_summary$batch_status[[1]], "\n")
  cat("Remaining after batch:", batch_summary$n_remaining_after[[1]], "\n")
  cat("Finished batch", batch_id, "at", format(batch_summary$batch_finished[[1]]), "\n")
  
  if (RUN_GC_AFTER_BATCH) invisible(gc())
  
  batch_summary
}

# =========================================================
# HELPERS: OUTSTANDING / FAILED BATCHS
# =========================================================

list_outstanding_batches <- function() {
  registry <- read_batch_registry()
  if (nrow(registry) == 0) return(tibble())
  registry |> filter(batch_status != "complete")
}

read_failed_rows_for_batch <- function(batch_id) {
  path <- failed_batch_path_rds(batch_id)
  if (!file.exists(path)) return(tibble())
  readRDS(path)
}

# =========================================================
# RUN PIPELINE
# =========================================================

run_pipeline <- function(edgar_df,
                         batch_size = DEFAULT_BATCH_SIZE,
                         ua,
                         resume = TRUE,
                         rerun_incomplete = FALSE,
                         delete_raw_after_success = DELETE_RAW_AFTER_SUCCESS,
                         sleep_between_batches_sec = SLEEP_BETWEEN_BATCHES_SEC,
                         cooldown_every_n_batches = COOLDOWN_EVERY_N_BATCHES,
                         cooldown_seconds = COOLDOWN_SECONDS) {
  
  stopifnot(all(c("cik", "year", "url", "destination") %in% names(edgar_df)))
  
  pipeline_df <- edgar_df |>
    add_pipeline_paths() |>
    add_batch_ids(batch_size = batch_size)
  
  total_files <- nrow(pipeline_df)
  total_batches <- max(pipeline_df$batch_id)
  
  registry <- read_batch_registry()
  
  completed_batches <- if (nrow(registry) > 0) {
    registry |>
      filter(batch_status == "complete") |>
      pull(batch_id)
  } else {
    integer()
  }
  
  batch_ids <- sort(unique(pipeline_df$batch_id))
  
  if (resume && !rerun_incomplete) {
    batch_ids <- setdiff(batch_ids, completed_batches)
  }
  
  if (length(batch_ids) == 0) {
    cat("No batches left to run.\n")
    return(invisible(read_batch_registry()))
  }
  
  pipeline_start <- Sys.time()
  
  for (i in seq_along(batch_ids)) {
    current_batch_id <- batch_ids[[i]]
    batch_df <- pipeline_df |> filter(batch_id == current_batch_id)
    
    registry <- read_batch_registry()
    completed_now <- if (nrow(registry) == 0) 0L else sum(registry$n_total[registry$batch_status == "complete"], na.rm = TRUE)
    pct_done <- round(100 * completed_now / total_files, 1)
    
    elapsed_mins <- as.numeric(difftime(Sys.time(), pipeline_start, units = "mins"))
    speed <- if (elapsed_mins > 0) completed_now / elapsed_mins else NA_real_
    remaining_files_est <- total_files - completed_now
    eta_mins <- if (!is.na(speed) && speed > 0) remaining_files_est / speed else NA_real_
    
    cat("\n----------------------------------------\n")
    cat("Overall complete from registry:", completed_now, "/", total_files, "(", pct_done, "% )\n")
    cat("Running batch", current_batch_id, "of", total_batches, "\n")
    cat("Batch rows:", min(batch_df$row_id), "to", max(batch_df$row_id), "of", total_files, "\n")
    cat("Elapsed minutes this session:", round(elapsed_mins, 1), "\n")
    cat("Files per minute this session:", round(speed, 2), "\n")
    cat("Estimated minutes remaining:", round(eta_mins, 1), "\n")
    cat("----------------------------------------\n")
    
    process_batch(
      batch_df = batch_df,
      ua = ua,
      delete_raw_after_success = delete_raw_after_success
    )
    
    if (RUN_GC_AFTER_BATCH) invisible(gc())
    
    if (sleep_between_batches_sec > 0 && i < length(batch_ids)) {
      Sys.sleep(sleep_between_batches_sec)
    }
    
    if (cooldown_every_n_batches > 0 &&
        cooldown_seconds > 0 &&
        i %% cooldown_every_n_batches == 0 &&
        i < length(batch_ids)) {
      cat("Cooldown after", i, "batches. Sleeping", cooldown_seconds, "seconds...\n")
      Sys.sleep(cooldown_seconds)
    }
  }
  
  invisible(read_batch_registry())
}

# =========================================================
# EXAMPLE RUNS
# =========================================================

edgar_link <- readRDS(file.path(LOG_DIR, "edgar_link_final.rds"))

# medium production-style test
 edgar_link_3000 <- edgar_link[1:3000, ]
 run_pipeline(
   edgar_df = edgar_link_3000,
   batch_size = 100,
   ua = ua,
   resume = TRUE,
   rerun_incomplete = FALSE,
   delete_raw_after_success = TRUE,
   sleep_between_batches_sec = 2,
   cooldown_every_n_batches = 10,
   cooldown_seconds = 30
 )

# full sample
# run_pipeline(
#   edgar_df = edgar_link,
#   batch_size = 100,
#   ua = ua,
#   resume = TRUE,
#   rerun_incomplete = FALSE,
#   delete_raw_after_success = TRUE,
#   sleep_between_batches_sec = 2,
#   cooldown_every_n_batches = 10,
#   cooldown_seconds = 30
# )