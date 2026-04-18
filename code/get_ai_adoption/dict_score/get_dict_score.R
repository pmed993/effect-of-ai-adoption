#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(stringi)
  library(tools)
})

# ============================================================
# CONFIG
# ============================================================
# Override at runtime with:
#   GET_AI_ADOPTION_ROOT=/path/to/get_ai_adoption Rscript get_disc_score_QA.R
ROOT_DIR <- normalizePath(
  path.expand(Sys.getenv("GET_AI_ADOPTION_ROOT", unset = "~/get_ai_adoption")),
  mustWork = FALSE
)

SCRIPT_DIR <- file.path(ROOT_DIR, "dict_score")
HELPER_PATH <- file.path(ROOT_DIR, "helper", "s3_utils.R")
DICT_PATH <- file.path(SCRIPT_DIR, "make_ai_dict.R")

# Name of the environment variable that contains the S3 prefix.
FILINGS_ENVVAR <- "S3_PREFIX_TEAM_EFFECT_OF_AI"

OUT_DIR <- file.path(ROOT_DIR, "output", "dict_ai_scored")

# "full"   = process extract_dataframe_full.rds only
# "chunks" = process extract_df_chunk_*.rds only
MODE <- "chunks"

# If MODE == "chunks", optionally subset chunk numbers here.
# Leave as NULL to process all chunk files.
CHUNK_START <- NULL
CHUNK_END <- NULL

# Use Inf for production. Set to a small integer only for testing.
MAX_FILES <- Inf

# Sentence window used for context classification: current +/- 1 sentence.
CONTEXT_WINDOW <- 1L

# BM25-like length normalisation parameters.
BM25_K1 <- 1.2
BM25_B <- 0.75

# TRUE = fail fast when any input file cannot be read/scored.
# FALSE = log failed files and continue.
STOP_ON_FILE_ERROR <- TRUE

# Write mention-level QA output.
WRITE_MENTIONS_LONG <- TRUE

CONTEXT_LEVELS <- c(
  "operational",
  "capability",
  "experimental",
  "risk_governance",
  "external",
  "negated",
  "unclear"
)

AI_DICT <- data.table()
ANY_DICT_PATTERN <- "(?i)(?:a^)"
ANCHOR_PATTERN <- "(?i)(?:a^)"

# ============================================================
# BASIC HELPERS
# ============================================================
clean_utf8 <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- stringi::stri_enc_toutf8(x, is_unknown_8bit = TRUE, validate = FALSE)
  x <- stringi::stri_replace_all_regex(x, "\\x{0000}", " ")
  x[is.na(x)] <- ""
  x
}

normalize_text <- function(x, keep_sentence_punct = FALSE) {
  x <- clean_utf8(x)
  x <- stringi::stri_trans_tolower(x)
  
  x <- stringi::stri_replace_all_fixed(
    x,
    c("’", "`", "–", "—"),
    c("'", "'", "-", "-"),
    vectorize_all = FALSE
  )
  
  if (!keep_sentence_punct) {
    x <- stringi::stri_replace_all_regex(x, "[^[:alnum:]\\s\\-\\./]", " ")
  }
  
  x <- stringi::stri_replace_all_regex(x, "\\s+", " ")
  x <- stringi::stri_trim_both(x)
  x[is.na(x)] <- ""
  x
}

split_sentences_safe <- function(x) {
  x <- clean_utf8(x)
  x <- stringi::stri_replace_all_regex(x, "\\s+", " ")
  x <- stringi::stri_trim_both(x)
  if (!nzchar(x)) return(character())
  
  s <- tryCatch(
    stringi::stri_split_boundaries(x, type = "sentence")[[1]],
    error = function(e) character()
  )
  
  s <- normalize_text(s, keep_sentence_punct = FALSE)
  s[nzchar(s)]
}

detect_regex_safe <- function(text, pattern) {
  text <- as.character(text)
  text[is.na(text)] <- ""
  
  out <- tryCatch(
    stringi::stri_detect_regex(text[1], pattern),
    error = function(e) FALSE
  )
  
  isTRUE(out[1])
}

count_regex_safe <- function(text, pattern) {
  text <- as.character(text)
  text[is.na(text)] <- ""
  
  out <- tryCatch(
    stringi::stri_count_regex(text[1], pattern),
    error = function(e) NA_integer_
  )
  
  if (length(out) == 0L || is.na(out[1])) return(0L)
  as.integer(out[1])
}

extract_first_match <- function(text, pattern) {
  out <- tryCatch(
    stringi::stri_extract_first_regex(text[1], pattern),
    error = function(e) NA_character_
  )
  
  if (length(out) == 0L || is.na(out[1])) return("")
  normalize_text(out[1])
}

word_count <- function(x) {
  x <- normalize_text(x)
  if (length(x) == 0L) return(integer())
  
  vapply(stringi::stri_split_regex(x, "\\s+"), function(v) {
    v <- v[nzchar(v)]
    length(v)
  }, integer(1))
}

safe_divide <- function(num, den) {
  out <- ifelse(!is.na(den) & den > 0, num / den, 0)
  out[is.na(out)] <- 0
  out
}

cap01 <- function(x) {
  x[is.na(x)] <- 0
  pmax(0, pmin(1, x))
}

