---
name: Word / DOCX
slug: word-docx
version: 1.1.0
homepage: https://clawic.com/skills/word-docx
description: "Create, inspect, and edit Microsoft Word documents and DOCX files with reliable styles, numbering, tracked changes, tables, sections, and compatibility checks. Use when (1) the task is about Word or `.docx`; (2) the file includes tracked changes, comments, fields, tables, templates, or page layout constraints; (3) the document must survive round-trip editing without formatting drift."
changelog: Added Rule 7 (CJK fonts), Rule 8 (Chinese multi-level numbering), Rule 9 (budget/personnel tables), and Rule 10 (template content controls) for Chinese fund-application document editing.
metadata: {"clawdbot":{"emoji":"📘","os":["linux","darwin","win32"]}}
---

## When to Use

Use when the main artifact is a Microsoft Word document or `.docx` file, especially when tracked changes, comments, headers, numbering, fields, tables, templates, or compatibility matter.

## Core Rules

### 1. Treat DOCX as OOXML, not plain text

- A `.docx` file is a ZIP of XML parts, so structure matters as much as visible text.
- The critical parts are usually `word/document.xml`, `styles.xml`, `numbering.xml`, headers, footers, and relationship files.
- Text may be split across multiple runs; never assume one word or sentence lives in one XML node.
- Use different workflows on purpose: structured extraction for quick reading, style-driven generation for new files, and OOXML-aware editing for fragile existing documents.
- If the job is mainly reading, extracting, or reviewing, prefer a structure-preserving read path before touching OOXML.
- For deep edits, inspect the package layout instead of relying only on rendered output.
- Reading, generating, and preserving an existing reviewed document are different jobs even when the format is the same.
- Legacy `.doc` inputs usually need conversion before you can trust modern `.docx` assumptions.

### 2. Preserve styles and direct formatting deliberately

- Prefer named styles over direct formatting so the document stays editable.
- Styles layer: paragraph styles, character styles, and direct formatting do not behave the same.
- Removing direct formatting is often safer than stacking more inline formatting on top.
- When editing an existing file, extend the current style system instead of inventing a parallel one.
- Copying content between documents can silently import foreign styles, theme settings, and numbering definitions.

### 3. Lists and numbering are their own system

- Bullets and numbering belong to Word's numbering definitions, not pasted Unicode characters.
- `abstractNum`, `num`, and paragraph numbering properties all matter, so restart behavior is rarely "visual only".
- Indentation and numbering are related but not identical; a list can have broken numbering even if the indent looks right.
- A list that looks correct in one editor can restart, flatten, or renumber itself later if the underlying numbering state is wrong.

### 4. Page layout lives in sections

- Margins, orientation, headers, footers, and page numbering are section-level behavior.
- First-page and odd/even headers can differ inside the same document, so one header fix may not fix the document.
- Set page size explicitly because A4 and US Letter defaults change pagination and table widths.
- Use section breaks for layout changes; manual spacing and stray page breaks usually create drift.
- Header and footer media use part-specific relationships, so copied IDs often break images or links.
- Tables, page breaks, and headers often drift together, so treat layout fixes as document-wide, not local cosmetic edits.
- Table geometry depends on page width, margins, and fixed widths, so "close enough" table edits often break later in Google Docs or LibreOffice.

### 5. Track changes, comments, and fields need precise edits

- Visible text is not the full document when tracked changes are enabled.
- Insertions, deletions, and comments carry metadata that can survive careless edits.
- Deleted text may still exist in the XML even when it no longer appears on screen.
- Comment anchors and review ranges can break if edits move text without preserving the surrounding structure.
- Comment markers and review wrappers do not behave like inline formatting, so moving text carelessly can orphan or misplace them.
- Comments, footnotes, bookmarks, and linked media may live in separate parts, not only in the main document body.
- Tables of contents, page numbers, dates, cross-references, and mail merge placeholders are fields.
- Edit the field source carefully and expect cached display values to lag until refresh.
- Hyperlinks, bookmarks, and references can break if IDs or relationships stop matching.
- Bookmarks, footnotes, comment ranges, and cross-references depend on stable anchors even when the visible text seems untouched.
- A document can look correct while still containing stale field output that refreshes later into something different.
- For review workflows, make minimal replacements instead of rewriting whole paragraphs.
- In tracked-change workflows, only the changed span should look changed; broad rewrites create noisy reviews and can destroy the original formatting context.
- For legal, academic, or business review documents, default to review-style edits over wholesale paragraph rewrites unless the user explicitly wants a rewrite.

