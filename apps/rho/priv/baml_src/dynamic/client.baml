client Openrouter {
  provider "openai-generic"
  options {
    base_url "https://openrouter.ai/api/v1"
    model "anthropic/claude-sonnet-4.6"
    api_key env.OPENROUTER_API_KEY
  }
}
