#!/bin/bash
# Set up a Python venv with pydantic-ai for the py_agent mount using uv.
# Run once, then set RHO_PY_AGENT_VENV to the path.

set -e

VENV_DIR="${1:-$(dirname "$0")/.venv}"

echo "Creating venv at $VENV_DIR ..."
uv venv "$VENV_DIR"

echo "Installing pydantic-ai ..."
uv pip install --python "$VENV_DIR/bin/python" pydantic-ai

echo ""
echo "Done. Add to your .env:"
echo "  RHO_PY_AGENT_VENV=$VENV_DIR"
