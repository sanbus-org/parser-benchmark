#!/bin/sh
set -eu

parser_c=$1
parser_h=$2
lexer_c=$3
grammar=$4
lexer=$5

bison --defines="$parser_h" --output="$parser_c" "$grammar"
flex --outfile="$lexer_c" "$lexer"