source_required <- function(path, label) {
  if (!file.exists(path)) {
    stop(label, " not found at: ", path, call. = FALSE)
  }
  source(path)
}

validate_config <- function() {
  if (!MODE %in% c("full", "chunks")) {
    stop("MODE must be either 'full' or 'chunks'. Current MODE: ", MODE, call. = FALSE)
  }
  
  if (!is.null(CHUNK_START) && (!is.numeric(CHUNK_START) || length(CHUNK_START) != 1L)) {
    stop("CHUNK_START must be NULL or a single numeric value.", call. = FALSE)
  }
  
  if (!is.null(CHUNK_END) && (!is.numeric(CHUNK_END) || length(CHUNK_END) != 1L)) {
    stop("CHUNK_END must be NULL or a single numeric value.", call. = FALSE)
  }
  
  if (!is.null(CHUNK_START) && !is.null(CHUNK_END) && CHUNK_START > CHUNK_END) {
    stop("CHUNK_START cannot be greater than CHUNK_END.", call. = FALSE)
  }
  
  if (!is.infinite(MAX_FILES) && (!is.numeric(MAX_FILES) || MAX_FILES < 1)) {
    stop("MAX_FILES must be Inf or a positive numeric value.", call. = FALSE)
  }
  
  prefix <- Sys.getenv(FILINGS_ENVVAR, unset = "")
  prefix <- stringi::stri_trim_both(prefix)
  if (!nzchar(prefix)) {
    stop("Environment variable ", FILINGS_ENVVAR, " is not set.", call. = FALSE)
  }
  
  if (!endsWith(prefix, "/")) {
    prefix <- paste0(prefix, "/")
    do.call(Sys.setenv, stats::setNames(as.list(prefix), FILINGS_ENVVAR))
    message("Added trailing slash to S3 prefix in ", FILINGS_ENVVAR, ".")
  }
  
  if (!dir.exists(OUT_DIR)) {
    dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
  }
  
  if (!dir.exists(OUT_DIR)) {
    stop("Could not create output directory: ", OUT_DIR, call. = FALSE)
  }
  
  invisible(TRUE)
}

# ============================================================
# DICTIONARY AND CONTEXT SETUP
# ============================================================
strip_inline_case_flag <- function(pattern) {
  pattern <- as.character(pattern)
  pattern[is.na(pattern)] <- ""
  stringi::stri_replace_first_regex(pattern, "^\\(\\?[iI]\\)", "")
}

make_union_pattern <- function(patterns) {
  patterns <- strip_inline_case_flag(patterns)
  patterns <- patterns[nzchar(patterns)]
  if (length(patterns) == 0L) return("(?i)(?:a^)")
  paste0("(?i)(?:", paste(patterns, collapse = "|"), ")")
}

validate_regexes <- function(dict) {
  ok <- vapply(dict$pattern, function(p) {
    isTRUE(tryCatch({
      stringi::stri_detect_regex("regex validation probe", p)
      TRUE
    }, error = function(e) FALSE))
  }, logical(1))
  
  if (any(!ok)) {
    bad <- dict[!ok, paste0(concept, " [", family, "]")]
    stop("Invalid regex pattern(s) in AI dictionary: ", paste(bad, collapse = "; "), call. = FALSE)
  }
  
  invisible(TRUE)
}

prepare_ai_dictionary <- function(raw_dict) {
  dict <- as.data.table(raw_dict)
  required_cols <- c("concept", "family", "pattern", "requires_anchor", "base_weight")
  missing_cols <- setdiff(required_cols, names(dict))
  if (length(missing_cols) > 0L) {
    stop("AI dictionary missing required columns: ", paste(missing_cols, collapse = ", "), call. = FALSE)
  }
  
  dict[, concept := as.character(concept)]
  dict[, family := as.character(family)]
  dict[, pattern := as.character(pattern)]
  dict[, requires_anchor := as.logical(requires_anchor)]
  dict[is.na(requires_anchor), requires_anchor := FALSE]
  dict[, base_weight := suppressWarnings(as.numeric(base_weight))]
  dict[is.na(base_weight) | base_weight <= 0, base_weight := 1]
  dict <- dict[nzchar(concept) & nzchar(pattern)]
  
  if (nrow(dict) == 0L) {
    stop("AI dictionary is empty after validation.", call. = FALSE)
  }
  
  validate_regexes(dict)
  unique(dict)
}

