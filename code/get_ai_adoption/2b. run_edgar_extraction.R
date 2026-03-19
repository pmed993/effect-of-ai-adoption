# =========================================================
# EFFICIENT EDGAR 10-K EXTRACTION
# Bus Description + Management Discussion
# Single-download, local-parse, resumable, low-noise
# Status logic:
#   - done              = both sections extracted
#   - done_with_missing = one or both sections genuinely absent
#   - incomplete        = technical failure only
# Raw file deletion:
#   - delete raw for done and done_with_missing
# =========================================================

setwd("/Users/piomedolla/Desktop/effect-of-genai")

# -------------------------
# Packages
# -------------------------
packages <- c("data.table", "httr2")
to_install <- setdiff(packages, rownames(installed.packages()))
if (length(to_install)) install.packages(to_install)
invisible(lapply(packages, require, character.only = TRUE))

# -------------------------
# Source local extractors
# These must parse FROM LOCAL RAW FILE
# -------------------------
source("code/get_ai_adoption/helper.R")
source("code/get_ai_adoption/extract_BusDesc_NEW.R")
source("code/get_ai_adoption/extract_MgmtDisc_NEW.R")

# =========================================================
# CONFIG
# =========================================================

ROOT <- getwd()
CACHE_DIR <- file.path(ROOT, "cache")
RAW_DIR   <- file.path(CACHE_DIR, "edgar_Raw10k")
BUS_DIR   <- file.path(CACHE_DIR, "edgar_BusDesc")
MGMT_DIR  <- file.path(CACHE_DIR, "edgar_MgmtDisc")
LOG_DIR   <- file.path(CACHE_DIR, "logs")

