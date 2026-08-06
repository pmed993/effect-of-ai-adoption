#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
})

# ------------------------------------------------------------------------------
# Read a filing by accession number and render Item 1 + Item 7 as HTML
# ------------------------------------------------------------------------------
# Command-line usage:
#   Rscript code/main/utils/read_filings.R 0000815097-18-000005
#   Rscript code/main/utils/read_filings.R 0000815097-18-000005 0001049521-13-000008
#   Rscript code/main/utils/read_filings.R --accession-file output/filings/suspected_accessions_top100.csv
#   Rscript code/main/utils/read_filings.R --cik 2488 --year 2019
#
# Source usage:
#   ACCESSION_NUMBER <- "0000815097-18-000005"
#   source("code/main/utils/read_filings.R")
#   CIK <- "2488"
#   YEAR <- 2019
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


normalize_cik <- function(x) {
  x_chr <- trimws(as.character(x))
  x_num <- suppressWarnings(as.numeric(x_chr))
  ifelse(
    is.na(x_num),
    gsub("[^0-9]", "", x_chr),
    as.character(as.integer(x_num))
  )
}


normalize_year <- function(x) {
  suppressWarnings(as.integer(as.character(x)))
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
  accession_file <- ""
  cik <- ""
  year <- ""
  positional <- character()
  i <- 1L

  while (i <= length(args)) {
    arg <- args[[i]]

    if (arg == "--stdout") {
      i <- i + 1L
      next
    }

    if (startsWith(arg, "--accession-file=")) {
      accession_file <- sub("^--accession-file=", "", arg)
      i <- i + 1L
      next
    }

    if (arg == "--accession-file") {
      if (i == length(args)) {
        stop("Expected a file path after --accession-file")
      }
      accession_file <- args[[i + 1L]]
      i <- i + 2L
      next
    }

    if (startsWith(arg, "--cik=")) {
      cik <- sub("^--cik=", "", arg)
      i <- i + 1L
      next
    }

    if (arg == "--cik") {
      if (i == length(args)) {
        stop("Expected a CIK after --cik")
      }
      cik <- args[[i + 1L]]
      i <- i + 2L
      next
    }

    if (startsWith(arg, "--year=")) {
      year <- sub("^--year=", "", arg)
      i <- i + 1L
      next
    }

    if (arg == "--year") {
      if (i == length(args)) {
        stop("Expected a year after --year")
      }
      year <- args[[i + 1L]]
      i <- i + 2L
      next
    }

    positional <- c(positional, arg)
    i <- i + 1L
  }

  list(
    print_html_to_stdout = any(args == "--stdout"),
    accession_file = trimws(accession_file),
    cik = trimws(cik),
    year = trimws(year),
    accession_numbers = trimws(positional)
  )
}


load_accessions_from_file <- function(accession_file) {
  accession_file <- resolve_project_path(accession_file, PROJECT_ROOT)

  if (!file.exists(accession_file)) {
    stop("Accession file not found: ", accession_file)
  }

  file_ext <- tolower(tools::file_ext(accession_file))

  if (file_ext %in% c("csv", "tsv")) {
    sep_value <- if (file_ext == "tsv") "\t" else ","
    dt <- fread(accession_file, sep = sep_value)

    if (!"accession_number" %in% names(dt)) {
      stop("Accession file must contain a column named 'accession_number': ", accession_file)
    }

    return(list(
      accessions = dt[, unique(trimws(as.character(accession_number)))],
      metadata = dt
    ))
  }

  values <- readLines(accession_file, warn = FALSE, encoding = "UTF-8")
  values <- trimws(values)
  values <- values[nzchar(values)]

  list(
    accessions = unique(values),
    metadata = data.table(accession_number = unique(values))
  )
}