classify_context_fallback <- function(text) {
  text <- normalize_text(text)
  if (!nzchar(text)) return(list(class = "unclear", material = 0L))
  
  material <- as.integer(detect_regex_safe(
    text,
    paste0(
      "\\b(material|significant|strategic|enterprise|company wide|company-wide|",
      "production|deployed|implemented|integrated|adopted|automated|workflow|",
      "customer|product|service|revenue|cost|efficien|operations?)\\b"
    )
  ))
  
  ai_terms <- paste0(
    "\\b(ai|artificial intelligence|machine learning|deep learning|",
    "generative ai|gen ai|large language model|llm|algorithmic|automation)\\b"
  )
  
  if (detect_regex_safe(
    text,
    paste0(
      "\\b(no|not|without|never|none|lack|lacks|lacked|do not|does not|did not)\\b.{0,80}",
      ai_terms,
      "|",
      ai_terms,
      ".{0,80}\\b(no|not|without|never|none|lack|lacks|lacked|not material)\\b"
    )
  )) {
    return(list(class = "negated", material = 0L))
  }
  
  if (detect_regex_safe(text, "\\b(risk|governance|privacy|security|bias|ethic|regulat|compliance|audit|oversight|control|model risk)\\b")) {
    return(list(class = "risk_governance", material = material))
  }
  
  if (detect_regex_safe(text, "\\b(vendor|supplier|customer|client|competitor|industry|market|third party|third-party|partner)\\b")) {
    return(list(class = "external", material = material))
  }
  
  if (detect_regex_safe(text, "\\b(pilot|prototype|experiment|trial|test|testing|evaluate|evaluating|explor|proof of concept|poc)\\b")) {
    return(list(class = "experimental", material = material))
  }
  
  if (detect_regex_safe(text, "\\b(use|uses|using|used|deploy|deployed|implement|implemented|integrat|automate|automated|production|operate|workflow)\\b")) {
    return(list(class = "operational", material = material))
  }
  
  if (detect_regex_safe(text, "\\b(capabilit|platform|tool|model|analytics|prediction|predictive|optimization|recommendation|classification|detection)\\b")) {
    return(list(class = "capability", material = material))
  }
  
  list(class = "unclear", material = material)
}

context_weight_fallback <- function(context_class, material_flag = 0L) {
  context_class <- as.character(context_class)
  material_flag <- as.integer(material_flag)
  
  weight <- fifelse(context_class == "operational", 1.00,
                    fifelse(context_class == "capability", 0.75,
                            fifelse(context_class == "experimental", 0.45,
                                    fifelse(context_class == "risk_governance", 0.35,
                                            fifelse(context_class == "external", 0.20,
                                                    fifelse(context_class == "negated", 0.05, 0.15)
                                            )
                                    )
                            )
                    )
  )
  
  material_boost <- context_class %in% c("operational", "capability", "experimental") & material_flag > 0L
  weight[material_boost] <- weight[material_boost] * 1.15
  as.numeric(weight)
}

section_weight_fallback <- function(section) {
  section <- as.character(section)
  fifelse(section == "item1", 1.05, fifelse(section == "item7", 1.00, 1.00))
}

ensure_runtime_functions <- function() {
  if (!exists("classify_context", mode = "function", inherits = TRUE)) {
    assign("classify_context", classify_context_fallback, envir = .GlobalEnv)
    message("Using built-in fallback classify_context().")
  }
  
  if (!exists("context_weight", mode = "function", inherits = TRUE)) {
    assign("context_weight", context_weight_fallback, envir = .GlobalEnv)
    message("Using built-in fallback context_weight().")
  }
  
  if (!exists("section_weight", mode = "function", inherits = TRUE)) {
    assign("section_weight", section_weight_fallback, envir = .GlobalEnv)
    message("Using built-in fallback section_weight().")
  }
  
  invisible(TRUE)
}

extract_context_result <- function(ctx) {
  if (is.list(ctx)) {
    ctx_class <- if (!is.null(ctx$class)) as.character(ctx$class[1]) else "unclear"
    material <- if (!is.null(ctx$material)) suppressWarnings(as.integer(ctx$material[1])) else 0L
  } else {
    ctx_class <- as.character(ctx[1])
    material <- 0L
  }
  
  if (length(ctx_class) == 0L || is.na(ctx_class) || !ctx_class %in% CONTEXT_LEVELS) {
    ctx_class <- "unclear"
  }
  if (length(material) == 0L || is.na(material)) material <- 0L
  
  list(class = ctx_class, material = as.integer(material > 0L))
}

compute_context_weight <- function(context_class, material_flag) {
  out <- tryCatch(
    context_weight(context_class, material_flag),
    error = function(e) {
      vapply(seq_along(context_class), function(i) {
        context_weight(context_class[i], material_flag[i])
      }, numeric(1))
    }
  )
  
  out <- as.numeric(out)
  out[!is.finite(out) | is.na(out)] <- 1
  out
}

compute_section_weight <- function(section) {
  out <- tryCatch(
    section_weight(section),
    error = function(e) vapply(section, section_weight, numeric(1))
  )
  
  out <- as.numeric(out)
  out[!is.finite(out) | is.na(out)] <- 1
  out
}

initialise_runtime <- function() {
  validate_config()
  source_required(HELPER_PATH, "S3 helper")
  source_required(DICT_PATH, "AI dictionary script")
  
  if (!exists("make_ai_dictionary", mode = "function", inherits = TRUE)) {
    stop("make_ai_dictionary() was not found after sourcing: ", DICT_PATH, call. = FALSE)
  }
  
  AI_DICT <<- prepare_ai_dictionary(make_ai_dictionary())
  ANY_DICT_PATTERN <<- make_union_pattern(AI_DICT$pattern)
  # Anchor terms are the dictionary entries that are allowed to stand alone.
  # This respects rows such as chatbot_or_copilot where family == "genai" but
  # requires_anchor == TRUE.
  ANCHOR_PATTERN <<- make_union_pattern(AI_DICT[requires_anchor == FALSE, pattern])
  ensure_runtime_functions()
  
  invisible(TRUE)
}

