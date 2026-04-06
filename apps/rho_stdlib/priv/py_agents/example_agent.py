"""
Weather agent — pydantic-ai agent callable from Rho via erlang_python.
"""

import os
import urllib.request
import urllib.parse
import json as json_mod

# --- Agent Definition (lazy init) ---

_agent = None
_sessions: dict[str, list] = {}


def _get_agent():
    global _agent
    if _agent is None:
        from pydantic_ai import Agent
        from pydantic_ai.models.openai import OpenAIModel
        from pydantic_ai.providers.openai import OpenAIProvider

        model = OpenAIModel(
            "anthropic/claude-haiku-4.5",
            provider=OpenAIProvider(
                base_url="https://openrouter.ai/api/v1",
                api_key=os.environ["OPENROUTER_API_KEY"],
            ),
        )

        _agent = Agent(
            model,
            instructions=(
                "You are a weather assistant. Use the get_weather tool to look up "
                "current weather for any city. Always call the tool before answering. "
                "You also have a get_air_quality tool for air quality data."
                "always answer in chinese"
            ),
            tools=[get_weather, get_air_quality],
        )
    return _agent


def _geocode(city: str) -> tuple[float, float, str] | None:
    """Geocode a city name to (lat, lon, display_name) using Open-Meteo."""
    url = f"https://geocoding-api.open-meteo.com/v1/search?name={urllib.parse.quote(city)}&count=1"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json_mod.loads(resp.read())
    results = data.get("results")
    if not results:
        return None
    r = results[0]
    name = r.get("name", city)
    country = r.get("country", "")
    display = f"{name}, {country}" if country else name
    return (r["latitude"], r["longitude"], display)


def get_weather(city: str) -> str:
    """Get the current weather for a city.

    Args:
        city: The city name to look up weather for, e.g. 'London' or 'Tokyo'.
    """
    geo = _geocode(city)
    if not geo:
        return f"Could not find city '{city}'."

    lat, lon, display = geo
    url = (
        f"https://api.open-meteo.com/v1/forecast?"
        f"latitude={lat}&longitude={lon}"
        f"&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code"
    )
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json_mod.loads(resp.read())

    current = data["current"]
    temp = current["temperature_2m"]
    humidity = current["relative_humidity_2m"]
    wind = current["wind_speed_10m"]
    code = current["weather_code"]

    WMO_CODES = {
        0: "Clear sky", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
        45: "Foggy", 48: "Depositing rime fog",
        51: "Light drizzle", 53: "Moderate drizzle", 55: "Dense drizzle",
        61: "Slight rain", 63: "Moderate rain", 65: "Heavy rain",
        71: "Slight snow", 73: "Moderate snow", 75: "Heavy snow",
        80: "Slight rain showers", 81: "Moderate rain showers", 82: "Violent rain showers",
        95: "Thunderstorm", 96: "Thunderstorm with slight hail", 99: "Thunderstorm with heavy hail",
    }
    desc = WMO_CODES.get(code, f"Code {code}")

    return f"{display}: {desc}, {temp}°C, humidity {humidity}%, wind {wind} km/h"


def get_air_quality(city: str) -> str:
    """Get air quality index for a city.

    Args:
        city: The city name to check air quality for.
    """
    geo = _geocode(city)
    if not geo:
        return f"Could not find city '{city}'."

    lat, lon, display = geo
    url = (
        f"https://air-quality-api.open-meteo.com/v1/air-quality?"
        f"latitude={lat}&longitude={lon}&current=pm2_5,pm10,us_aqi"
    )
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json_mod.loads(resp.read())

    current = data["current"]
    pm25 = current.get("pm2_5", "N/A")
    pm10 = current.get("pm10", "N/A")
    aqi = current.get("us_aqi", "N/A")

    return f"{display}: AQI {aqi}, PM2.5 {pm25} µg/m³, PM10 {pm10} µg/m³"


# --- Bridge functions ---


def describe() -> dict:
    return {
        "name": "weather",
        "description": "A weather assistant that can look up current weather and air quality for any city.",
    }


def chat(session_id: str, message: str) -> str:
    agent = _get_agent()
    history = _sessions.get(session_id)

    result = agent.run_sync(
        message,
        message_history=history,
    )

    _sessions[session_id] = result.all_messages()
    return result.output


def reset(session_id: str) -> str:
    _sessions.pop(session_id, None)
    return "ok"
