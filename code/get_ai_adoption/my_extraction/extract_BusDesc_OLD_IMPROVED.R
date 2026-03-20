# =========================================================
# IMPROVED LOCAL BUSINESS DESCRIPTION EXTRACTION
# Logic remains aligned to Gunratan/edgar getBusinessDescr
# but text normalization and heading detection are stronger
# for HTML / XML filings parsed from local raw files.
# =========================================================

extract_BusDesc <- function(dest, out_dir = "edgar_BusDesc", min_words = 100L) {
  if (!file.exists(dest)) {
    stop("File does not exist: ", dest)
  }
  
  if (!dir.exists(out_dir)) {
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  }
  
  if (!requireNamespace("stringr", quietly = TRUE)) {
    stop("Package 'stringr' is required. Install it with install.packages('stringr').")
  }
  
  if (!requireNamespace("XML", quietly = TRUE)) {
    stop("Package 'XML' is required. Install it with install.packages('XML').")
  }
  
  base_name <- tools::file_path_sans_ext(basename(dest))
  
  # -------------------------
  # Helpers
  # -------------------------
  decode_html_basic <- function(x) {
    x <- as.character(x)
    x[is.na(x)] <- ""
    
    x <- gsub("&#160;|&#xa0;|&nbsp;", " ", x, ignore.case = TRUE)
    x <- gsub("&#8217;|&#x2019;|&rsquo;|&apos;", "'", x, ignore.case = TRUE)
    x <- gsub("&#8216;|&#x2018;|&lsquo;", "'", x, ignore.case = TRUE)
    x <- gsub("&#8220;|&#x201c;|&ldquo;", "\"", x, ignore.case = TRUE)
    x <- gsub("&#8221;|&#x201d;|&rdquo;", "\"", x, ignore.case = TRUE)
    x <- gsub("&#8211;|&#8212;|&#x2013;|&#x2014;|&ndash;|&mdash;", "-", x, ignore.case = TRUE)
    x <- gsub("&#38;|&amp;", "&", x, ignore.case = TRUE)
    x <- gsub("&#9;|&#10;|&#13;", " ", x, ignore.case = TRUE)
    
    x
  }
  
  normalize_text_vec <- function(x) {
    x <- decode_html_basic(x)
    x <- iconv(x, from = "", to = "ASCII//TRANSLIT", sub = " ")
    x[is.na(x)] <- ""
    
    x <- gsub("\u00A0", " ", x, fixed = TRUE)
    x <- gsub("[\r\n\t]", " ", x)
    x <- gsub("\\s{2,}", " ", x)
    x <- gsub("^\\s+|\\s+$", "", x)
    
    # keep close to original Business extractor
    x <- gsub("\\/", " ", x)
    x <- gsub("Items", "Item", x, ignore.case = TRUE)
    x <- gsub("PART I", "", x, ignore.case = TRUE)
    x <- gsub("Item III", "Item 3", x, ignore.case = TRUE)
    x <- gsub("Item II", "Item 2", x, ignore.case = TRUE)
    x <- gsub("Item I|Item l", "Item 1", x, ignore.case = TRUE)
    x <- gsub(":|\\*", "", x)
    x <- gsub("-", " ", x)
    x <- gsub("\\bONE\\b", "1", x, ignore.case = TRUE)
    x <- gsub("\\bTWO\\b", "2", x, ignore.case = TRUE)
    x <- gsub("\\bTHREE\\b", "3", x, ignore.case = TRUE)
    x <- gsub("1\\s{0,}\\.", "1", x)
    x <- gsub("2\\s{0,}\\.", "2", x)
    x <- gsub("3\\s{0,}\\.", "3", x)
    x <- gsub("\\s{2,}", " ", x)
    x <- gsub("^\\s+|\\s+$", "", x)
    
    x[nzchar(x)]
  }
  
  extract_text_nodes <- function(filing.text) {
    if (any(grepl("<xml>|<type>xml|<html>|10k\\.htm", filing.text, ignore.case = TRUE))) {
      txt <- tryCatch(
        {
          doc <- XML::htmlParse(
            filing.text,
            asText = TRUE,
            useInternalNodes = TRUE,
            addFinalizer = FALSE
          )
          
          XML::xpathSApply(
            doc,
            "//text()[not(ancestor::script)][not(ancestor::style)][not(ancestor::noscript)][not(ancestor::form)]",
            XML::xmlValue
          )
        },
        error = function(e) filing.text
      )
    } else {
      txt <- filing.text
    }
    
    normalize_text_vec(txt)
  }
  
  merge_item_heading_lines <- function(x) {
    if (length(x) <= 1L) return(x)
    
    standalone_item <- grepl("^ITEM\\s{0,}\\d{1,}[A-Z]{0,1}\\.?\\s*$|^ITEM\\s{0,}1\\s+AND\\s+2\\.?\\s*$",
                             x, ignore.case = TRUE)
    
    idx <- which(standalone_item & seq_along(x) < length(x))
    if (length(idx)) {
      x[idx + 1L] <- paste(x[idx], x[idx + 1L])
      x[idx] <- ""
    }
    
    x <- x[nzchar(x)]
    x
  }
  
  heading_like <- function(x) {
    grepl("^ITEM\\s{0,}[0-9]+[A-Z]{0,1}\\b", x, ignore.case = TRUE)
  }
  
  choose_best_pair <- function(startline, endline, f.text) {
    startline <- as.integer(startline)
    endline <- as.integer(endline)
    
    startline <- startline[!is.na(startline)]
    endline <- endline[!is.na(endline)]
    
    if (!length(startline) || !length(endline)) {
      return(list(startline = integer(), endline = integer()))
    }
    
    pairs <- expand.grid(
      startline = startline,
      endline = endline,
      KEEP.OUT.ATTRS = FALSE,
      stringsAsFactors = FALSE
    )
    
    pairs <- pairs[pairs$endline > pairs$startline, , drop = FALSE]
    if (!nrow(pairs)) {
      return(list(startline = integer(), endline = integer()))
    }
    
    pairs$span <- pairs$endline - pairs$startline
    
    pairs$body_words <- vapply(
      seq_len(nrow(pairs)),
      function(i) {
        s <- pairs$startline[i]
        e <- pairs$endline[i]
        body <- f.text[s:min(e - 1L, length(f.text))]
        
        # penalize obvious TOC-like spans
        heading_ratio <- mean(heading_like(body))
        n_words <- stringr::str_count(paste(body, collapse = " "), "\\S+")
        
        score <- n_words - 200 * heading_ratio
        as.numeric(score)
      },
      numeric(1)
    )
    
    keep <- which.max(pairs$body_words)
    
    list(
      startline = pairs$startline[keep],
      endline = pairs$endline[keep]
    )
  }
  
  # -------------------------
  # Read filing
  # -------------------------
  filing.text <- tryCatch(
    readLines(dest, warn = FALSE, encoding = "UTF-8"),
    error = function(e) readLines(dest, warn = FALSE)
  )
  
  if (!length(filing.text)) {
    return(NA_character_)
  }
  
  # first DOCUMENT block only, same broad approach as original
  doc_start <- grep("<DOCUMENT>", filing.text, ignore.case = TRUE)[1]
  doc_end   <- grep("</DOCUMENT>", filing.text, ignore.case = TRUE)[1]
  if (!is.na(doc_start) && !is.na(doc_end) && doc_start < doc_end) {
    filing.text <- filing.text[doc_start:doc_end]
  }
  
  f.text <- extract_text_nodes(filing.text)
  f.text <- merge_item_heading_lines(f.text)
  
  if (!length(f.text)) {
    return(NA_character_)
  }
  
  # -------------------------
  # Heading detection
  # Keep original logic, just make regex more tolerant
  # -------------------------
  startline <- grep(
    "^ITEM\\s{0,}1\\s{0,}(BUSINESS|DESCRIPTION OF BUSINESS)\\b",
    f.text,
    ignore.case = TRUE
  )
  
  endline <- grep(
    "^ITEM\\s{0,}2\\s{0,}(PROPERTIES|DESCRIPTION OF PROPERTY|REAL ESTATE)\\b",
    f.text,
    ignore.case = TRUE
  )
  
  # keep original fallback concept
  if (length(startline) == 0L && length(endline) == 0L) {
    startline <- grep(
      "^ITEM\\s{0,}1\\s{0,}(AND|&)\\s{0,}2\\s{0,}(BUSINESS AND PROPERTIES|BUSINESS AND DESCRIPTION OF PROPERTY)\\b",
      f.text,
      ignore.case = TRUE
    )
    
    endline <- grep(
      "^ITEM\\s{0,}3\\s{0,}(LEGAL PROCEEDINGS|LEGAL MATTERS)\\b",
      f.text,
      ignore.case = TRUE
    )
  }
  
  pair <- choose_best_pair(startline, endline, f.text)
  startline <- pair$startline
  endline <- pair$endline
  
  product.descr <- NA_character_
  words.count <- 0L
  
  if (length(startline) && length(endline)) {
    product.descr <- paste(f.text[startline:endline], collapse = " ")
    product.descr <- gsub("\\s{2,}", " ", product.descr)
    product.descr <- gsub("\\.\\s*ITEM\\s{0,}2\\b.*$", ".", product.descr, ignore.case = TRUE)
    words.count <- stringr::str_count(product.descr, "\\S+")
  }
  
  if (!is.na(product.descr) && words.count > min_words) {
    out_file <- file.path(out_dir, paste0(base_name, "_BusDesc.txt"))
    writeLines(product.descr, out_file, useBytes = TRUE)
    return(out_file)
  }
  
  return(NA_character_)
}