setwd("/Users/piomedolla/Desktop/effect-of-genai")

# ---- Packages ----
packages <- c("data.table", "edgar", "usethis")
to_install <- setdiff(packages, rownames(installed.packages()))
if (length(to_install)) install.packages(to_install)
invisible(lapply(packages, require, character.only = TRUE))

# ---- Config ----
ROOT <- getwd()
OUTDIR <- file.path(getwd(), "cache", "edgar_extraction")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)
setwd(OUTDIR)

PROGRESS_FILE <- file.path(OUTDIR, "extraction_progress.csv")

# ---- Validate env variable ----
ua <- Sys.getenv("EDGAR_USER_AGENT")
if (!nzchar(ua)) {
  stop("EDGAR_USER_AGENT is not set. Set it in your .Renviron before running.")
}

# ---- Input prep ----
prepare_pairs <- function(dt) {
  dt <- as.data.table(dt)
  stopifnot(all(c("cik", "year") %in% names(dt)))
  
  dt[, cik := as.character(cik)]
  dt[, year := as.integer(year)]
  dt[, cik_no := suppressWarnings(as.integer(sub("^0+", "", cik)))]
  dt <- dt[!is.na(cik_no) & !is.na(year)]
  
  unique(dt[, .(cik, cik_no, year)])
}

# ---- Progress helpers ----
load_progress <- function() {
  if (file.exists(PROGRESS_FILE)) {
    fread(PROGRESS_FILE)
  } else {
    data.table(
      cik_no = integer(),
      year = integer(),
      business_status = character(),
      mdna_status = character(),
      overall_status = character(),
      error_msg = character(),
      run_time = character()
    )
  }
}

write_progress <- function(progress_dt) {
  fwrite(progress_dt, PROGRESS_FILE)
}

# ---- Robust extraction ----
run_edgar_extraction <- function(pairs, sleep_sec = 1, gc_every = 25, save_every = 25) {
  pairs <- as.data.table(pairs)
  setorder(pairs, year, cik_no)
  
  progress <- load_progress()
  
  done_keys <- unique(progress[overall_status == "done", .(cik_no, year)])
  if (nrow(done_keys) > 0) {
    pairs <- pairs[!done_keys, on = .(cik_no, year)]
  }
  
  message("Remaining pairs to process: ", nrow(pairs))
  
  if (nrow(pairs) == 0) {
    message("Nothing left to extract.")
    return(invisible(NULL))
  }
  
  for (i in seq_len(nrow(pairs))) {
    row <- pairs[i]
    cik_no_i <- row$cik_no
    year_i   <- row$year
    
    message(sprintf("[%s/%s] cik_no=%s year=%s", i, nrow(pairs), cik_no_i, year_i))
    
    business_status <- "not_run"
    mdna_status <- "not_run"
    error_msg <- NA_character_
    
    tryCatch(
      {
        edgar::getBusinDescr(
          cik.no = cik_no_i,
          filing.year = year_i,
          useragent = ua
        )
        business_status <- "ok"
      },
      error = function(e) {
        business_status <<- "error"
        error_msg <<- paste0("getBusinDescr: ", conditionMessage(e))
        message("Business description failed for ", cik_no_i, " / ", year_i, ": ", conditionMessage(e))
      }
    )
    
    tryCatch(
      {
        edgar::getMgmtDisc(
          cik.no = cik_no_i,
          filing.year = year_i,
          useragent = ua
        )
        mdna_status <- "ok"
      },
      error = function(e) {
        mdna_status <<- "error"
        msg <- paste0("getMgmtDisc: ", conditionMessage(e))
        error_msg <<- if (is.na(error_msg)) msg else paste(error_msg, msg, sep = " | ")
        message("MD&A failed for ", cik_no_i, " / ", year_i, ": ", conditionMessage(e))
      }
    )
    
    overall_status <- if (business_status == "ok" && mdna_status == "ok") "done" else "incomplete"

    new_row <- data.table(
      cik_no = cik_no_i,
      year = year_i,
      business_status = business_status,
      mdna_status = mdna_status,
      overall_status = overall_status,
      error_msg = error_msg,
      run_time = as.character(Sys.time())
    )
    
    progress <- progress[!(cik_no == cik_no_i & year == year_i)]
    progress <- rbind(progress, new_row, fill = TRUE)
    
    if (i %% save_every == 0 || i == nrow(pairs)) {
      write_progress(progress)
    }
    
    if (i %% gc_every == 0) {
      gc()
    }
    
    Sys.sleep(sleep_sec)
  }
  
  write_progress(progress)
  invisible(NULL)
}

# ---- MAIN ----
cik_year <- readRDS(file.path(ROOT, "cache/cik_year.rds"))
pairs <- prepare_pairs(cik_year)

run_edgar_extraction(pairs, sleep_sec = 1, gc_every = 100, save_every = 100)

message("Extraction pass finished.")