# ============================================================
# LONG -> WIDE
# ============================================================
normalize_item_label <- function(x) {
  x <- clean_utf8(x)
  x <- stringi::stri_trans_tolower(x)
  x <- stringi::stri_replace_all_regex(x, "\\s+", "")
  x <- stringi::stri_replace_all_regex(x, "[^[:alnum:]]", "")
  
  fifelse(x %chin% c("1", "item1"), "item1",
          fifelse(x %chin% c("7", "item7"), "item7", x)
  )
}

empty_wide_filings <- function() {
  data.table(
    accession_number = character(),
    cik = character(),
    year = integer(),
    form_type = character(),
    item1_text = character(),
    item7_text = character()
  )
}

long_to_wide_filings <- function(dt) {
  required_cols <- c("item", "year", "accession_number", "cik", "form_type", "text")
  missing_cols <- setdiff(required_cols, names(dt))
  if (length(missing_cols) > 0L) {
    stop("Missing required columns: ", paste(missing_cols, collapse = ", "), call. = FALSE)
  }
  
  dt <- as.data.table(copy(dt))
  if (nrow(dt) == 0L) return(empty_wide_filings())
  
  dt[, `:=`(
    accession_number = as.character(accession_number),
    cik = as.character(cik),
    year = suppressWarnings(as.integer(year)),
    form_type = as.character(form_type),
    item_norm = normalize_item_label(item),
    text_clean = clean_utf8(text)
  )]
  
  base <- unique(dt[, .(accession_number, cik, year, form_type)])
  if (nrow(base) == 0L) return(empty_wide_filings())
  
  dt_items <- dt[item_norm %chin% c("item1", "item7")]
  
  if (nrow(dt_items) > 0L) {
    dt_collapsed <- dt_items[
      ,
      .(text = paste(unique(text_clean[nzchar(text_clean)]), collapse = " ")),
      by = .(accession_number, cik, year, form_type, item = item_norm)
    ]
    
    wide_items <- dcast(
      dt_collapsed,
      accession_number + cik + year + form_type ~ item,
      value.var = "text",
      fill = ""
    )
    
    wide <- merge(
      base,
      wide_items,
      by = c("accession_number", "cik", "year", "form_type"),
      all.x = TRUE,
      sort = FALSE
    )
  } else {
    wide <- copy(base)
  }
  
  if (!("item1" %in% names(wide))) wide[, item1 := ""]
  if (!("item7" %in% names(wide))) wide[, item7 := ""]
  wide[is.na(item1), item1 := ""]
  wide[is.na(item7), item7 := ""]
  
  setnames(wide, old = c("item1", "item7"), new = c("item1_text", "item7_text"))
  setcolorder(wide, c("accession_number", "cik", "year", "form_type", "item1_text", "item7_text"))
  setorderv(wide, c("year", "cik", "accession_number"), na.last = TRUE)
  wide[]
}

# ============================================================
# CORPUS STATS FOR SMOOTHED IDF + YEARLY AVG DOC LENGTH
# ============================================================
make_doc_ids <- function(file_id, wide_dt) {
  paste(file_id, seq_len(nrow(wide_dt)), wide_dt$accession_number, wide_dt$cik, sep = "|")
}

concept_presence <- function(text) {
  text <- normalize_text(text)
  if (!nzchar(text)) return(character())
  if (!detect_regex_safe(text, ANY_DICT_PATTERN)) return(character())
  
  has_anchor <- detect_regex_safe(text, ANCHOR_PATTERN)
  
  present <- AI_DICT[vapply(seq_len(nrow(AI_DICT)), function(i) {
    if (isTRUE(AI_DICT$requires_anchor[i]) && !has_anchor) return(FALSE)
    detect_regex_safe(text, AI_DICT$pattern[i])
  }, logical(1)), concept]
  
  unique(present)
}

read_filings_file <- function(path_in) {
  s3_args <- names(formals(source_s3data))
  if ("filename" %in% s3_args) {
    dt <- source_s3data(S3_BUCK = FILINGS_ENVVAR, filename = path_in)
  } else if ("fp" %in% s3_args) {
    dt <- source_s3data(S3_BUCK = FILINGS_ENVVAR, fp = path_in)
  } else {
    dt <- source_s3data(FILINGS_ENVVAR, path_in)
  }
  
  if (!is.data.table(dt)) dt <- as.data.table(dt)
  dt
}

scan_one_file_for_corpus <- function(fp) {
  file_id <- file_path_sans_ext(basename(fp))
  message("Scanning for corpus stats: ", basename(fp))
  
  dt <- read_filings_file(fp)
  wide_dt <- long_to_wide_filings(dt)
  wide_dt[, combined_text := paste(item1_text, item7_text, sep = " ")]
  wide_dt[, total_words_tmp := word_count(combined_text)]
  wide_dt[, doc_id := make_doc_ids(file_id, wide_dt)]
  
  docs_this <- wide_dt[, .(
    doc_id,
    year = as.integer(year),
    total_words = as.numeric(total_words_tmp)
  )]
  
  df_list <- vector("list", nrow(wide_dt))
  idx <- 1L
  for (r in seq_len(nrow(wide_dt))) {
    concepts <- concept_presence(wide_dt$combined_text[r])
    if (length(concepts) == 0L) next
    df_list[[idx]] <- data.table(
      doc_id = wide_dt$doc_id[r],
      year = as.integer(wide_dt$year[r]),
      concept = concepts
    )
    idx <- idx + 1L
  }
  
  df_list <- df_list[seq_len(idx - 1L)]
  df_this <- if (length(df_list) > 0L) {
    rbindlist(df_list, fill = TRUE)
  } else {
    data.table(doc_id = character(), year = integer(), concept = character())
  }
  
  list(docs = docs_this, df = df_this)
}

