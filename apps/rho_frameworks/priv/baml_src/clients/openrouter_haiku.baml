client OpenRouterHaiku {
  provider "openai-generic"
  options {
    base_url "https://openrouter.ai/api/v1"
    model "anthropic/claude-haiku-4.5"
    api_key env.OPENROUTER_API_KEY
  }
}
