client OpenRouter4oMini {
  provider "openai-generic"
  options {
    base_url "https://openrouter.ai/api/v1"
    model "openai/gpt-4o-mini"
    api_key env.OPENROUTER_API_KEY
  }
}