build_corpus_stats <- function(files) {
  message("\nPass 1/2: building corpus statistics for smoothed IDF and yearly length normalisation...")
  
  doc_list <- list()
  df_list <- list()
  failed <- character()
  
  for (fp in files) {
    res <- tryCatch(
      scan_one_file_for_corpus(fp),
      error = function(e) {
        msg <- paste0(basename(fp), ": ", conditionMessage(e))
        if (STOP_ON_FILE_ERROR) stop(msg, call. = FALSE)
        message("Skipping corpus stats for failed file: ", msg)
        failed <<- c(failed, msg)
        NULL
      }
    )
    
    if (is.null(res)) next
    doc_list[[length(doc_list) + 1L]] <- res$docs
    df_list[[length(df_list) + 1L]] <- res$df
  }
  
  docs_dt <- if (length(doc_list)) {
    unique(rbindlist(doc_list, fill = TRUE), by = "doc_id")
  } else {
    data.table(doc_id = character(), year = integer(), total_words = numeric())
  }
  
  df_dt <- if (length(df_list)) {
    unique(rbindlist(df_list, fill = TRUE), by = c("doc_id", "year", "concept"))
  } else {
    data.table(doc_id = character(), year = integer(), concept = character())
  }
  
  if (nrow(docs_dt) == 0L) {
    stop("No documents were available for corpus statistics.", call. = FALSE)
  }
  
  year_stats <- docs_dt[
    ,
    .(
      n_docs = uniqueN(doc_id),
      avg_words_year = mean(total_words, na.rm = TRUE)
    ),
    by = .(year)
  ]
  
  df_year <- if (nrow(df_dt) > 0L) {
    df_dt[, .(df = uniqueN(doc_id)), by = .(year, concept)]
  } else {
    data.table(year = integer(), concept = character(), df = integer())
  }
  
  idf_year <- merge(df_year, year_stats, by = "year", all.x = TRUE, sort = FALSE)
  idf_year[, idf := log((n_docs + 1) / (df + 1)) + 1]
  
  all_concepts <- data.table(concept = unique(AI_DICT$concept))
  global_docs <- uniqueN(docs_dt$doc_id)
  global_df <- if (nrow(df_dt) > 0L) {
    df_dt[, .(df = uniqueN(doc_id)), by = .(concept)]
  } else {
    data.table(concept = character(), df = integer())
  }
  
  global_df <- merge(all_concepts, global_df, by = "concept", all.x = TRUE, sort = FALSE)
  global_df[is.na(df), df := 0L]
  global_df[, global_idf := log((global_docs + 1) / (df + 1)) + 1]
  
  if (length(failed) > 0L) {
    message("Files skipped during corpus build: ", length(failed))
  }
  
  list(
    year_stats = year_stats,
    idf_year = idf_year[, .(year, concept, idf)],
    global_idf = global_df[, .(concept, global_idf)]
  )
}

# ============================================================
# SENTENCE-LEVEL MENTION EXTRACTION
# ============================================================
empty_mentions_table <- function() {
  data.table(
    file_id = character(),
    row_id = integer(),
    year = integer(),
    section = character(),
    sentence_id = integer(),
    concept = character(),
    family = character(),
    base_weight = numeric(),
    n_mentions = integer(),
    example_match = character(),
    sentence = character(),
    context = character(),
    context_class = character(),
    material_flag = integer()
  )
}

extract_mentions_one_text <- function(text, section_name, row_id, file_id, year_value) {
  text <- clean_utf8(text)
  if (!nzchar(normalize_text(text))) return(empty_mentions_table())
  
  sentences <- split_sentences_safe(text)
  n_sent <- length(sentences)
  if (n_sent == 0L) return(empty_mentions_table())
  
  out <- list()
  j <- 1L
  
  for (i in seq_len(n_sent)) {
    sent <- sentences[i]
    if (!nzchar(sent)) next
    if (!detect_regex_safe(sent, ANY_DICT_PATTERN)) next
    
    lo <- max(1L, i - CONTEXT_WINDOW)
    hi <- min(n_sent, i + CONTEXT_WINDOW)
    window <- paste(sentences[lo:hi], collapse = " ")
    has_anchor <- detect_regex_safe(window, ANCHOR_PATTERN)
    ctx <- extract_context_result(classify_context(window))
    
    for (k in seq_len(nrow(AI_DICT))) {
      pat <- AI_DICT$pattern[k]
      if (isTRUE(AI_DICT$requires_anchor[k]) && !has_anchor) next
      n_hits <- count_regex_safe(sent, pat)
      if (n_hits <= 0L) next
      
      out[[j]] <- data.table(
        file_id = file_id,
        row_id = as.integer(row_id),
        year = as.integer(year_value),
        section = section_name,
        sentence_id = as.integer(i),
        concept = AI_DICT$concept[k],
        family = AI_DICT$family[k],
        base_weight = AI_DICT$base_weight[k],
        n_mentions = n_hits,
        example_match = extract_first_match(sent, pat),
        sentence = sent,
        context = window,
        context_class = ctx$class,
        material_flag = ctx$material
      )
      j <- j + 1L
    }
  }
  
  if (length(out) == 0L) return(empty_mentions_table())
  rbindlist(out, fill = TRUE)
}

