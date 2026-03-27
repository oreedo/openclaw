#!/bin/bash

# Delete all cached session files on Linux
rm -f ~/.openclaw/agents/main/sessions/*.jsonl
rm -f ~/.openclaw/agents/main/sessions/*.jsonl.lock
rm -f ~/.openclaw/agents/main/sessions/*.jsonl.reset.*

# Optional: Also delete the sessions index file (will be regenerated)
rm -f ~/.openclaw/agents/main/sessions/sessions.json

echo "Cached sessions deleted successfully!"