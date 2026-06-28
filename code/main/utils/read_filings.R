#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
})

# ------------------------------------------------------------------------------
# Read a filing by accession number and render Item 1 + Item 7 as HTML
# ------------------------------------------------------------------------------
# Command-line usage:
#   Rscript code/main/utils/read_filings.R 0000815097-18-000005
#
# Source usage:
#   ACCESSION_NUMBER <- "0000815097-18-000005"
#   source("code/main/utils/read_filings.R")
# ------------------------------------------------------------------------------

detect_script_path <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)

  if (length(file_arg) > 0L) {
    return(normalizePath(sub("^--file=", "", file_arg[[1]]), winslash = "/", mustWork = TRUE))
  }

  frame_files <- vapply(
    sys.frames(),
    function(frame) {
      if (!is.null(frame$ofile)) frame$ofile else NA_character_
    },
    character(1)
  )
  frame_files <- frame_files[!is.na(frame_files) & nzchar(frame_files)]

  if (length(frame_files) > 0L) {
    return(normalizePath(frame_files[[length(frame_files)]], winslash = "/", mustWork = TRUE))
  }

  stop("Could not determine the script path.")
}


resolve_project_path <- function(path, project_root) {
  if (startsWith(path, "/")) {
    return(normalizePath(path, winslash = "/", mustWork = FALSE))
  }

  normalizePath(file.path(project_root, path), winslash = "/", mustWork = FALSE)
}


SCRIPT_PATH <- detect_script_path()
SCRIPT_DIR <- dirname(SCRIPT_PATH)
PROJECT_ROOT <- normalizePath(
  file.path(SCRIPT_DIR, "..", "..", ".."),
  winslash = "/",
  mustWork = TRUE
)

if (!exists("ASSEMBLED_DIR", inherits = FALSE)) {
  ASSEMBLED_DIR <- file.path("cache", "edgar_metrics_parser", "assembled")
}
if (!exists("OUTPUT_HTML_DIR", inherits = FALSE)) {
  OUTPUT_HTML_DIR <- file.path("output", "filings")
}

ASSEMBLED_DIR <- resolve_project_path(ASSEMBLED_DIR, PROJECT_ROOT)
OUTPUT_HTML_DIR <- resolve_project_path(OUTPUT_HTML_DIR, PROJECT_ROOT)


parse_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)

  list(
    print_html_to_stdout = any(args == "--stdout"),
    accession_number = {
      non_flag_args <- args[!startsWith(args, "--")]
      if (length(non_flag_args) > 0L) trimws(non_flag_args[[1]]) else ""
    }
  )
}


parse_accession_input <- function(parsed_args) {
  if (exists("ACCESSION_NUMBER", inherits = FALSE) && nzchar(ACCESSION_NUMBER)) {
    return(trimws(ACCESSION_NUMBER))
  }

  if (!nzchar(parsed_args$accession_number)) {
    stop(
      "Please provide an accession number.\n",
      "Example: Rscript code/main/utils/read_filings.R 0000815097-18-000005\n",
      "Optional: add --stdout to print the HTML in the terminal."
    )
  }

  parsed_args$accession_number
}


html_escape <- function(x) {
  x <- enc2utf8(ifelse(is.na(x), "", x))
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  gsub("'", "&#39;", x, fixed = TRUE)
}


collapse_item_text <- function(dt, item_name) {
  item_text <- unique(dt[item == item_name & !is.na(text), text])
  item_text <- item_text[nzchar(trimws(item_text))]

  if (length(item_text) == 0L) {
    return("")
  }

  paste(item_text, collapse = "\n\n")
}


find_filing_rows <- function(accession_number, assembled_dir) {
  chunk_files <- list.files(
    assembled_dir,
    pattern = "^extract_df_chunk_[0-9]{5}\\.rds$",
    full.names = TRUE
  )

  if (length(chunk_files) == 0L) {
    stop("No assembled extract chunk files found in: ", assembled_dir)
  }

  matches <- vector("list", length(chunk_files))
  n_matches <- 0L
  accession_value <- accession_number

  for (chunk_file in chunk_files) {
    chunk_dt <- as.data.table(readRDS(chunk_file))
    hit <- chunk_dt[
      accession_number == accession_value &
        item %in% c("item1", "item7")
    ]

    if (nrow(hit) > 0L) {
      n_matches <- n_matches + 1L
      matches[[n_matches]] <- copy(hit)
    }
  }

  if (n_matches == 0L) {
    stop("Accession number not found in assembled extract: ", accession_number)
  }

  unique(rbindlist(matches[seq_len(n_matches)], use.names = TRUE, fill = TRUE))
}


