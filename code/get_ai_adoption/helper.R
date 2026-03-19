# -------------------------
# Common Helpers
# -------------------------
decode_html_basic <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  
  x <- gsub("&#160;|&#xa0;|&nbsp;", " ", x, ignore.case = TRUE)
  x <- gsub("&#8217;|&#x2019;|&rsquo;|&apos;|&#146;", "'", x, ignore.case = TRUE)
  x <- gsub("&#8216;|&#x2018;|&lsquo;", "'", x, ignore.case = TRUE)
  x <- gsub("&#8220;|&#x201c;|&ldquo;|&#147;", "\"", x, ignore.case = TRUE)
  x <- gsub("&#8221;|&#x201d;|&rdquo;|&#148;", "\"", x, ignore.case = TRUE)
  x <- gsub("&#8211;|&#8212;|&#x2013;|&#x2014;|&ndash;|&mdash;|&#150;|&#151;", "-", x, ignore.case = TRUE)
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
  x <- gsub(" s ", " ", x, fixed = TRUE)
  x <- gsub("\\s{2,}", " ", x)
  x <- gsub("^\\s+|\\s+$", "", x)
  
  x[nzchar(x)]
}

normalize_filing_text <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  
  x <- gsub("&#160;|&nbsp;|\\xa0", " ", x, ignore.case = TRUE)
  x <- gsub("&#146;|&#8217;|&rsquo;|&apos;", "'", x, ignore.case = TRUE)
  x <- gsub("&#147;|&#148;|&#8220;|&#8221;|&ldquo;|&rdquo;", '"', x, ignore.case = TRUE)
  x <- gsub("&#151;|&#8212;|&mdash;|&#150;|&#8211;|&ndash;", "-", x, ignore.case = TRUE)
  x <- gsub("&amp;", "&", x, ignore.case = TRUE)
  x <- gsub("&lt;", "<", x, ignore.case = TRUE)
  x <- gsub("&gt;", ">", x, ignore.case = TRUE)
  x <- gsub("&quot;", '"', x, ignore.case = TRUE)
  x <- gsub("&rsquo;|&lsquo;", "'", x, ignore.case = TRUE)
  x <- gsub("&ldquo;|&rdquo;", '"', x, ignore.case = TRUE)
  x <- gsub("&mdash;|&ndash;", "-", x, ignore.case = TRUE)
  
  # fallback support if parsing fails
  x <- gsub("<[^>]+>", " ", x)
  
  x <- gsub("[[:space:]]+", " ", x)
  x <- gsub("^\\s+|\\s+$", "", x)
  
  x
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
  
  standalone_item <- grepl(
    "^ITEM\\s{0,}\\d{1,}[A-Z]{0,1}\\.?\\s*$|^ITEM\\s{0,}1\\s*(AND|&)\\s*2\\.?\\s*$",
    x,
    ignore.case = TRUE
  )
  
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
      n_words - 200 * heading_ratio
    },
    numeric(1)
  )
  
  keep <- which.max(pairs$body_words)
  
  list(
    startline = pairs$startline[keep],
    endline = pairs$endline[keep]
  )
}

is_probable_toc_line <- function(x) {
  grepl("see\\s+[\"']?item\\s*[0-9]", x, ignore.case = TRUE, perl = TRUE) |
    grepl("table of contents", x, ignore.case = TRUE, perl = TRUE) |
    grepl("item\\s*1.*item\\s*1a.*item\\s*3", x, ignore.case = TRUE, perl = TRUE) |
    grepl("item\\s*7.*financial condition.*results of operations.*\\.{2,}\\s*\\d*$", x, ignore.case = TRUE, perl = TRUE) |
    grepl("item\\s*1.*business.*\\.{2,}\\s*\\d*$", x, ignore.case = TRUE, perl = TRUE) |
    grepl("item\\s*[0-9]+[a-z]?(\\.|\\b).*(item\\s*[0-9]+[a-z]?(\\.|\\b))", x, ignore.case = TRUE, perl = TRUE)
}