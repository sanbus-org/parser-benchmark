#include <stdbool.h>
#include <stddef.h>

#include "yyjson.h"

// Returns the parsed document, or NULL when the input does not parse. The
// driver frees it with benchmark_yyjson_dom_free after it stops the clock,
// so timing covers building the document and not tearing it down.
void *benchmark_yyjson_dom(const char *input, size_t length) {
    return yyjson_read(input, length, YYJSON_READ_NOFLAG);
}

void benchmark_yyjson_dom_free(void *document) {
    yyjson_doc_free((yyjson_doc *)document);
}
