# =========================================================
# IMPROVED LOCAL MD&A EXTRACTION
# Logic remains aligned to Gunratan/edgar getMgmtDisc
# but text normalization and heading detection are stronger
# for HTML / XML filings parsed from local raw files.
# =========================================================

mgmt_start_patterns <- c(
  "^ITEM\\s*7\\s*[\\.:\\-]?\\s*MANAGEMENT(?:['’`]S)?\\s+DISCUSSION\\s+AND\\s+ANALYSIS\\b",
  "^ITEM\\s*7\\s*[\\.:\\-]?$",
  "^MANAGEMENT(?:['’`]S)?\\s+DISCUSSION\\s+AND\\s+ANALYSIS\\b"
)

mgmt_end_patterns <- c(
  "^ITEM\\s*7A\\s*[\\.:\\-]?",
  "^ITEM\\s*8\\s*[\\.:\\-]?"
)

extract_MgmtDisc <- function(dest, out_dir = "edgar_MgmtDisc", min_words = 100L) {
  if (!file.exists(dest)) stop("File does not exist: ", dest)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  if (!requireNamespace("stringr", quietly = TRUE)) stop("Package 'stringr' is required.")
  if (!requireNamespace("XML", quietly = TRUE)) stop("Package 'XML' is required.")
  
  base_name <- tools::file_path_sans_ext(basename(dest))
  
  filing.text <- tryCatch(
    readLines(dest, warn = FALSE, encoding = "UTF-8"),
    error = function(e) readLines(dest, warn = FALSE)
  )
  
  if (!length(filing.text)) return(NA_character_)
  
  tryCatch({
    doc_start <- grep("<DOCUMENT>", filing.text, ignore.case = TRUE)[1]
    doc_end   <- grep("</DOCUMENT>", filing.text, ignore.case = TRUE)[1]
    if (!is.na(doc_start) && !is.na(doc_end) && doc_start <= doc_end) {
      filing.text <- filing.text[doc_start:doc_end]
    }
  }, error = function(e) {
    filing.text <<- filing.text
  })
  
  f.text <- extract_text_nodes(filing.text)
  f.text <- merge_item_heading_lines(f.text)
  f.text <- normalize_filing_text(f.text)
  f.text <- f.text[nzchar(f.text)]
  
  if (!length(f.text)) return(NA_character_)
  
  form_guess <- toupper(base_name)
  
  if (grepl("10KSB40|10KSB", form_guess)) {
    f.type <- "10KSB"
  } else if (grepl("10-K405", form_guess)) {
    f.type <- "10-K405"
  } else {
    f.type <- "10-K"
  }
  
  if (f.type %in% c("10-K", "10-K405")) {
    startline <- unique(unlist(lapply(
      mgmt_start_patterns,
      function(p) grep(p, f.text, ignore.case = TRUE, perl = TRUE)
    )))
    
    endline <- unique(unlist(lapply(
      mgmt_end_patterns,
      function(p) grep(p, f.text, ignore.case = TRUE, perl = TRUE)
    )))
    
    startline <- startline[!is_probable_toc_line(f.text[startline])]
    endline   <- endline[!is_probable_toc_line(f.text[endline])]
    
    startline <- startline[
      startline > round(length(f.text) * 0.03) |
        grepl("business|management|discussion|analysis", f.text[startline], ignore.case = TRUE)
    ]
    
    use_item8 <- FALSE
    
    if (length(endline) == 0L) {
      use_item8 <- TRUE
    } else {
      valid_pairs_7a <- choose_largest_valid_pair(startline, endline, f.text)
      if (length(valid_pairs_7a$startline) == 0L || length(valid_pairs_7a$endline) == 0L) {
        use_item8 <- TRUE
      }
    }
    
    if (use_item8) {
      endline <- grep("^ITEM\\s{0,}8\\b", f.text, ignore.case = TRUE)
    }
    
    pair <- choose_largest_valid_pair(startline, endline, f.text)
    startline <- pair$startline
    endline <- pair$endline
    
  } else {
    startline <- grep("^ITEM\\s{0,}6\\b", f.text, ignore.case = TRUE)
    endline   <- grep("^ITEM\\s{0,}7\\b", f.text, ignore.case = TRUE)
    
    pair <- choose_largest_valid_pair(startline, endline, f.text)
    startline <- pair$startline
    endline <- pair$endline
  }
  
  md.discussion <- NA_character_
  words.count <- 0L
  
  if (length(startline) && length(endline)) {
    s <- startline[1]
    e <- endline[1] - 1L
    
    if (!is.na(s) && !is.na(e) && s < e) {
      md.discussion <- paste(f.text[s:e], collapse = " ")
      md.discussion <- gsub("\\s{2,}", " ", md.discussion)
      words.count <- stringr::str_count(md.discussion, "\\S+")
    }
  }
  
  if (!is.na(md.discussion) && words.count > min_words) {
    out_file <- file.path(out_dir, paste0(base_name, "_MgmtDisc.txt"))
    writeLines(md.discussion, out_file, useBytes = TRUE)
    return(out_file)
  }
  
  NA_character_
}