extract_mentions_table <- function(wide_dt, file_id) {
  if (nrow(wide_dt) == 0L) return(empty_mentions_table())
  
  out <- vector("list", nrow(wide_dt) * 2L)
  j <- 1L
  
  for (r in seq_len(nrow(wide_dt))) {
    out[[j]] <- extract_mentions_one_text(wide_dt$item1_text[r], "item1", r, file_id, wide_dt$year[r])
    j <- j + 1L
    out[[j]] <- extract_mentions_one_text(wide_dt$item7_text[r], "item7", r, file_id, wide_dt$year[r])
    j <- j + 1L
  }
  
  non_empty <- out[vapply(out, nrow, integer(1)) > 0L]
  if (length(non_empty) == 0L) return(empty_mentions_table())
  
  rbindlist(non_empty, fill = TRUE)
}

add_mention_identifiers <- function(mentions, wide_dt) {
  ids <- wide_dt[, .(
    row_id = seq_len(.N),
    accession_number = accession_number,
    cik = cik,
    form_type = form_type
  )]
  
  mentions <- merge(mentions, ids, by = "row_id", all.x = TRUE, sort = FALSE)
  
  id_cols <- c("file_id", "row_id", "accession_number", "cik", "year", "form_type")
  setcolorder(mentions, c(id_cols, setdiff(names(mentions), id_cols)))
  mentions[]
}

# ============================================================
# ROW-LEVEL SCORING
# ============================================================
COUNT_COLS <- c(
  "ai_mentions_total",
  "ai_operational_n",
  "ai_capability_n",
  "ai_experimental_n",
  "ai_risk_n",
  "ai_external_n",
  "ai_negated_n",
  "ai_unclear_n",
  "ai_core_n",
  "ai_genai_n",
  "ai_secondary_n",
  "ai_item1_mentions",
  "ai_item7_mentions",
  "ai_dictionary_breadth",
  "ai_operational_concept_breadth",
  "ai_section_breadth"
)

SCORE_COLS <- c(
  "ai_mentions_per_1k",
  "ai_operational_per_1k",
  "ai_genai_per_1k",
  "ai_weighted_score_raw",
  "ai_operational_weighted",
  "ai_capability_weighted",
  "ai_experimental_weighted",
  "ai_risk_weighted",
  "ai_external_weighted",
  "ai_negated_weighted",
  "ai_unclear_weighted",
  "ai_genai_weighted",
  "ai_adoption_score_raw",
  "ai_adoption_score"
)

FLAG_COLS <- c("ai_any_mention", "ai_any_operational", "ai_any_genai")

fill_missing_metrics <- function(dt) {
  for (cc in COUNT_COLS) {
    if (!cc %in% names(dt)) dt[, (cc) := 0L]
    dt[is.na(get(cc)), (cc) := 0L]
  }
  
  for (cc in SCORE_COLS) {
    if (!cc %in% names(dt)) dt[, (cc) := 0]
    dt[is.na(get(cc)), (cc) := 0]
  }
  
  for (cc in FLAG_COLS) {
    if (!cc %in% names(dt)) dt[, (cc) := 0L]
    dt[is.na(get(cc)), (cc) := 0L]
  }
  
  dt[]
}

set_dominant_context <- function(dt) {
  ctx_cols <- c(
    "ai_operational_n",
    "ai_capability_n",
    "ai_experimental_n",
    "ai_risk_n",
    "ai_external_n",
    "ai_negated_n",
    "ai_unclear_n"
  )
  
  ctx_labels <- c(
    "operational",
    "capability",
    "experimental",
    "risk_governance",
    "external",
    "negated",
    "unclear"
  )
  
  mat <- as.matrix(dt[, ..ctx_cols])
  if (nrow(mat) == 0L) {
    dt[, ai_dominant_context := character()]
    return(dt[])
  }
  
  dom_idx <- max.col(mat, ties.method = "first")
  dt[, ai_dominant_context := fifelse(ai_mentions_total > 0, ctx_labels[dom_idx], "none")]
  dt[]
}

weighted_global_avg_words <- function(year_stats, fallback_words) {
  out <- NA_real_
  
  if (nrow(year_stats) > 0L && all(c("n_docs", "avg_words_year") %in% names(year_stats))) {
    out <- sum(year_stats$n_docs * year_stats$avg_words_year, na.rm = TRUE) /
      sum(year_stats$n_docs, na.rm = TRUE)
  }
  
  if (!is.finite(out) || is.na(out) || out <= 0) {
    out <- mean(fallback_words, na.rm = TRUE)
  }
  
  if (!is.finite(out) || is.na(out) || out <= 0) out <- 1
  out
}

