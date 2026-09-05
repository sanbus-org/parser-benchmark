use std::slice;
use std::str;

use lalrpop_util::lalrpop_mod;

lalrpop_mod!(pub json);
lalrpop_mod!(pub json_ast);
pub mod nom_json;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AstNodeType {
    Object,
    Array,
    Member,
    String,
    Number,
    True,
    False,
    Null,
}

/// Arena node mirroring Bison's Simple AST: borrowed input span plus
/// first-child / last-child / next-sibling links, stored by index.
pub struct AstNode {
    /// Retained for tree-shape parity with Bison; only read by tests.
    #[allow(dead_code)]
    pub kind: AstNodeType,
    pub start: usize,
    pub len: usize,
    pub first_child: Option<usize>,
    pub last_child: Option<usize>,
    pub next_sibling: Option<usize>,
}

/// Strict JSON string-content check over a complete `"..."` token, mirroring
/// Galley's unicode grammar and the Flex lexer: raw bytes limited to tab/CR/
/// LF/VT/FF plus printable ASCII except `"` and `\`, well-formed UTF-8
/// sequences, and `\` + one of `"/bfnrt` or `u` + 4 hex digits. Both LALRPOP
/// grammars call it, so No-AST and AST lex identical work. (Input is `&str`,
/// so multi-byte content is valid UTF-8 by construction; the structural scan
/// still runs to keep the work comparable.)
pub fn validate_json_string(token: &str) -> bool {
    let bytes = token.as_bytes();
    if bytes.len() < 2 || bytes[0] != b'"' || bytes[bytes.len() - 1] != b'"' {
        return false;
    }
    // Take n content bytes starting at i; false if they would overrun the
    // closing quote.
    let end = bytes.len() - 1;
    let mut i = 1;
    while i < end {
        let take = |i: usize, n: usize| i + n <= end;
        match bytes[i] {
            0x09..=0x0D | 0x20..=0x21 | 0x23..=0x5B | 0x5D..=0x7E => i += 1,
            b'\\' => {
                i += 1;
                if i >= end {
                    return false;
                }
                match bytes[i] {
                    b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => i += 1,
                    b'u' => {
                        if !take(i + 1, 4)
                            || !bytes[i + 1..i + 5].iter().all(|b| b.is_ascii_hexdigit())
                        {
                            return false;
                        }
                        i += 5;
                    }
                    _ => return false,
                }
            }
            0xC2..=0xDF => {
                if !take(i + 1, 1) || !(0x80..=0xBF).contains(&bytes[i + 1]) {
                    return false;
                }
                i += 2;
            }
            0xE0 => {
                if !take(i + 1, 2)
                    || !(0xA0..=0xBF).contains(&bytes[i + 1])
                    || !(0x80..=0xBF).contains(&bytes[i + 2])
                {
                    return false;
                }
                i += 3;
            }
            0xE1..=0xEC | 0xEE..=0xEF => {
                if !take(i + 1, 2)
                    || !(0x80..=0xBF).contains(&bytes[i + 1])
                    || !(0x80..=0xBF).contains(&bytes[i + 2])
                {
                    return false;
                }
                i += 3;
            }
            0xED => {
                if !take(i + 1, 2)
                    || !(0x80..=0x9F).contains(&bytes[i + 1])
                    || !(0x80..=0xBF).contains(&bytes[i + 2])
                {
                    return false;
                }
                i += 3;
            }
            0xF0 => {
                if !take(i + 1, 3)
                    || !(0x90..=0xBF).contains(&bytes[i + 1])
                    || !(0x80..=0xBF).contains(&bytes[i + 2])
                    || !(0x80..=0xBF).contains(&bytes[i + 3])
                {
                    return false;
                }
                i += 4;
            }
            0xF1..=0xF3 => {
                if !take(i + 1, 3)
                    || !(0x80..=0xBF).contains(&bytes[i + 1])
                    || !(0x80..=0xBF).contains(&bytes[i + 2])
                    || !(0x80..=0xBF).contains(&bytes[i + 3])
                {
                    return false;
                }
                i += 4;
            }
            0xF4 => {
                if !take(i + 1, 3)
                    || !(0x80..=0x8F).contains(&bytes[i + 1])
                    || !(0x80..=0xBF).contains(&bytes[i + 2])
                    || !(0x80..=0xBF).contains(&bytes[i + 3])
                {
                    return false;
                }
                i += 4;
            }
            _ => return false,
        }
    }
    true
}

