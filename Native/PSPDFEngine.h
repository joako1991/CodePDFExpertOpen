/* SPDX-License-Identifier: AGPL-3.0-or-later */
#ifndef PS_PDF_ENGINE_H
#define PS_PDF_ENGINE_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct { float x0, y0, x1, y1; } PSRect;
enum { PS_REPLACE_TEXT = 1, PS_REPLACE_IMAGE = 2, PS_EXPORT_DOCX = 3, PS_INSERT_IMAGE = 4, PS_REDACT = 5 };
typedef struct {
    unsigned char *data;
    size_t length;
    char *message;
} PSResult;

/* Synchronous, independent context per call. Input is borrowed only for this call.
 * Bounds/point use raw PDF page coordinates (PDFKit page space).
 * Image replacement uses (x0,y0) to select the last painted intersecting image.
 * Text replacement is a single line using a fallback font; no automatic reflow.
 * All MuPDF exceptions are caught in C. Returns 0 on success, 1 on failure.
 * Initialize result to zero and call ps_pdf_result_free after EVERY call.
 */
int ps_pdf_process(const unsigned char *input, size_t input_length,
    const char *password, int operation, int page_index, PSRect region,
    const char *replacement_text, float font_size,
    const unsigned char *replacement_image, size_t image_length, PSResult *result);
void ps_pdf_result_free(PSResult *result);
const char *ps_pdf_version(void);

#ifdef __cplusplus
}
#endif
#endif
