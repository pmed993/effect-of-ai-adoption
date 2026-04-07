#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(stringi)
  library(tools)
})

# ============================================================
# CONFIG
# ============================================================
ROOT_DIR <- "/Users/piomedolla/Desktop/effect-of-genai"
ASSEMBLED_DIR <- file.path(ROOT_DIR, "cache", "edgar_metrics_parser", "assembled")
OUT_DIR <- file.path(ROOT_DIR, "cache", "assembled_ai_scored")

if (!dir.exists(OUT_DIR)) {
  dir.create(OUT_DIR, recursive = TRUE)
}

# "full"   = process extract_dataframe_full.rds only
# "chunks" = process extract_df_chunk_*.rds only
MODE <- "chunks"

# If MODE == "chunks", optionally subset chunk numbers here
# Leave as NULL to process all chunk files
CHUNK_START <- NULL
CHUNK_END <- NULL

# sentence window used for context classification: current +/- 1 sentence
CONTEXT_WINDOW <- 1L

# BM25-like length normalisation parameters
BM25_K1 <- 1.2
BM25_B  <- 0.75

# ============================================================
# HELPERS
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
  
  # normalise apostrophes / dashes
  x <- stringi::stri_replace_all_fixed(x, c("’", "`", "–", "—"), c("'", "'", "-", "-"), vectorize_all = FALSE)
  
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
  s <- s[nzchar(s)]
  s
}

count_regex_safe <- function(text, pattern) {
  text <- as.character(text)
  text[is.na(text)] <- ""
  
  out <- tryCatch(
    stringi::stri_count_regex(text, pattern),
    error = function(e) NA_integer_
  )
  
  if (length(out) == 0L || is.na(out)) return(0L)
  as.integer(out)
}

extract_first_match <- function(text, pattern) {
  out <- tryCatch(stringi::stri_extract_first_regex(text, pattern), error = function(e) NA_character_)
  if (length(out) == 0L || is.na(out)) return("")
  normalize_text(out)
}

word_count <- function(x) {
  x <- normalize_text(x)
  vapply(stri_split_regex(x, "\\s+"), function(v) {
    v <- v[nzchar(v)]
    length(v)
  }, integer(1))
}

safe_divide <- function(num, den) {
  out <- ifelse(den > 0, num / den, 0)
  out[is.na(out)] <- 0
  out
}

cap01 <- function(x) {
  x[is.na(x)] <- 0
  pmax(0, pmin(1, x))
}

