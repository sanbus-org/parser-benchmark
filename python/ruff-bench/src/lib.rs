//! C ABI exports so the Zig benchmark driver can call the pinned
//! `ruff_python_parser` in-process, mirroring `json/lalrpop-bench`.
//! The standalone `src/main.rs` prototype still builds as the bin target.
use ruff_python_parser::parse_module;
use std::any::Any;
use std::ffi::c_void;
use std::ptr;
use std::slice;
use std::str;

// The allocator Ruff uses on these targets (see its `ruff` binary and
// `ruff_benchmark`), so tree allocation costs what it costs in Ruff.
#[cfg(all(
    not(target_os = "windows"),
    not(target_os = "openbsd"),
    any(
        target_arch = "x86_64",
        target_arch = "aarch64",
        target_arch = "powerpc64",
        target_arch = "riscv64"
    )
))]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

/// Full module parse building the AST. Returns a handle owning the parse
/// result, or null when the source is not valid UTF-8 or does not parse.
/// The UTF-8 check is part of the timed parse, as Ruff needs a `&str`. The
/// driver releases the handle with `benchmark_ruff_free` after it stops the
/// clock, so timing covers building the tree and not dropping it.
#[no_mangle]
pub extern "C" fn benchmark_ruff_parse_module(
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
    std::panic::catch_unwind(|| match parse_module(source) {
        Ok(parsed) => {
            let owned: Box<dyn Any> = Box::new(parsed);
            Box::into_raw(Box::new(owned)) as *mut c_void
        }
        Err(_) => ptr::null_mut(),
    })
    .unwrap_or(ptr::null_mut())
}

/// Drops a handle returned by `benchmark_ruff_parse_module`.
///
/// # Safety
/// `handle` must be null or a handle not yet released.
#[no_mangle]
pub unsafe extern "C" fn benchmark_ruff_free(handle: *mut c_void) {
    if !handle.is_null() {
        drop(Box::from_raw(handle as *mut Box<dyn Any>));
    }
}