score_mentions <- function(wide_dt, mentions, corpus_stats) {
  wide_dt <- copy(wide_dt)
  wide_dt[, row_id := .I]
  wide_dt[, item1_words := word_count(item1_text)]
  wide_dt[, item7_words := word_count(item7_text)]
  wide_dt[, total_words := item1_words + item7_words]
  
  wide_dt <- merge(wide_dt, corpus_stats$year_stats, by = "year", all.x = TRUE, sort = FALSE)
  global_avg_words <- weighted_global_avg_words(corpus_stats$year_stats, wide_dt$total_words)
  wide_dt[is.na(avg_words_year) | avg_words_year <= 0, avg_words_year := global_avg_words]
  
  if (nrow(mentions) == 0L) {
    wide_dt <- fill_missing_metrics(wide_dt)
    wide_dt[, ai_dominant_context := "none"]
    return(wide_dt[])
  }
  
  mentions_agg <- mentions[
    ,
    .(
      n_mentions = sum(n_mentions),
      base_weight = max(base_weight),
      material_flag = max(material_flag),
      family = first(family)
    ),
    by = .(row_id, year, section, concept, context_class)
  ]
  
  mentions_agg <- merge(mentions_agg, corpus_stats$idf_year, by = c("year", "concept"), all.x = TRUE, sort = FALSE)
  mentions_agg <- merge(mentions_agg, corpus_stats$global_idf, by = "concept", all.x = TRUE, sort = FALSE)
  mentions_agg[is.na(idf), idf := global_idf]
  mentions_agg[is.na(idf), idf := 1]
  
  mentions_agg <- merge(
    mentions_agg,
    wide_dt[, .(row_id, total_words, avg_words_year)],
    by = "row_id",
    all.x = TRUE,
    sort = FALSE
  )
  
  mentions_agg[, len_norm := 1 - BM25_B + BM25_B * safe_divide(total_words, avg_words_year)]
  mentions_agg[len_norm <= 0 | is.na(len_norm), len_norm := 1]
  
  mentions_agg[, tf_component :=
                 (n_mentions * (BM25_K1 + 1)) / (n_mentions + BM25_K1 * len_norm)]
  mentions_agg[, ctx_weight := compute_context_weight(context_class, material_flag)]
  mentions_agg[, sec_weight := compute_section_weight(section)]
  mentions_agg[, concept_score := base_weight * idf * tf_component * ctx_weight * sec_weight]
  
  row_metrics <- mentions_agg[
    ,
    .(
      ai_mentions_total = sum(n_mentions),
      ai_operational_n = sum(n_mentions[context_class == "operational"]),
      ai_capability_n = sum(n_mentions[context_class == "capability"]),
      ai_experimental_n = sum(n_mentions[context_class == "experimental"]),
      ai_risk_n = sum(n_mentions[context_class == "risk_governance"]),
      ai_external_n = sum(n_mentions[context_class == "external"]),
      ai_negated_n = sum(n_mentions[context_class == "negated"]),
      ai_unclear_n = sum(n_mentions[context_class == "unclear"]),
      ai_core_n = sum(n_mentions[family == "core"]),
      ai_genai_n = sum(n_mentions[family == "genai"]),
      ai_secondary_n = sum(n_mentions[family == "secondary"]),
      ai_item1_mentions = sum(n_mentions[section == "item1"]),
      ai_item7_mentions = sum(n_mentions[section == "item7"]),
      ai_dictionary_breadth = uniqueN(concept),
      ai_operational_concept_breadth = uniqueN(concept[context_class %in% c("operational", "capability")]),
      ai_section_breadth = uniqueN(section[context_class %in% c("operational", "capability")]),
      ai_weighted_score_raw = sum(concept_score),
      ai_operational_weighted = sum(concept_score[context_class == "operational"]),
      ai_capability_weighted = sum(concept_score[context_class == "capability"]),
      ai_experimental_weighted = sum(concept_score[context_class == "experimental"]),
      ai_risk_weighted = sum(concept_score[context_class == "risk_governance"]),
      ai_external_weighted = sum(concept_score[context_class == "external"]),
      ai_negated_weighted = sum(concept_score[context_class == "negated"]),
      ai_unclear_weighted = sum(concept_score[context_class == "unclear"]),
      ai_genai_weighted = sum(concept_score[family == "genai"])
    ),
    by = .(row_id)
  ]
  
  wide_dt <- merge(wide_dt, row_metrics, by = "row_id", all.x = TRUE, sort = FALSE)
  wide_dt <- fill_missing_metrics(wide_dt)
  
  wide_dt[, ai_mentions_per_1k := 1000 * safe_divide(ai_mentions_total, total_words)]
  wide_dt[, ai_operational_per_1k := 1000 * safe_divide(ai_operational_n, total_words)]
  wide_dt[, ai_genai_per_1k := 1000 * safe_divide(ai_genai_n, total_words)]
  
  wide_dt[, ai_adoption_score_raw :=
            ai_operational_weighted +
            0.75 * ai_capability_weighted +
            0.30 * ai_experimental_weighted +
            0.05 * log1p(ai_operational_concept_breadth) +
            0.05 * pmin(ai_section_breadth, 2)]
  
  wide_dt[, ai_adoption_score := cap01(1 - exp(-ai_adoption_score_raw))]
  wide_dt[, ai_any_mention := as.integer(ai_mentions_total > 0)]
  wide_dt[, ai_any_operational := as.integer(ai_operational_n > 0)]
  wide_dt[, ai_any_genai := as.integer(ai_genai_n > 0)]
  
  set_dominant_context(wide_dt)
}