# ============================================================
# DICTIONARY
# Best practice here is to separate:
# 1) anchor / high-specificity AI concepts that can trigger a mention
# 2) secondary AI-related concepts that are only counted when they
#    appear near an anchor concept
# 3) GenAI terms, refreshed for post-2022 filings
# ============================================================
make_ai_dictionary <- function() {
  dt <- data.table(
    concept = c(
      "artificial_intelligence",
      "ai_abbrev",
      "machine_learning",
      "deep_learning",
      "neural_network",
      "computer_vision",
      "natural_language_processing",
      "natural_language_generation",
      "natural_language_understanding",
      "speech_recognition",
      "image_recognition",
      "optical_character_recognition",
      "expert_system",
      "reinforcement_learning",
      "large_language_model",
      "foundation_model",
      "generative_ai",
      "transformer_model",
      "retrieval_augmented_generation",
      "gpt_model",
      "chatbot_or_copilot",
      "robotic_process_automation",
      "recommendation_system",
      "predictive_analytics",
      "knowledge_graph",
      "information_extraction",
      "text_mining",
      "sentiment_analysis",
      "object_detection",
      "pattern_recognition",
      "face_recognition",
      "virtual_agent",
      "autonomous_system",
      "data_mining",
      "transfer_learning",
      "word_embedding",
      "topic_model",
      "support_vector_machine",
      "random_forest",
      "xgboost"
    ),
    family = c(
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "core",
      "genai",
      "genai",
      "genai",
      "genai",
      "genai",
      "genai",
      "genai",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary",
      "secondary"
    ),
    pattern = c(
      "\\bartificial intelligence\\b",
      "(?<![a-z])a\\.?i\\.?(?![a-z])",
      "\\b(machine learning|machine-learning)\\b",
      "\\bdeep learning\\b",
      "\\b(neural network|neural networks|artificial neural network|artificial neural networks|convolutional neural network|deep neural network|recurrent neural network)\\b",
      "\\bcomputer vision\\b",
      "\\b(natural language processing|nlp)\\b",
      "\\bnatural language generation\\b",
      "\\bnatural language understanding\\b",
      "\\bspeech recognition\\b",
      "\\bimage recognition\\b",
      "\\b(optical character recognition|ocr)\\b",
      "\\bexpert system\\b",
      "\\breinforcement learning\\b",
      "\\b(large language model|large language models|llm|llms)\\b",
      "\\b(foundation model|foundation models)\\b",
      "\\b(generative ai|genai)\\b",
      "\\b(transformer model|transformer models|transformer architecture|transformers)\\b",
      "\\b(retrieval augmented generation|retrieval-augmented generation|rag pipeline|rag system|rag systems)\\b",
      "\\b(gpt[- ]?3|gpt[- ]?4|gpt[- ]?4o|gpt[- ]?5|chatgpt)\\b",
      "\\b(chatbot|chatbots|copilot|copilots|ai assistant|virtual assistant)\\b",
      "\\b(robotic process automation|software robotic process automation|intelligent automation)\\b",
      "\\b(recommendation engine|recommendation system|recommendation systems|recommender system)\\b",
      "\\b(predictive analytics|predictive analytic|predictive model|predictive models)\\b",
      "\\b(knowledge graph|knowledge graphs)\\b",
      "\\binformation extraction\\b",
      "\\b(text mining|text analytics|text classification)\\b",
      "\\bsentiment analysis\\b",
      "\\bobject detection\\b",
      "\\bpattern recognition\\b",
      "\\bface recognition\\b",
      "\\bvirtual agent\\b",
      "\\b(autonomous system|autonomous systems|autonomous vehicle|autonomous vehicles|self-driving|self driving|autonomous robot|autonomous robots|autonomous drone|autonomous drones)\\b",
      "\\bdata mining\\b",
      "\\btransfer learning\\b",
      "\\b(word embedding|word2vec|embedding model|embedding models|vector embedding|vector embeddings)\\b",
      "\\b(topic model|topic modelling|topic modeling|latent dirichlet allocation)\\b",
      "\\b(support vector machine|support vector regression)\\b",
      "\\brandom forest\\b",
      "\\bxgboost\\b"
    ),
    base_weight = c(
      1.00, 0.95, 0.95, 1.00, 0.95, 0.90, 0.95, 0.90, 0.90, 0.85,
      0.85, 0.80, 0.80, 0.95, 1.10, 1.05, 1.10, 1.00, 1.00, 0.95,
      0.70, 0.55, 0.50, 0.45, 0.45, 0.45, 0.45, 0.45, 0.45, 0.45,
      0.45, 0.45, 0.55, 0.40, 0.50, 0.40, 0.35, 0.35, 0.35, 0.35
    ),
    requires_anchor = c(
      FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
      FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
      TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
      TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE
    )
  )
  
  dt[, pattern := paste0("(?i)", pattern)]
  dt[]
}

AI_DICT <- make_ai_dictionary()
ANCHOR_PATTERN <- paste0("(?i)(", paste(AI_DICT[family %in% c("core", "genai"), sub("^\\(\\?i\\)", "", pattern)], collapse = "|"), ")")
ANY_DICT_PATTERN <- paste0("(?i)(", paste(AI_DICT[, sub("^\\(\\?i\\)", "", pattern)], collapse = "|"), ")")

# ============================================================
# CONTEXT CLASSIFICATION
# ============================================================
operational_cues <- c(
  "deploy", "deployed", "deployment",
  "implement", "implemented", "implementation",
  "integrate", "integrated", "integration",
  "use", "uses", "used", "using",
  "embed", "embedded", "embedding",
  "power", "powered", "powering",
  "run on", "running on",
  "automate", "automated", "automation",
  "optimi[sz]e", "optimi[sz]ed", "optimi[sz]ation",
  "generate", "generated", "generating",
  "classify", "classifies", "classification",
  "detect", "detects", "detection",
  "predict", "predicts", "prediction",
  "recommend", "recommends", "recommendation",
  "assist", "assists", "assistant",
  "customer service", "workflow", "operations", "operational",
  "manufacturing", "supply chain", "underwriting", "fraud detection",
  "claims processing", "demand forecasting", "contact center"
)