parse_accession_inputs <- function(parsed_args) {
  file_inputs <- if (nzchar(parsed_args$accession_file)) {
    load_accessions_from_file(parsed_args$accession_file)
  } else {
    list(accessions = character(), metadata = NULL)
  }

  if (exists("ACCESSION_NUMBER", inherits = FALSE) && nzchar(ACCESSION_NUMBER)) {
    accessions <- trimws(ACCESSION_NUMBER)
    return(list(
      accessions = unique(accessions[nzchar(accessions)]),
      metadata = data.table(accession_number = unique(accessions[nzchar(accessions)]))
    ))
  }

  cli_inputs <- trimws(parsed_args$accession_numbers)
  cli_inputs <- cli_inputs[nzchar(cli_inputs)]

  all_accessions <- unique(c(file_inputs$accessions, cli_inputs))

  if (length(all_accessions) == 0L) {
    stop(
      "Please provide at least one accession number.\n",
      "Example: Rscript code/main/utils/read_filings.R 0000815097-18-000005\n",
      "Batch mode: Rscript code/main/utils/read_filings.R --accession-file output/filings/suspected_accessions_top100.csv\n",
      "Optional: add --stdout to print the HTML in the terminal for a single filing."
    )
  }

  metadata <- if (!is.null(file_inputs$metadata)) {
    copy(file_inputs$metadata)
  } else {
    data.table(accession_number = all_accessions)
  }

  if (!"accession_number" %in% names(metadata)) {
    metadata[, accession_number := all_accessions]
  }
  metadata[, accession_number := trimws(as.character(accession_number))]
  metadata <- unique(metadata[accession_number %in% all_accessions], by = "accession_number")

  list(
    accessions = all_accessions,
    metadata = metadata
  )
}


load_accessions_for_cik_year <- function(cik_value, year_value, assembled_dir) {
  target_cik <- normalize_cik(cik_value)
  target_year <- normalize_year(year_value)

  if (!nzchar(target_cik) || is.na(target_year)) {
    stop("Please provide a valid --cik and --year pair.")
  }

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

  for (chunk_file in chunk_files) {
    chunk_dt <- as.data.table(readRDS(chunk_file))
    chunk_dt[, cik_match := normalize_cik(cik)]
    chunk_dt[, year_match := normalize_year(year)]

    hit <- unique(
      chunk_dt[
        cik_match == target_cik &
          year_match == target_year &
          item %in% c("item1", "item7"),
        .(
          accession_number = as.character(accession_number),
          cik = as.character(cik),
          year = as.character(year),
          form_type = if ("form_type" %in% names(chunk_dt)) as.character(form_type) else ""
        )
      ],
      by = "accession_number"
    )

    if (nrow(hit) > 0L) {
      n_matches <- n_matches + 1L
      matches[[n_matches]] <- copy(hit)
    }
  }

  if (n_matches == 0L) {
    stop(
      "No filing rows were found for CIK ", target_cik,
      " and year ", target_year, " in the assembled extract."
    )
  }

  metadata <- unique(rbindlist(matches[seq_len(n_matches)], use.names = TRUE, fill = TRUE), by = "accession_number")
  setorder(metadata, accession_number)

  if (nrow(metadata) > 1L) {
    warning(
      "Found ", nrow(metadata), " accessions for CIK ", target_cik,
      " and year ", target_year, ". Generating one HTML file per accession."
    )
  }

  list(
    accessions = metadata$accession_number,
    metadata = metadata
  )
}


parse_request_inputs <- function(parsed_args, assembled_dir) {
  has_accession_request <- nzchar(parsed_args$accession_file) || any(nzchar(parsed_args$accession_numbers))
  has_source_accession <- exists("ACCESSION_NUMBER", inherits = FALSE) && nzchar(trimws(as.character(ACCESSION_NUMBER)))

  if (has_accession_request || has_source_accession) {
    return(parse_accession_inputs(parsed_args))
  }

  cik_value <- if (exists("CIK", inherits = FALSE) && nzchar(trimws(as.character(CIK)))) {
    trimws(as.character(CIK))
  } else {
    parsed_args$cik
  }
  year_value <- if (exists("YEAR", inherits = FALSE) && nzchar(trimws(as.character(YEAR)))) {
    trimws(as.character(YEAR))
  } else {
    parsed_args$year
  }

  if (nzchar(cik_value) || nzchar(year_value)) {
    return(load_accessions_for_cik_year(cik_value, year_value, assembled_dir))
  }

  stop(
    "Please provide either accession number(s) or a --cik / --year pair.\n",
    "Examples:\n",
    "  Rscript code/main/utils/read_filings.R 0000815097-18-000005\n",
    "  Rscript code/main/utils/read_filings.R --cik 2488 --year 2019\n"
  )
}


html_escape <- function(x) {
  x <- enc2utf8(ifelse(is.na(x), "", x))
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  gsub("'", "&#39;", x, fixed = TRUE)
}


display_value <- function(x, missing = "NA") {
  x <- as.character(x)
  x[is.na(x) | !nzchar(trimws(x))] <- missing
  x
}