### 6. Verify round-trip compatibility before delivery

- Complex documents can shift between Word, LibreOffice, Google Docs, and conversion tools.
- Tables, headers, embedded fonts, and copied styles are common sources of layout drift.
- Treat `.docm` as macro-bearing and higher risk; treat `.doc` as legacy input that may need conversion first.
- When layout matters, explicit table widths are safer than auto-fit or percentage-style behavior that different editors reinterpret.
- A document that passes a text check can still fail on pagination, table widths, or reference refresh after the recipient opens it.

### 7. CJK fonts and Latino-CJK mixing

- CJK (Chinese/Japanese/Korean) documents need separate font settings for East-Asian and Latin characters.
- In OOXML, one `<w:rPr>` typically has both `w:rFonts` with `ascii`/`hAnsi` covering Latin/number, and `eastAsia` covering CJK. Setting only one side gives the wrong font for the other.
- Common Chinese fund-application font pairs:
  - Body: SimSun (宋体) for CJK, Times New Roman for Latin/numbers.
  - Section headings: SimHei (黑体) for CJK, Arial or Times New Roman for Latin/numbers.
  - Quotes/citations: KaiTi (楷体) for CJK, Times New Roman for Latin/numbers.
  - English titles/abstract: the spec says "Times New Roman", but headings often also specify a CJK font (usually SimHei) so the fallback is correct.
- Font sizes in Chinese documents often use 小四 (12 pt) for body text, 四号 (14 pt) for first-level headings, and 小三 (15 pt) or 三号 (16 pt) for document titles. These map to absolute pt values.
- Word theme fonts (`w:themeFont`) can mask real font settings — when editing, resolve theme references to explicit fonts for reliability.
- Line spacing in Chinese documents is often specified as 固定值 20磅 (fixed 20 pt), 1.25倍 or 1.5倍行距. Do not rely on "single spacing" defaults.
- CJK characters are typically full-width and need different indentation rules: 首行缩进2字符 (first-line indent by 2 characters, ~2 em, i.e. ~2 × the font size in pt).
- When copy-pasting from one Chinese document to another, font embedding and character-spacing settings often leak, causing the visible spacing to look wrong even when font names appear correct.
- Character spacing (字符间距) in CJK documents is sometimes set to 加宽 (expanded) or 紧缩 (condensed) by small amounts — a common source of "this paragraph looks longer than that one" mismatches. Check `w:spacing` in the run properties.

### 8. Chinese multi-level list numbering

- Chinese fund documents commonly mix CJK-style numbering (一、 (一) ) at top levels with Arabic numbering (1. 1.1 1.1.1) at deeper levels.
- This is configured through Word's multi-level list (`w:abstractNum` with multiple `w:lvl` entries), not by typing the characters manually.
- Each level has its own `w:numFmt`, `w:lvlText`, and `w:lvlJc`:
  - Level 1: `w:numFmt="chineseCounting"` (一、二、三…), text format = "%1、"
  - Level 2: `w:numFmt="chineseCounting"` ( (一)(二)(三)…), text format = "（%1）"
  - Level 3: `w:numFmt="decimal"`, text format = "%1."
  - Level 4+: `w:numFmt="decimal"`, text format = "%1.%2.%3…"