# ============================================================
# FILE SELECTION
# ============================================================
extract_chunk_number <- function(files) {
  m <- stringi::stri_match_first_regex(files, "^extract_df_chunk_([0-9]{5})\\.rds$")
  suppressWarnings(as.integer(m[, 2]))
}

get_files_to_process <- function() {
  keys <- get_file_ls(FILINGS_ENVVAR)
  files <- unique(basename(keys))
  files <- files[nzchar(files)]
  files <- files[grepl("\\.rds$", files, ignore.case = TRUE)]
  
  if (MODE == "full") {
    files <- files[files == "extract_dataframe_full.rds"]
    files <- sort(files)
  } else {
    chunk_num <- extract_chunk_number(files)
    chunk_dt <- data.table(file = files, chunk_num = chunk_num)
    chunk_dt <- chunk_dt[!is.na(chunk_num)]
    
    if (!is.null(CHUNK_START)) {
      chunk_dt <- chunk_dt[chunk_num >= as.integer(CHUNK_START)]
    }
    
    if (!is.null(CHUNK_END)) {
      chunk_dt <- chunk_dt[chunk_num <= as.integer(CHUNK_END)]
    }
    
    setorder(chunk_dt, chunk_num, file)
    files <- chunk_dt$file
  }
  
  if (!is.infinite(MAX_FILES)) {
    files <- head(files, as.integer(MAX_FILES))
  }
  
  if (length(files) == 0L) {
    stop("No files matched MODE=", MODE, " and the configured chunk range.", call. = FALSE)
  }
  
  files
}

# ============================================================
# PROCESS ONE FILE
# ============================================================
process_one_file <- function(path_in, corpus_stats) {
  if (length(path_in) != 1L || is.na(path_in) || !nzchar(path_in)) {
    stop("Invalid input file name: ", paste(path_in, collapse = ", "), call. = FALSE)
  }
  
  file_id <- file_path_sans_ext(basename(path_in))
  message("\nProcessing: ", path_in)
  
  dt <- read_filings_file(path_in)
  wide_dt <- long_to_wide_filings(dt)
  mentions <- extract_mentions_table(wide_dt, file_id = file_id)
  mentions <- add_mention_identifiers(mentions, wide_dt)
  scored <- score_mentions(wide_dt, mentions, corpus_stats = corpus_stats)
  
  if (nrow(mentions) > 0L) {
    qa_examples <- mentions[
      ,
      .(
        ai_example_context = context[1],
        ai_example_concept = concept[1],
        ai_example_context_class = context_class[1]
      ),
      by = .(row_id)
    ]
    scored <- merge(scored, qa_examples, by = "row_id", all.x = TRUE, sort = FALSE)
  } else {
    scored[, `:=`(
      ai_example_context = NA_character_,
      ai_example_concept = NA_character_,
      ai_example_context_class = NA_character_
    )]
  }
  
  if ("row_id" %in% names(scored)) scored[, row_id := NULL]
  
  out_rds <- file.path(OUT_DIR, paste0(file_id, "_ai_scored.rds"))
  out_csv <- file.path(OUT_DIR, paste0(file_id, "_ai_scored.csv"))
  out_mentions <- file.path(OUT_DIR, paste0(file_id, "_ai_mentions_long.csv"))
  
  saveRDS(scored, out_rds)
  fwrite(scored, out_csv)
  if (isTRUE(WRITE_MENTIONS_LONG)) fwrite(mentions, out_mentions)
  
  message("Saved scored RDS: ", out_rds)
  message("Saved scored CSV: ", out_csv)
  if (isTRUE(WRITE_MENTIONS_LONG)) message("Saved mention CSV: ", out_mentions)
  message("Filings scored: ", nrow(scored))
  message("Filings with any AI mention: ", sum(scored$ai_any_mention, na.rm = TRUE))
  message("Filings with operational AI evidence: ", sum(scored$ai_any_operational, na.rm = TRUE))
  message("Filings with GenAI mention: ", sum(scored$ai_any_genai, na.rm = TRUE))
  message("Mean AI adoption score: ", round(mean(scored$ai_adoption_score, na.rm = TRUE), 4))
  
  invisible(scored)
}

# ============================================================
# RUN
# ============================================================
main <- function() {
  initialise_runtime()
  
  files <- get_files_to_process()
  message("Mode: ", MODE)
  message("Files to process: ", length(files))
  message("First file: ", files[1])
  message("Last file: ", files[length(files)])
  
  corpus_stats <- build_corpus_stats(files)
  
  failed <- character()
  for (fp in files) {
    tryCatch(
      process_one_file(fp, corpus_stats = corpus_stats),
      error = function(e) {
        msg <- paste0(basename(fp), ": ", conditionMessage(e))
        if (STOP_ON_FILE_ERROR) stop(msg, call. = FALSE)
        failed <<- c(failed, msg)
        message("Failed file: ", msg)
      }
    )
  }
  
  if (length(failed) > 0L) {
    message("\nDone with failures: ", length(failed))
    message(paste(failed, collapse = "\n"))
  } else {
    message("\nDone.")
  }
  
  invisible(TRUE)
}

main()
