#!/usr/bin/env python3
"""Builds the .pptx fixtures the A9.2 renderer tests open (App/TaskLensTests/Fixtures).

Usage: make_renderer_fixtures.py <A8 audit deck> <output directory>
Requires python-pptx and Pillow. Everything is synthetic.
"""
import copy
import io
import sys
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Inches, Pt

audit, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
NOTES = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide"


def save(prs, name):
    path = out / name
    prs.save(path)
    print(path.name, path.stat().st_size, "bytes", len(prs.slides), "slides")


def deck(width=13.333, height=7.5):
    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(width), Inches(height)
    return prs


def text(slide, value, top, size=32, rtl=False, color=None, width=None, height=1.2):
    prs_width = slide.part.package.presentation_part.presentation.slide_width
    box = slide.shapes.add_textbox(Inches(0.5), Inches(top), width or prs_width - Inches(1), Inches(height))
    frame = box.text_frame
    frame.word_wrap = True
    frame.text = value
    paragraph = frame.paragraphs[0]
    paragraph.alignment = PP_ALIGN.RIGHT if rtl else PP_ALIGN.LEFT
    if rtl:
        paragraph._p.get_or_add_pPr().set("rtl", "1")
    run = paragraph.runs[0]
    run.font.size = Pt(size)
    run.font.name = "Arial"
    if color:
        run.font.color.rgb = RGBColor(*color)
    if rtl:
        run.font._rPr.set("lang", "ar-SA")
    return box


def background(slide, rgb):
    fill = slide.background.fill
    fill.solid()
    fill.fore_color.rgb = RGBColor(*rgb)


# 1. The A8 audit deck without its speaker notes (A8 showed WebKit refuses notes slides).
prs = Presentation(audit)
for slide in prs.slides:
    for rid, rel in list(slide.part.rels.items()):
        if rel.reltype == NOTES:
            slide.part.drop_rel(rid)
save(prs, "audit-15.pptx")

# 2. The A8 deck as it is, notes included: the renderer must fail cleanly or render.
(out / "audit-with-notes.pptx").write_bytes(audit.read_bytes())

# 3. Arabic.
prs = deck()
lines = [
    ["مرحبا بكم في العرض", "هذا عرض تقديمي باللغة العربية"],
    ["TaskLens — عرض تقديمي", "عرض تقديمي من TaskLens باللغتين."],
    ["الاجتماع (الأول) يوم 2026/10/04 الساعة 10:30، مع فريق Design؛ الميزانية ١٢٬٥٠٠ ريال!",
     "هل الموعد مناسب؟ «نعم» أو «لا» — والرقم 42."],
    ["Mixed: التقرير السنوي (Annual Report) is due on 15 March — ١٥ مارس.",
     "خطوات: ١) الإعداد ٢) المراجعة ٣) النشر."],
]
for first, second in lines:
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    rtl_first = not first.startswith("Mixed")
    text(slide, first, 0.6, 36, rtl=rtl_first)
    text(slide, second, 2.6, 30, rtl=True)
save(prs, "arabic.pptx")

# 4. Order: slides are created as C, A, E, B, D, then put in A–E order in sldIdLst,
#    so the part names (slide1.xml…) do not follow the presentation order.
colors = {"A": (220, 30, 30), "B": (30, 160, 60), "C": (30, 60, 220), "D": (240, 200, 0), "E": (120, 30, 160)}
prs = deck()
made = {}
for letter in "CAEBD":
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    background(slide, colors[letter])
    text(slide, f"Slide {letter}", 0.6, 48, color=(255, 255, 255))
    made[letter] = slide.slide_id
ids = prs.slides._sldIdLst
items = {int(item.get("id")): item for item in ids}
for item in list(ids):
    ids.remove(item)
for letter in "ABCDE":
    ids.append(items[made[letter]])
save(prs, "order.pptx")