capability_cues <- c(
  "develop", "developed", "developing", "development",
  "build", "built", "building",
  "train", "trained", "training",
  "fine[- ]?tune", "fine[- ]?tuned", "fine[- ]?tuning",
  "offer", "offers", "offering",
  "provide", "provides", "providing",
  "sell", "sells", "selling",
  "license", "licenses", "licensing",
  "platform", "solution", "solutions", "product", "products",
  "service", "services", "model", "models", "application", "applications",
  "api", "inference", "compute", "accelerator"
)

experimental_cues <- c(
  "pilot", "pilots", "piloted",
  "prototype", "prototypes", "prototyping",
  "proof of concept", "poc",
  "trial", "trials", "testing", "test",
  "explore", "exploring", "exploration",
  "evaluate", "evaluating", "evaluation",
  "assess", "assessing", "assessment",
  "intend", "intends", "intended",
  "plan", "plans", "planned", "planning",
  "expect", "expects", "expected",
  "may", "might", "could", "potential"
)

risk_cues <- c(
  "risk factor", "risk factors", "risks",
  "regulatory", "regulation", "compliance",
  "ethic", "responsible ai", "bias", "hallucination",
  "cybersecurity", "privacy", "security",
  "legal", "litigation", "governance",
  "misleading", "ai washing"
)

external_cues <- c(
  "industry", "industries", "market trend", "market trends",
  "competitive landscape", "competitor", "competitors",
  "third party", "third-party", "vendor", "vendors",
  "supplier", "suppliers",
  "customer demand", "public discourse", "news coverage",
  "sector", "across the industry"
)

negation_cues <- c(
  "do not use", "does not use", "did not use",
  "not using", "no current use", "no material use",
  "have not deployed", "has not deployed", "had not deployed",
  "no deployment", "not deployed", "not implemented",
  "not material", "immaterial", "limited use"
)

materiality_cues <- c(
  "revenue", "revenues", "sales", "margin", "margins",
  "productivity", "efficiency", "cost saving", "cost savings",
  "opex", "capex", "profit", "profits", "ebitda",
  "customer", "customers", "subscription", "bookings", "contract",
  "operations", "operational", "throughput", "yield"
)

make_or_pattern <- function(x, word_boundaries = TRUE) {
  pieces <- paste(x, collapse = "|")
  if (word_boundaries) {
    paste0("(?i)\\b(", pieces, ")\\b")
  } else {
    paste0("(?i)(", pieces, ")")
  }
}

OPERATIONAL_PATTERN <- make_or_pattern(operational_cues)
CAPABILITY_PATTERN  <- make_or_pattern(capability_cues)
EXPERIMENTAL_PATTERN <- make_or_pattern(experimental_cues)
RISK_PATTERN <- make_or_pattern(risk_cues)
EXTERNAL_PATTERN <- make_or_pattern(external_cues)
NEGATION_PATTERN <- make_or_pattern(negation_cues, word_boundaries = FALSE)
MATERIALITY_PATTERN <- make_or_pattern(materiality_cues)

classify_context <- function(context_text) {
  context_text <- normalize_text(context_text)
  if (!nzchar(context_text)) {
    return(list(class = "unclear", material = 0L))
  }
  
  n_neg  <- count_regex_safe(context_text, NEGATION_PATTERN)
  n_op   <- count_regex_safe(context_text, OPERATIONAL_PATTERN)
  n_cap  <- count_regex_safe(context_text, CAPABILITY_PATTERN)
  n_exp  <- count_regex_safe(context_text, EXPERIMENTAL_PATTERN)
  n_risk <- count_regex_safe(context_text, RISK_PATTERN)
  n_ext  <- count_regex_safe(context_text, EXTERNAL_PATTERN)
  n_mat  <- count_regex_safe(context_text, MATERIALITY_PATTERN)
  
  cls <- "unclear"
  if (n_neg > 0L) {
    cls <- "negated"
  } else if ((n_op + n_mat) > 0L && (n_op + n_mat) >= n_cap && (n_op + n_mat) >= n_exp) {
    cls <- "operational"
  } else if (n_cap > 0L && n_cap >= n_exp) {
    cls <- "capability"
  } else if (n_exp > 0L) {
    cls <- "experimental"
  } else if (n_risk > 0L && n_risk >= n_ext) {
    cls <- "risk_governance"
  } else if (n_ext > 0L) {
    cls <- "external"
  }
  
  list(class = cls, material = as.integer(n_mat > 0L))
}