dir.create(CACHE_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(RAW_DIR,   recursive = TRUE, showWarnings = FALSE)
dir.create(BUS_DIR,   recursive = TRUE, showWarnings = FALSE)
dir.create(MGMT_DIR,  recursive = TRUE, showWarnings = FALSE)
dir.create(LOG_DIR,   recursive = TRUE, showWarnings = FALSE)

PROGRESS_FILE <- file.path(LOG_DIR, "extraction_progress.csv")
FAILED_FILE   <- file.path(LOG_DIR, "extraction_failed.csv")

UA <- "Pio Medolla (pio.medolla@kcl.ac.uk)"

# -------------------------
# Tuning
# -------------------------
BATCH_SIZE <- 1000L
SAVE_EVERY <- 100L
GC_EVERY   <- 100L
SLEEP_SEC  <- 0.15
COOLDOWN_EVERY_BATCHES <- 10L
COOLDOWN_SECONDS <- 15L
DELETE_RAW_AFTER_TERMINAL <- FALSE

# If TRUE, rerun rows previously marked incomplete
RERUN_INCOMPLETE <- TRUE

# If FALSE, existing output files are respected and not overwritten
OVERWRITE_EXISTING_OUTPUTS <- FALSE

# =========================================================
# HELPERS
# =========================================================

prepare_input <- function(edgar_df) {
  dt <- as.data.table(edgar_df)
  
  required_cols <- c("cik", "year", "url", "destination")
  missing_cols <- setdiff(required_cols, names(dt))
  if (length(missing_cols)) {
    stop("Missing required columns: ", paste(missing_cols, collapse = ", "))
  }
  
  dt[, cik := as.character(cik)]
  dt[, year := as.integer(year)]
  dt[, url := as.character(url)]
  dt[, destination := as.character(destination)]
  
  # Preserve original row_id if already supplied
  if (!"row_id" %in% names(dt)) {
    dt[, row_id := .I]
  } else {
    dt[, row_id := as.integer(row_id)]
  }
  
  setorder(dt, row_id)
  
  dt[, raw_file := file.path(RAW_DIR, basename(destination))]
  dt[, stem := tools::file_path_sans_ext(basename(raw_file))]
  dt[, bus_file := file.path(BUS_DIR,  paste0(stem, "_BusDesc.txt"))]
  dt[, mgmt_file := file.path(MGMT_DIR, paste0(stem, "_MgmtDisc.txt"))]
  
  if (!"batch_id" %in% names(dt)) {
    dt[, batch_id := ((seq_len(.N) - 1L) %/% BATCH_SIZE) + 1L]
  } else {
    dt[, batch_id := as.integer(batch_id)]
  }
  
  dt[]
}

load_progress <- function() {
  if (file.exists(PROGRESS_FILE)) {
    p <- fread(PROGRESS_FILE)
    
    needed <- c(
      "row_id", "batch_id", "cik", "year", "url",
      "raw_file", "bus_file", "mgmt_file",
      "download_status", "bus_status", "mgmt_status",
      "overall_status", "error_msg", "updated_at"
    )
    
    missing_cols <- setdiff(needed, names(p))
    if (length(missing_cols)) {
      stop("Progress file exists but is missing columns: ",
           paste(missing_cols, collapse = ", "))
    }
    
    p[]
  } else {
    data.table(
      row_id = integer(),
      batch_id = integer(),
      cik = character(),
      year = integer(),
      url = character(),
      raw_file = character(),
      bus_file = character(),
      mgmt_file = character(),
      download_status = character(),
      bus_status = character(),
      mgmt_status = character(),
      overall_status = character(),
      error_msg = character(),
      updated_at = character()
    )
  }
}

write_progress <- function(progress_dt) {
  setorder(progress_dt, row_id)
  fwrite(progress_dt, PROGRESS_FILE)
  invisible(TRUE)
}

write_failed <- function(progress_dt) {
  failed <- progress_dt[overall_status == "incomplete"]
  setorder(failed, row_id)
  fwrite(failed, FAILED_FILE)
  invisible(TRUE)
}
merge_progress_row <- function(progress_dt, new_row) {
  new_row <- as.data.table(new_row)
  
  new_row[, row_id := as.integer(row_id)]
  new_row[, batch_id := as.integer(batch_id)]
  new_row[, cik := as.character(cik)]
  new_row[, year := as.integer(year)]
  new_row[, url := as.character(url)]
  new_row[, raw_file := as.character(raw_file)]
  new_row[, bus_file := as.character(bus_file)]
  new_row[, mgmt_file := as.character(mgmt_file)]
  new_row[, download_status := as.character(download_status)]
  new_row[, bus_status := as.character(bus_status)]
  new_row[, mgmt_status := as.character(mgmt_status)]
  new_row[, overall_status := as.character(overall_status)]
  new_row[, error_msg := as.character(error_msg)]
  new_row[, updated_at := as.character(updated_at)]
  
  progress_dt <- progress_dt[!(
    cik == new_row$cik &
      year == new_row$year &
      url == new_row$url
  )]
  
  rbind(progress_dt, new_row, fill = TRUE, use.names = TRUE)
}


quiet_run <- function(expr) {
  tmp <- tempfile()
  on.exit(unlink(tmp), add = TRUE)
  
  suppressWarnings(
    suppressMessages(
      capture.output(
        result <- force(expr),
        file = tmp
      )
    )
  )
  
  result
}

is_terminal_section_status <- function(x) {
  x %in% c("ok", "already_exists", "no_section_found")
}

is_retry_section_status <- function(x) {
  x %in% c("error", "raw_missing", "missing_after_download", "unexpected_output_path")
}

#safe_download <- function(url, dest, ua) {
#  if (file.exists(dest)) {
#    return(list(
#      status = "already_exists",
#      error  = NA_character_
#    ))
#  }
  
#  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  
#  tryCatch(
#    {
#      request(url) |>
#        req_user_agent(ua) |>
#        req_perform(path = dest)
      
#      if (file.exists(dest)) {
#        list(status = "ok", error = NA_character_)
#      } else {
#        list(status = "missing_after_download", error = NA_character_)
#      }
#    },
#    error = function(e) {
#      list(status = "error", error = conditionMessage(e))
#    }
#  )
#}

clean_error_text <- function(x) {
  if (is.na(x) || !nzchar(x)) return(x)
  gsub("\\033\\[[0-9;]*m|\\[[0-9;]*m", "", x)
}

safe_download <- function(url, dest, ua, max_tries = 5L, base_wait = 2) {
  if (file.exists(dest)) {
    return(list(
      status = "already_exists",
      error  = NA_character_
    ))
  }
  
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  
  last_error <- NA_character_
  
  for (attempt in seq_len(max_tries)) {
    res <- tryCatch(
      {
        request(url) |>
          req_user_agent(ua) |>
          req_perform(path = dest)
        
        if (file.exists(dest)) {
          return(list(status = "ok", error = NA_character_))
        } else {
          return(list(status = "missing_after_download", error = NA_character_))
        }
      },
      error = function(e) {
        msg <- clean_error_text(conditionMessage(e))
        
        if (file.exists(dest)) {
          try(file.remove(dest), silent = TRUE)
        }
        
        list(status = "error", error = msg)
      }
    )
    
    if (res$status %in% c("ok", "already_exists")) {
      return(res)
    }
    
    last_error <- res$error
    
    is_retryable <- grepl("503|502|500|429|timeout|timed out|connection", last_error, ignore.case = TRUE)
    
    if (!is_retryable || attempt == max_tries) {
      return(list(status = res$status, error = last_error))
    }
    
    wait_time <- base_wait * (2 ^ (attempt - 1))
    Sys.sleep(wait_time)
  }
  
  list(status = "error", error = last_error)
}


safe_extract <- function(raw_file, expected_out_file, extractor_fun, out_dir) {
  if (file.exists(expected_out_file) && !OVERWRITE_EXISTING_OUTPUTS) {
    return(list(
      status = "already_exists",
      error  = NA_character_
    ))
  }
  
  if (!file.exists(raw_file)) {
    return(list(
      status = "raw_missing",
      error  = NA_character_
    ))
  }
  
  tryCatch(
    {
      returned_path <- quiet_run(
        extractor_fun(dest = raw_file, out_dir = out_dir)
      )
      
      returned_path <- if (is.null(returned_path) || length(returned_path) == 0 || isTRUE(is.na(returned_path)[1])) {
        NA_character_
      } else {
        as.character(returned_path)[1]
      }
      
      if (file.exists(expected_out_file)) {
        return(list(
          status = "ok",
          error  = NA_character_
        ))
      }
      
      if (!is.na(returned_path) && file.exists(returned_path)) {
        ok <- FALSE
        
        try({
          dir.create(dirname(expected_out_file), recursive = TRUE, showWarnings = FALSE)
          ok <- file.rename(returned_path, expected_out_file)
          if (!ok) {
            ok <- file.copy(returned_path, expected_out_file, overwrite = TRUE)
          }
        }, silent = TRUE)
        
        if (file.exists(expected_out_file)) {
          return(list(
            status = "ok",
            error  = NA_character_
          ))
        } else {
          return(list(
            status = "unexpected_output_path",
            error  = returned_path
          ))
        }
      }
      
      list(
        status = "no_section_found",
        error  = NA_character_
      )
    },
    error = function(e) {
      list(
        status = "error",
        error  = conditionMessage(e)
      )
    }
  )
}

safe_delete_raw <- function(raw_file, delete_enabled = TRUE) {
  if (!delete_enabled) return(invisible(FALSE))
  if (!file.exists(raw_file)) return(invisible(FALSE))
  try(file.remove(raw_file), silent = TRUE)
  invisible(TRUE)
}

row_done_by_files <- function(bus_file, mgmt_file) {
  file.exists(bus_file) && file.exists(mgmt_file)
}

row_terminal_by_progress <- function(progress_dt, row_id) {
  if (nrow(progress_dt) == 0L) return(FALSE)
  any(progress_dt$row_id == row_id &
        progress_dt$overall_status %in% c("done", "done_with_missing"))
}

build_error_msg <- function(download_error, bus_error, mgmt_error) {
  parts <- c()
  
  if (!is.na(download_error)) parts <- c(parts, paste0("download: ", download_error))
  if (!is.na(bus_error))      parts <- c(parts, paste0("bus: ", bus_error))
  if (!is.na(mgmt_error))     parts <- c(parts, paste0("mgmt: ", mgmt_error))
  
  if (length(parts) == 0L) NA_character_ else paste(parts, collapse = " | ")
}

# =========================================================
# MAIN ROW PROCESSOR
# =========================================================

process_one_row <- function(row, ua, delete_raw_after_terminal = TRUE) {
  bus_exists_before  <- file.exists(row$bus_file)
  mgmt_exists_before <- file.exists(row$mgmt_file)
  
  # If both outputs already exist, treat as done immediately
  if (bus_exists_before && mgmt_exists_before) {
    safe_delete_raw(row$raw_file, delete_enabled = delete_raw_after_terminal)
    
    return(data.table(
      row_id = row$row_id,
      batch_id = row$batch_id,
      cik = row$cik,
      year = row$year,
      url = row$url,
      raw_file = row$raw_file,
      bus_file = row$bus_file,
      mgmt_file = row$mgmt_file,
      download_status = if (file.exists(row$raw_file)) "already_exists" else "not_needed",
      bus_status = "already_exists",
      mgmt_status = "already_exists",
      overall_status = "done",
      error_msg = NA_character_,
      updated_at = as.character(Sys.time())
    ))
  }
  
  dl <- safe_download(row$url, row$raw_file, ua)
  
  bus <- safe_extract(
    raw_file = row$raw_file,
    expected_out_file = row$bus_file,
    extractor_fun = extract_BusDesc,
    out_dir = BUS_DIR
  )
  
  mgmt <- safe_extract(
    raw_file = row$raw_file,
    expected_out_file = row$mgmt_file,
    extractor_fun = extract_MgmtDisc,
    out_dir = MGMT_DIR
  )
  
  bus_ok  <- file.exists(row$bus_file)
  mgmt_ok <- file.exists(row$mgmt_file)
  
  bus_status_final  <- if (bus_ok)  "ok" else bus$status
  mgmt_status_final <- if (mgmt_ok) "ok" else mgmt$status
  
  if (dl$status %in% c("error", "missing_after_download")) {
    overall_status <- "incomplete"
  } else if (bus_ok && mgmt_ok) {
    overall_status <- "done"
  } else if (is_terminal_section_status(bus_status_final) &&
             is_terminal_section_status(mgmt_status_final)) {
    overall_status <- "done_with_missing"
  } else {
    overall_status <- "incomplete"
  }
  
  error_msg <- build_error_msg(
    download_error = dl$error,
    bus_error = bus$error,
    mgmt_error = mgmt$error
  )
  
  if (overall_status %in% c("done", "done_with_missing")) {
    safe_delete_raw(row$raw_file, delete_enabled = delete_raw_after_terminal)
  }
  
  data.table(
    row_id = row$row_id,
    batch_id = row$batch_id,
    cik = row$cik,
    year = row$year,
    url = row$url,
    raw_file = row$raw_file,
    bus_file = row$bus_file,
    mgmt_file = row$mgmt_file,
    download_status = dl$status,
    bus_status = bus_status_final,
    mgmt_status = mgmt_status_final,
    overall_status = overall_status,
    error_msg = error_msg,
    updated_at = as.character(Sys.time())
  )
}

# =========================================================
# PIPELINE
# =========================================================

run_edgar_local_extraction <- function(edgar_df,
                                       ua,
                                       resume = TRUE,
                                       rerun_incomplete = RERUN_INCOMPLETE,
                                       delete_raw_after_terminal = DELETE_RAW_AFTER_TERMINAL,
                                       save_every = SAVE_EVERY,
                                       gc_every = GC_EVERY,
                                       sleep_sec = SLEEP_SEC,
                                       cooldown_every_batches = COOLDOWN_EVERY_BATCHES,
                                       cooldown_seconds = COOLDOWN_SECONDS) {
  dt <- prepare_input(edgar_df)
  progress <- load_progress()
  
  total_n <- nrow(dt)
  
  if (resume) {
    terminal_from_progress <- integer()
    incomplete_from_progress <- integer()
    
    if (nrow(progress)) {
      terminal_from_progress <- progress[
        overall_status %in% c("done", "done_with_missing"),
        unique(row_id)
      ]
      
      incomplete_from_progress <- progress[
        overall_status == "incomplete",
        unique(row_id)
      ]
    }
    
    done_by_files <- dt[file.exists(bus_file) & file.exists(mgmt_file), row_id]
    
    skip_ids <- unique(c(terminal_from_progress, done_by_files))
    
    if (!rerun_incomplete) {
      skip_ids <- unique(c(skip_ids, incomplete_from_progress))
    }
    
    if (length(skip_ids)) {
      dt <- dt[!row_id %in% skip_ids]
    }
  }
  
  remaining_n <- nrow(dt)
  
  cat("Total rows:", total_n, "\n")
  cat("Remaining rows to process:", remaining_n, "\n")
  
  if (remaining_n == 0L) {
    cat("Nothing left to do.\n")
    return(invisible(load_progress()))
  }
  
  processed_this_run <- 0L
  batch_counter <- 0L
  batch_ids <- sort(unique(dt$batch_id))
  status_every <- 25L
  
  for (b in batch_ids) {
    batch_counter <- batch_counter + 1L
    batch_rows <- dt[batch_id == b]
    batch_n <- nrow(batch_rows)
    
    cat(sprintf("Batch %d | rows in this batch: %d\n", b, batch_n))
    
    for (i in seq_len(batch_n)) {
      row <- batch_rows[i]
      
      result_row <- process_one_row(
        row = row,
        ua = ua,
        delete_raw_after_terminal = delete_raw_after_terminal
      )
      
      progress <- merge_progress_row(progress, result_row)
      processed_this_run <- processed_this_run + 1L
      
      if (processed_this_run %% save_every == 0L) {
        write_progress(progress)
        write_failed(progress)
      }
      
      if (processed_this_run %% gc_every == 0L) {
        gc()
      }
      
      if (sleep_sec > 0) {
        Sys.sleep(sleep_sec)
      }
    }
    
    write_progress(progress)
    write_failed(progress)
    
    batch_summary <- progress[batch_id == b, .N, by = overall_status][order(overall_status)]
    cat(sprintf("Finished batch %d\n", b))
    print(batch_summary)
    
    if (cooldown_every_batches > 0 &&
        cooldown_seconds > 0 &&
        batch_counter %% cooldown_every_batches == 0 &&
        b != tail(batch_ids, 1)) {
      cat(sprintf("Cooldown %d sec\n", cooldown_seconds))
      Sys.sleep(cooldown_seconds)
    }
  }
  
  if (processed_this_run %% status_every == 0L) {
    terminal_n <- progress[overall_status %in% c("done", "done_with_missing"), .N]
    incomplete_n <- progress[overall_status == "incomplete", .N]
    pct <- round(100 * terminal_n / total_n, 1)
    
    cat(sprintf(
      "Processed this run: %d | completed overall: %d/%d (%.1f%%) | incomplete: %d\n",
      processed_this_run, terminal_n, total_n, pct, incomplete_n
    ))
  }
  
  write_progress(progress)
  write_failed(progress)
  
  cat("Extraction pass finished.\n")
  invisible(progress)
}

# =========================================================
# DIAGNOSTICS
# =========================================================

summarise_progress <- function() {
  if (!file.exists(PROGRESS_FILE)) {
    cat("No progress file yet.\n")
    return(invisible(NULL))
  }
  
  p <- fread(PROGRESS_FILE)
  
  cat("\nOverall summary\n")
  print(p[, .N, by = overall_status][order(-N)])
  
  cat("\nDownload status\n")
  print(p[, .N, by = download_status][order(-N)])
  
  cat("\nBus status\n")
  print(p[, .N, by = bus_status][order(-N)])
  
  cat("\nMgmt status\n")
  print(p[, .N, by = mgmt_status][order(-N)])
  
  invisible(p)
}

show_incomplete_examples <- function(n = 20L) {
  if (!file.exists(PROGRESS_FILE)) {
    cat("No progress file yet.\n")
    return(invisible(NULL))
  }
  
  p <- fread(PROGRESS_FILE)
  out <- p[overall_status == "incomplete"][1:min(.N, n)]
  
  if (nrow(out) == 0L) {
    cat("No incomplete rows.\n")
    return(invisible(NULL))
  }
  
  print(out[, .(
    row_id, cik, year,
    download_status, bus_status, mgmt_status,
    error_msg
  )])
  
  invisible(out)
}


cleanup_terminal_raw_files <- function() {
  p <- load_progress()

  removable <- p[
    overall_status %in% c("done", "done_with_missing") &
      file.exists(raw_file)
  ]

  if (nrow(removable) == 0L) {
    cat("No raw files eligible for cleanup.\n")
    return(invisible(NULL))
  }

  removed <- file.remove(removable$raw_file)
  cat("Removed", sum(removed, na.rm = TRUE), "raw files\n")

  invisible(removable)
}



rebuild_failed_file <- function() {
  p <- load_progress()
  write_failed(p)
  invisible(TRUE)
}

# =========================================================
# RUN
# =========================================================

edgar_link <- readRDS(file.path(CACHE_DIR, "edgar_link_final.rds"))

# Test run
edgar_link_test <- edgar_link[1:300, ]

run_edgar_local_extraction(
  edgar_df = edgar_link_test,
  ua = UA,
  resume = TRUE,
  rerun_incomplete = TRUE, 
  save_every = 25,
  gc_every = 100,
  sleep_sec = 0.15,
  cooldown_every_batches = 10,
  cooldown_seconds = 15
)

# Full run
# run_edgar_local_extraction(
#   edgar_df = edgar_link,
#   ua = UA,
#   resume = TRUE, # Keep this
#   rerun_incomplete = TRUE, # keep this on
#   save_every = 100,
#   gc_every = 100,
#   sleep_sec = 0.15,
#   cooldown_every_batches = 10,
#   cooldown_seconds = 15
# )

# Optional diagnostics
# summarise_progress()
# show_incomplete_examples(20)

# Read progress
progress_dt <- fread(PROGRESS_FILE)

# Keep only rows marked done_with_missing
done_missing_rows <- progress_dt[overall_status == "done_with_missing"]

# Join back to the original edgar_link using row_id
done_missing_edgar <- edgar_link[done_missing_rows$row_id, ]

# Rerun only those rows
run_edgar_local_extraction(
  edgar_df = done_missing_edgar,
  ua = UA,
  resume = FALSE,
  rerun_incomplete = TRUE,
  delete_raw_after_terminal = FALSE,
  save_every = 25,
  gc_every = 100,
  sleep_sec = 0.5,
  cooldown_every_batches = 1,
  cooldown_seconds = 10
)
