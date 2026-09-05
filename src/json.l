%{
typedef union {
    void *node;
    struct {
        const char *text;
        size_t length;
    } token;
} YYSTYPE;
#define YYSTYPE_IS_DECLARED 1

#include "parser.h"
%}

%option fast
%option 8bit
%option noyywrap
%option nounput
%option noinput
%option nodefault

/* Strict JSON string content, mirroring Galley's json-unicode grammar:
 * unescaped ASCII is limited to Galley's `character` set (tab/CR/LF/VT/FF
 * plus printable ASCII except '"' and '\'), multi-byte sequences follow the
 * same UTF-8 lead/continuation ranges (surrogates and overlongs excluded),
 * and escapes require one of "/bfnrt plus 'u' with exactly 4 hex digits.
 * Anything else falls through to the catch-all rule and fails the parse,
 * so invalid unicode rejects exactly where Galley rejects it. */
HEX     [0-9a-fA-F]
UTF8_2  [\xC2-\xDF][\x80-\xBF]
UTF8_3  (\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF][\x80-\xBF]|\xED[\x80-\x9F][\x80-\xBF])
UTF8_4  (\xF0[\x90-\xBF][\x80-\xBF][\x80-\xBF]|[\xF1-\xF3][\x80-\xBF][\x80-\xBF][\x80-\xBF]|\xF4[\x80-\x8F][\x80-\xBF][\x80-\xBF])
ESC     \\([\"\\/bfnrt]|u{HEX}{HEX}{HEX}{HEX})
STRCHAR ([\x09-\x0D\x20-\x21\x23-\x5B\x5D-\x7E]|{UTF8_2}|{UTF8_3}|{UTF8_4}|{ESC})

%%
[ \t\r\n]+             ; /* Ignore whitespace */
"{"                     { yylval.token.text = yytext; yylval.token.length = yyleng; return '{'; }
"}"                     { yylval.token.text = yytext; yylval.token.length = yyleng; return '}'; }
"["                     { yylval.token.text = yytext; yylval.token.length = yyleng; return '['; }
"]"                     { yylval.token.text = yytext; yylval.token.length = yyleng; return ']'; }
":"                     { yylval.token.text = yytext; yylval.token.length = yyleng; return ':'; }
","                     { yylval.token.text = yytext; yylval.token.length = yyleng; return ','; }
"true"                  { yylval.token.text = yytext; yylval.token.length = yyleng; return TRUE; }
"false"                 { yylval.token.text = yytext; yylval.token.length = yyleng; return FALSE; }
"null"                  { yylval.token.text = yytext; yylval.token.length = yyleng; return NULL_TOK; }
\"{STRCHAR}*\"          { yylval.token.text = yytext; yylval.token.length = yyleng; return STRING; }
[-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)? { yylval.token.text = yytext; yylval.token.length = yyleng; return NUMBER; }
.                       return yytext[0];
%%
