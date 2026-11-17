use std::collections::HashMap;
use std::panic::catch_unwind;
use std::ptr;
use std::sync::OnceLock;

mod compatibility;
mod session;
mod session_ffi;
pub use session::{Key, KeyEvent, Learning, Session, SessionOptions, Snapshot};
pub use session_ffi::*;

const TABLE: &str = include_str!("../../data/cangjie.tsv");
const SIMPLEX_TABLE: &str = include_str!("../../data/simplex.tsv");
static SIMPLEX_DICTIONARY: OnceLock<HashMap<&'static str, Vec<&'static str>>> = OnceLock::new();
static DICTIONARY: OnceLock<HashMap<&'static str, Vec<&'static str>>> = OnceLock::new();

/// Exact lookup; wildcard composition is handled by `Session`.
pub fn lookup(code: &str) -> Result<&'static [&'static str], InvalidCode> {
    lookup_mode(code, false)
}

fn lookup_mode(code: &str, simplex: bool) -> Result<&'static [&'static str], InvalidCode> {
    if code.is_empty() || code.len() > 5 || !code.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err(InvalidCode);
    }
    let index = if simplex {
        &SIMPLEX_DICTIONARY
    } else {
        &DICTIONARY
    };
    let dictionary = index.get_or_init(|| {
        let mut dictionary: HashMap<&str, Vec<&str>> = HashMap::new();
        for line in (if simplex { SIMPLEX_TABLE } else { TABLE }).lines() {
            let (code, text) = line.split_once('\t').expect("validated embedded table");
            dictionary.entry(code).or_default().push(text);
        }
        dictionary
    });
    Ok(dictionary
        .get(code.to_ascii_lowercase().as_str())
        .map(Vec::as_slice)
        .unwrap_or(&[]))
}

#[derive(Debug, PartialEq, Eq)]
pub struct InvalidCode;

/// Owns the result handle, but borrows immutable strings from the embedded table.
pub struct LookupResult {
    candidates: &'static [&'static str],
}

/// Returns 0 on success, -1 for invalid arguments, -2 for a caught Rust panic.
///
/// # Safety
/// `code` must point to `code_len` readable bytes, and `output` to a writable,
/// aligned pointer slot. The two regions must not overlap. On success the caller
/// owns `*output` and must free it exactly once with `cjx_result_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_lookup(
    code: *const u8,
    code_len: usize,
    output: *mut *mut LookupResult,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    // SAFETY: the caller provides a writable, aligned output slot.
    unsafe { output.write(ptr::null_mut()) };
    if code.is_null() || code_len == 0 || code_len > 5 {
        return -1;
    }
    let result = catch_unwind(|| {
        // SAFETY: the caller guarantees the readable input region.
        let bytes = unsafe { std::slice::from_raw_parts(code, code_len) };
        let code = std::str::from_utf8(bytes).map_err(|_| InvalidCode)?;
        lookup(code).map(|candidates| Box::into_raw(Box::new(LookupResult { candidates })))
    });
    match result {
        Ok(Ok(handle)) => {
            // SAFETY: the output slot is valid and does not overlap input.
            unsafe { output.write(handle) };
            0
        }
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}

/// # Safety
/// `result` must be null or an unfreed handle returned by `cjx_lookup`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_result_count(result: *const LookupResult) -> usize {
    // SAFETY: the caller guarantees a valid handle or null.
    unsafe { result.as_ref() }.map_or(0, |result| result.candidates.len())
}

/// Returns borrowed UTF-8 bytes, without a NUL terminator. Returns null for an
/// invalid index/handle/output, setting the length to zero when possible.
///
/// # Safety
/// `result` must be null or a live handle; `length` must be null or writable and
/// aligned and must not overlap the result or candidate bytes. Returned bytes
/// must not be modified and are valid until result free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_result_candidate(
    result: *const LookupResult,
    index: usize,
    length: *mut usize,
) -> *const u8 {
    if length.is_null() {
        return ptr::null();
    }
    // SAFETY: the caller provides a writable length slot and valid handle.
    unsafe { length.write(0) };
    let Some(candidate) =
        (unsafe { result.as_ref() }).and_then(|result| result.candidates.get(index))
    else {
        return ptr::null();
    };
    // SAFETY: length is writable and does not alias the immutable handle data.
    unsafe { length.write(candidate.len()) };
    candidate.as_ptr()
}