build_html_document <- function(accession_number, filing_dt) {
  filing_dt <- copy(filing_dt)
  setorder(filing_dt, item)

  item1_text <- collapse_item_text(filing_dt, "item1")
  item7_text <- collapse_item_text(filing_dt, "item7")

  meta <- filing_dt[1]
  filing_year <- if ("year" %in% names(meta)) meta$year[[1]] else NA_integer_
  cik <- if ("cik" %in% names(meta)) meta$cik[[1]] else NA_character_
  form_type <- if ("form_type" %in% names(meta)) meta$form_type[[1]] else NA_character_

  item1_block <- if (nzchar(item1_text)) {
    sprintf("<pre>%s</pre>", html_escape(item1_text))
  } else {
    "<p class=\"missing\">Item 1 text was not found for this accession.</p>"
  }

  item7_block <- if (nzchar(item7_text)) {
    sprintf("<pre>%s</pre>", html_escape(item7_text))
  } else {
    "<p class=\"missing\">Item 7 text was not found for this accession.</p>"
  }

  paste0(
    "<!DOCTYPE html>\n",
    "<html lang=\"en\">\n",
    "<head>\n",
    "  <meta charset=\"utf-8\">\n",
    "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
    "  <title>Filing ", html_escape(accession_number), "</title>\n",
    "  <style>\n",
    "    body { font-family: Georgia, 'Times New Roman', serif; margin: 0; background: #f5f1e8; color: #1f2933; }\n",
    "    main { max-width: 1100px; margin: 0 auto; padding: 32px 24px 48px; }\n",
    "    .card { background: #fffdf8; border: 1px solid #d7c9a5; border-radius: 14px; padding: 20px 24px; box-shadow: 0 8px 30px rgba(31, 41, 51, 0.08); }\n",
    "    h1, h2 { margin-top: 0; }\n",
    "    h1 { font-size: 30px; margin-bottom: 10px; }\n",
    "    h2 { font-size: 22px; margin-bottom: 12px; padding-bottom: 10px; border-bottom: 1px solid #eadfca; }\n",
    "    p.meta { margin: 6px 0; color: #52606d; }\n",
    "    p.missing { color: #9b1c1c; font-weight: 600; }\n",
    "    section { margin-top: 28px; }\n",
    "    pre { white-space: pre-wrap; word-break: break-word; font-family: Georgia, 'Times New Roman', serif; font-size: 16px; line-height: 1.55; margin: 0; }\n",
    "  </style>\n",
    "</head>\n",
    "<body>\n",
    "  <main>\n",
    "    <div class=\"card\">\n",
    "      <h1>Combined Filing View</h1>\n",
    "      <p class=\"meta\"><strong>Accession number:</strong> ", html_escape(accession_number), "</p>\n",
    "      <p class=\"meta\"><strong>CIK:</strong> ", html_escape(as.character(cik)), "</p>\n",
    "      <p class=\"meta\"><strong>Form type:</strong> ", html_escape(as.character(form_type)), "</p>\n",
    "      <p class=\"meta\"><strong>Year:</strong> ", html_escape(as.character(filing_year)), "</p>\n",
    "      <section>\n",
    "        <h2>Item 1. Business</h2>\n",
             item1_block, "\n",
    "      </section>\n",
    "      <section>\n",
    "        <h2>Item 7. Management's Discussion and Analysis</h2>\n",
             item7_block, "\n",
    "      </section>\n",
    "    </div>\n",
    "  </main>\n",
    "</body>\n",
    "</html>\n"
  )
}


parsed_args <- parse_args()
accession_number <- parse_accession_input(parsed_args)
filing_dt <- find_filing_rows(accession_number, ASSEMBLED_DIR)
html_doc <- build_html_document(accession_number, filing_dt)

dir.create(OUTPUT_HTML_DIR, recursive = TRUE, showWarnings = FALSE)
output_html <- file.path(
  OUTPUT_HTML_DIR,
  sprintf("filing_%s.html", gsub("[^A-Za-z0-9-]", "_", accession_number))
)

writeLines(html_doc, output_html, useBytes = TRUE)

cat("Wrote filing HTML to:", normalizePath(output_html, winslash = "/", mustWork = TRUE), "\n")

if (isTRUE(parsed_args$print_html_to_stdout)) {
  cat(html_doc)
}

if (interactive()) {
  browseURL(normalizePath(output_html, winslash = "/", mustWork = TRUE))
}
