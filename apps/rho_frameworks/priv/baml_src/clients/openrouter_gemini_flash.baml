client OpenRouterGeminiFlash {
  provider "openai-generic"
  options {
    base_url "https://openrouter.ai/api/v1"
    model "google/gemini-2.5-flash"
    api_key env.OPENROUTER_API_KEY
  }
}