context_weight <- function(context_class, material_flag = 0L) {
  base <- fifelse(
    context_class == "operational", 1.00,
    fifelse(
      context_class == "capability", 0.70,
      fifelse(
        context_class == "experimental", 0.30,
        fifelse(
          context_class == "risk_governance", 0.10,
          fifelse(
            context_class == "external", 0.05,
            fifelse(context_class == "negated", 0.00, 0.20)
          )
        )
      )
    )
  )
  
  ifelse(context_class == "operational" & material_flag > 0L, base * 1.15, base)
}

section_weight <- function(section) {
  ifelse(section == "item1", 1.05, 1.00)
}

# ============================================================
# LONG -> WIDE
# ============================================================
long_to_wide_filings <- function(dt) {
  required_cols <- c("item", "year", "accession_number", "cik", "form_type", "text")
  missing_cols <- setdiff(required_cols, names(dt))
  if (length(missing_cols) > 0L) {
    stop("Missing required columns: ", paste(missing_cols, collapse = ", "))
  }
  
  dt <- copy(dt)
  dt <- dt[item %in% c("item1", "item7")]
  
  dt_collapsed <- dt[
    ,
    .(text = paste(unique(text[!is.na(text) & nzchar(text)]), collapse = " ")),
    by = .(accession_number, cik, year, form_type, item)
  ]
  
  wide <- dcast(
    dt_collapsed,
    accession_number + cik + year + form_type ~ item,
    value.var = "text",
    fill = ""
  )
  
  if (!("item1" %in% names(wide))) wide[, item1 := ""]
  if (!("item7" %in% names(wide))) wide[, item7 := ""]
  
  setnames(wide, old = c("item1", "item7"), new = c("item1_text", "item7_text"))
  setcolorder(wide, c("accession_number", "cik", "year", "form_type", "item1_text", "item7_text"))
  wide[, year := as.integer(year)]
  wide[]
}

# ============================================================
# CORPUS STATS FOR SMOOTHED IDF + YEARLY AVG DOC LENGTH
# ============================================================
concept_presence <- function(text) {
  text <- normalize_text(text)
  if (!nzchar(text)) return(character())
  if (!stri_detect_regex(text, ANY_DICT_PATTERN)) return(character())
  
  present <- AI_DICT[vapply(pattern, function(p) {
    tryCatch(stringi::stri_detect_regex(text, p)[1], error = function(e) FALSE)
  }, logical(1)), concept]
  
  unique(present)
}

