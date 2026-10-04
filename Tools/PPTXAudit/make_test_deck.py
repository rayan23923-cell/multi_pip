#!/usr/bin/env python3
"""Builds the synthetic 15-slide deck used by the A8 PowerPoint audit.

Everything is generated here (no third-party slides). Requires python-pptx
and Pillow. Output: TaskLens-PPTX-Audit.pptx next to this script, or the path
given as the first argument.
"""
import io
import sys
from pathlib import Path

from PIL import Image, ImageDraw
from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.dml.color import RGBColor
from pptx.enum.chart import XL_CHART_TYPE
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN
from pptx.util import Emu, Inches, Pt

prs = Presentation()
prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)  # 16:9
BLANK = prs.slide_layouts[6]
W, H = prs.slide_width, prs.slide_height


def png(width, height, color, label):
    image = Image.new("RGB", (width, height), color)
    draw = ImageDraw.Draw(image)
    for x in range(0, width, max(width // 16, 1)):
        draw.line([(x, 0), (width - x, height)], fill=(255, 255, 255), width=3)
    draw.rectangle([10, 10, width - 10, height - 10], outline=(0, 0, 0), width=8)
    draw.text((40, 40), label, fill=(0, 0, 0))
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    buffer.seek(0)
    return buffer


def text(slide, value, left, top, width, height, size=28, font="Calibri", bold=False,
         align=PP_ALIGN.LEFT, rtl=False, color=(0, 0, 0)):
    box = slide.shapes.add_textbox(left, top, width, height)
    frame = box.text_frame
    frame.word_wrap = True
    paragraph = frame.paragraphs[0]
    paragraph.alignment = align
    if rtl:
        # a:pPr rtl="1": PowerPoint's right-to-left paragraph flag.
        paragraph._p.get_or_add_pPr().set("rtl", "1")
    run = paragraph.add_run()
    run.text = value
    run.font.size = Pt(size)
    run.font.name = font
    run.font.bold = bold
    run.font.color.rgb = RGBColor(*color)
    if rtl:
        rpr = run._r.get_or_add_rPr()
        rpr.set("lang", "ar-SA")
        cs = rpr.makeelement("{http://schemas.openxmlformats.org/drawingml/2006/main}cs", {"typeface": font})
        rpr.append(cs)
    return box


def title(slide, number, value):
    text(slide, f"{number}. {value}", Inches(0.5), Inches(0.3), W - Inches(1), Inches(1), size=36, bold=True)


def notes(slide, value):
    slide.notes_slide.notes_text_frame.text = value


# 1 Text
s = prs.slides.add_slide(BLANK)
title(s, 1, "Text")
text(s, "TaskLens PowerPoint audit. Plain text in Calibri, 28 pt.", Inches(0.5), Inches(1.6), Inches(12), Inches(1))
notes(s, "Speaker note on slide 1: check whether notes survive.")

# 2 Multiple fonts
s = prs.slides.add_slide(BLANK)
title(s, 2, "Multiple fonts")
for i, (font, size) in enumerate([("Calibri", 28), ("Times New Roman", 28), ("Courier New", 24),
                                  ("Arial Black", 26), ("Georgia", 30), ("Helvetica Neue", 28)]):
    text(s, f"{font} {size} pt — The quick brown fox 0123456789", Inches(0.5), Inches(1.4 + i * 0.9),
         Inches(12), Inches(0.8), size=size, font=font)

# 3 Images
s = prs.slides.add_slide(BLANK)
title(s, 3, "Images")
for i, color in enumerate([(230, 80, 60), (60, 160, 90), (60, 110, 220)]):
    s.shapes.add_picture(png(800, 600, color, f"Image {i + 1}"), Inches(0.5 + i * 4.2), Inches(1.6), width=Inches(4))

# 4 Shapes
s = prs.slides.add_slide(BLANK)
title(s, 4, "Shapes")
for i, kind in enumerate([MSO_SHAPE.RECTANGLE, MSO_SHAPE.OVAL, MSO_SHAPE.ROUNDED_RECTANGLE,
                          MSO_SHAPE.ISOSCELES_TRIANGLE, MSO_SHAPE.RIGHT_ARROW, MSO_SHAPE.STAR_5_POINT]):
    shape = s.shapes.add_shape(kind, Inches(0.5 + (i % 3) * 4.2), Inches(1.6 + (i // 3) * 2.8), Inches(3.6), Inches(2.4))
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor(40 * i, 120, 255 - 30 * i)
    shape.text_frame.text = kind.name if hasattr(kind, "name") else str(kind)

# 5 Table
s = prs.slides.add_slide(BLANK)
title(s, 5, "Table")
table = s.shapes.add_table(5, 4, Inches(0.5), Inches(1.6), Inches(12), Inches(4)).table
for r in range(5):
    for c in range(4):
        table.cell(r, c).text = ["Item", "Q1", "Q2", "Q3"][c] if r == 0 else (f"Row {r}" if c == 0 else str(r * 10 + c))

# 6 Chart
s = prs.slides.add_slide(BLANK)
title(s, 6, "Chart")
data = CategoryChartData()
data.categories = ["Jan", "Feb", "Mar", "Apr"]
data.add_series("Sales", (12, 19, 7, 24))
data.add_series("Costs", (8, 11, 9, 13))
s.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(0.5), Inches(1.4), Inches(12), Inches(5.6), data)

# 7 Backgrounds
s = prs.slides.add_slide(BLANK)
s.background.fill.solid()
s.background.fill.fore_color.rgb = RGBColor(20, 30, 70)
text(s, "7. Dark background, white text", Inches(0.5), Inches(0.3), Inches(12), Inches(1), size=36, bold=True, color=(255, 255, 255))
band = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, Inches(5.5), W, Inches(2))
band.fill.solid()
band.fill.fore_color.rgb = RGBColor(250, 200, 40)

# 8 Layout using a built-in placeholder layout
s = prs.slides.add_slide(prs.slide_layouts[1])
s.shapes.title.text = "8. Title and Content layout"
s.placeholders[1].text_frame.text = "Bullet one"
for value in ["Bullet two", "Bullet three (level 2)"]:
    p = s.placeholders[1].text_frame.add_paragraph()
    p.text = value
p.level = 1

# 9 Arabic
s = prs.slides.add_slide(BLANK)
text(s, "٩. نص عربي", Inches(0.5), Inches(0.3), W - Inches(1), Inches(1), size=36, bold=True, align=PP_ALIGN.RIGHT, rtl=True, font="Arial")
text(s, "مرحباً بكم في تطبيق TaskLens. هذه شريحة لاختبار تشكيل الحروف العربية والاتجاه من اليمين إلى اليسار، مع علامات الترقيم: «اقتباس»، وسؤال؟ وفاصلة، ونقطة.",
     Inches(0.5), Inches(1.6), W - Inches(1), Inches(3), size=30, align=PP_ALIGN.RIGHT, rtl=True, font="Arial")
text(s, "الأرقام: ١٢٣٤٥٦٧٨٩٠ و 1234567890", Inches(0.5), Inches(5), W - Inches(1), Inches(1), size=28, align=PP_ALIGN.RIGHT, rtl=True, font="Arial")

# 10 Mixed Arabic + English
s = prs.slides.add_slide(BLANK)
title(s, 10, "Mixed Arabic + English")
text(s, "اجتماع الفريق يوم Monday الساعة 10:30 AM في غرفة Meeting Room B، والميزانية 25,000 SAR.",
     Inches(0.5), Inches(1.6), W - Inches(1), Inches(1.6), size=30, align=PP_ALIGN.RIGHT, rtl=True, font="Arial")
text(s, "The report «التقرير السنوي» is due on 15 March (١٥ مارس).", Inches(0.5), Inches(3.6), W - Inches(1), Inches(1.4), size=30)
link = text(s, "Link: https://example.com", Inches(0.5), Inches(5.4), Inches(8), Inches(0.8), size=24)
link.text_frame.paragraphs[0].runs[0].hyperlink.address = "https://example.com"

# 11 Large image
s = prs.slides.add_slide(BLANK)
s.shapes.add_picture(png(4000, 2250, (90, 40, 160), "Large 4000x2250"), 0, 0, width=W, height=H)
text(s, "11. Large image (4000 × 2250)", Inches(0.5), Inches(0.3), Inches(12), Inches(1), size=36, bold=True, color=(255, 255, 255))

# 12 Long text
s = prs.slides.add_slide(BLANK)
title(s, 12, "Long text")
text(s, " ".join(["Long paragraph to test wrapping and overflow."] * 22), Inches(0.5), Inches(1.4), Inches(12), Inches(5.6), size=18)
notes(s, "Speaker note on slide 12. ملاحظة المتحدث بالعربية.")

# 13 Many objects
s = prs.slides.add_slide(BLANK)
title(s, 13, "Multiple objects")
for i in range(40):
    shape = s.shapes.add_shape(MSO_SHAPE.OVAL, Inches(0.4 + (i % 10) * 1.25), Inches(1.6 + (i // 10) * 1.4), Inches(1), Inches(1))
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor((i * 37) % 255, (i * 91) % 255, (i * 53) % 255)
    shape.text_frame.text = str(i + 1)

# 14 Complex layout: overlap, rotation, group-like stacking, transparency
s = prs.slides.add_slide(BLANK)
title(s, 14, "Complex layout")
for i in range(6):
    shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(1 + i * 1.4), Inches(1.6 + i * 0.6), Inches(5), Inches(2.4))
    shape.rotation = i * 8
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor(200 - i * 25, 80 + i * 20, 120)
    shape.text_frame.text = f"Layer {i + 1} — طبقة {i + 1}"
s.shapes.add_picture(png(600, 600, (240, 240, 240), "Overlay"), Inches(9.5), Inches(3.5), width=Inches(3))

# 15 Final
s = prs.slides.add_slide(BLANK)
s.background.fill.solid()
s.background.fill.fore_color.rgb = RGBColor(0, 120, 90)
text(s, "15. Final slide — الشريحة الأخيرة", Inches(0.5), Inches(3), W - Inches(1), Inches(1.5), size=44, bold=True,
     align=PP_ALIGN.CENTER, color=(255, 255, 255))

output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("TaskLens-PPTX-Audit.pptx")
prs.save(output)
print(f"{output} {output.stat().st_size} bytes, {len(prs.slides)} slides")
