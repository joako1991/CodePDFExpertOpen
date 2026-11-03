/* SPDX-License-Identifier: AGPL-3.0-or-later */
#include "PSPDFEngine.h"
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

const char *ps_pdf_version(void) { return FZ_VERSION; }
void ps_pdf_result_free(PSResult *result)
{
    if (!result) return;
    free(result->data); free(result->message);
    memset(result, 0, sizeof(*result));
}

static void error_message(PSResult *result, const char *message)
{
    size_t n = strlen(message) + 1;
    result->message = malloc(n);
    if (result->message) memcpy(result->message, message, n);
}

static void replace_text(fz_context *ctx, pdf_document *doc, pdf_page *page,
    PSRect region, const char *replacement, float size)
{
    pdf_annot *annot = NULL;
    fz_font *font = NULL;
    fz_text *text = NULL;
    fz_device *device = NULL;
    fz_buffer *content = NULL;
    pdf_obj *resources = NULL, *font_resources = NULL, *stream = NULL;
    pdf_obj *array = NULL, *prefix = NULL, *suffix = NULL;
    fz_buffer *prefix_buffer = NULL, *suffix_buffer = NULL;
    fz_var(annot); fz_var(font); fz_var(text); fz_var(device); fz_var(content);
    fz_var(resources); fz_var(font_resources); fz_var(stream); fz_var(array);
    fz_var(prefix); fz_var(suffix); fz_var(prefix_buffer); fz_var(suffix_buffer);
    fz_try(ctx)
    {
        fz_rect box;
        fz_matrix page_ctm;
        pdf_page_transform(ctx, page, &box, &page_ctm);
        fz_rect raw = fz_make_rect(region.x0, region.y0, region.x1, region.y1);
        raw = fz_intersect_rect(raw, fz_transform_rect(pdf_bound_page(ctx, page, FZ_CROP_BOX), fz_invert_matrix(page_ctm)));
        fz_rect bounds = fz_transform_rect(raw, page_ctm);
        if (!replacement || !replacement[0] || strchr(replacement, '\n') || strchr(replacement, '\r'))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Le remplacement doit contenir une seule ligne non vide.");
        if (fz_is_empty_rect(raw) || !isfinite(size) || size < 4 || size > 200 || size > (raw.y1 - raw.y0) * 1.2f)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "La taille du texte ne tient pas dans la sélection.");
        font = fz_new_base14_font(ctx, "Helvetica");
        fz_matrix matrix = fz_make_matrix(size, 0, 0, -size, 0, size * 0.85f);
        fz_matrix end = fz_measure_string(ctx, font, matrix, replacement, 0, 0, FZ_BIDI_NEUTRAL, FZ_LANG_UNSET);
        if (end.e > raw.x1 - raw.x0 + 0.5f)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Texte trop long : réduisez la taille ou raccourcissez la ligne.");
        annot = pdf_create_annot(ctx, page, PDF_ANNOT_REDACT);
        pdf_set_annot_rect(ctx, annot, bounds);
        pdf_redact_options redact = {0};
        redact.image_method = PDF_REDACT_IMAGE_NONE;
        redact.line_art = PDF_REDACT_LINE_ART_NONE;
        redact.text = PDF_REDACT_TEXT_REMOVE;
        pdf_apply_redaction(ctx, annot, &redact);

        pdf_obj *page_obj = page->obj;
        resources = pdf_copy_dict(ctx, pdf_page_resources(ctx, page));
        pdf_obj *old_fonts = pdf_dict_get(ctx, resources, PDF_NAME(Font));
        font_resources = old_fonts ? pdf_copy_dict(ctx, old_fonts) : pdf_new_dict(ctx, doc, 4);
        pdf_dict_put(ctx, resources, PDF_NAME(Font), font_resources);
        content = fz_new_buffer(ctx, 256);
        // Layout in raw PDF space: page /Rotate then affects old and new text identically.
        device = pdf_new_pdf_device(ctx, doc, fz_make_matrix(1, 0, 0, -1, raw.x0, raw.y1), resources, content);
        text = fz_new_text(ctx);
        fz_show_string(ctx, text, font, matrix, replacement, 0, 0, FZ_BIDI_NEUTRAL, FZ_LANG_UNSET);
        float black[] = {0};
        fz_fill_text(ctx, device, text, fz_identity, fz_device_gray(ctx), black, 1, fz_default_color_params);
        fz_close_device(ctx, device);
        stream = pdf_add_stream(ctx, doc, content, NULL, 0);
        prefix_buffer = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)"q\n", 2);
        suffix_buffer = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)"\nQ\n", 3);
        prefix = pdf_add_stream(ctx, doc, prefix_buffer, NULL, 0);
        suffix = pdf_add_stream(ctx, doc, suffix_buffer, NULL, 0);
        array = pdf_new_array(ctx, doc, 5);
        pdf_array_push(ctx, array, prefix);
        pdf_obj *old_content = pdf_page_contents(ctx, page);
        if (pdf_is_array(ctx, old_content))
            for (int i = 0; i < pdf_array_len(ctx, old_content); ++i)
                pdf_array_push(ctx, array, pdf_array_get(ctx, old_content, i));
        else if (old_content) pdf_array_push(ctx, array, old_content);
        pdf_array_push(ctx, array, suffix);
        pdf_array_push(ctx, array, stream);
        pdf_dict_put(ctx, page_obj, PDF_NAME(Resources), resources);
        pdf_dict_put(ctx, page_obj, PDF_NAME(Contents), array);
    }
    fz_always(ctx)
    {
        fz_drop_device(ctx, device); fz_drop_text(ctx, text); fz_drop_font(ctx, font);
        pdf_drop_annot(ctx, annot); fz_drop_buffer(ctx, content);
        fz_drop_buffer(ctx, prefix_buffer); fz_drop_buffer(ctx, suffix_buffer);
        pdf_drop_obj(ctx, resources); pdf_drop_obj(ctx, font_resources);
        pdf_drop_obj(ctx, stream); pdf_drop_obj(ctx, array); pdf_drop_obj(ctx, prefix); pdf_drop_obj(ctx, suffix);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

typedef struct {
    fz_point point;
    fz_image *replacement;
    int hit_count;
    int selected_hit;
    int applied;
    int scan_only;
} ImageFilter;

static fz_image *image_filter(fz_context *ctx, void *opaque, fz_matrix ctm,
    const char *name, fz_image *original, fz_rect clip)
{
    ImageFilter *filter = opaque;
    int is_inline = !strcmp(name, "<inline>");
    fz_point local = fz_transform_point(filter->point, fz_invert_matrix(ctm));
    int inside = local.x >= 0 && local.x <= 1 && local.y >= 0 && local.y <= 1 &&
        filter->point.x >= clip.x0 && filter->point.x <= clip.x1 && filter->point.y >= clip.y0 && filter->point.y <= clip.y1;
    if (inside)
    {
        ++filter->hit_count;
        if (!filter->scan_only && filter->hit_count == filter->selected_hit)
        {
            if (is_inline) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Les images inline ne peuvent pas être remplacées dans cette version.");
            filter->applied = 1;
            return fz_keep_image(ctx, filter->replacement);
        }
    }
    /* The sanitize API borrows unchanged XObjects, but owns inline callback results. */
    return is_inline ? fz_keep_image(ctx, original) : original;
}

static void replace_image(fz_context *ctx, pdf_document *doc, pdf_page *page,
    PSRect region, const unsigned char *image_data, size_t image_length)
{
    fz_buffer *buffer = NULL;
    fz_image *image = NULL;
    fz_var(buffer); fz_var(image);
    fz_try(ctx)
    {
        if (!image_data || !image_length) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Choisissez une image de remplacement.");
        buffer = fz_new_buffer_from_shared_data(ctx, image_data, image_length);
        image = fz_new_image_from_buffer(ctx, buffer);
        ImageFilter filter = {0};
        filter.point = fz_make_point(region.x0, region.y0);
        filter.replacement = image;
        filter.scan_only = 1;
        pdf_sanitize_filter_options sanitize = {0};
        sanitize.opaque = &filter;
        sanitize.image_filter = image_filter;
        pdf_filter_factory factories[] = { {pdf_new_sanitize_filter, &sanitize}, {NULL, NULL} };
        pdf_filter_options options = {0};
        options.filters = factories;
        options.instance_forms = 1;
        options.no_update = 1;
        pdf_filter_page_contents(ctx, doc, page, &options);
        if (!filter.hit_count) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Aucune image PDF détectée à cet endroit.");
        filter.selected_hit = filter.hit_count;
        filter.hit_count = 0;
        filter.scan_only = 0;
        options.no_update = 0;
        pdf_filter_page_contents(ctx, doc, page, &options);
        if (!filter.applied) fz_throw(ctx, FZ_ERROR_FORMAT, "Impossible de sélectionner cette occurrence d’image.");
    }
    fz_always(ctx) { fz_drop_image(ctx, image); fz_drop_buffer(ctx, buffer); }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

int ps_pdf_process(const unsigned char *input, size_t input_length,
    const char *password, int operation, int page_index, PSRect region,
    const char *replacement_text, float font_size,
    const unsigned char *replacement_image, size_t image_length, PSResult *result)
{
    if (!result) return 1;
    memset(result, 0, sizeof(*result));
    if (!input || !input_length) { error_message(result, "Document PDF vide."); return 1; }
    fz_context *ctx = fz_new_context(NULL, NULL, 32 * 1024 * 1024);
    if (!ctx) { error_message(result, "Mémoire insuffisante."); return 1; }
    fz_stream *input_stream = NULL;
    pdf_document *doc = NULL;
    pdf_page *page = NULL;
    fz_buffer *output_buffer = NULL;
    fz_output *output = NULL;
    fz_document_writer *writer = NULL;
    int status = 0;
    fz_var(input_stream); fz_var(doc); fz_var(page); fz_var(output_buffer);
    fz_var(output); fz_var(writer); fz_var(status);
    fz_try(ctx)
    {
        input_stream = fz_open_memory(ctx, input, input_length);
        doc = pdf_open_document_with_stream(ctx, input_stream);
        if (pdf_needs_password(ctx, doc) && !pdf_authenticate_password(ctx, doc, password ? password : ""))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Mot de passe PDF incorrect ou absent.");
        if (operation < PS_REPLACE_TEXT || operation > PS_EXPORT_DOCX)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Opération PDF inconnue.");
        if (!pdf_has_permission(ctx, doc, operation == PS_EXPORT_DOCX ? FZ_PERMISSION_COPY : FZ_PERMISSION_EDIT))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Les permissions de ce PDF ne permettent pas cette opération.");
        output_buffer = fz_new_buffer(ctx, 1024);
        if (operation == PS_EXPORT_DOCX)
        {
            writer = fz_new_document_writer_with_buffer(ctx, output_buffer, "docx", NULL);
            fz_write_document(ctx, writer, (fz_document *)doc);
            fz_close_document_writer(ctx, writer);
        }
        else
        {
            if (page_index < 0 || page_index >= pdf_count_pages(ctx, doc) ||
                !isfinite(region.x0) || !isfinite(region.y0) || !isfinite(region.x1) || !isfinite(region.y1))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Page ou coordonnées invalides.");
            page = pdf_load_page(ctx, doc, page_index);
            if (operation == PS_REPLACE_TEXT)
                replace_text(ctx, doc, page, region, replacement_text, font_size);
            else replace_image(ctx, doc, page, region, replacement_image, image_length);
            output = fz_new_output_with_buffer(ctx, output_buffer);
            pdf_write_options options = pdf_default_write_options;
            options.do_incremental = 0;
            options.do_garbage = 3;
            options.do_compress = 1;
            options.do_encrypt = PDF_ENCRYPT_KEEP;
            pdf_write_document(ctx, doc, output, &options);
            fz_close_output(ctx, output);
        }
        unsigned char *bytes = NULL;
        size_t length = fz_buffer_storage(ctx, output_buffer, &bytes);
        if (!length) fz_throw(ctx, FZ_ERROR_FORMAT, "Le moteur a produit un document vide.");
        result->data = malloc(length);
        if (!result->data) fz_throw(ctx, FZ_ERROR_SYSTEM, "Mémoire insuffisante.");
        memcpy(result->data, bytes, length);
        result->length = length;
    }
    fz_always(ctx)
    {
        fz_drop_document_writer(ctx, writer); fz_drop_output(ctx, output);
        fz_drop_buffer(ctx, output_buffer); pdf_drop_page(ctx, page);
        pdf_drop_document(ctx, doc); fz_drop_stream(ctx, input_stream);
    }
    fz_catch(ctx)
    {
        free(result->data); result->data = NULL; result->length = 0;
        error_message(result, fz_caught_message(ctx)); status = 1;
    }
    fz_drop_context(ctx);
    return status;
}