build_corpus_stats <- function(files) {
  message("\nPass 1/2: building corpus statistics for smoothed IDF and yearly length normalisation...")
  
  df_list <- list()
  doc_list <- list()
  idx_df <- 1L
  idx_doc <- 1L
  
  for (fp in files) {
    message("Scanning for corpus stats: ", basename(fp))
    dt <- readRDS(fp)
    if (!is.data.table(dt)) dt <- as.data.table(dt)
    wide_dt <- long_to_wide_filings(dt)
    
    wide_dt[, combined_text := paste(item1_text, item7_text, sep = " ")]
    wide_dt[, total_words_tmp := word_count(combined_text)]
    
    docs_this <- wide_dt[, .(
      year = as.integer(year),
      total_words = as.numeric(total_words_tmp)
    )]
    doc_list[[idx_doc]] <- docs_this
    idx_doc <- idx_doc + 1L
    
    for (r in seq_len(nrow(wide_dt))) {
      concepts <- concept_presence(wide_dt$combined_text[r])
      if (length(concepts) == 0L) next
      df_list[[idx_df]] <- data.table(
        year = as.integer(wide_dt$year[r]),
        concept = concepts
      )
      idx_df <- idx_df + 1L
    }
  }
  
  docs_dt <- if (length(doc_list)) rbindlist(doc_list, fill = TRUE) else data.table(year = integer(), total_words = numeric())
  df_dt   <- if (length(df_list)) rbindlist(df_list, fill = TRUE) else data.table(year = integer(), concept = character())
  
  year_stats <- docs_dt[
    ,
    .(
      n_docs = .N,
      avg_words_year = mean(total_words, na.rm = TRUE)
    ),
    by = .(year)
  ]
  
  df_year <- if (nrow(df_dt) > 0L) {
    unique(df_dt)[, .(df = .N), by = .(year, concept)]
  } else {
    data.table(year = integer(), concept = character(), df = integer())
  }
  
  idf_year <- merge(df_year, year_stats, by = "year", all.x = TRUE)
  idf_year[, idf := log((n_docs + 1) / (df + 1)) + 1]
  
  global_docs <- nrow(docs_dt)
  global_df <- if (nrow(df_dt) > 0L) {
    unique(df_dt)[, .(df = .N), by = .(concept)]
  } else {
    data.table(concept = AI_DICT$concept, df = 0L)
  }
  global_df[, global_idf := log((global_docs + 1) / (df + 1)) + 1]
  
  list(
    year_stats = year_stats,
    idf_year = idf_year[, .(year, concept, idf)],
    global_idf = global_df[, .(concept, global_idf)]
  )
}

