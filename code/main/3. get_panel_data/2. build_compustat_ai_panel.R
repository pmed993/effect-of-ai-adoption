#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# Build merged Compustat + AI panel for the AI project
# ------------------------------------------------------------------------------
# This script:
# 1. loads (or optionally rebuilds) the annual Compustat panel,
# 2. merges AI exposure by NAICS4,
# 3. loads the filing-based AI adoption panel,
# 4. merges AI adoption to the annual panel on cik-year,
# 5. creates AI-specific investment variables and merge flags, and
# 6. optionally saves the merged outputs to disk.
#
# Recommended filename:
#   code/main/3. get_panel_data/2. build_compustat_ai_panel.R
# ------------------------------------------------------------------------------


# ---- Source dependencies ------------------------------------------------------
source("code/config/global_settings.R")


# ---- Helpers ------------------------------------------------------------------
normalize_cik <- function(x) {
  x_num <- suppressWarnings(as.numeric(x))
  ifelse(is.na(x_num), NA_character_, as.character(as.integer(x_num)))
}

assert_unique_nonmissing_keys <- function(data, keys, label) {
  dt <- as.data.table(data)
  key_dt <- dt[, ..keys]
  is_present <- function(x) {
    if (is.character(x)) {
      !is.na(x) & x != ""
    } else {
      !is.na(x)
    }
  }
  nonmissing <- dt[Reduce(`&`, lapply(key_dt, is_present))]
  dupes <- nonmissing[, .N, by = keys][N > 1]
  if (nrow(dupes) > 0) {
    stop(
      label, " has duplicate non-missing key rows for: ",
      paste(keys, collapse = ", "), "."
    )
  }
  invisible(NULL)
}

find_ai_exposure_sheet <- function(path, preferred = "Appendix B") {
  sheets <- excel_sheets(path)
  normalized <- str_trim(str_to_lower(sheets))
  preferred_norm <- str_trim(str_to_lower(preferred))

  exact_match <- sheets[normalized == preferred_norm]
  if (length(exact_match) == 1) {
    return(exact_match[[1]])
  }

  appendix_b_match <- sheets[str_detect(normalized, "^appendix\\s*b$|appendix\\s*b")]
  if (length(appendix_b_match) == 1) {
    return(appendix_b_match[[1]])
  }

  stop(
    "Could not uniquely identify the AI exposure sheet in ", path, ". ",
    "Available sheets: ", paste(sheets, collapse = ", "), "."
  )
}

