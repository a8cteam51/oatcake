// Markdown helpers shared by the main process (previews) and the window (rendering).

/**
 * Drops the block older meeting files open with: a "# Title" line followed by "- **Date:** …"
 * style metadata lines. The meeting view shows that information from meeting.json instead.
 */
export function stripHeader(markdown: string): string {
  const lines = markdown.split("\n");
  let i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  if (!/^#\s/.test(lines[i] ?? "")) return markdown;
  i++;
  while (i < lines.length && (!lines[i].trim() || /^\s*[-*]\s+\*\*[^*]+:\*\*/.test(lines[i]) || /^-{3,}$/.test(lines[i].trim()))) i++;
  return lines.slice(i).join("\n");
}

/** The first line of prose in a summary, as plain text, for the meeting list. */
export function previewOf(summary: string): string {
  for (const raw of stripHeader(summary).split("\n")) {
    const line = raw.trim();
    if (!line || /^#/.test(line) || /^-{3,}$/.test(line)) continue;
    return line
      .replace(/^[-*]\s+(\[[ xX]\]\s+)?/, "")
      .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
      .replace(/\s*\[\d{1,2}:\d\d(?::\d\d)?\]/g, "")
      .replace(/[*_`]/g, "")
      .trim();
  }
  return "";
}
