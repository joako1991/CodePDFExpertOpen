// SPDX-License-Identifier: AGPL-3.0-or-later
// Study only: native C operations on a controlled fixture, not an iPadOS bridge.
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <stdio.h>
#include <string.h>

static void remove_original_text(fz_context *ctx, pdf_document *doc)
{
    pdf_page *page = NULL;
    pdf_annot *annot = NULL;
    pdf_redact_options options = {0};
    fz_var(page);
    fz_var(annot);
    fz_try(ctx)
    {
        page = pdf_load_page(ctx, doc, 0);
        annot = pdf_create_annot(ctx, page, PDF_ANNOT_REDACT);
        // MuPDF page space is top-left, unlike raw PDF content coordinates.
        pdf_set_annot_rect(ctx, annot, fz_make_rect(45, 80, 300, 110));
        options.black_boxes = 0;
        options.image_method = PDF_REDACT_IMAGE_NONE;
        options.line_art = PDF_REDACT_LINE_ART_NONE;
        options.text = PDF_REDACT_TEXT_REMOVE;
        pdf_redact_page(ctx, doc, page, &options);
    }
    fz_always(ctx)
    {
        pdf_drop_annot(ctx, annot);
        pdf_drop_page(ctx, page);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

static void insert_replacement(fz_context *ctx, pdf_document *doc)
{
    fz_font *font = NULL;
    fz_buffer *buffer = NULL;
    pdf_obj *font_ref = NULL, *stream = NULL, *array = NULL;
    fz_var(font); fz_var(buffer); fz_var(font_ref); fz_var(stream); fz_var(array);
    fz_try(ctx)
    {
        pdf_obj *page = pdf_lookup_page_obj(ctx, doc, 0);
        pdf_obj *resources = pdf_dict_get_inheritable(ctx, page, PDF_NAME(Resources));
        pdf_obj *fonts = pdf_dict_get(ctx, resources, PDF_NAME(Font));
        const char *operators = "\nBT /PSReplacement 18 Tf 50 740 Td (REPLACEMENT_TEXT) Tj ET\n";
        font = fz_new_base14_font(ctx, "Helvetica");
        font_ref = pdf_add_simple_font(ctx, doc, font, PDF_SIMPLE_ENCODING_LATIN);
        pdf_dict_puts(ctx, fonts, "PSReplacement", font_ref);
        buffer = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)operators, strlen(operators));
        stream = pdf_add_stream(ctx, doc, buffer, NULL, 0);
        pdf_obj *old = pdf_dict_get(ctx, page, PDF_NAME(Contents));
        array = pdf_new_array(ctx, doc, 2);
        if (pdf_is_array(ctx, old))
        {
            for (int i = 0; i < pdf_array_len(ctx, old); ++i)
                pdf_array_push(ctx, array, pdf_array_get(ctx, old, i));
        }
        else if (old) pdf_array_push(ctx, array, old);
        pdf_array_push(ctx, array, stream);
        pdf_dict_put(ctx, page, PDF_NAME(Contents), array);
    }
    fz_always(ctx)
    {
        pdf_drop_obj(ctx, array); pdf_drop_obj(ctx, stream); pdf_drop_obj(ctx, font_ref);
        fz_drop_buffer(ctx, buffer); fz_drop_font(ctx, font);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

static void replace_page_image(fz_context *ctx, pdf_document *doc)
{
    fz_pixmap *pixmap = NULL;
    fz_image *image = NULL;
    pdf_obj *ref = NULL, *resources = NULL, *xobjects = NULL;
    fz_var(pixmap); fz_var(image); fz_var(ref); fz_var(resources); fz_var(xobjects);
    fz_try(ctx)
    {
        pixmap = fz_new_pixmap(ctx, fz_device_rgb(ctx), 4, 4, NULL, 0);
        unsigned char *samples = fz_pixmap_samples(ctx, pixmap);
        int stride = fz_pixmap_stride(ctx, pixmap);
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x)
            {
                samples[y * stride + x * 3] = 0;
                samples[y * stride + x * 3 + 1] = 0;
                samples[y * stride + x * 3 + 2] = 255;
            }
        image = fz_new_image_from_pixmap(ctx, pixmap, NULL);
        ref = pdf_add_image(ctx, doc, image);
        pdf_obj *page = pdf_lookup_page_obj(ctx, doc, 0);
        // Copy both dictionaries so a shared resource dictionary on another page is not modified.
        resources = pdf_copy_dict(ctx, pdf_dict_get_inheritable(ctx, page, PDF_NAME(Resources)));
        xobjects = pdf_copy_dict(ctx, pdf_dict_get(ctx, resources, PDF_NAME(XObject)));
        pdf_dict_puts(ctx, xobjects, "Im0", ref);
        pdf_dict_put(ctx, resources, PDF_NAME(XObject), xobjects);
        pdf_dict_put(ctx, page, PDF_NAME(Resources), resources);
    }
    fz_always(ctx)
    {
        pdf_drop_obj(ctx, xobjects); pdf_drop_obj(ctx, resources); pdf_drop_obj(ctx, ref);
        fz_drop_image(ctx, image); fz_drop_pixmap(ctx, pixmap);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

int main(int argc, char **argv)
{
    if (argc != 4)
    {
        fprintf(stderr, "usage: probe INPUT.pdf OUTPUT.pdf redact|replace-text|replace-image\n");
        return 2;
    }
    if (strcmp(argv[1], argv[2]) == 0)
    {
        fprintf(stderr, "Output must be a different file; the study never overwrites its input.\n");
        return 2;
    }
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) return 1;
    pdf_document *doc = NULL;
    int result = 0;
    fz_var(doc); fz_var(result);
    fz_try(ctx)
    {
        doc = pdf_open_document(ctx, argv[1]);
        if (!strcmp(argv[3], "redact")) remove_original_text(ctx, doc);
        else if (!strcmp(argv[3], "replace-text"))
        {
            remove_original_text(ctx, doc);
            insert_replacement(ctx, doc);
        }
        else if (!strcmp(argv[3], "replace-image")) replace_page_image(ctx, doc);
        else fz_throw(ctx, FZ_ERROR_ARGUMENT, "Unknown operation");
        pdf_write_options options = pdf_default_write_options;
        options.do_incremental = 0;
        options.do_garbage = 3;
        options.do_compress = 1;
        pdf_save_document(ctx, doc, argv[2], &options);
    }
    fz_always(ctx) { pdf_drop_document(ctx, doc); }
    fz_catch(ctx)
    {
        fprintf(stderr, "MuPDF: %s\n", fz_caught_message(ctx));
        result = 1;
    }
    fz_drop_context(ctx);
    return result;
}