- Restart rules (`w:start` / `w:lvlRestart`) are critical: level 2 should restart at each level 1, level 3 at each level 2, etc. In OOXML, this means setting `w:lvlRestart="1"` on level 2, `w:lvlRestart="2"` on level 3, and so on.
- The `w:ilvl` attribute on a paragraph's `w:numPr` determines which list level that paragraph belongs to. Mis-setting `ilvl` is the most common cause of "this paragraph is numbered as level 1 when it should be level 2".
- CJK numbering (`chineseCounting`) uses fullwidth characters; numbering alignment (`w:lvlJc`) is typically "left" (左对齐) rather than right-aligned like Arabic numerals.
- Indentation for CJK list items needs larger `w:ind` values to accommodate the wider CJK characters. A rule of thumb: first-level indent about 2× the font size, deeper levels increment by about 1.5×.
- Word's built-in "List Number" gallery does not expose `chineseCounting` levels through the GUI. They are either defined in the template's `numbering.xml` or created via the "Define New Multi-Level List" dialog before styles are applied. Editing these in raw OOXML is often safer than trusting the GUI round-trip.
- When opening a Chinese fund template in a non-CJK locale of Word, the numbering definitions survive in XML but the GUI may render them incorrectly. Verify by inspecting `numbering.xml` directly.
- Copying list items between documents carries the full `abstractNum` + `num` definition pair, which can duplicate or collide with existing numbering IDs in the target document. The safest approach is to copy only the text and reapply the target document's list style.

### 9. Budget and personnel tables (项目经费/人员表)

- Chinese fund applications almost always contain budget tables with a standard column set: 序号/预算科目/金额/计算依据. The exact columns vary by funding agency (NSFC, MOST, provincial).
- These tables frequently use merged cells (`w:gridSpan`, `w:vMerge`) for multi-line entries like "设备费" split into "购置费" and "试制费". Editing cell merges without understanding the `w:tc` merge chain can break alignment.
- Column widths are usually set in absolute centimeters ( `w:tcW w:w="..." w:type="dxa"` ), not percentages. A common issue: pasting into a different page-width context causes the fixed-width table to overflow the margin.
- Table body cells typically have 宋体 小四 (SimSun 12 pt), while header rows use 黑体 五号 (SimHei 10.5 pt) or 小五 (9 pt).
- Number alignment inside budget columns: amounts are right-aligned with 千分位 comma separator. In OOXML this means `w:jc="right"` with `w:numFmt` at the run level or applying a number-style character format.
- Currency symbols (¥) are often packed into a separate narrow column or prefixed in the amount column. If you need to add/remove the ¥ sign, do it at the cell level, not by appending text to each number — Word's number-formatting won't combine a text prefix with a numeric value in the same cell.
- Personnel tables (人员表) have columns: 序号/姓名/职称/工作单位/分工/签名. The signature column is usually left empty in the electronic version; do not delete it or adjust its width to zero, or the printed version will fail.
- Budget totals: the last row is always a "合计" (total) row with `w:vMerge="continue"` across all description columns and `=SUM(ABOVE)` or a summed formula in the amount column. In OOXML, the formula is an `<w:fldSimple w:instr="=SUM(ABOVE)"/>` or a full `<w:fldChar>` field. When rewriting budget rows, check that the SUM range is still correct.
- A common trap: inserting a new budget row inside a merged-cell group without checking whether the merge spans need to be split first. Always unmerge the affected rows, insert, then re-merge if needed.
- When the budget table spans multiple pages, set header-row repetition: in OOXML, `<w:tblHeader>` on each `<w:tr>` that should repeat. This is often missing in pasted tables, causing the header to disappear on page 2.

### 10. Template content controls and form fields

- Many Chinese fund templates use Word content controls (结构化文档标签, aka SDT — Structured Document Tags) or legacy form fields (窗体域) to constrain where the applicant can type.
- Content controls appear in OOXML as `<w:sdt>` / `<w:sdtPr>` / `<w:sdtContent>` wrapping the regular paragraph or run content. The `<w:sdtPr>` stores properties: type (plain text, rich text, dropdown, date picker, checkbox), locking, tagging, placeholder text, and data bindings.
- Content control types (in `<w:sdtPr><w:alias>` and `<w:tag>`):
  - Plain text (`<w:text w:multiLine="true"/>`): allows multi-paragraph input but only plain text.
  - Rich text (`<w:richText/>`): allows formatted text, images, tables inside.
  - Drop-down list (`<w:dropDownList>`): `w:listItem` entries with display text and value.
  - Date picker (`<w:date w:fullDate="..."/>`): enforces date format.
  - Checkbox (`<w:checkBox>`): `w:checked` state.
