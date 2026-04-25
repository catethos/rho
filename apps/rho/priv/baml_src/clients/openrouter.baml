client OpenRouter {
  provider "openai-generic"
  options {
    base_url "https://openrouter.ai/api/v1"
    model "deepseek/deepseek-chat-v3-0324"
    api_key env.OPENROUTER_API_KEY
  }
}
