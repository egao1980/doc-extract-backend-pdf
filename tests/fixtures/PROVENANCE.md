# tests/fixtures/

| File | Content | Source | License | Regenerate |
|------|---------|--------|---------|------------|
| `raster.pdf` | 4 pages for `render-page`: 300 × 200 pt with black, red and blue rectangles and a line of Helvetica; 144 × 72 pt with `/Rotate 90`; 5 × 5 pt; a 100 × 50 pt CropBox inside a 200 × 200 MediaBox | written byte by byte by `make-raster-pdf.py` (Python standard library only); no third-party content. Helvetica is named, not embedded. | MIT (this repository) | `python3 tests/fixtures/make-raster-pdf.py` |

The pixel-count bands and probe pixels in `tests/render-test.lisp` were measured by rendering `raster.pdf` through an independent pdfium build: `uv run --with pypdfium2==5.15.2 python -I tests/fixtures/make-raster-pdf.py` (pypdfium2 5.15.2, Apache-2.0 OR BSD-3-Clause, bundling pdfium 159.0.8149, BSD-3-Clause). Only the measurements are recorded. The overlay this repository ships is pdfium 154.0.8035, so the live tests allow ± 3 % on the counts, except the opaque count, which must be every pixel. The rectangle counts at 72 dpi are exact (4500 red, 3600 blue): pdfium fills axis-aligned rectangles on whole pixels.

pypdfium2 sizes its bitmaps by rounding up, where `render-page` rounds to nearest. The two agree on every fixture page; they would differ on, for example, a 100.2 pt side at 72 dpi (101 px for pypdfium2, 100 for us).
