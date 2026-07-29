#include <stdbool.h>
#include <stddef.h>

#include "yyjson.h"

bool benchmark_yyjson_dom(const char *input, size_t length) {
    yyjson_doc *document = yyjson_read(input, length, YYJSON_READ_NOFLAG);
    if (document == NULL) return false;
    yyjson_doc_free(document);
    return true;
}
