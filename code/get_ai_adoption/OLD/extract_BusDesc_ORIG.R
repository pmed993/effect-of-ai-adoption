# Take logic from below and create function that extracts from file instead
# https://github.com/GunratanedgarblobmasterRgetBusinessDescr.R
extract_BusDesc <- function(dest, out_dir = "edgar_BusDesc", min_words = 100L) {
  if (!file.exists(dest)) {
    stop("File does not exist: ", dest)
  }
  
  if (!dir.exists(out_dir)) {
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  }
  
  filing.text <- readLines(dest, warn = FALSE, encoding = "UTF-8")
  
  # Extract from first <DOCUMENT> to first </DOCUMENT> if present
  doc_start <- grep("<DOCUMENT>", filing.text, ignore.case = TRUE)[1]
  doc_end   <- grep("</DOCUMENT>", filing.text, ignore.case = TRUE)[1]
  
  if (!is.na(doc_start) && !is.na(doc_end) && doc_start < doc_end) {
    filing.text <- filing.text[doc_start:doc_end]
  }
  
  # Parse HTML/XML if needed
  if (any(grepl("<xml>|<type>xml|<html>|10k\\.htm", filing.text, ignore.case = TRUE))) {
    if (!requireNamespace("XML", quietly = TRUE)) {
      stop("Package 'XML' is required. Install it with install.packages('XML').")
    }
    
    doc <- XML::htmlParse(
      filing.text,
      asText = TRUE,
      useInternalNodes = TRUE,
      addFinalizer = FALSE
    )
    
    f.text <- XML::xpathSApply(
      doc,
      "//text()[not(ancestor::script)][not(ancestor::style)][not(ancestor::noscript)][not(ancestor::form)]",
      XML::xmlValue
    )
    
    f.text <- iconv(f.text, "latin1", "ASCII", sub = " ")
  } else {
    f.text <- filing.text
  }
  
  # Preprocessing kept close to original
  f.text <- gsub("\\n|\\t", " ", f.text)
  f.text <- gsub("\\s{2,}|\\/", " ", f.text)
  f.text <- gsub("^\\s{1,}", "", f.text)
  f.text <- gsub(" s ", " ", f.text)
  
  f.text <- gsub("Items", "Item", f.text, ignore.case = TRUE)
  f.text <- gsub("PART I", "", f.text, ignore.case = TRUE)
  f.text <- gsub("Item III", "Item 3", f.text, ignore.case = TRUE)
  f.text <- gsub("Item II", "Item 2", f.text, ignore.case = TRUE)
  f.text <- gsub("Item I|Item l", "Item 1", f.text, ignore.case = TRUE)
  f.text <- gsub(":|\\*", "", f.text, ignore.case = TRUE)
  f.text <- gsub("-", " ", f.text)
  f.text <- gsub("ONE", "1", f.text, ignore.case = TRUE)
  f.text <- gsub("TWO", "2", f.text, ignore.case = TRUE)
  f.text <- gsub("THREE", "3", f.text, ignore.case = TRUE)
  f.text <- gsub("1\\s{0,}\\.", "1", f.text)
  f.text <- gsub("2\\s{0,}\\.", "2", f.text)
  f.text <- gsub("3\\s{0,}\\.", "3", f.text)
  
  empty.lnumbers <- grep("^\\s*$", f.text)
  if (length(empty.lnumbers) > 0) {
    f.text <- f.text[-empty.lnumbers]
  }
  
  item.lnumbers <- grep(
    "^ITEM\\s{0,}\\d{0,}\\s{0,}$|^ITEM\\s{0,}1 and 2\\s{0,}$",
    f.text,
    ignore.case = TRUE
  )
  
  valid_idx <- item.lnumbers[item.lnumbers < length(f.text)]
  f.text[valid_idx + 1] <- paste0(f.text[valid_idx], " ", f.text[valid_idx + 1])
  
  startline <- grep(
    "^Item\\s{0,}1\\s{0,}Business\\s{0,}\\.{0,1}\\s{0,}$|^Item\\s{0,}1\\s{0,}DESCRIPTION OF BUSINESS\\s{0,}\\.{0,1}\\s{0,}$",
    f.text,
    ignore.case = TRUE
  )
  
  endline <- grep(
    "^Item\\s{0,}2\\s{0,}Properties\\s{0,}\\.{0,1}\\s{0,}$|Item\\s{0,}2\\s{0,}DESCRIPTION OF PROPERTY\\s{0,}\\.{0,1}\\s{0,}$|^Item\\s{0,}2\\s{0,}REAL ESTATE\\s{0,}\\.{0,1}\\s{0,}$",
    f.text,
    ignore.case = TRUE
  )
  
  # Important: keep original fallback condition exactly
  if (length(startline) == 0 && length(endline) == 0) {
    startline <- grep(
      "^Item\\s{0,}1 and 2\\s{1,}Business AND PROPERTIES\\s{0,}\\.{0,1}\\s{0,}$|^Item\\s{0,}1 and 2\\s{1,}Business and Description of Property\\s{0,}\\.{0,1}\\s{0,}$",
      f.text,
      ignore.case = TRUE
    )
    
    endline <- grep(
      "^Item\\s{0,}3\\s{1,}LEGAL PROCEEDINGS\\s{0,}\\.{0,1}\\s{0,}$|^Item\\s{0,}3\\s{1,}LEGAL matters\\s{0,}\\.{0,1}\\s{0,}$",
      f.text,
      ignore.case = TRUE
    )
  }
  
  product.descr <- NA_character_
  words.count <- 0L
  
  if (length(startline) != 0 && length(endline) != 0) {
    if (length(startline) == length(endline)) {
      product.descr <- character(length(startline))
      for (l in seq_along(startline)) {
        product.descr[l] <- paste(f.text[startline[l]:endline[l]], collapse = " ")
      }
    } else {
      startline <- startline[length(startline)]
      endline <- endline[length(endline)]
      product.descr <- paste(f.text[startline:endline], collapse = " ")
    }
    
    product.descr <- gsub("\\s{2,}", " ", product.descr)
    words.count <- stringr::str_count(product.descr, pattern = "\\S+")
    product.descr <- product.descr[which(words.count == max(words.count))]
    product.descr <- gsub("\\. Item 2 .*", ".", product.descr)
  }
  
  if (!is.na(product.descr) && max(words.count) > min_words) {
    out_file <- file.path(
      out_dir,
      paste0(tools::file_path_sans_ext(basename(dest)), "_BusDesc.txt")
    )
    writeLines(product.descr, out_file, useBytes = TRUE)
    return(out_file)
  }
  
  return(NA_character_)
}