/// # Safety
/// `result` must be null or an owned handle from `cjx_lookup`, freed exactly once.
/// No reads of this handle may run concurrently with this function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_result_free(result: *mut LookupResult) {
    if !result.is_null() {
        // SAFETY: the caller transfers back the unique, live allocation.
        drop(unsafe { Box::from_raw(result) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simplex_lookup_preserves_every_row_and_stays_separate_from_cangjie() {
        let mut expected: std::collections::BTreeMap<&str, Vec<&str>> =
            std::collections::BTreeMap::new();
        for row in SIMPLEX_TABLE.lines() {
            let (code, text) = row.split_once('\t').unwrap();
            expected.entry(code).or_default().push(text);
        }
        assert_eq!(expected.len(), 706);
        assert_eq!(expected.values().map(Vec::len).sum::<usize>(), 63234);
        for (code, candidates) in expected {
            assert_eq!(lookup_mode(code, true).unwrap(), candidates.as_slice());
        }
        assert_ne!(lookup_mode("aa", true), lookup("aa"));
    }

    #[test]
    fn preserves_order_duplicates_punctuation_and_supplementary_unicode() {
        assert_eq!(lookup("a"), Ok(["日", "曰"].as_slice()));
        assert_eq!(lookup("A"), lookup("a"));
        assert_eq!(lookup("'"), Ok(["、", "、", "′", "‘", "’", "‵"].as_slice()));
        assert_eq!(lookup("%"), Ok(["％"].as_slice()));
        assert_eq!(lookup("rvbce"), Ok(["𨈍"].as_slice()));
        assert_eq!(lookup("mfmff"), Ok(["厵"].as_slice()));
        assert_eq!(lookup("aaaaa"), Ok([].as_slice()));
    }

    #[test]
    fn rejects_invalid_codes() {
        for code in ["", "abcdef", "日", "a b", "a\0", "\n"] {
            assert_eq!(lookup(code), Err(InvalidCode), "{code:?}");
        }
    }

    #[test]
    fn shares_one_immutable_dictionary_between_threads() {
        let threads: Vec<_> = (0..8)
            .map(|_| std::thread::spawn(|| lookup("a").unwrap().as_ptr() as usize))
            .collect();
        let pointers: Vec<_> = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect();
        assert!(pointers.iter().all(|pointer| *pointer == pointers[0]));
    }

    #[test]
    fn ffi_owns_results_and_bounds_checks_borrowed_candidates() {
        // SAFETY: all pointers below refer to live allocations and aligned slots.
        unsafe {
            let mut first = ptr::null_mut();
            let mut second = ptr::null_mut();
            assert_eq!(cjx_lookup(b"a".as_ptr(), 1, &mut first), 0);
            assert_eq!(cjx_lookup(b"rvbce".as_ptr(), 5, &mut second), 0);
            assert_eq!(cjx_result_count(first), 2);
            assert_eq!(cjx_result_count(second), 1);
            cjx_result_free(first);
            let mut length = 0;
            let bytes = cjx_result_candidate(second, 0, &mut length);
            assert_eq!(std::slice::from_raw_parts(bytes, length), "𨈍".as_bytes());
            assert!(cjx_result_candidate(second, 1, &mut length).is_null());
            assert_eq!(length, 0);
            assert!(cjx_result_candidate(second, 0, ptr::null_mut()).is_null());
            cjx_result_free(second);
        }
    }

    #[test]
    fn ffi_rejects_invalid_arguments_and_clears_output() {
        // SAFETY: null handling is part of the ABI; the output slot is valid.
        unsafe {
            let mut output = ptr::null_mut();
            assert_eq!(cjx_lookup(b"a".as_ptr(), 1, ptr::null_mut()), -1);
            for bytes in [b"".as_slice(), b"abcdef", b"\xff", b"a\0", b"a b"] {
                // A non-null sentinel proves errors overwrite the output slot;
                // it is never read through or passed to result_free.
                output = ptr::dangling_mut();
                assert_eq!(cjx_lookup(bytes.as_ptr(), bytes.len(), &mut output), -1);
                assert!(output.is_null());
            }
            assert_eq!(cjx_lookup(ptr::null(), 1, &mut output), -1);
            assert_eq!(cjx_result_count(ptr::null()), 0);
            let mut length = 123;
            assert!(cjx_result_candidate(ptr::null(), 0, &mut length).is_null());
            assert_eq!(length, 0);
            cjx_result_free(ptr::null_mut());
            assert_eq!(cjx_lookup(b"aaaaa".as_ptr(), 5, &mut output), 0);
            assert_eq!(cjx_result_count(output), 0);
            cjx_result_free(output);
        }
    }
}
