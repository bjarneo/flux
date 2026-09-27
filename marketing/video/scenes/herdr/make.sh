#!/bin/bash
# Bakes the phone screens that only the herdr video uses.
#   agent-codex-working.png   the codex output after the answer: the status
#                             label '● WORKING' from the claude capture, which
#                             has the same card, and no choice buttons.
#   agent-codex-done.png      the same screen after the agent finished: the
#                             label '● DONE' from the web card of the agents
#                             list, which uses the same label style.
set -euo pipefail
cd "$(dirname "$0")/../.."
magick assets/phone/agent-codex.png \
  '(' assets/cap/herdr-agent_w1_p1.png -crop 280x44+56+302 +repage ')' -geometry +56+302 -composite \
  -fill '#16161E' -draw 'rectangle 0,1695 1080,2022' \
  scenes/herdr/agent-codex-working.png
magick scenes/herdr/agent-codex-working.png \
  '(' assets/phone/agents.png -crop 280x44+56+580 +repage ')' -geometry +56+302 -composite \
  scenes/herdr/agent-codex-done.png
echo scenes/herdr/agent-codex-working.png scenes/herdr/agent-codex-done.png
