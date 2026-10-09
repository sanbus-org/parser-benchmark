#include "simdjson.h"

// Validate: use the ondemand API which lazily validates structure without
// materialising a DOM. raw_json() internally consumes the document through
// its end, so its result reports structural errors found during traversal.
extern "C" bool benchmark_simdjson_validate(const char *input_ptr, size_t input_len) {
    auto view = simdjson::padded_string_view(input_ptr, input_len, input_len + simdjson::SIMDJSON_PADDING);
    simdjson::ondemand::parser parser;
    simdjson::ondemand::document doc;
    if (parser.iterate(view).get(doc)) return false;
    return doc.raw_json().error() == simdjson::error_code::SUCCESS;
}

// DOM: use the dom::parser which always builds the full internal tape
// (stage 1 structural indexing + stage 2 full parse → DOM element tree).
extern "C" bool benchmark_simdjson_dom(const char *input_ptr, size_t input_len) {
    auto view = simdjson::padded_string_view(input_ptr, input_len, input_len + simdjson::SIMDJSON_PADDING);
    simdjson::dom::parser parser;
    simdjson::dom::element doc;
    auto error = parser.parse(view).get(doc);
    return error == simdjson::error_code::SUCCESS;
}
