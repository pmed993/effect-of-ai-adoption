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