load_ai_exposure_table <- function(path, sheet_name) {
  ai_naics <- read_excel(path, sheet = sheet_name) |>
    clean_names() |>
    as.data.table()

  required_cols <- c("naics", "aiie")
  missing_cols <- setdiff(required_cols, names(ai_naics))
  if (length(missing_cols) > 0) {
    stop(
      "AI exposure sheet is missing required columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  ai_naics[, naics4 := str_pad(as.character(as.integer(naics)), 4, pad = "0")]
  ai_naics <- ai_naics[!is.na(naics4) & naics4 != ""]

  dupes <- ai_naics[, .N, by = naics4][N > 1]
  if (nrow(dupes) > 0) {
    stop(
      "AI exposure appendix contains ambiguous duplicate NAICS4 codes: ",
      paste(dupes$naics4, collapse = ", "), ". ",
      "These grouped NAICS codes cannot be safely merged to firm-level naics4. ",
      "Clean the appendix mapping first or set SKIP_AI_EXPOSURE <- TRUE to skip industry exposure variables."
    )
  }

  ai_naics[, .(naics4, aiie)]
}

add_empty_ai_exposure <- function(panel_dt) {
  panel_dt[, `:=`(
    aiie = NA_real_,
    ai_rd_intensity = NA_real_,
    ai_capx_intensity = NA_real_,
    ai_inv_intensity = NA_real_,
    ai_rd_intensity_w = NA_real_,
    ai_capx_intensity_w = NA_real_,
    ai_inv_intensity_w = NA_real_
  )]
  panel_dt
}


# ---- User options -------------------------------------------------------------
if (!exists("SAVE_MERGED_OUTPUTS", inherits = FALSE)) {
  SAVE_MERGED_OUTPUTS <- FALSE
}
if (!exists("REBUILD_ANNUAL_PANEL", inherits = FALSE)) {
  REBUILD_ANNUAL_PANEL <- FALSE
}
if (!exists("SKIP_AI_EXPOSURE", inherits = FALSE)) {
  SKIP_AI_EXPOSURE <- FALSE
}
if (!exists("AI_EXPOSURE_FILE", inherits = FALSE)) {
  AI_EXPOSURE_FILE <- file.path(INPUT_DIR, "AIOE_DataAppendix.xlsx")
}
if (!exists("AI_EXPOSURE_SHEET", inherits = FALSE)) {
  AI_EXPOSURE_SHEET <- "Appendix B"
}
if (!exists("AI_ADOPTION_FILE", inherits = FALSE)) {
  AI_ADOPTION_FILE <- file.path(INPUT_DIR, "llm_score", "ai_adoption_firm_year_panel.csv")
}
if (!exists("ANNUAL_PANEL_RDS", inherits = FALSE)) {
  ANNUAL_PANEL_RDS <- file.path(INPUT_DIR, "compustat_annual_panel.rds")
}
if (!exists("OUTPUT_MERGED_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_MERGED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_panel.rds")
}
if (!exists("OUTPUT_MERGED_PANEL_CSV", inherits = FALSE)) {
  OUTPUT_MERGED_PANEL_CSV <- file.path(INPUT_DIR, "compustat_ai_panel.csv")
}
if (!exists("OUTPUT_MATCHED_PANEL_RDS", inherits = FALSE)) {
  OUTPUT_MATCHED_PANEL_RDS <- file.path(INPUT_DIR, "compustat_ai_matched_panel.rds")
}
if (!exists("OUTPUT_MATCHED_PANEL_CSV", inherits = FALSE)) {
  OUTPUT_MATCHED_PANEL_CSV <- file.path(INPUT_DIR, "compustat_ai_matched_panel.csv")
}
if (!exists("OUTPUT_UNMATCHED_CSV", inherits = FALSE)) {
  OUTPUT_UNMATCHED_CSV <- file.path(INPUT_DIR, "compustat_ai_unmatched.csv")
}


# ---- Build or load annual panel ----------------------------------------------
if (REBUILD_ANNUAL_PANEL) {
  source("code/main/3. get_panel_data/1. build_compustat_annual_panel.R")
} else {
  if (!file.exists(ANNUAL_PANEL_RDS)) {
    stop(
      "Annual panel not found: ", ANNUAL_PANEL_RDS, ". ",
      "Either build it first with code/main/3. get_panel_data/1. build_compustat_annual_panel.R ",
      "or set REBUILD_ANNUAL_PANEL <- TRUE."
    )
  }
  comp <- readRDS(ANNUAL_PANEL_RDS)
}

# ---- Merge AI exposure --------------------------------------------------------
comp_panel <- copy(comp)
setDT(comp_panel)

existing_ai_cols <- intersect(
  c(
    "aiie", "ai_rd_intensity", "ai_capx_intensity", "ai_inv_intensity",
    "ai_rd_intensity_w", "ai_capx_intensity_w", "ai_inv_intensity_w"
  ),
  names(comp_panel)
)
if (length(existing_ai_cols) > 0) {
  comp_panel[, (existing_ai_cols) := NULL]
}

if (SKIP_AI_EXPOSURE) {
  comp_panel <- add_empty_ai_exposure(comp_panel)
} else {
  if (!file.exists(AI_EXPOSURE_FILE)) {
    stop("AI exposure file not found: ", AI_EXPOSURE_FILE)
  }

  sheet_name <- find_ai_exposure_sheet(AI_EXPOSURE_FILE, AI_EXPOSURE_SHEET)
  ai_naics <- load_ai_exposure_table(AI_EXPOSURE_FILE, sheet_name)
  comp_panel <- merge(comp_panel, ai_naics, by = "naics4", all.x = TRUE, sort = FALSE)

  if (!"aiie" %in% names(comp_panel)) {
    stop("Expected AI exposure column 'aiie' was not found after merging the AIOE appendix.")
  }

  # ---- AI-specific investment variables ----------------------------------------
  comp_panel[, ai_rd_intensity := rd_intensity_y * aiie]
  comp_panel[, ai_capx_intensity := capx_intensity_y * aiie]
  comp_panel[, ai_inv_intensity := total_inv_intensity_y * aiie]

  comp_panel[, ai_rd_intensity_w := rd_intensity_y_w * aiie]
  comp_panel[, ai_capx_intensity_w := capx_intensity_y_w * aiie]
  comp_panel[, ai_inv_intensity_w := total_inv_intensity_y_w * aiie]
}


# ---- Load AI adoption panel ---------------------------------------------------
if (!file.exists(AI_ADOPTION_FILE)) {
  stop("AI adoption panel not found: ", AI_ADOPTION_FILE)
}

ai_adoption_score <- fread(AI_ADOPTION_FILE)

required_ai_cols <- c(
  "cik", "year", "accession_number", "llama_score",
  "keyword_hits", "llama_llm_called", "llama_score_status"
)
missing_ai_cols <- setdiff(required_ai_cols, names(ai_adoption_score))
if (length(missing_ai_cols) > 0) {
  stop(
    "AI adoption panel is missing required columns: ",
    paste(missing_ai_cols, collapse = ", ")
  )
}

ai_panel <- ai_adoption_score[, ..required_ai_cols]
setDT(ai_panel)


# ---- Standardise merge keys ---------------------------------------------------
comp_panel <- comp_panel[year >= 2010]
comp_panel[, cik := normalize_cik(cik)]
comp_panel[, year := as.integer(year)]

ai_panel[, cik := normalize_cik(cik)]
ai_panel[, year := as.integer(year)]
ai_panel <- ai_panel[!is.na(cik) & cik != ""]


# ---- Check uniqueness before merge -------------------------------------------
assert_unique_nonmissing_keys(comp_panel, c("cik", "year"), "Annual Compustat panel")
assert_unique_nonmissing_keys(ai_panel, c("cik", "year"), "AI adoption panel")


# ---- Merge AI adoption --------------------------------------------------------
panel <- merge(
  comp_panel,
  ai_panel,
  by = c("cik", "year"),
  all.x = TRUE,
  sort = FALSE
)
setDT(panel)

stopifnot(nrow(panel) == nrow(comp_panel))

setkey(panel, cik, year)
panel[, edgar_match := !is.na(accession_number) & accession_number != ""]
panel[, llm_score_available := !is.na(llama_score)]
panel[, ai_exposure_matched := !is.na(aiie)]


# ---- Generate ai adoption indicator and categorical variables----------------
panel[, ai_adopted := fifelse(
  is.na(llama_score),
  NA_integer_,
  fifelse(llama_score > 0, 1L, 0L)
)]
panel[, ai_adoption := ai_adopted]
panel[, ai_adoption_f := factor(ai_adopted, levels = c(0L, 1L), labels = c("0", "1"))]
panel[, ai_adoption_level := fifelse(
  is.na(llama_score),
  NA_character_,
  fifelse(
    llama_score == 0,
    "No adoption",
    fifelse(llama_score <= 0.33, "Low", fifelse(llama_score <= 0.66, "Medium", "High"))
  )
)]
panel[, ai_adoption_level := factor(
  ai_adoption_level,
  levels = c("No adoption", "Low", "Medium", "High"),
  ordered = TRUE
)]


# ---- Create matched and unmatched samples ------------------------------------
panel_edgar_matched <- panel[edgar_match == TRUE]
panel_ai <- panel[llm_score_available == TRUE]
unmatched <- panel[edgar_match == FALSE]
edgar_unscored <- panel[edgar_match == TRUE & llm_score_available == FALSE]

assert_unique_nonmissing_keys(panel, c("cik", "year"), "Merged Compustat + AI panel")
assert_unique_nonmissing_keys(panel_ai, c("cik", "year"), "Scored Compustat + AI panel")

# ---- Save outputs -------------------------------------------------------------
if (SAVE_MERGED_OUTPUTS) {
  saveRDS(panel, OUTPUT_MERGED_PANEL_RDS)
  fwrite(panel, OUTPUT_MERGED_PANEL_CSV)
  saveRDS(panel_ai, OUTPUT_MATCHED_PANEL_RDS)
  fwrite(panel_ai, OUTPUT_MATCHED_PANEL_CSV)
  fwrite(unmatched, OUTPUT_UNMATCHED_CSV)
}


# ---- Friendly console output --------------------------------------------------
cat("\nBuilt merged Compustat + AI panel.\n")
cat("Rows in annual panel:", nrow(comp), "\n")
cat("Rows in merged panel:", nrow(panel), "\n")
cat("Rows with EDGAR match:", nrow(panel_edgar_matched), "\n")
cat("Rows with usable AI score:", nrow(panel_ai), "\n")
cat("EDGAR-matched rows without usable AI score:", nrow(edgar_unscored), "\n")
cat("Rows in matched panel:", nrow(panel_ai), "\n")
cat("EDGAR match rate:", round(mean(panel$edgar_match, na.rm = TRUE), 4), "\n")
cat("LLM score availability rate:", round(mean(panel$llm_score_available, na.rm = TRUE), 4), "\n")
cat("AI exposure match rate:", round(mean(panel$ai_exposure_matched, na.rm = TRUE), 4), "\n")
if (SKIP_AI_EXPOSURE) {
  cat("AI exposure merge skipped: TRUE\n")
}

if (SAVE_MERGED_OUTPUTS) {
  cat("Saved merged panel to:", OUTPUT_MERGED_PANEL_RDS, "and", OUTPUT_MERGED_PANEL_CSV, "\n")
  cat("Saved matched panel to:", OUTPUT_MATCHED_PANEL_RDS, "and", OUTPUT_MATCHED_PANEL_CSV, "\n")
  cat("Saved unmatched rows to:", OUTPUT_UNMATCHED_CSV, "\n")
}
