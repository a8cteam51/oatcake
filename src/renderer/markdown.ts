import { marked } from "marked";
import { stripHeader } from "../shared/markdown.ts";

// Summaries and answers come from a model: show any raw HTML in them as text, never as markup.
const escape = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
marked.use({ renderer: { html: ({ text }) => escape(text) } });

/**
 * Renders Markdown, showing transcript timestamps like [12:34] as the same chips used for to-dos
 * (data-stamp lets the meeting view jump to that moment).
 */
export function toHtml(markdown: string): string {
  const html = marked.parse(markdown, { async: false });
  // Only in text between tags, never inside attributes.
  return html.replace(/>([^<]*)</g, (_, text: string) =>
    ">" +
    text.replace(/\[(\d{1,2}:\d\d(?::\d\d)?)\]/g, (_m, t: string) => {
      const stamp = /^\d:\d\d$/.test(t) ? `0${t}` : t;
      return `<span class="chip stamp" data-stamp="${stamp}">${stamp}</span>`;
    }) +
    "<",
  );
}

/**
 * A meeting file's content for reading: older files open with a title-and-date block, and
 * Granola's summaries with a lone "## Summary" heading; both are dropped here.
 */
export const forReading = (markdown: string) => stripHeader(markdown).replace(/^\s*#{1,3}\s+Summary\s*\n/i, "");
