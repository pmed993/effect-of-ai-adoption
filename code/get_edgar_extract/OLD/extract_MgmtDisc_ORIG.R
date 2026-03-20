# Take logic from below and create function that extracts from file instead
# https://github.com/GunratanedgarblobmasterRgetBusinessDescr.R
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
  
  base_name <- tools::file_path_sans_ext(basename(dest))
  
  # -------------------------------------------------
  # Read filing
  # -------------------------------------------------
  filing.text <- tryCatch(
    readLines(dest, warn = FALSE, encoding = "UTF-8"),
    error = function(e) readLines(dest, warn = FALSE)
  )
  
  if (length(filing.text) == 0L) {
    return(NA_character_)
  }
  
  # -------------------------------------------------
  # Extract data from first <DOCUMENT> to </DOCUMENT>
  # Keep original Edgar package behaviour as closely as possible
  # -------------------------------------------------
  tryCatch({
    doc_start <- grep("<DOCUMENT>", filing.text, ignore.case = TRUE)[1]
    doc_end   <- grep("</DOCUMENT>", filing.text, ignore.case = TRUE)[1]
    
    if (!is.na(doc_start) && !is.na(doc_end) && doc_start <= doc_end) {
      filing.text <- filing.text[doc_start:doc_end]
    }
  }, error = function(e) {
    filing.text <<- filing.text
  })
  
  # -------------------------------------------------
  # See if filing is in XML/HTML format
  # -------------------------------------------------
  if (any(grepl(pattern = "<xml>|<type>xml|<html>|10k\\.htm", filing.text, ignore.case = TRUE))) {
    if (!requireNamespace("XML", quietly = TRUE)) {
      stop("Package 'XML' is required. Install it with install.packages('XML').")
    }
    
    f.text <- tryCatch(
      {
        doc <- XML::htmlParse(
          filing.text,
          asText = TRUE,
          useInternalNodes = TRUE,
          addFinalizer = FALSE
        )
        
        txt <- XML::xpathSApply(
          doc,
          "//text()[not(ancestor::script)][not(ancestor::style)][not(ancestor::noscript)][not(ancestor::form)]",
          XML::xmlValue
        )
        
        iconv(txt, "latin1", "ASCII", sub = " ")
      },
      error = function(e) filing.text
    )
  } else {
    f.text <- filing.text
  }
  
  # -------------------------------------------------
  # Preprocessing kept close to original
  # -------------------------------------------------
  f.text <- as.character(f.text)
  f.text[is.na(f.text)] <- ""
  
  f.text <- gsub("\\n|\\t|$", " ", f.text)
  f.text <- gsub("^\\s{1,}", "", f.text)
  f.text <- gsub(" s ", " ", f.text)
  
  empty.lnumbers <- grep("^\\s*$", f.text)
  if (length(empty.lnumbers) > 0) {
    f.text <- f.text[-empty.lnumbers]
  }
  
  if (length(f.text) == 0L) {
    return(NA_character_)
  }
  
  # -------------------------------------------------
  # Infer form type from filename
  # Keep standard logic:
  # 10-K / 10-K405 => Item 7 to Item 7A or Item 8
  # 10KSB / 10KSB40 => Item 6 to Item 7
  # -------------------------------------------------
  form_guess <- toupper(base_name)
  
  if (grepl("10KSB40|10KSB", form_guess)) {
    f.type <- "10KSB"
  } else if (grepl("10-K405", form_guess)) {
    f.type <- "10-K405"
  } else {
    f.type <- "10-K"
  }
  
  # -------------------------------------------------
  # Helper to choose the pair covering the most lines
  # but only among valid end > start combinations
  # This preserves the original "largest span" idea,
  # while making it safe.
  # -------------------------------------------------
  choose_largest_valid_pair <- function(startline, endline) {
    startline <- as.integer(startline)
    endline <- as.integer(endline)
    
    startline <- startline[!is.na(startline)]
    endline <- endline[!is.na(endline)]
    
    if (length(startline) == 0L || length(endline) == 0L) {
      return(list(startline = integer(), endline = integer()))
    }
    
    pairs <- expand.grid(
      startline = startline,
      endline = endline,
      KEEP.OUT.ATTRS = FALSE,
      stringsAsFactors = FALSE
    )
    
    pairs <- pairs[pairs$endline > pairs$startline, , drop = FALSE]
    
    if (nrow(pairs) == 0L) {
      return(list(startline = integer(), endline = integer()))
    }
    
    pairs$span <- pairs$endline - pairs$startline
    keep <- which.max(pairs$span)
    
    list(
      startline = pairs$startline[keep],
      endline = pairs$endline[keep]
    )
  }
  
  # -------------------------------------------------
  # Get MD&A sections
  # Logic kept aligned with Edgar package
  # -------------------------------------------------
  if (f.type %in% c("10-K", "10-K405")) {
    
    startline <- grep("^Item\\s{0,}7\\.{0,}[^A.|\\(A\\)]", f.text, ignore.case = TRUE)
    endline <- grep("^Item\\s{0,}7\\.{0,}(A|\\(A\\)|\\.A)", f.text, ignore.case = TRUE)
    
    # If no Item 7A, then take up to Item 8
    # Also fallback to Item 8 if Item 7A matching is structurally unsafe
    use_item8 <- FALSE
    
    if (length(endline) == 0L) {
      use_item8 <- TRUE
    } else {
      valid_pairs_7a <- choose_largest_valid_pair(startline, endline)
      if (length(valid_pairs_7a$startline) == 0L || length(valid_pairs_7a$endline) == 0L) {
        use_item8 <- TRUE
      }
    }
    
    if (use_item8) {
      endline <- grep("^Item\\s{0,}8", f.text, ignore.case = TRUE)
    }
    
    # If more than one match, use the pair with the largest span
    if (length(startline) >= 1L && length(endline) >= 1L) {
      pair <- choose_largest_valid_pair(startline, endline)
      startline <- pair$startline
      endline <- pair$endline
    }
    
  } else {
    
    startline <- grep("^Item\\s{0,}6", f.text, ignore.case = TRUE)
    endline <- grep("^Item\\s{0,}7", f.text, ignore.case = TRUE)
    
    if (length(startline) >= 1L && length(endline) >= 1L) {
      pair <- choose_largest_valid_pair(startline, endline)
      startline <- pair$startline
      endline <- pair$endline
    }
  }
  
  # -------------------------------------------------
  # Build extracted section
  # -------------------------------------------------
  md.discussion <- NA_character_
  words.count <- 0L
  
  if (length(startline) != 0L && length(endline) != 0L) {
    startline <- startline[length(startline)]
    endline <- endline[length(endline)] - 1L
    
    if (!is.na(startline) && !is.na(endline) && startline < endline) {
      md.discussion <- paste(f.text[startline:endline], collapse = " ")
      md.discussion <- gsub("\\s{2,}", " ", md.discussion)
      words.count <- stringr::str_count(md.discussion, pattern = "\\S+")
    }
  }
  
  if (!is.na(md.discussion) && words.count > min_words) {
    out_file <- file.path(out_dir, paste0(base_name, "_MgmtDisc.txt"))
    writeLines(md.discussion, out_file, useBytes = TRUE)
    return(out_file)
  }
  
  return(NA_character_)
}