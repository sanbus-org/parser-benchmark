//! C ABI exports so the Zig benchmark driver can call RustPython's
//! LALRPOP-generated Python parser in-process, mirroring `python/ruff-bench`.
use rustpython_parser::{parse, Mode};
use std::any::Any;
use std::ffi::c_void;
use std::ptr;
use std::slice;
use std::str;

/// Full module parse building RustPython's AST. Returns a handle owning the
/// parse result, or null when the source is not valid UTF-8 or does not
/// parse. The UTF-8 check is part of the timed parse because the parser
/// requires a `&str`. The driver releases the handle with
/// `benchmark_lalrpop_python_free` after it stops the clock, so timing
/// covers building the tree and not dropping it.
#[no_mangle]
pub extern "C" fn benchmark_lalrpop_python_parse_module(
    input_ptr: *const u8,
    input_len: usize,
) -> *mut c_void {
    if input_ptr.is_null() {
        return ptr::null_mut();
    }
    let bytes = unsafe { slice::from_raw_parts(input_ptr, input_len) };
    let Ok(source) = str::from_utf8(bytes) else {
        return ptr::null_mut();
    };
    match parse(source, Mode::Module, "<benchmark>") {
        Ok(module) => {
            let owned: Box<dyn Any> = Box::new(module);
            Box::into_raw(Box::new(owned)) as *mut c_void
        }
        Err(_) => ptr::null_mut(),
    }
}

/// Drops a handle returned by `benchmark_lalrpop_python_parse_module`.
///
/// # Safety
/// `handle` must be null or a handle not yet released.
#[no_mangle]
pub unsafe extern "C" fn benchmark_lalrpop_python_free(handle: *mut c_void) {
    if !handle.is_null() {
        drop(Box::from_raw(handle as *mut Box<dyn Any>));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn parse_handle(source: &str) -> *mut c_void {
        benchmark_lalrpop_python_parse_module(source.as_ptr(), source.len())
    }

    #[test]
    fn parses_all_python_datasets() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../datasets/python");
        let mut entries: Vec<_> = std::fs::read_dir(&dir)
            .expect("python datasets dir")
            .map(|entry| entry.expect("dir entry").path())
            .filter(|path| path.extension().map(|ext| ext == "py").unwrap_or(false))
            .collect();
        entries.sort();
        assert!(entries.len() >= 7, "expected all Python benchmark datasets");
        for path in entries {
            let source = std::fs::read_to_string(&path).expect("read dataset");
            let handle = parse_handle(&source);
            assert!(!handle.is_null(), "failed: {}", path.display());
            unsafe { benchmark_lalrpop_python_free(handle) };
        }
    }

    #[test]
    fn rejects_invalid_utf8() {
        let bytes = [0xff];
        let handle = benchmark_lalrpop_python_parse_module(bytes.as_ptr(), bytes.len());
        assert!(handle.is_null());
    }
}
