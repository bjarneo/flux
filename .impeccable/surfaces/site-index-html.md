---
version: 1
slug: "site-index-html"
primary_target: "site/index.html"
related_targets: []
---

# Surface brief: the Flux website

Scope: the public marketing site in `site/`, published to GitHub Pages at `https://bjarneo.github.io/flux/`. Persuade mode.

Audience and job: an Omarchy user who found Flux on GitHub, on AUR, or in a video. They must understand in seconds that the phone answers what waits on the computer, and then install Flux on both sides.

Action: install on Omarchy with `yay -S omarchy-flux`, then get the phone or Mac app. Android, iPhone, and Mac get equal weight: the APK and the Mac zip from the latest release, and the Xcode steps for the iPhone.

Proof and content: real captures of Flux for Android from the emulator in demo mode, the desktop window from `make snapshot`, and the Flux mark animation from `marketing/video/engine/ui/bits.js`. No user counts, reviews, or benchmarks. The sample computers and agents of demo mode are sample data.

Constraints: static files with no build step, no file from another site, 1 GitHub API call for the latest release, STE copy, WCAG 2.2 AA, reduced motion respected, works at 390 px wide.

Memorable moment: a large mono clock at 14:07 beside a phone with an agent that waits, and the clock moves on as the visitor scrolls through the afternoon.

Open decisions: none.

## Direction contract

THESIS: The page is one afternoon away from the desk, told by the times on the phone. It refuses the hero-plus-feature-grid page that every phone bridge ships.

OWN-WORLD: Tokyo Night ground `#16161e`, tiles `#1f2335` with 1 px `#292e42` borders, 12 px corners, 8 px gaps, no shadows. JetBrains Mono sets the clock, the times, prompts, commands, and keys. A sans sets what Flux says. 1 tile at a time carries the active border gradient, accent to cyan. Red means only "needs you". The active border follows the tile at the middle of the window across the whole page, as the Hyprland focus follows the pointer. The story moments also drive the clock and the phone.

STORY: At 14:07 an agent waits, and the visitor answers it from the phone. Each later time shows one more thing that Flux does away from the desk, then back at the desk. The visitor believes that the phone and Omarchy work as one, and installs both sides.

FIRST VIEWPORT: Left 7 of 12 columns, because the headline needs the width at 3.6rem: a 14:07 clock in mono at display scale, up to 9rem because it is a lock-screen numeral, the headline, and `yay -S omarchy-flux` with a copy button. The lockup sits in the sticky bar, which stays in view. Right 5 of 12: a phone frame with the real Inbox capture, the agent prompt and its choices. Below: a time rail with the next stops. Signature interaction: a sticky clock that rolls forward to the time of each moment as it scrolls into focus, and that moment takes the active border. The Flux mark traces in on load and again at the end card.

FORM: "One afternoon away", position 6 of 7 on the ranked structure list, seed key 9e8f9593.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
