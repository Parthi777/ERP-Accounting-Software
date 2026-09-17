import { inflateSync } from 'node:zlib';

import { describe, expect, test } from 'vitest';

import { GUIDE_SECTIONS, guideSectionFor } from '@/content/process-guide';
import { renderProcessGuide } from '@/server/documents/process-guide';

/**
 * The process guide, and the PDF of it.
 *
 * Two things are worth testing here and they are different. The content
 * invariants catch an edit to the guide that breaks a link or an anchor — the
 * likely mistake, since the guide will be edited far more often than the
 * renderer. Rendering the PDF catches a layout call that throws, which is the
 * only failure mode of a document nobody looks at until a new starter prints it.
 *
 * What is not tested is whether it looks right. pdfkit compresses its streams,
 * so the text cannot be read back out of the buffer, and page breaks are a
 * matter of eyes rather than assertions.
 */

describe('guide content', () => {
  test('every section has what both renderings need', () => {
    for (const section of GUIDE_SECTIONS) {
      expect(section.id, 'an id is the PDF bookmark and the page anchor').toMatch(/^[a-z][a-z-]*$/);
      expect(section.title.length, section.id).toBeGreaterThan(3);
      expect(section.who.length, section.id).toBeGreaterThan(3);
      expect(section.why.length, `${section.id} needs at least one paragraph`).toBeGreaterThan(0);
    }
  });

  test('ids are unique, or one anchor would shadow another', () => {
    const ids = GUIDE_SECTIONS.map((s) => s.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  test('navPaths are absolute app routes', () => {
    for (const section of GUIDE_SECTIONS) {
      for (const path of section.navPaths ?? []) {
        expect(path, section.id).toMatch(/^\/[a-z-]/);
      }
    }
  });
});

describe('guideSectionFor', () => {
  test('matches a screen to the process that explains it', () => {
    expect(guideSectionFor('/sales')?.id).toBe('vehicle-sale');
    expect(guideSectionFor('/sales/new')?.id).toBe('vehicle-sale');
    expect(guideSectionFor('/cash-book/day-close')?.id).toBe('cash-book');
    expect(guideSectionFor('/gst/e-invoice')?.id).toBe('gst');
  });

  test('the longest prefix wins', () => {
    // Counter sales lives under /inventory but is its own process, and the
    // inventory sections must not swallow it.
    expect(guideSectionFor('/inventory/counter-sales')?.id).toBe('counter-sale');
  });

  test('an unexplained screen gets the top of the guide, not a wrong section', () => {
    expect(guideSectionFor('/admin/settings')).toBeNull();
    expect(guideSectionFor('/help')).toBeNull();
  });
});

describe('renderProcessGuide', () => {
  test('produces a PDF', async () => {
    const rendered = await renderProcessGuide('Dharani Motors LLP', new Date('2026-09-17'));

    expect(rendered.contentType).toBe('application/pdf');
    expect(rendered.filename).toBe('process-guide.pdf');
    expect(rendered.body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
    expect(rendered.body.subarray(-6).toString('latin1')).toContain('EOF');

    // A cover and roughly a page per section. Well under this and a section has
    // silently stopped rendering.
    expect(rendered.body.length).toBeGreaterThan(30_000);
  });

  test('has no page carrying only a footer', async () => {
    // The footer is written after the page count is known, and pdfkit answers a
    // write below the bottom margin by starting a new page rather than by
    // refusing — which once produced a blank numbered page for every page of
    // content, doubling a 15-page document to 29.
    //
    // The page streams are inflated rather than measured compressed: a guess at
    // a compressed length is what made the first version of this test pass
    // against the bug it was written for.
    const { body, pages } = await renderProcessGuide('Dharani Motors LLP', new Date('2026-09-17'));

    const contentSizes: number[] = [];
    let at = 0;
    for (;;) {
      const open = body.indexOf('stream\n', at);
      if (open === -1) break;
      const from = open + 'stream\n'.length;
      const close = body.indexOf('endstream', from);
      if (close === -1) break;
      // Past the whole marker: 'endstream\n' itself contains 'stream\n', so
      // stopping at its start desynchronises every later match.
      at = close + 'endstream'.length;

      try {
        const inflated = inflateSync(body.subarray(from, close));
        // BT begins a text object, so this is a page rather than a font or image.
        if (inflated.includes('BT')) contentSizes.push(inflated.length);
      } catch {
        // Not a deflate stream — a font file or an object without compression.
      }
    }

    expect(contentSizes.length, 'no page streams were found to inspect').toBe(pages);
    const footerOnly = contentSizes.filter((size) => size < 400);
    expect(footerOnly.length, `${footerOnly.length} of ${pages} pages hold only a footer`).toBe(0);
  });

  test('renders without a dealer name', async () => {
    // A platform administrator has no tenant, and the cover has to cope.
    const rendered = await renderProcessGuide(null, new Date('2026-09-17'));
    expect(rendered.body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  });
});
