"""Write tests/fixtures/raster.pdf, the render-page fixture, from scratch.

    python3 tests/fixtures/make-raster-pdf.py                 # write the PDF only
    uv run --with pypdfium2==5.15.2 python -I tests/fixtures/make-raster-pdf.py
                                                              # and print the oracle

The PDF is hand-assembled here (no third-party content): four pages of filled
rectangles and one line of Helvetica (a standard font, not embedded). With
pypdfium2 installed the script also renders every page through pypdfium2's own
pdfium build and prints the sizes, probe pixels and pixel counts that
tests/render-test.lisp expects. Coordinates in comments are top-left based,
in points (= pixels at 72 dpi).
"""

import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "raster.pdf")

PAGES = [
    # 0: 300 x 200. Background left unpainted (render-page fills white).
    #    black 100 x 80 at (30, 40); red 90 x 50 at (180, 130);
    #    blue 90 x 40 at (180, 50); black text, baseline at y 30.
    ("/MediaBox [0 0 300 200]",
     "0 0 0 rg 30 80 100 80 re f\n"
     "1 0 0 rg 180 20 90 50 re f\n"
     "0 0 1 rg 180 110 90 40 re f\n"
     "0 g BT /F1 12 Tf 30 170 Td (Raster fixture) Tj ET"),
    # 1: 144 x 72 turned 90 degrees clockwise by /Rotate, so 72 x 144 on screen.
    #    The black left half of the unrotated page becomes the top half.
    ("/MediaBox [0 0 144 72] /Rotate 90",
     "0 0 0 rg 0 0 72 72 re f"),
    # 2: 5 x 5, all black: 2.5 px at 36 dpi, so the rounding rule shows.
    ("/MediaBox [0 0 5 5]",
     "0 0 0 rg 0 0 5 5 re f"),
    # 3: CropBox 100 x 50 inside a 200 x 200 MediaBox; black left half.
    ("/MediaBox [0 0 200 200] /CropBox [50 50 150 100]",
     "0 0 0 rg 50 50 50 50 re f"),
]


def build():
    objs = {1: "<< /Type /Catalog /Pages 2 0 R >>"}
    kids = []
    font = 3 + 2 * len(PAGES)
    for i, (boxes, content) in enumerate(PAGES):
        page, stream = 3 + 2 * i, 4 + 2 * i
        kids.append(f"{page} 0 R")
        objs[page] = (f"<< /Type /Page /Parent 2 0 R {boxes} /Contents {stream} 0 R"
                      f" /Resources << /Font << /F1 {font} 0 R >> >> >>")
        data = content.encode("ascii")
        objs[stream] = f"<< /Length {len(data)} >>\nstream\n{content}\nendstream"
    objs[2] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(PAGES)} >>"
    objs[font] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    info = font + 1
    objs[info] = "<< /Title (Raster fixture) /Producer (make-raster-pdf.py) >>"
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for n in sorted(objs):
        offsets[n] = len(out)
        out += f"{n} 0 obj\n{objs[n]}\nendobj\n".encode("ascii")
    xref = len(out)
    out += f"xref\n0 {info + 1}\n0000000000 65535 f \n".encode("ascii")
    for n in range(1, info + 1):
        out += f"{offsets[n]:010d} 00000 n \n".encode("ascii")
    out += (f"trailer\n<< /Size {info + 1} /Root 1 0 R /Info {info} 0 R >>\n"
            f"startxref\n{xref}\n%%EOF\n").encode("ascii")
    return bytes(out)


def oracle():
    import pypdfium2 as pdfium
    import pypdfium2.raw as c

    print("pypdfium2", pdfium.version.PYPDFIUM_INFO, "pdfium", pdfium.version.PDFIUM_INFO)
    pdf = pdfium.PdfDocument(OUT)
    for index, dpi in [(0, 72), (0, 150), (1, 72), (1, 150), (2, 36), (3, 72)]:
        page = pdf[index]
        w, h = page.get_size()
        bm = page.render(scale=dpi / 72, fill_color=(255, 255, 255, 255),
                         force_bitmap_format=c.FPDFBitmap_BGRA)
        buf = bytes(bm.buffer)
        bw, bh, stride = bm.width, bm.height, bm.stride

        def rgba(x, y):
            o = y * stride + 4 * x
            b, g, r, a = buf[o:o + 4]
            return (r, g, b, a)

        counts = {"dark": 0, "red": 0, "blue": 0, "white": 0, "opaque": 0}
        for y in range(bh):
            for x in range(bw):
                r, g, b, a = rgba(x, y)
                counts["opaque"] += a == 255
                counts["dark"] += r < 64 and g < 64 and b < 64
                counts["red"] += r >= 192 and g < 64 and b < 64
                counts["blue"] += b >= 192 and r < 64 and g < 64
                counts["white"] += r >= 250 and g >= 250 and b >= 250
        k = dpi / 72
        probes = {"0": [(80, 80), (225, 155), (225, 70), (5, 195), (290, 10), (150, 125)],
                  "1": [(36, 36), (36, 108)], "2": [(0, 0)], "3": [(25, 25), (75, 25)]}[str(index)]
        print(f"page {index} at {dpi} dpi: points {w} x {h}; pypdfium2 bitmap {bw} x {bh}"
              f" stride {stride}; counts {counts}")
        for (x, y) in probes:
            px, py = int(x * k), int(y * k)
            print(f"  probe pt ({x}, {y}) -> px ({px}, {py}) = {rgba(px, py)}")


def main():
    data = build()
    with open(OUT, "wb") as f:
        f.write(data)
    print(f"wrote {OUT} ({len(data)} bytes)")
    if importlib.util.find_spec("pypdfium2"):
        oracle()


if __name__ == "__main__":
    main()