- **Critical**: when editing text inside a content control, you must preserve the `<w:sdt>` wrapper. Deleting the wrapper removes the control and breaks the template.
- To replace placeholder text inside a plain-text content control, find the `<w:sdtPr><w:alias>` and the `<w:sdtContent>` text, then replace the text node inside `<w:sdtContent>`. Do not touch the `<w:sdtPr>` or the outer `<w:sdt>`.
- Rich-text content controls are more fragile: the `<w:sdtContent>` may contain multiple paragraphs, runs, or even nested tables. Only modify the innermost text runs, leaving all structural wrappers intact.
- Content control locking (`<w:lock w:locking="sdtContentLocked"/>` or `"unlocked"`): if locked, the user cannot edit the content through the GUI, but the OOXML text can still be changed programmatically. If you change locked content, note that the user will not be able to edit it again in Word — this is usually intended for template boilerplate.
- Legacy form fields (pre-2007 .doc compatibility) use `<w:ffData>` inside a `<w:fldChar>` sequence. These are rarer in modern fund templates but still appear in older `.doc` converted files. They behave differently from SDT: the field value lives in the `<w:ffData><w:textInput><w:default>` element, and the displayed text is a `<w:fldChar w:fldCharType="begin">…<w:instrText> FORMTEXT </w:instrText>…<w:fldChar w:fldCharType="end">` field sequence.
- Content controls can be locked at the group level, where an SDT wraps an entire section. In that case, the entire section content appears inside one `<w:sdt>` block. Be extremely careful when editing group-level SDTs: altering paragraph numbering, headers, or page breaks inside a group SDT can corrupt the structural boundary.
- Copying text out of a content control and pasting it elsewhere usually strips the SDT wrapper (Word's default paste behavior). In OOXML editing, be explicit: wrap the pasted content in `<w:sdt>` if you want the control, or strip the wrapper if you want plain text.
- Multiple content controls can share a tag or alias namespace. If the template uses `w:alias` keys for auto-population (common in NSFC templates), changing the alias name breaks the data-binding link. Rename aliases only when the user explicitly asks.

## Common Traps

- Copy-paste can import unwanted styles and numbering definitions.
- Header or footer images use part-specific relationships, so reusing IDs blindly breaks them.
- Empty paragraphs used as spacing make templates fragile; spacing belongs in paragraph settings.
- A clean-looking export can still hide unresolved revisions, comments, or stale field values.
- Restarting lists "by eye" usually fails because numbering state lives outside the paragraph text.
- One visible phrase can be split across several runs, bookmarks, revision tags, or field boundaries.
- Replacing a whole paragraph to change one clause often breaks review quality, bookmarks, comments, or nearby inline formatting.
- Deleting all visible text from a paragraph or list item can still leave behind an empty paragraph mark, empty bullet, or unstable numbering.
- Table auto-fit and percentage-like width behavior can look acceptable in Word and still drift in Google Docs or LibreOffice.
- LibreOffice and Google Docs can shift complex tables, section behavior, and embedded fonts even when Word looks perfect.
- Compatibility mode can silently cap newer features or change pagination behavior.
- A single change in page size or margin defaults can ripple through tables, headers, TOC, and cross-references.
- A revision workflow can look accepted on screen while leftover metadata, comments, or field caches still make the file unstable later.
- TOC entries, footnotes, and cross-references can look correct until the recipient updates fields and exposes broken anchors.

## Related Skills
Install with `clawhub install <slug>` if user confirms:
- `documents` — General document handling and format conversion.
- `brief` — Concise business writing and structured summaries.
- `article` — Long-form drafting and editorial structure.

## Feedback

- If useful: `clawhub star word-docx`
- Stay updated: `clawhub sync`
