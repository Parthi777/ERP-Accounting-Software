import 'server-only';

import PDFDocument from 'pdfkit';

import { loadFonts } from '@/server/export/pdf';
import {
  GUIDE_SECTIONS,
  GUIDE_SUBTITLE,
  GUIDE_TITLE,
  type GuideSection,
} from '@/content/process-guide';

/**
 * The process guide as a printable handbook.
 *
 * Prose rather than a table, so it does not go through renderPdf() — that builds
 * columns and stripes for report data. It borrows loadFonts() because finding the
 * embedded font on Railway's standalone build is the one genuinely awkward part,
 * and it is already solved there.
 *
 * Content comes from src/content/process-guide.ts, the same source the /help
 * screen reads. A printed handbook that has drifted from the screen is worse
 * than none, because people believe it.
 */

const INK = '#1e293b';
const MUTED = '#64748b';
const BRAND = '#1d4ed8';
const RULE = '#cbd5e1';
const WARN_BG = '#fef3c7';
const WARN_INK = '#92400e';

const MARGIN = 54;
const PAGE_WIDTH = 595.28; // A4 portrait
const CONTENT_WIDTH = PAGE_WIDTH - MARGIN * 2;

export interface RenderedGuide {
  readonly body: Buffer;
  readonly filename: string;
  readonly contentType: string;
  /** Pages written, including the cover. Asserted in the tests. */
  readonly pages: number;
}

export async function renderProcessGuide(
  dealerName: string | null,
  generatedAt: Date,
): Promise<RenderedGuide> {
  const fonts = loadFonts();
  const doc = new PDFDocument({
    size: 'A4',
    layout: 'portrait',
    margins: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN },
    bufferPages: true,
    info: {
      Title: GUIDE_TITLE,
      Author: dealerName ?? 'TW ERP',
      Subject: GUIDE_SUBTITLE,
    },
  });

  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<void>((resolve) => doc.on('end', () => resolve()));

  const regular = () => doc.font(fonts.regular as string);
  const bold = () => doc.font(fonts.bold as string);

  // ── Cover ────────────────────────────────────────────────────────────────
  doc.moveDown(6);
  bold().fontSize(26).fillColor(INK).text(GUIDE_TITLE, { width: CONTENT_WIDTH });
  doc.moveDown(0.4);
  regular().fontSize(12).fillColor(MUTED).text(GUIDE_SUBTITLE, { width: CONTENT_WIDTH });

  doc.moveDown(2);
  doc
    .moveTo(MARGIN, doc.y)
    .lineTo(MARGIN + CONTENT_WIDTH, doc.y)
    .strokeColor(RULE)
    .lineWidth(1)
    .stroke();
  doc.moveDown(1.2);

  bold().fontSize(11).fillColor(INK).text(dealerName ?? 'TW ERP');
  regular()
    .fontSize(9.5)
    .fillColor(MUTED)
    .text(
      `Printed ${generatedAt.toLocaleDateString('en-IN', {
        day: '2-digit',
        month: 'long',
        year: 'numeric',
      })}. Kept alongside the Help screen in the application, which carries the same text and is `
        + 'always current — if the two ever disagree, the screen is right.',
      { width: CONTENT_WIDTH },
    );

  // ── Contents ─────────────────────────────────────────────────────────────
  doc.moveDown(2);
  bold().fontSize(13).fillColor(INK).text('Contents');
  doc.moveDown(0.6);
  GUIDE_SECTIONS.forEach((section, index) => {
    regular().fontSize(10.5).fillColor(INK);
    doc.text(`${index + 1}.  ${section.title}`, { width: CONTENT_WIDTH });
    doc.moveDown(0.25);
  });

  // ── Sections ─────────────────────────────────────────────────────────────
  for (const [index, section] of GUIDE_SECTIONS.entries()) {
    doc.addPage();
    renderSection(doc, section, index + 1, regular, bold, fonts);
  }

  // ── Page numbers, added once the page count is known ─────────────────────
  //
  // The bottom margin is dropped for the duration of each footer. A footer sits
  // by definition below the text area, and pdfkit answers a write that does not
  // fit above the bottom margin by starting a new page — which produced a blank
  // numbered page per page of content, doubling the document.
  const range = doc.bufferedPageRange();
  for (let i = range.start; i < range.start + range.count; i += 1) {
    // The cover carries no number.
    if (i === range.start) continue;

    doc.switchToPage(i);
    const bottom = doc.page.margins.bottom;
    doc.page.margins.bottom = 0;

    regular()
      .fontSize(8.5)
      .fillColor(MUTED)
      .text(`${i} of ${range.count - 1}`, MARGIN, doc.page.height - 38, {
        width: CONTENT_WIDTH,
        align: 'right',
        lineBreak: false,
      });

    doc.page.margins.bottom = bottom;
  }

  doc.end();
  await finished;

  return {
    body: Buffer.concat(chunks),
    filename: 'process-guide.pdf',
    contentType: 'application/pdf',
    pages: range.count,
  };
}

