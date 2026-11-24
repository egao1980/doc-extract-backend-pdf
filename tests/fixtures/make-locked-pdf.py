"""Fixture for doc-extract-backend-pdf: an AES-128 encrypted one-page PDF.
User password "s3cret", owner password "owner-pw". Text: "Locked report".
Run: uv run --with reportlab --with pypdf --with cryptography python -I make-locked-pdf.py locked-aes128.pdf
"""
import io, sys
from reportlab.pdfgen import canvas
from pypdf import PdfReader, PdfWriter

buf = io.BytesIO()
c = canvas.Canvas(buf, invariant=1)
c.setTitle("Locked")
c.setAuthor("egao1980")
c.drawString(72, 720, "Locked report")
c.showPage()
c.save()
w = PdfWriter(clone_from=PdfReader(io.BytesIO(buf.getvalue())))
w.encrypt(user_password="s3cret", owner_password="owner-pw", algorithm="AES-128")
with open(sys.argv[1], "wb") as f:
    w.write(f)
