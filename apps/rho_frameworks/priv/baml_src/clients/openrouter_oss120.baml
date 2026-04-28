client OpenRouterOSS120 {
  provider "openai-generic"
  options {
    base_url "https://openrouter.ai/api/v1"
    model "openai/gpt-oss-120b"
    api_key env.OPENROUTER_API_KEY
  }
}