thread_local! {
    static AST_ARENA: std::cell::RefCell<Vec<AstNode>> = std::cell::RefCell::new(Vec::new());
}

/// Clear the arena before a parse; the benchmark calls this per iteration,
/// which also keeps peak memory flat across warmup and measured runs.
pub fn ast_arena_clear() {
    AST_ARENA.with(|arena| arena.borrow_mut().clear());
}

pub fn ast_node_count() -> usize {
    AST_ARENA.with(|arena| arena.borrow().len())
}

pub fn alloc_node(kind: AstNodeType, start: usize, end: usize) -> usize {
    AST_ARENA.with(|arena| {
        let mut arena = arena.borrow_mut();
        let index = arena.len();
        arena.push(AstNode {
            kind,
            start,
            len: end.saturating_sub(start),
            first_child: None,
            last_child: None,
            next_sibling: None,
        });
        index
    })
}

/// Append `child` to `parent` in O(1), extending the parent span to cover the
/// child — the same accumulation Bison performs for object/array spans, so a
/// single-member object ends up spanning its member exactly like Bison's.
/// A parent with an empty span is a fresh accumulator and adopts the first
/// child's span; Member nodes arrive with a real span and only ever extend.
pub fn append_child(parent: usize, child: usize) {
    AST_ARENA.with(|arena| {
        let mut arena = arena.borrow_mut();
        let (child_start, child_end) = {
            let node = &arena[child];
            (node.start, node.start + node.len)
        };
        if arena[parent].first_child.is_none() {
            // Fresh accumulators carry an empty span and adopt the first
            // child's; Member nodes already span key through value.
            if arena[parent].len == 0 {
                arena[parent].start = child_start;
                arena[parent].len = child_end.saturating_sub(child_start);
            }
            arena[parent].first_child = Some(child);
            arena[parent].last_child = Some(child);
        } else {
            let parent_end = arena[parent].start + arena[parent].len;
            if child_end > parent_end {
                arena[parent].len = child_end - arena[parent].start;
            }
            let last = arena[parent].last_child.unwrap();
            arena[last].next_sibling = Some(child);
            arena[parent].last_child = Some(child);
        }
    })
}

#[no_mangle]
pub extern "C" fn benchmark_lalrpop(input_ptr: *const u8, input_len: usize) -> bool {
    let bytes = unsafe { slice::from_raw_parts(input_ptr, input_len) };

    let s = match str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return false,
    };

    let parser = json::JSONParser::new();
    parser.parse(s).is_ok()
}

#[no_mangle]
pub extern "C" fn benchmark_lalrpop_ast(input_ptr: *const u8, input_len: usize) -> bool {
    let bytes = unsafe { slice::from_raw_parts(input_ptr, input_len) };

    let s = match str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return false,
    };

    ast_arena_clear();
    let parser = json_ast::JSONParser::new();
    match parser.parse(s) {
        Ok(root) => {
            std::hint::black_box(root);
            true
        }
        Err(_) => false,
    }
}