# 5. A hidden slide (the second of three).
prs = deck()
for index, rgb in enumerate([(220, 30, 30), (30, 160, 60), (30, 60, 220)]):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    background(slide, rgb)
    text(slide, f"Slide {index + 1}", 0.6, 48, color=(255, 255, 255))
    if index == 1:
        slide._element.set("show", "0")
save(prs, "hidden.pptx")

# 6. Aspect ratios: 4:3 and a square custom size, each with a full-size frame.
for name, width, height in [("aspect-4x3.pptx", 10, 7.5), ("aspect-square.pptx", 7.5, 7.5)]:
    prs = deck(width, height)
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    background(slide, (30, 60, 220))
    shape = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(1), Inches(1), Inches(width - 2), Inches(height - 2))
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor(255, 255, 255)
    text(slide, f"{width} × {height} in", 1.5, 32)
    save(prs, name)

# 7. A picture linked to an external address (must never be fetched).
prs = deck()
slide = prs.slides.add_slide(prs.slide_layouts[6])
text(slide, "External picture link (blocked)", 0.6, 36)
save(prs, "external.pptx")
with zipfile.ZipFile(out / "external.pptx") as source:
    parts = {item.filename: source.read(item.filename) for item in source.infolist()}
rels = "ppt/slides/_rels/slide1.xml.rels"
parts[rels] = parts[rels].replace(
    b"</Relationships>",
    b'<Relationship Id="rIdExt" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
    b'Target="https://example.invalid/tasklens-blocked.png" TargetMode="External"/></Relationships>')
picture = (b'<p:pic><p:nvPicPr><p:cNvPr id="9" name="Linked"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>'
           b'<p:blipFill><a:blip r:link="rIdExt"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
           b'<p:spPr><a:xfrm><a:off x="914400" y="1828800"/><a:ext cx="3657600" cy="2057400"/></a:xfrm>'
           b'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree>')
parts["ppt/slides/slide1.xml"] = parts["ppt/slides/slide1.xml"].replace(b"</p:spTree>", picture)
with zipfile.ZipFile(out / "external.pptx", "w", zipfile.ZIP_DEFLATED) as target:
    for name, data in parts.items():
        target.writestr(name, data)

# 8. A slide part listed in the presentation but missing from the package.
prs = deck()
for index in range(3):
    text(prs.slides.add_slide(prs.slide_layouts[6]), f"Slide {index + 1}", 0.6, 48)
buffer = io.BytesIO()
prs.save(buffer)
with zipfile.ZipFile(buffer) as source, zipfile.ZipFile(out / "missing-slide.pptx", "w", zipfile.ZIP_DEFLATED) as target:
    for item in source.infolist():
        if item.filename != "ppt/slides/slide2.xml":
            target.writestr(item, source.read(item.filename))
print("missing-slide.pptx written")


# 9. 1, 3, 10, 50 and 100 slides: Arabic and English text, a 960×540 photo on slide 3.
# One photo per deck: on the iOS 26.5 simulator WebKit links slides to other
# slides' photos, which the renderer refuses (A9.5.6), so these decks, which
# test scale, caching and recovery, keep to one.
def scale(count):
    prs = deck()
    for n in range(1, count + 1):
        slide = prs.slides.add_slide(prs.slide_layouts[6])
        text(slide, f"Slide {n} — الشريحة {n}", 0.3, 36)
        if n == 3:
            image = Image.new("RGB", (960, 540), ((n * 37) % 256, (n * 91) % 256, (n * 53) % 256))
            draw = ImageDraw.Draw(image)
            for x in range(0, 960, 16):
                draw.line([(x, 0), (960 - x, 540)], fill=(255, 255, 255), width=2)
            data = io.BytesIO()
            image.save(data, "JPEG", quality=60)
            data.seek(0)
            slide.shapes.add_picture(data, Inches(0.5), Inches(1.5), Inches(8))
        else:
            text(slide, ("هذا نص عربي للاختبار. " if n % 2 else "English body text for the test. ") * 8,
                 1.5, 20, rtl=bool(n % 2), height=4)
    save(prs, f"scale-{count}.pptx")


for count in (1, 3, 10, 50, 100):
    scale(count)
