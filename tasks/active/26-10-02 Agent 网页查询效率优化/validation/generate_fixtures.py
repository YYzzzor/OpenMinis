#!/usr/bin/env python3
"""Generate deterministic, credential-free PDF and raster fixtures in ./fixtures."""
from __future__ import annotations

from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw
from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.lib.utils import ImageReader
from reportlab.lib.pdfencrypt import StandardEncryption
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle
from reportlab.pdfgen import canvas


FIXTURES = Path(__file__).resolve().parent / "fixtures"


def text_pdf(path: Path) -> None:
    styles = getSampleStyleSheet()
    body = ParagraphStyle("FixtureBody", parent=styles["BodyText"], alignment=TA_LEFT, fontName="Helvetica")
    story = [
        Paragraph("MULTIPAGE FIXTURE PAGE 1", styles["Title"]),
        Paragraph("First page paragraph marker: PDF-PAGE-ONE-4107.", body),
        Spacer(1, 0.18 * inch),
        Table(
            [["Plan", "Monthly price"], ["Basic", "39"], ["Pro", "99"]],
            colWidths=[2.4 * inch, 2.4 * inch],
            style=TableStyle([
                ("GRID", (0, 0), (-1, -1), 0.7, colors.black),
                ("BACKGROUND", (0, 0), (-1, 0), colors.lightgrey),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("ALIGN", (1, 1), (1, -1), "RIGHT"),
            ]),
        ),
        PageBreak(),
        Paragraph("MULTIPAGE FIXTURE PAGE 2", styles["Title"]),
        Paragraph("Final page exact marker: PDF-END-MARKER-82C1.", body),
        Paragraph("A separate paragraph preserves a normal reading order.", body),
    ]
    SimpleDocTemplate(str(path), pagesize=letter, title="Local web-read fixture").build(story)


def raster_table(path: Path, fmt: str) -> None:
    image = Image.new("RGB", (960, 420), "white")
    draw = ImageDraw.Draw(image)
    draw.rectangle((16, 16, 944, 404), outline=(25, 45, 60), width=4)
    draw.text((52, 54), "PACKAGE     MONTHLY PRICE", fill=(20, 30, 40))
    draw.line((48, 112, 910, 112), fill=(20, 30, 40), width=3)
    draw.text((52, 164), "BASIC             39", fill=(20, 30, 40))
    draw.text((52, 248), "PRO               99", fill=(20, 30, 40))
    draw.text((52, 340), "IMAGE-FACT-END-617A", fill=(20, 30, 40))
    image.save(path, format=fmt, quality=94 if fmt == "JPEG" else None)


def chart_image(path: Path) -> None:
    image = Image.new("RGB", (800, 360), "white")
    draw = ImageDraw.Draw(image)
    draw.rectangle((12, 12, 788, 348), outline=(30, 50, 70), width=3)
    draw.text((36, 30), "WEEKLY SALES CHART", fill=(20, 30, 40))
    draw.rectangle((110, 180, 230, 310), fill=(75, 125, 180))
    draw.rectangle((330, 125, 450, 310), fill=(75, 125, 180))
    draw.rectangle((550, 75, 670, 310), fill=(75, 125, 180))
    draw.text((140, 318), "W1", fill=(20, 30, 40))
    draw.text((360, 318), "W2", fill=(20, 30, 40))
    draw.text((580, 318), "W3", fill=(20, 30, 40))
    draw.text((36, 72), "CHART-VALUE-END-735B", fill=(20, 30, 40))
    image.save(path, format="PNG")


def scanned_pdf(path: Path) -> None:
    scan_path = FIXTURES / "scan-page.png"
    image = Image.new("RGB", (1275, 1650), "white")
    draw = ImageDraw.Draw(image)
    draw.text((125, 220), "SCANNED ONLY DOCUMENT", fill="black")
    draw.text((125, 360), "OCR TARGET SCAN-OCR-MARKER-59D2", fill="black")
    draw.text((125, 520), "BASIC PRICE 39; PRO PRICE 99", fill="black")
    image.save(scan_path, format="PNG")
    page = canvas.Canvas(str(path), pagesize=letter)
    page.drawImage(ImageReader(str(scan_path)), 0.25 * inch, 0.25 * inch, width=7.5 * inch, height=9.5 * inch)
    page.save()
    scan_path.unlink()


def encrypted_pdf(path: Path) -> None:
    page = canvas.Canvas(str(path), pagesize=letter, encrypt=StandardEncryption("fixture-open", ownerPassword="fixture-owner"))
    page.drawString(72, 700, "ENCRYPTED-PDF-MARKER-4B19")
    page.save()


def large_pdf(path: Path) -> None:
    page = canvas.Canvas(str(path), pagesize=letter, pageCompression=0)
    for page_index in range(1, 33):
        page.setFont("Helvetica", 8)
        page.drawString(36, 760, f"LARGE PDF PAGE {page_index:02d}")
        for row in range(1, 181):
            page.drawString(36, 740 - row * 3.7, f"Page {page_index:02d} row {row:03d} stable payload 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if page_index == 32:
            page.drawString(36, 18, "LARGE-PDF-END-MARKER-88F3")
        page.showPage()
    page.save()


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    text_pdf(FIXTURES / "multipage-table.pdf")
    scanned_pdf(FIXTURES / "scanned-only.pdf")
    encrypted_pdf(FIXTURES / "encrypted.pdf")
    large_pdf(FIXTURES / "large.pdf")
    (FIXTURES / "corrupt.pdf").write_bytes(b"%PDF-1.7\nTHIS IS NOT A VALID PDF OBJECT GRAPH\n%%EOF\n")
    raster_table(FIXTURES / "price-table.png", "PNG")
    raster_table(FIXTURES / "price-table.jpg", "JPEG")
    chart_image(FIXTURES / "sales-chart.png")
    raster_table(FIXTURES / "misleading-alt.png", "PNG")
    for path in sorted(FIXTURES.iterdir()):
        print(f"{path.name}\t{path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