function renderSection(
  doc: PDFKit.PDFDocument,
  section: GuideSection,
  number: number,
  regular: () => PDFKit.PDFDocument,
  bold: () => PDFKit.PDFDocument,
  fonts: ReturnType<typeof loadFonts>,
): void {
  bold().fontSize(17).fillColor(INK).text(`${number}. ${section.title}`, { width: CONTENT_WIDTH });
  doc.moveDown(0.35);

  bold().fontSize(9).fillColor(BRAND).text(section.who.toUpperCase(), { width: CONTENT_WIDTH });
  if (section.where) {
    regular().fontSize(9.5).fillColor(MUTED).text(section.where, { width: CONTENT_WIDTH });
  }
  doc.moveDown(0.8);

  for (const paragraph of section.why) {
    regular().fontSize(10.5).fillColor(INK).text(paragraph, {
      width: CONTENT_WIDTH,
      align: 'left',
      lineGap: 2,
    });
    doc.moveDown(0.5);
  }

  if (section.steps?.length) {
    doc.moveDown(0.3);
    section.steps.forEach((step, i) => {
      const y = doc.y;
      // The number in its own gutter, so wrapped text lines up under itself.
      bold().fontSize(10.5).fillColor(BRAND).text(`${i + 1}.`, MARGIN, y, { width: 18 });
      bold()
        .fontSize(10.5)
        .fillColor(INK)
        .text(step.text, MARGIN + 20, y, { width: CONTENT_WIDTH - 20, lineGap: 1.5 });
      if (step.note) {
        doc.moveDown(0.2);
        regular()
          .fontSize(9.5)
          .fillColor(MUTED)
          .text(step.note, MARGIN + 20, doc.y, { width: CONTENT_WIDTH - 20, lineGap: 1.5 });
      }
      doc.moveDown(0.65);
    });
  }

  if (section.watchOut?.length) {
    doc.moveDown(0.4);
    const top = doc.y;
    const inner = CONTENT_WIDTH - 24;

    // Measured first, because the panel has to be drawn before the text that
    // sits on it and pdfkit cannot tell us a height after the fact.
    let height = 20;
    bold().fontSize(9);
    height += doc.heightOfString('WATCH OUT', { width: inner }) + 6;
    regular().fontSize(9.5);
    for (const line of section.watchOut) {
      height += doc.heightOfString(`•  ${line}`, { width: inner, lineGap: 1.5 }) + 4;
    }

    doc.roundedRect(MARGIN, top, CONTENT_WIDTH, height, 6).fillColor(WARN_BG).fill();

    bold()
      .fontSize(9)
      .fillColor(WARN_INK)
      .text('WATCH OUT', MARGIN + 12, top + 10, { width: inner });
    doc.moveDown(0.3);
    for (const line of section.watchOut) {
      regular()
        .fontSize(9.5)
        .fillColor(WARN_INK)
        .text(`•  ${line}`, MARGIN + 12, doc.y, { width: inner, lineGap: 1.5 });
      doc.moveDown(0.2);
    }
  }

  // Referenced so the fallback case is obvious to a reader of this function:
  // without the embedded font pdfkit still renders, just in Helvetica.
  void fonts.hasRupeeGlyph;
}