#[no_mangle]
pub extern "C" fn benchmark_nom(input_ptr: *const u8, input_len: usize) -> bool {
    let bytes = unsafe { slice::from_raw_parts(input_ptr, input_len) };

    let s = match str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return false,
    };

    match nom_json::root::<()>(s) {
        Ok((remaining, _)) => remaining.is_empty(),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_ast(input: &str) -> Option<usize> {
        ast_arena_clear();
        let parser = json_ast::JSONParser::new();
        parser.parse(input).ok()
    }

    /// Tree shape mirrors Bison's Simple AST node-for-node:
    /// object(1) + member a(1) + array(1) + 1, 2(2) + object(1) +
    /// member b(1) + null(1) + member c(1) + true(1) = 10 nodes.
    #[test]
    fn ast_node_count_matches_bison_shape() {
        let input = r#"{"a": [1, 2, {"b": null}], "c": true}"#;
        let root = parse_ast(input).expect("parse failed");
        assert_eq!(ast_node_count(), 10);
        AST_ARENA.with(|arena| {
            let arena = arena.borrow();
            // Root object spans its members (not the braces), like Bison's
            // accumulation: first key at 1 through the end of `"c": true`.
            assert_eq!(arena[root].kind, AstNodeType::Object);
            assert_eq!(arena[root].start, 1);
            assert_eq!(arena[root].start + arena[root].len, input.len() - 1);
        });
    }

    #[test]
    fn ast_empty_containers() {
        let root = parse_ast(r#"{"e": {}, "a": []}"#).expect("parse failed");
        // object + member + object + member + array = 5 nodes.
        assert_eq!(ast_node_count(), 5);
        AST_ARENA.with(|arena| {
            assert_eq!(arena.borrow()[root].kind, AstNodeType::Object);
        });
    }

    #[test]
    fn ast_rejects_invalid_input() {
        assert!(parse_ast(r#"{"a": }"#).is_none());
        assert!(parse_ast(r#"{"a": 01}"#).is_some()); // lax number, same as No-AST sibling
    }

    /// Every benchmark dataset must parse; inputs are shared with the harness.
    #[test]
    fn ast_parses_all_datasets() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../datasets");
        let mut count = 0;
        let mut entries: Vec<_> = std::fs::read_dir(&dir)
            .expect("datasets dir")
            .map(|e| e.expect("dir entry").path())
            .filter(|p| p.extension().map(|e| e == "json").unwrap_or(false))
            .collect();
        entries.sort();
        for path in entries {
            let input = std::fs::read_to_string(&path).expect("read dataset");
            assert!(parse_ast(&input).is_some(), "failed: {}", path.display());
            assert!(ast_node_count() > 0, "empty tree: {}", path.display());
            count += 1;
        }
        assert!(count >= 10, "expected all benchmark datasets");
    }

    #[test]
    fn validate_json_string_cases() {
        for valid in [
            r#""hello""#,
            r#""""#,
            "\"a\\nb\"",
            "\"\\u0041\"",
            "\"caf\u{e9}\"",
            "\"tab\there\"",
        ] {
            assert!(validate_json_string(valid), "accept: {valid}");
        }
        for invalid in ["\"\\q\"", "\"\\u12\"", "\"abc", "\"a\x01b\"", "\"\u{7f}\""] {
            assert!(!validate_json_string(invalid), "reject: {invalid:?}");
        }
    }

    fn dataset_paths() -> Vec<std::path::PathBuf> {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../datasets");
        let mut entries: Vec<_> = std::fs::read_dir(&dir)
            .expect("datasets dir")
            .map(|e| e.expect("dir entry").path())
            .filter(|p| p.extension().map(|e| e == "json").unwrap_or(false))
            .collect();
        entries.sort();
        assert!(entries.len() >= 10, "expected all benchmark datasets");
        entries
    }

    /// The No-AST entry must accept every benchmark dataset after tightening.
    #[test]
    fn lalrpop_no_ast_parses_all_datasets() {
        for path in dataset_paths() {
            let input = std::fs::read_to_string(&path).expect("read dataset");
            let ok = benchmark_lalrpop(input.as_ptr(), input.len());
            assert!(ok, "failed: {}", path.display());
        }
    }

    /// The Nom entry must accept every benchmark dataset after tightening.
    #[test]
    fn nom_parses_all_datasets() {
        for path in dataset_paths() {
            let input = std::fs::read_to_string(&path).expect("read dataset");
            let ok = benchmark_nom(input.as_ptr(), input.len());
            assert!(ok, "failed: {}", path.display());
        }
    }

    #[test]
    fn nom_rejects_bad_escapes() {
        for bad in ["\"\\q\"", "\"\\u12\"", "\"a\x01b\""] {
            assert!(!benchmark_nom(bad.as_ptr(), bad.len()), "reject: {bad:?}");
        }
    }
}
