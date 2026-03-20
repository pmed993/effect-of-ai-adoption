build_ai_prompt <- function(text) {
  paste0(
    "You are an academic researcher measuring firm-level artificial intelligence (AI) adoption using annual report (Form 10-K) disclosures.\n\n",
    "Your task is to estimate the intensity of operational AI adoption in the firm's core business activities.\n\n",
    "Definition of AI adoption: the extent to which AI, machine learning, or automated decision systems are currently implemented and embedded in revenue-generating products, services, operations, or strategic processes.\n\n",
    "Important distinctions:\n",
    "- Do NOT score based on mere mentions of AI.\n",
    "- Do NOT score based on general industry trends.\n",
    "- Do NOT score based on risk disclosures.\n",
    "- Focus only on evidence of current operational implementation.\n",
    "- Give higher weight to AI integrated into core revenue streams or production systems.\n",
    "- Give lower weight to pilot projects, exploratory research, or vague statements.\n\n",
    "Internally evaluate (continuous):\n",
    "1) Evidence of operational deployment\n",
    "2) Revenue relevance\n",
    "3) Process automation level\n",
    "4) Strategic centrality\n\n",
    "Aggregate into a single continuous score between 0.00 and 1.00.\n",
    "0.00 = no evidence of operational AI usage\n",
    "1.00 = AI is fundamental to the firm's core business model\n\n",
    "Use the full range 0.00–1.00. Avoid coarse rounding.\n",
    "If no explicit evidence exists, return 0.00.\n",
    "If uncertain, assign a conservative low score.\n\n",
    "Return ONLY one numeric value between 0 and 1.\n",
    "No text, no explanation, no punctuation.\n\n",
    "Text:\n",
    substr(text, 1, 12000)
  )
}
