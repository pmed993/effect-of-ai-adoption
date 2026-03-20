# =========================================================
# IMPROVED LOCAL BUSINESS DESCRIPTION EXTRACTION
# Logic remains aligned to Gunratan/edgar getBusinessDescr
# but text normalization and heading detection are stronger
# for HTML / XML filings parsed from local raw files.
# =========================================================

bus_start_patterns <- c(
  "^ITEM\\s*1\\s*[\\.:\\-]?\\s*BUSINESS\\b",
  "^ITEM\\s*1\\s*[\\.:\\-]?\\s*DESCRIPTION OF BUSINESS\\b",
  "^ITEM\\s*1\\s*[\\.:\\-]?\\s*OUR BUSINESS\\b",
  "^OUR BUSINESS\\b$",
  "^BUSINESS\\b$",
  "^ITEM\\s*1\\s*[\\.:\\-]?$"
)

bus_end_patterns <- c(
  "^ITEM\\s*1A\\s*[\\.:\\-]?\\s*RISK FACTORS\\b",
  "^ITEM\\s*2\\s*[\\.:\\-]?\\s*PROPERTIES\\b",
  "^ITEM\\s*2\\s*[\\.:\\-]?\\s*DESCRIPTION OF PROPERTY\\b",
  "^ITEM\\s*2\\s*[\\.:\\-]?\\s*REAL ESTATE\\b",
  "^ITEM\\s*3\\s*[\\.:\\-]?\\s*LEGAL PROCEEDINGS\\b"
)

extract_BusDesc <- function(dest, out_dir = "edgar_BusDesc", min_words = 100L) {
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
  
  doc_start <- grep("<DOCUMENT>", filing.text, ignore.case = TRUE)[1]
  doc_end   <- grep("</DOCUMENT>", filing.text, ignore.case = TRUE)[1]
  if (!is.na(doc_start) && !is.na(doc_end) && doc_start < doc_end) {
    filing.text <- filing.text[doc_start:doc_end]
  }
  
  f.text <- extract_text_nodes(filing.text)
  f.text <- merge_item_heading_lines(f.text)
  f.text <- normalize_filing_text(f.text)
  f.text <- f.text[nzchar(f.text)]
  
  if (!length(f.text)) return(NA_character_)
  
  startline <- unique(unlist(lapply(
    bus_start_patterns,
    function(p) grep(p, f.text, ignore.case = TRUE, perl = TRUE)
  )))
  
  endline <- unique(unlist(lapply(
    bus_end_patterns,
    function(p) grep(p, f.text, ignore.case = TRUE, perl = TRUE)
  )))
  
  startline <- startline[!is_probable_toc_line(f.text[startline])]
  endline   <- endline[!is_probable_toc_line(f.text[endline])]
  
  startline <- startline[
    startline > round(length(f.text) * 0.03) |
      grepl("business|management|discussion|analysis", f.text[startline], ignore.case = TRUE)
  ]
  
  if (length(startline) == 0L && length(endline) == 0L) {
    startline <- grep(
      "^ITEM\\s{0,}1\\s{0,}(AND|&)\\s{0,}2\\s{0,}(BUSINESS AND PROPERTIES|BUSINESS AND DESCRIPTION OF PROPERTY)\\b",
      f.text,
      ignore.case = TRUE
    )
    
    endline <- unique(unlist(lapply(
      bus_end_patterns,
      function(p) grep(p, f.text, ignore.case = TRUE, perl = TRUE)
    )))
  }
  
  pair <- choose_largest_valid_pair(startline, endline, f.text)
  startline <- pair$startline
  endline <- pair$endline
  
  product.descr <- NA_character_
  words.count <- 0L
  
  if (length(startline) && length(endline)) {
    s <- startline[1]
    e <- endline[1]
    product.descr <- paste(f.text[s:e], collapse = " ")
    product.descr <- gsub("\\s{2,}", " ", product.descr)
    product.descr <- gsub("\\.\\s*ITEM\\s{0,}(1A|2|3)\\b.*$", ".", product.descr, ignore.case = TRUE)
    words.count <- stringr::str_count(product.descr, "\\S+")
  }
  
  if (!is.na(product.descr) && words.count > min_words) {
    out_file <- file.path(out_dir, paste0(base_name, "_BusDesc.txt"))
    writeLines(product.descr, out_file, useBytes = TRUE)
    return(out_file)
  }
  
  NA_character_
}