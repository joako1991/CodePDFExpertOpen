/* SPDX-License-Identifier: AGPL-3.0-or-later */
#include "PSPDFEngine.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned char *read_file(const char *path, size_t *length)
{
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    if (fseek(file, 0, SEEK_END)) { fclose(file); return NULL; }
    long size = ftell(file);
    if (size < 0 || fseek(file, 0, SEEK_SET)) { fclose(file); return NULL; }
    unsigned char *data = malloc((size_t)size + 1);
    if (!data) { fclose(file); return NULL; }
    if (fread(data, 1, (size_t)size, file) != (size_t)size) { free(data); fclose(file); return NULL; }
    fclose(file); *length = (size_t)size; return data;
}

int main(int argc, char **argv)
{
    if (argc != 13) return 2;
    size_t input_size = 0, image_size = 0;
    unsigned char *input = read_file(argv[1], &input_size);
    unsigned char *image = argv[11][0] ? read_file(argv[11], &image_size) : NULL;
    if (!input) return 2;
    PSRect region = {(float)atof(argv[5]), (float)atof(argv[6]), (float)atof(argv[7]), (float)atof(argv[8])};
    PSResult result = {0};
    int status = ps_pdf_process(input, input_size, argv[12], atoi(argv[3]), atoi(argv[4]), region,
        argv[9], (float)atof(argv[10]), image, image_size, &result);
    if (status) fprintf(stderr, "%s\n", result.message ? result.message : "Engine failure");
    else
    {
        FILE *file = fopen(argv[2], "wb");
        if (!file) status = 2;
        else
        {
            if (fwrite(result.data, 1, result.length, file) != result.length) status = 2;
            if (fclose(file)) status = 2;
        }
    }
    ps_pdf_result_free(&result);
    free(input); free(image);
    return status;
}