collapse_item_text <- function(dt, item_name) {
  item_text <- unique(dt[item == item_name & !is.na(text), text])
  item_text <- item_text[nzchar(trimws(item_text))]

  if (length(item_text) == 0L) {
    return("")
  }

  paste(item_text, collapse = "\n\n")
}


find_filing_rows <- function(accession_numbers, assembled_dir) {
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
  accession_values <- unique(accession_numbers)

  for (chunk_file in chunk_files) {
    chunk_dt <- as.data.table(readRDS(chunk_file))
    hit <- chunk_dt[
      accession_number %chin% accession_values &
        item %in% c("item1", "item7")
    ]

    if (nrow(hit) > 0L) {
      n_matches <- n_matches + 1L
      matches[[n_matches]] <- copy(hit)
    }
  }

  if (n_matches == 0L) {
    stop("None of the requested accession numbers were found in the assembled extract.")
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


filing_summary_row <- function(accession_number, filing_dt) {
  item1_text <- collapse_item_text(filing_dt, "item1")
  item7_text <- collapse_item_text(filing_dt, "item7")
  combined_text <- paste0(item1_text, item7_text)

  data.table(
    accession_number = accession_number,
    has_item1 = ifelse(nzchar(item1_text), "Yes", "No"),
    has_item7 = ifelse(nzchar(item7_text), "Yes", "No"),
    combined_chars = as.character(nchar(combined_text, type = "chars"))
  )
}


build_index_document <- function(index_dt) {
  rows_html <- paste0(
    apply(index_dt, 1, function(row) {
      sprintf(
        paste0(
          "<tr>",
          "<td><a href=\"%s\">%s</a></td>",
          "<td>%s</td>",
          "<td>%s</td>",
          "<td>%s</td>",
          "<td>%s</td>",
          "<td>%s</td>",
          "<td>%s</td>",
          "<td>%s</td>",
          "<td>%s</td>",
          "</tr>"
        ),
        html_escape(row[["html_file"]]),
        html_escape(row[["accession_number"]]),
        html_escape(row[["reason"]]),
        html_escape(row[["cik"]]),
        html_escape(row[["year"]]),
        html_escape(row[["keyword_hits"]]),
        html_escape(row[["llama_score"]]),
        html_escape(row[["has_item1"]]),
        html_escape(row[["has_item7"]]),
        html_escape(row[["combined_chars"]])
      )
    }),
    collapse = "\n"
  )

  paste0(
    "<!DOCTYPE html>\n",
    "<html lang=\"en\">\n",
    "<head>\n",
    "  <meta charset=\"utf-8\">\n",
    "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
    "  <title>Filing Batch Index</title>\n",
    "  <style>\n",
    "    body { font-family: Georgia, 'Times New Roman', serif; margin: 0; background: #f5f1e8; color: #1f2933; }\n",
    "    main { max-width: 1200px; margin: 0 auto; padding: 32px 24px 48px; }\n",
    "    .card { background: #fffdf8; border: 1px solid #d7c9a5; border-radius: 14px; padding: 20px 24px; box-shadow: 0 8px 30px rgba(31, 41, 51, 0.08); }\n",
    "    table { width: 100%; border-collapse: collapse; margin-top: 18px; }\n",
    "    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #eadfca; vertical-align: top; }\n",
    "    th { background: #f0e6d0; }\n",
    "    a { color: #8b2e16; text-decoration: none; }\n",
    "    a:hover { text-decoration: underline; }\n",
    "  </style>\n",
    "</head>\n",
    "<body>\n",
    "  <main>\n",
    "    <div class=\"card\">\n",
    "      <h1>Filing Batch Index</h1>\n",
    "      <p>Generated ", html_escape(as.character(nrow(index_dt))), " filing pages.</p>\n",
    "      <table>\n",
    "        <thead>\n",
    "          <tr><th>Accession number</th><th>Reason</th><th>CIK</th><th>Year</th><th>Keyword hits</th><th>Llama score</th><th>Has Item 1</th><th>Has Item 7</th><th>Combined chars</th></tr>\n",
    "        </thead>\n",
    "        <tbody>\n",
             rows_html, "\n",
    "        </tbody>\n",
    "      </table>\n",
    "    </div>\n",
    "  </main>\n",
    "</body>\n",
    "</html>\n"
  )
}


parsed_args <- parse_args()
accession_inputs <- parse_request_inputs(parsed_args, ASSEMBLED_DIR)
filing_rows <- find_filing_rows(accession_inputs$accessions, ASSEMBLED_DIR)

dir.create(OUTPUT_HTML_DIR, recursive = TRUE, showWarnings = FALSE)

available_accessions <- unique(filing_rows$accession_number)
missing_accessions <- setdiff(accession_inputs$accessions, available_accessions)

if (length(missing_accessions) > 0L) {
  warning(
    "Some accession numbers were not found in the assembled extract: ",
    paste(missing_accessions, collapse = ", ")
  )
}

index_dt <- unique(copy(accession_inputs$metadata), by = "accession_number")
index_dt <- index_dt[accession_number %in% available_accessions]
index_dt[, accession_number := as.character(accession_number)]

for (optional_col in c("reason", "cik", "year", "keyword_hits", "llama_score")) {
  if (!optional_col %in% names(index_dt)) {
    index_dt[, (optional_col) := ""]
  } else {
    index_dt[, (optional_col) := as.character(get(optional_col))]
  }
}

for (optional_col in c("has_item1", "has_item7", "combined_chars")) {
  if (!optional_col %in% names(index_dt)) {
    index_dt[, (optional_col) := ""]
  } else {
    index_dt[, (optional_col) := as.character(get(optional_col))]
  }
}

generated_paths <- character()

for (current_accession in available_accessions) {
  filing_dt <- filing_rows[accession_number == current_accession]
  html_doc <- build_html_document(current_accession, filing_dt)
  filing_summary <- filing_summary_row(current_accession, filing_dt)
  output_html <- file.path(
    OUTPUT_HTML_DIR,
    sprintf("filing_%s.html", gsub("[^A-Za-z0-9-]", "_", current_accession))
  )

  writeLines(html_doc, output_html, useBytes = TRUE)
  generated_paths <- c(generated_paths, normalizePath(output_html, winslash = "/", mustWork = TRUE))

  if (nrow(index_dt[accession_number == current_accession]) > 0L) {
    index_dt[accession_number == current_accession, `:=`(
      cik = ifelse(nzchar(as.character(cik)), as.character(cik), as.character(filing_dt$cik[[1]])),
      year = ifelse(nzchar(as.character(year)), as.character(year), as.character(filing_dt$year[[1]])),
      has_item1 = filing_summary$has_item1[[1]],
      has_item7 = filing_summary$has_item7[[1]],
      combined_chars = filing_summary$combined_chars[[1]]
    )]
  }

  if (isTRUE(parsed_args$print_html_to_stdout)) {
    if (length(available_accessions) > 1L) {
      warning("--stdout is intended for a single accession number. Printing only the first filing.")
      parsed_args$print_html_to_stdout <- FALSE
    } else {
      cat(html_doc)
    }
  }
}

index_dt[, html_file := sprintf("filing_%s.html", gsub("[^A-Za-z0-9-]", "_", accession_number))]
index_dt[, llama_score := display_value(llama_score, missing = "NA")]
index_dt[, keyword_hits := display_value(keyword_hits, missing = "NA")]
index_dt[, has_item1 := display_value(has_item1, missing = "No")]
index_dt[, has_item7 := display_value(has_item7, missing = "No")]
index_dt[, combined_chars := display_value(combined_chars, missing = "0")]

cat("Generated", length(generated_paths), "filing HTML files in:", OUTPUT_HTML_DIR, "\n")

if (length(generated_paths) == 1L) {
  cat("Wrote filing HTML to:", generated_paths[[1]], "\n")
} else if (length(generated_paths) > 1L) {
  batch_index_html <- file.path(OUTPUT_HTML_DIR, "filing_batch_index.html")
  batch_index_doc <- build_index_document(index_dt[order(reason, year, accession_number)])
  writeLines(batch_index_doc, batch_index_html, useBytes = TRUE)
  cat("Wrote filing batch index to:", normalizePath(batch_index_html, winslash = "/", mustWork = TRUE), "\n")
}

if (interactive() && length(generated_paths) == 1L) {
  browseURL(generated_paths[[1]])
} else if (interactive() && length(generated_paths) > 1L) {
  browseURL(normalizePath(file.path(OUTPUT_HTML_DIR, "filing_batch_index.html"), winslash = "/", mustWork = TRUE))
}
