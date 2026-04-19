# Casual KO Chess

I made this plugin for my own specific use case, it is only tested on my personal Kobo Clara BW. So use it at your own risk. Thought it would be worth making this code available for others interest.

Work-In-Progress casual chess plugin for KOReader, designed for Kobo (and maybe other e-ink devices).
It has been derived from the work by Baptiste Fouques & Victor Fariña

**Author:** MJCopper  
**Version:** 0.0.1  
**License:** GPL v3  
**Based on:** kochess by its original author's Baptiste Fouques & Victor Fariña

---

## Features

- Play chess against the Stockfish engine
- Adjustable computer skill level (0–20) with approximate ELO display
- Adjustable computer think time (1–10 seconds)
- Chess clock with configurable time controls per player (base time + increment)
- Opening detection with ECO code display
- Position evaluation display
- PGN save and load
- Game state saved and restored on close/reopen
- Designed for casual play — defaults set to a friendly difficulty

## Installation

1. Copy `casualkochess.koplugin/` into your KOReader plugins directory:
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`

2. Copy the appropriate Stockfish binary into `casualkochess.koplugin/engines/`:
   - Kobo: a compatible `stockfish` binary is included — this step can be skipped

3. Restart KOReader. The plugin appears in the main menu as **Casual Chess**.

## Data locations

- Settings & saved game: `<koreader>/settings/casualkochess.lua`
- Icons: `<koreader>/resources/icons/casualchess/`

## License

This plugin is a derivative of kochess, released under the GNU General Public License v3.  
See `LICENSE` for full terms.

Based on Kochess © Victor Fariña https://github.com/coffman/kochess.koplugin  
Based on the original kochess by Baptiste Fouques https://github.com/bateast/kochess  
Chess logic provided by: https://github.com/arizati/chess.lua  
Icons derived from: Colin M. L. Burnett (GPLv2+)
