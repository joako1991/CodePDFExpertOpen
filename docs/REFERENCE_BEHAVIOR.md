# PDF Expert recording: observations and implementation

Reference: the latest MP4 supplied on 9 November 2026, duration 3:33 (688 × 480, 60 fps). The first approximately 14 seconds and the closing seconds show V Recorder; its VIP advertisements and watermark controls are unrelated to PDF Expert. The PDF's text is reference content, not instructions for this project. No recording frames, PDF Expert graphics or source PDF are bundled with Paper Studio.

## Observed interactions

| Recording | Observable behaviour | Paper Studio implementation |
|---|---|---|
| 0:15–0:50 | Persistent markup tools, yellow/blue/green highlights, underline/strikeout, repeated use without confirming each mark | Annotate mode, visible colour presets, direct text-range marking and one undo step per completed gesture. A second tap on the active tool opens its settings; Read/Done ends it. |
| 0:51–1:02 | Handwriting becomes typed “Hello”; text colour changes while editing | On-page text input, Helvetica 12 pt default, font/weight/size/colour accessory bar. Native indirect Scribble can focus a writing area when Pencil writing starts. Requires iPadOS Scribble to be enabled. |
| 1:02–1:20 | Ink handwriting, colour and width controls, variable tip setting, handwriting-to-text option | Coalesced Pencil samples and force-dependent PDF ink widths. Finger/mouse input has constant width. The conversion option routes writing into native Scribble text input; no application handwriting-recognition service is invented. |
| 1:20–1:30 | Broad diagonal freehand highlighter strokes, distinct from text highlighting | Freehand highlighter with its own colour, width and opacity preset. Text highlighting remains a separate tool. |
| 1:30–1:41 | Whole/partial eraser and brush size | Whole-stroke and swept partial erasing. Partial mode splits the PDF ink paths; it does not cover them with white paint. Cancelling restores the original paths. Erasing is one undo operation per gesture. |
| 1:42–2:08 | Rectangle, ellipse, line and arrow; colour, width, dash, fill/opacity and arrow settings | Native editable PDF shape/line annotations, shared shape presets, double-arrow option and live appearance changes to the selected shape. Move selects/repositions objects; the corner handle resizes text, shapes and inserted image stamps. Line endpoint dragging is not implemented. |
| 2:08–2:20 | Edit PDF toolbar (text, image, link, redact), followed by an upgrade screen | Edit PDF mode exposes local MuPDF text/image replacement, image insertion, link annotations and real content redaction. The recording does not demonstrate the paid editor actually changing source content, so its precise advanced editing behaviour cannot be inferred. |
| 2:20–2:49 | Fill & Sign tools, repeated checks/crosses, text entry and a date; a further upgrade screen | Reusable text, handwritten signature, date, check, cross, configurable text stamp and image placement. Text is edited in place. These features do not require a Paper Studio subscription. |
| 2:50–3:05 | Vertical/horizontal/two-page reading, brightness, day/sepia/night, margins, speech and stay-awake settings | Display settings with those reading controls. Margin hiding changes the viewport, not the PDF crop boxes. Speech uses the system's local voice. Screen-awake state is restored when the editor closes. |
| 3:06–3:15 | Outline/bookmark/annotation sidebar, grouped marks and handwriting previews | Document panel with page thumbnails, outline, bookmarks and searchable annotation text/snippets; pressure components are grouped into one stroke. Ink previews use the actual annotation paths. |
| 3:16–3:28 | Return to file library and navigation | The library sidebar collapses when opening a PDF and returns when closing it; document/page panels start closed. Existing local import, rename, duplicate, recent-document and share functions remain available. Cloud providers are not implemented. |

## What the Premium screens establish

At approximately **2:13**, the recording shows an upgrade page headed “Modifiez vos PDF sans limites”. At approximately **2:41**, another is headed “Remplissez et signez vos PDF sans limites”. These prompts establish a subscription gate encountered in those sections for this account/version. They do not establish that every visible button in those sections is always paid, nor that any resulting document was successfully saved/exported.

The upgrade pages advertise editing/redaction, conversions, AI extraction, signing, merging/splitting and multi-device use. The annotation panel at approximately 3:07 also advertises Premium transcription/search of handwritten notes. The Export toolbar displays Word, Excel, PowerPoint, text and image destinations, but the recording does not execute those conversions.

[PDF Expert's published pricing page](https://pdfexpert.com/pricing), checked on 9 November 2026, also lists source text/image/link editing, signing, OCR, Word/Excel/PPT conversion and PDF Copilot among Premium benefits. Entitlements and offers can change; the recording is the evidence for the two encountered prompts. The recorder's VIP offer is excluded from this inventory.

| Advertised/encountered capability | Available in this application | Practical limit |
|---|---|---|
| Edit original PDF text | MuPDF replacement, accessible without a paywall | One non-empty line, fallback Helvetica, no paragraph reflow or preservation of arbitrary original typography. |
| Edit images | Replace one painted image occurrence; insert a movable/resizable image stamp | Inline image replacement is rejected. Insertion is an annotation, rather than rebuilding the page's original image object. |
| Links | Editable PDF link annotations | HTTP, HTTPS and mailto addresses. |
| Redact | MuPDF removes selected source content and draws a black redaction | Overlapping text, image pixels and touched vector objects are removed. Review the page before saving; intersecting vector objects may be removed as whole objects. Undo is available within the current session. This is separate from the existing rasterized masked-copy export. |
| Sign / Fill & Sign | Handwritten signature, text, dates, checks, crosses, text stamps and images | Visual/electronic annotations; no certificate-based digital signature or identity verification. |
| OCR / searchable PDF | Local Vision OCR and searchable PDF export | Recognition depends on scan quality and supported system languages; results need review. |
| Word conversion | Actual DOCX export with MuPDF | Layout fidelity varies, especially for tables, columns and complex typography. |
| Merge / split | Merge PDFs, extract a page, reorder/delete/rotate pages | No batch split-by-range interface. |
| Excel / PowerPoint conversion | **Not implemented** | No reliable spreadsheet/presentation converter is integrated; these are not displayed as working export actions. |
| PDF Copilot / AI extraction | **Not implemented** | No AI service, model or credentials are configured. |
| Search/transcribe arbitrary ink notes | **Not implemented** | Typed/Scribble-converted text and text-markup snippets are searchable. Freehand ink is not silently converted into searchable annotation text. |
| iPhone/Mac apps and cloud synchronization | **Not implemented** | This repository still targets iPadOS and local storage. |

## Validation

The production C bridge has native regression cases for inserted-image rendering, original-content redaction, rotated/cropped pages, and preserving image occurrences outside the selected area. XCTest covers live previews, style changes, saved line/arrow properties, pressure widths, group movement/deletion, partial/whole erasing and undo, repeated stamps, Scribble focus, reading layout/margin changes, links, and native operation history. Pixel checks also exercise recolouring and partial erasing of reopened annotations that already have PDF appearance streams; undo restores their previous rendering.

The Linux syntax/project/localization checks do not replace Xcode compilation. Simulator tests exercise the editing pipeline and saved PDFs. Actual Pencil force, system handwriting recognition, speech playback and physical touch feel still require an iPad check.

Suggested device pass: replay the sequence in the table on a copy of a PDF; save/reopen; inspect marks in another PDF reader; verify eraser undo, colour changes on a selected arrow, image placement, and that redacted text is no longer searchable. Test pressure with a pressure-capable Pencil (some Pencil models do not report force).