# ============================================================
# SENTENCE-LEVEL MENTION EXTRACTION
# ============================================================
extract_mentions_one_text <- function(text, section_name, row_id, file_id, year_value) {
  text <- clean_utf8(text)
  if (!nzchar(normalize_text(text))) return(data.table())
  
  sentences <- split_sentences_safe(text)
  n_sent <- length(sentences)
  if (n_sent == 0L) return(data.table())
  
  out <- list()
  j <- 1L
  
  for (i in seq_len(n_sent)) {
    sent <- sentences[i]
    if (!nzchar(sent)) next
    if (!stri_detect_regex(sent, ANY_DICT_PATTERN)) next
    
    lo <- max(1L, i - CONTEXT_WINDOW)
    hi <- min(n_sent, i + CONTEXT_WINDOW)
    window <- paste(sentences[lo:hi], collapse = " ")
    has_anchor <- stri_detect_regex(window, ANCHOR_PATTERN)
    ctx <- classify_context(window)
    
    for (k in seq_len(nrow(AI_DICT))) {
      pat <- AI_DICT$pattern[k]
      if (AI_DICT$requires_anchor[k] && !has_anchor) next
      n_hits <- count_regex_safe(sent, pat)
      if (n_hits <= 0L) next
      
      out[[j]] <- data.table(
        file_id = file_id,
        row_id = row_id,
        year = as.integer(year_value),
        section = section_name,
        sentence_id = i,
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
  
  if (length(out) == 0L) return(data.table())
  rbindlist(out, fill = TRUE)
}

extract_mentions_table <- function(wide_dt, file_id) {
  out <- vector("list", nrow(wide_dt) * 2L)
  j <- 1L
  
  for (r in seq_len(nrow(wide_dt))) {
    out[[j]] <- extract_mentions_one_text(wide_dt$item1_text[r], "item1", r, file_id, wide_dt$year[r])
    j <- j + 1L
    out[[j]] <- extract_mentions_one_text(wide_dt$item7_text[r], "item7", r, file_id, wide_dt$year[r])
    j <- j + 1L
  }
  
  mentions <- rbindlist(out, fill = TRUE)
  
  if (nrow(mentions) == 0L) {
    mentions <- data.table(
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
  
  mentions
}

# ============================================================
# ROW-LEVEL SCORING
# ============================================================
score_mentions <- function(wide_dt, mentions, corpus_stats) {
  wide_dt <- copy(wide_dt)
  wide_dt[, row_id := .I]
  wide_dt[, item1_words := word_count(item1_text)]
  wide_dt[, item7_words := word_count(item7_text)]
  wide_dt[, total_words := item1_words + item7_words]
  
  wide_dt <- merge(wide_dt, corpus_stats$year_stats, by = "year", all.x = TRUE)
  global_avg_words <- mean(corpus_stats$year_stats$avg_words_year, na.rm = TRUE)
  if (!is.finite(global_avg_words)) global_avg_words <- mean(wide_dt$total_words, na.rm = TRUE)
  if (!is.finite(global_avg_words) || is.na(global_avg_words) || global_avg_words <= 0) global_avg_words <- 1
  wide_dt[is.na(avg_words_year) | avg_words_year <= 0, avg_words_year := global_avg_words]
  
  if (nrow(mentions) == 0L) {
    wide_dt[, `:=`(
      ai_mentions_total = 0L,
      ai_operational_n = 0L,
      ai_capability_n = 0L,
      ai_experimental_n = 0L,
      ai_risk_n = 0L,
      ai_external_n = 0L,
      ai_negated_n = 0L,
      ai_unclear_n = 0L,
      ai_core_n = 0L,
      ai_genai_n = 0L,
      ai_secondary_n = 0L,
      ai_item1_mentions = 0L,
      ai_item7_mentions = 0L,
      ai_dictionary_breadth = 0L,
      ai_operational_concept_breadth = 0L,
      ai_section_breadth = 0L,
      ai_mentions_per_1k = 0,
      ai_operational_per_1k = 0,
      ai_genai_per_1k = 0,
      ai_weighted_score_raw = 0,
      ai_adoption_score_raw = 0,
      ai_adoption_score = 0,
      ai_any_mention = 0L,
      ai_any_operational = 0L,
      ai_any_genai = 0L,
      ai_dominant_context = "none"
    )]
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
  
  mentions_agg <- merge(mentions_agg, corpus_stats$idf_year, by = c("year", "concept"), all.x = TRUE)
  mentions_agg <- merge(mentions_agg, corpus_stats$global_idf, by = "concept", all.x = TRUE)
  mentions_agg[is.na(idf), idf := global_idf]
  mentions_agg[is.na(idf), idf := 1]
  
  mentions_agg <- merge(
    mentions_agg,
    wide_dt[, .(row_id, total_words, avg_words_year)],
    by = "row_id",
    all.x = TRUE
  )
  
  mentions_agg[, len_norm := 1 - BM25_B + BM25_B * safe_divide(total_words, avg_words_year)]
  mentions_agg[len_norm <= 0 | is.na(len_norm), len_norm := 1]
  
  mentions_agg[, tf_component := ((n_mentions * (BM25_K1 + 1)) / (n_mentions + BM25_K1))]
  mentions_agg[, ctx_weight := context_weight(context_class, material_flag)]
  mentions_agg[, sec_weight := section_weight(section)]
  mentions_agg[, concept_score := base_weight * idf * tf_component * ctx_weight * sec_weight / len_norm]
  
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
      ai_negated_weighted = sum(concept_score[context_class == "negated"]),
      ai_genai_weighted = sum(concept_score[family == "genai"])
    ),
    by = .(row_id)
  ]
  
  wide_dt <- merge(wide_dt, row_metrics, by = "row_id", all.x = TRUE)
  
  num_fill_zero <- c(
    "ai_mentions_total", "ai_operational_n", "ai_capability_n", "ai_experimental_n",
    "ai_risk_n", "ai_external_n", "ai_negated_n", "ai_unclear_n", "ai_core_n",
    "ai_genai_n", "ai_secondary_n", "ai_item1_mentions", "ai_item7_mentions",
    "ai_dictionary_breadth", "ai_operational_concept_breadth", "ai_section_breadth",
    "ai_weighted_score_raw", "ai_operational_weighted", "ai_capability_weighted",
    "ai_experimental_weighted", "ai_risk_weighted", "ai_negated_weighted", "ai_genai_weighted"
  )
  for (cc in num_fill_zero) {
    wide_dt[is.na(get(cc)), (cc) := 0]
  }
  
  wide_dt[, ai_mentions_per_1k := 1000 * safe_divide(ai_mentions_total, total_words)]
  wide_dt[, ai_operational_per_1k := 1000 * safe_divide(ai_operational_n, total_words)]
  wide_dt[, ai_genai_per_1k := 1000 * safe_divide(ai_genai_n, total_words)]
  
  # Raw adoption score = operational + capability + light experimentation,
  # plus modest breadth rewards, while keeping risk/negation separate rather
  # than heavily penalising already-low context weights.
  wide_dt[, ai_adoption_score_raw :=
            ai_operational_weighted +
            0.75 * ai_capability_weighted +
            0.30 * ai_experimental_weighted +
            0.05 * log1p(ai_operational_concept_breadth) +
            0.05 * pmin(ai_section_breadth, 2)
  ]
  
  wide_dt[, ai_adoption_score := 1 - exp(-ai_adoption_score_raw)]
  wide_dt[, ai_adoption_score := cap01(ai_adoption_score)]
  
  wide_dt[, ai_any_mention := as.integer(ai_mentions_total > 0)]
  wide_dt[, ai_any_operational := as.integer(ai_operational_n > 0)]
  wide_dt[, ai_any_genai := as.integer(ai_genai_n > 0)]
  
  wide_dt[, ai_dominant_context := fifelse(
    ai_operational_n >= pmax(ai_capability_n, ai_experimental_n, ai_risk_n, ai_external_n, ai_unclear_n) & ai_mentions_total > 0,
    "operational",
    fifelse(
      ai_capability_n >= pmax(ai_experimental_n, ai_risk_n, ai_external_n, ai_unclear_n) & ai_mentions_total > 0,
      "capability",
      fifelse(
        ai_experimental_n >= pmax(ai_risk_n, ai_external_n, ai_unclear_n) & ai_mentions_total > 0,
        "experimental",
        fifelse(
          ai_risk_n >= pmax(ai_external_n, ai_unclear_n) & ai_mentions_total > 0,
          "risk_governance",
          fifelse(ai_mentions_total > 0, "external_or_unclear", "none")
        )
      )
    )
  )]
  
  wide_dt[]
}

# ============================================================
# FILE SELECTION
# ============================================================
get_files_to_process <- function() {
  if (MODE == "full") {
    files <- file.path(ASSEMBLED_DIR, "extract_dataframe_full.rds")
    files <- files[file.exists(files)]
    return(files)
  }
  
  if (MODE == "chunks") {
    files <- list.files(
      ASSEMBLED_DIR,
      pattern = "^extract_df_chunk_[0-9]{5}\\.rds$",
      full.names = TRUE
    )
    
    if (!is.null(CHUNK_START)) {
      chunk_num <- as.integer(sub("^.*_([0-9]{5})\\.rds$", "\\1", basename(files)))
      files <- files[chunk_num >= CHUNK_START]
    }
    
    if (!is.null(CHUNK_END)) {
      chunk_num <- as.integer(sub("^.*_([0-9]{5})\\.rds$", "\\1", basename(files)))
      files <- files[chunk_num <= CHUNK_END]
    }
    
    return(files)
  }
  
  stop("MODE must be either 'full' or 'chunks'")
}

# ============================================================
# PROCESS ONE FILE
# ============================================================
process_one_file <- function(path_in, corpus_stats) {
  file_id <- file_path_sans_ext(basename(path_in))
  message("\nProcessing: ", path_in)
  
  dt <- readRDS(path_in)
  if (!is.data.table(dt)) dt <- as.data.table(dt)
  
  wide_dt <- long_to_wide_filings(dt)
  mentions <- extract_mentions_table(wide_dt, file_id = file_id)
  scored <- score_mentions(wide_dt, mentions, corpus_stats = corpus_stats)
  
  # join a compact example context per row for QA convenience
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
    scored <- merge(scored, qa_examples, by = "row_id", all.x = TRUE)
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
  fwrite(mentions, out_mentions)
  
  message("Saved scored RDS: ", out_rds)
  message("Saved scored CSV: ", out_csv)
  message("Saved mention CSV: ", out_mentions)
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
files <- get_files_to_process()

if (length(files) == 0L) {
  stop("No files found to process in mode: ", MODE)
}

message("Mode: ", MODE)
message("Files to process: ", length(files))


files <- files[1:2]

corpus_stats <- build_corpus_stats(files)

for (fp in files) {
  process_one_file(fp, corpus_stats = corpus_stats)
}

message("\nDone.")
