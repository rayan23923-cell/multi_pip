#!/usr/bin/env python3
"""Builds the 20-slide deck the A9.3 UI tests present (App/TaskLensAppUITests/Fixtures).

Usage: make_presentation_fixture.py <output .pptx>
Requires python-pptx. Each slide has its own background color and number;
slide 1 is Arabic and slide 2 mixes Arabic and English.
"""
import sys

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN
from pptx.util import Inches, Pt

prs = Presentation()
prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
titles = {1: "مرحبا بكم في العرض", 2: "TaskLens — عرض تقديمي"}
for number in range(1, 21):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    fill = slide.background.fill
    fill.solid()
    fill.fore_color.rgb = RGBColor((number * 47) % 200 + 30, (number * 83) % 200 + 30, (number * 29) % 200 + 30)
    box = slide.shapes.add_textbox(Inches(0.5), Inches(2.5), prs.slide_width - Inches(1), Inches(2.5))
    frame = box.text_frame
    frame.text = titles.get(number, f"Slide {number}")
    paragraph = frame.paragraphs[0]
    rtl = number in titles
    paragraph.alignment = PP_ALIGN.RIGHT if rtl else PP_ALIGN.CENTER
    if rtl:
        paragraph._p.get_or_add_pPr().set("rtl", "1")
    run = paragraph.runs[0]
    run.font.size = Pt(66)
    run.font.name = "Arial"
    run.font.color.rgb = RGBColor(255, 255, 255)
    if rtl:
        run.font._rPr.set("lang", "ar-SA")
prs.save(sys.argv[1])
print(sys.argv[1], len(prs.slides), "slides")
