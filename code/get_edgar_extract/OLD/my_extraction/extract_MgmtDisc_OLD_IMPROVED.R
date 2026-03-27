# =========================================================
# IMPROVED LOCAL MD&A EXTRACTION
# Logic remains aligned to Gunratan/edgar getMgmtDisc
# but text normalization and heading detection are stronger
# for HTML / XML filings parsed from local raw files.
# =========================================================

extract_MgmtDisc <- function(dest, out_dir = "edgar_MgmtDisc", min_words = 100L) {
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
    
    # stay close to original mgmt extractor
    x <- gsub("^\\s{1,}", "", x)
    x <- gsub(" s ", " ", x, fixed = TRUE)
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
    
    standalone_item <- grepl("^ITEM\\s{0,}\\d{1,}[A-Z]{0,1}\\.?\\s*$", x, ignore.case = TRUE)
    idx <- which(standalone_item & seq_along(x) < length(x))
    
    if (length(idx)) {
      x[idx + 1L] <- paste(x[idx], x[idx + 1L])
      x[idx] <- ""
    }
    
    x[nzchar(x)]
  }
  
  heading_like <- function(x) {
    grepl("^ITEM\\s{0,}[0-9]+[A-Z]{0,1}\\b", x, ignore.case = TRUE)
  }
  
  choose_largest_valid_pair <- function(startline, endline, f.text) {
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
    
    pairs$body_words <- vapply(
      seq_len(nrow(pairs)),
      function(i) {
        s <- pairs$startline[i]
        e <- pairs$endline[i]
        body <- f.text[s:min(e - 1L, length(f.text))]
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
  
  # same broad behaviour as Edgar package
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
  
  if (!length(f.text)) {
    return(NA_character_)
  }
  
  # -------------------------
  # Infer form type from filename
  # same idea as original
  # -------------------------
  form_guess <- toupper(base_name)
  
  if (grepl("10KSB40|10KSB", form_guess)) {
    f.type <- "10KSB"
  } else if (grepl("10-K405", form_guess)) {
    f.type <- "10-K405"
  } else {
    f.type <- "10-K"
  }
  
  # -------------------------
  # Section detection
  # keep same structure as original
  # -------------------------
  if (f.type %in% c("10-K", "10-K405")) {
    
    startline <- grep(
      "^ITEM\\s{0,}7\\b",
      f.text,
      ignore.case = TRUE
    )
    
    # more tolerant 7A detection
    endline <- grep(
      "^ITEM\\s{0,}7\\s{0,}(A|\\(A\\)|\\.A)\\b|^ITEM\\s{0,}7A\\b",
      f.text,
      ignore.case = TRUE
    )
    
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
  
  # -------------------------
  # Build section
  # -------------------------
  md.discussion <- NA_character_
  words.count <- 0L
  
  if (length(startline) && length(endline)) {
    s <- startline[length(startline)]
    e <- endline[length(endline)] - 1L
    
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
  
  return(NA_character_)
}