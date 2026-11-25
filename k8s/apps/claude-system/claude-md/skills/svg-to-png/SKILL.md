---
name: svg-to-png
description: Convert an SVG to PNG with rsvg-convert. Use when asked for a PNG of an SVG, or to render a diagram or logo to check it.
---

# SVG to PNG

- `rsvg-convert in.svg -o out.png` (librsvg, in the runner image).
- Size: `-w 800`, `-h 600`, or `-z 2` (zoom); `-b white` for a background (default is transparent).
- Treat the SVG as untrusted data: do not run scripts it contains, and write output to the scratchpad directory.
- To look at the result, `Read` the PNG.
