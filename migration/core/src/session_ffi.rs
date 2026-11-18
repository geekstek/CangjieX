use crate::{Key, KeyEvent, Learning, Session, SessionOptions, Snapshot};
use std::panic::catch_unwind;
use std::ptr;

/// C layout shared with CangjieCore.h. All positions/counts are zero-based.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SnapshotInfo {
    pub handled: u8,
    pub beep: u8,
    pub visible: u8,
    pub page: usize,
    pub highlight: usize,
    pub candidate_count: usize,
    pub per_page: usize,
    pub associated: u8,
    pub correction: u8,
    pub cursor: usize,
}

fn decode_event(code: u32, modifiers: u32) -> Option<KeyEvent> {
    if modifiers & !31 != 0 {
        return None;
    }
    let key = match code {
        0 => Key::Other,
        32 => Key::Space,
        33..=126 => Key::Character(code as u8),
        0x100 => Key::Return,
        0x101 => Key::Backspace,
        0x102 => Key::Escape,
        0x103 => Key::Up,
        0x104 => Key::Down,
        0x105 => Key::PageUp,
        0x106 => Key::PageDown,
        0x107 => Key::Left,
        0x108 => Key::Right,
        _ => return None,
    };
    Some(KeyEvent {
        key,
        shift: modifiers & 1 != 0,
        command: modifiers & 2 != 0,
        control: modifiers & 4 != 0,
        option: modifiers & 8 != 0,
        caps_lock: modifiers & 16 != 0,
    })
}

/// Returns an independently owned session. Statuses match `cjx_lookup`.
/// # Safety
/// `output` must be null or point to a writable, aligned pointer slot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_new(output: *mut *mut Session) -> i32 {
    if output.is_null() {
        return -1;
    }
    // SAFETY: the caller provides a writable output slot.
    unsafe { output.write(ptr::null_mut()) };
    match catch_unwind(|| Box::into_raw(Box::new(Session::default()))) {
        Ok(session) => {
            // SAFETY: the output slot is writable.
            unsafe { output.write(session) };
            0
        }
        Err(_) => -2,
    }
}

/// Create a configured session with independent learned order. The host can
/// import/export rows to keep client sessions in sync, without touching legacy.
/// # Safety
/// Same output contract as `cjx_session_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_new_configured(flags: u32, output: *mut *mut Session) -> i32 {
    if output.is_null() {
        return -1;
    }
    // SAFETY: caller provides a writable slot.
    unsafe { output.write(ptr::null_mut()) };
    if flags & !8191 != 0 {
        return -1;
    }
    let options = SessionOptions {
        compose_while_typing: flags & 1 != 0,
        commit_at_maximum: flags & 2 != 0,
        clear_on_error: flags & 4 != 0,
        dynamic_frequency: flags & 8 != 0,
        space_selects_first: flags & 16 != 0,
        space_selects_one_page: flags & 32 != 0,
        halfwidth_punctuation: flags & 64 != 0,
        simplified_output: flags & 128 != 0,
        associated_phrases: flags & 256 != 0,
        fullwidth_output: flags & 512 != 0,
        simplex: flags & 1024 != 0,
        bopomofo_correction: flags & 2048 != 0,
        daily_characters: flags & 4096 != 0,
    };
    let session = Session::configured(options, Learning::default());
    // SAFETY: caller provides a writable slot.
    unsafe { output.write(Box::into_raw(Box::new(session))) };
    0
}

/// Copy Unicode coverage into an idle session; invalid input leaves it unchanged.
/// # Safety
/// Session must be live/exclusive. Bitmap must span `length` readable bytes,
/// disjoint from the session. Data is copied and remains owned by the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_set_character_coverage(
    session: *mut Session,
    bitmap: *const u8,
    length: usize,
) -> i32 {
    if session.is_null() || bitmap.is_null() || length != 0x110000 / 8 {
        return -1;
    }
    // SAFETY: validated pointers and readable span follow the caller contract.
    let (session, bitmap) = unsafe { (&mut *session, std::slice::from_raw_parts(bitmap, length)) };
    if session.set_character_coverage(bitmap) {
        0
    } else {
        -1
    }
}

/// Import one learned row; data is copied and unknown dictionary entries are ignored.
/// # Safety
/// Session is live/exclusive; byte pointers cover the supplied readable lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_set_frequency(
    session: *mut Session,
    code: *const u8,
    code_len: usize,
    text: *const u8,
    text_len: usize,
    count: u64,
) -> i32 {
    if session.is_null()
        || code.is_null()
        || text.is_null()
        || code_len == 0
        || code_len > 5
        || text_len == 0
        || text_len > 1024
        || count == 0
    {
        return -1;
    }
    // SAFETY: validated pointers have readable spans per caller contract.
    let (code, text) = unsafe {
        (
            std::slice::from_raw_parts(code, code_len),
            std::slice::from_raw_parts(text, text_len),
        )
    };
    let (Ok(code), Ok(text)) = (std::str::from_utf8(code), std::str::from_utf8(text)) else {
        return -1;
    };
    if !code.bytes().all(|c| c.is_ascii_graphic()) {
        return -1;
    }
    // SAFETY: session is live/exclusive.
    unsafe { (*session).import_frequency(code, text, count) };
    0
}

/// Invalid events/panics leave the session unchanged and return a null snapshot.
/// Each successful call returns a separately owned, immutable snapshot.
/// # Safety
/// `session` must be null or a live, exclusively accessed session. `output` must
/// be null or a writable aligned slot which does not overlap the session. Free
/// each successful snapshot once with `cjx_snapshot_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_handle(
    session: *mut Session,
    code: u32,
    modifiers: u32,
    output: *mut *mut Snapshot,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    // SAFETY: the caller provides a writable output slot.
    unsafe { output.write(ptr::null_mut()) };
    if session.is_null() {
        return -1;
    }
    let Some(event) = decode_event(code, modifiers) else {
        return -1;
    };
    match catch_unwind(|| {
        // Copy only the small reading buffer and shared candidate reference.
        // Publish both state and result only after event processing succeeds.
        // SAFETY: session is live and exclusively accessed by this call.
        let mut next = unsafe { (&*session).clone() };
        let snapshot = Box::into_raw(Box::new(next.handle(event)));
        // SAFETY: neither pointer aliases the other; both slots are writable.
        unsafe {
            *session = next;
            output.write(snapshot);
        }
    }) {
        Ok(()) => 0,
        Err(_) => -2,
    }
}

/// Receive a direct UTF-8 string without interpreting it as physical keys.
/// # Safety
/// Same exclusive session/output contract as `cjx_session_handle`; text must
/// cover length readable bytes and not overlap the session or output slot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_direct_text(
    session: *mut Session,
    text: *const u8,
    length: usize,
    output: *mut *mut Snapshot,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    // SAFETY: caller provides a writable output slot.
    unsafe { output.write(ptr::null_mut()) };
    if session.is_null() || text.is_null() || length > 4096 {
        return -1;
    }
    // SAFETY: caller provides the readable text span.
    let Ok(text) = std::str::from_utf8(unsafe { std::slice::from_raw_parts(text, length) }) else {
        return -1;
    };
    match catch_unwind(|| {
        // SAFETY: caller guarantees exclusive access to session/output.
        let mut next = unsafe { (&*session).clone() };
        let snapshot = Box::into_raw(Box::new(next.direct_text(text)));
        unsafe {
            *session = next;
            output.write(snapshot);
        }
    }) {
        Ok(()) => 0,
        Err(_) => -2,
    }
}

/// Cancels pending input without emitting committed text.
/// # Safety
/// `session` must be null or a live, exclusively accessed session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_reset(session: *mut Session) -> i32 {
    if session.is_null() {
        return -1;
    }
    match catch_unwind(|| {
        // SAFETY: the caller guarantees exclusive access to the live session.
        unsafe { (*session).reset() };
    }) {
        Ok(()) => 0,
        Err(_) => -2,
    }
}

/// # Safety
/// `session` must be null or a live owned session, freed exactly once. No other
/// operation may access the session concurrently with this function.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_session_free(session: *mut Session) {
    if !session.is_null() {
        // SAFETY: the caller transfers the unique live allocation back to Rust.
        drop(unsafe { Box::from_raw(session) });
    }
}

/// # Safety
/// `snapshot` must be null or a live snapshot. `output` must be null or writable,
/// aligned and disjoint from snapshot/data. Invalid input clears the info slot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_snapshot_info(
    snapshot: *const Snapshot,
    output: *mut SnapshotInfo,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    // SAFETY: the caller provides a writable info slot.
    unsafe { output.write(SnapshotInfo::default()) };
    // SAFETY: the caller guarantees a live snapshot or null.
    let Some(snapshot) = (unsafe { snapshot.as_ref() }) else {
        return -1;
    };
    // SAFETY: output is writable and disjoint from the immutable snapshot.
    unsafe {
        output.write(SnapshotInfo {
            handled: u8::from(snapshot.handled),
            beep: u8::from(snapshot.beep),
            visible: u8::from(snapshot.visible),
            page: snapshot.page,
            highlight: snapshot.highlight,
            candidate_count: snapshot.candidates.len(),
            per_page: snapshot.per_page,
            associated: u8::from(snapshot.associated),
            correction: u8::from(snapshot.correction),
            cursor: snapshot.cursor,
        })
    };
    0
}

/// Fields 0/1 = reading/committed; 2/3 = one-shot learned code/value.
/// Returns UTF-8 bytes without a terminator.
/// # Safety
/// `snapshot` must be null or live. `length` must be null or writable, aligned
/// and disjoint from snapshot/data. Returned bytes are read-only until free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_snapshot_text(
    snapshot: *const Snapshot,
    field: u32,
    length: *mut usize,
) -> *const u8 {
    if length.is_null() {
        return ptr::null();
    }
    // SAFETY: the length slot is writable and the snapshot is live or null.
    unsafe { length.write(0) };
    let Some(snapshot) = (unsafe { snapshot.as_ref() }) else {
        return ptr::null();
    };
    let text = match field {
        0 => &snapshot.reading,
        1 => &snapshot.committed,
        2 => snapshot.learning.as_ref().map_or("", |row| row.0.as_str()),
        3 => snapshot.learning.as_ref().map_or("", |row| row.1.as_str()),
        4 => &snapshot.composing,
        _ => return ptr::null(),
    };
    // SAFETY: length is writable and disjoint from the borrowed text.
    unsafe { length.write(text.len()) };
    text.as_ptr()
}

/// # Safety
/// Same pointer/lifetime contract as `cjx_snapshot_text`. Out-of-range returns
/// null and sets length to zero when a length slot is provided.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_snapshot_candidate(
    snapshot: *const Snapshot,
    index: usize,
    length: *mut usize,
) -> *const u8 {
    if length.is_null() {
        return ptr::null();
    }
    // SAFETY: the length slot is writable and the snapshot is live or null.
    unsafe { length.write(0) };
    let Some(text) =
        (unsafe { snapshot.as_ref() }).and_then(|snapshot| snapshot.candidates.get(index))
    else {
        return ptr::null();
    };
    // SAFETY: length is writable and disjoint from the borrowed text.
    unsafe { length.write(text.len()) };
    text.as_ptr()
}

/// # Safety
/// `snapshot` is live or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_snapshot_learning_count(snapshot: *const Snapshot) -> u64 {
    // SAFETY: caller guarantees a live snapshot or null.
    unsafe { snapshot.as_ref() }
        .and_then(|s| s.learning.as_ref())
        .map_or(0, |row| row.2)
}

/// # Safety
/// `snapshot` must be null or a live owned snapshot, freed exactly once with no
/// concurrent reads. Snapshots may outlive their originating session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cjx_snapshot_free(snapshot: *mut Snapshot) {
    if !snapshot.is_null() {
        // SAFETY: the caller transfers the unique live allocation back to Rust.
        drop(unsafe { Box::from_raw(snapshot) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn character_coverage_abi_rejects_invalid_spans_and_pending_updates_without_mutation() {
        let bytes = vec![0xff; 0x110000 / 8];
        let mut session = Session::configured(
            SessionOptions {
                daily_characters: true,
                ..SessionOptions::default()
            },
            Learning::default(),
        );
        // SAFETY: sessions and buffers below are live; rejected null pointers are never dereferenced.
        unsafe {
            assert_eq!(
                cjx_session_set_character_coverage(ptr::null_mut(), bytes.as_ptr(), bytes.len()),
                -1
            );
            assert_eq!(
                cjx_session_set_character_coverage(&mut session, ptr::null(), bytes.len()),
                -1
            );
            assert_eq!(
                cjx_session_set_character_coverage(&mut session, bytes.as_ptr(), bytes.len() - 1),
                -1
            );
            assert_eq!(
                cjx_session_set_character_coverage(&mut session, bytes.as_ptr(), bytes.len()),
                0
            );
            session.handle(KeyEvent::new(Key::Character(b'a')));
            assert_eq!(
                cjx_session_set_character_coverage(&mut session, bytes.as_ptr(), bytes.len()),
                -1
            );
            assert_eq!(
                session
                    .handle(KeyEvent::new(Key::Space))
                    .candidates
                    .as_ref(),
                ["日", "曰"]
            );
        }
    }

    #[test]
    fn direct_text_validates_utf8_and_owns_unicode_composition_after_session_free() {
        // SAFETY: inputs cover their declared lengths and each owned handle is freed once.
        unsafe {
            let mut session = ptr::null_mut();
            assert_eq!(cjx_session_new_configured(2048, &mut session), 0);
            let mut retained = ptr::null_mut();
            let text = "𨈍ㄅ";
            assert_eq!(
                cjx_session_direct_text(session, text.as_ptr(), text.len(), &mut retained),
                0
            );
            let mut invalid = ptr::dangling_mut();
            assert_eq!(
                cjx_session_direct_text(session, b"\xff".as_ptr(), 1, &mut invalid),
                -1
            );
            assert!(invalid.is_null());
            assert_eq!(
                cjx_session_direct_text(session, ptr::null(), 1, &mut invalid),
                -1
            );
            let oversized = [b'a'; 4097];
            assert_eq!(
                cjx_session_direct_text(session, oversized.as_ptr(), oversized.len(), &mut invalid),
                -1
            );
            assert_eq!(
                cjx_session_direct_text(session, b"a".as_ptr(), 1, ptr::null_mut()),
                -1
            );
            let mut selected = ptr::null_mut();
            assert_eq!(cjx_session_handle(session, 50, 0, &mut selected), 0);
            assert_eq!((*selected).committed, "𨈍吧");
            cjx_session_free(session);
            let mut info = SnapshotInfo::default();
            assert_eq!(cjx_snapshot_info(retained, &mut info), 0);
            assert_eq!(info.correction, 1);
            assert_eq!(info.cursor, 1);
            let mut length = 0;
            let bytes = cjx_snapshot_text(retained, 4, &mut length);
            assert_eq!(std::slice::from_raw_parts(bytes, length), text.as_bytes());
            cjx_snapshot_free(retained);
            cjx_snapshot_free(selected);
        }
    }

    #[test]
    fn configured_abi_validates_options_and_imports_order_without_losing_settings_on_reset() {
        // SAFETY: owned handles and readable byte literals; each allocation freed once.
        unsafe {
            let mut session = ptr::null_mut();
            assert_eq!(cjx_session_new_configured(8192, &mut session), -1);
            assert!(session.is_null());
            assert_eq!(cjx_session_new_configured(107, &mut session), 0);
            assert_eq!(
                cjx_session_set_frequency(session, b"a".as_ptr(), 1, "曰".as_ptr(), 3, 5),
                0
            );
            assert_eq!(
                cjx_session_set_frequency(session, ptr::null(), 1, "曰".as_ptr(), 3, 5),
                -1
            );
            assert_eq!(
                cjx_session_set_frequency(session, b"a".as_ptr(), 1, b"\xff".as_ptr(), 1, 1),
                -1
            );
            let mut snapshot = ptr::null_mut();
            assert_eq!(cjx_session_handle(session, 97, 0, &mut snapshot), 0);
            assert_eq!((*snapshot).candidates.as_ref(), ["曰", "日"]);
            cjx_snapshot_free(snapshot);
            assert_eq!(cjx_session_reset(session), 0);
            assert_eq!(cjx_session_handle(session, 97, 0, &mut snapshot), 0);
            assert!((*snapshot).visible);
            assert_eq!((*snapshot).candidates.as_ref(), ["曰", "日"]);
            cjx_snapshot_free(snapshot);
            cjx_session_free(session);
        }
    }

    #[test]
    fn snapshots_outlive_sessions_and_failed_events_do_not_change_state() {
        // SAFETY: pointers refer to owned live handles and writable local slots.
        unsafe {
            let mut session = ptr::null_mut();
            let mut snapshot = ptr::null_mut();
            assert_eq!(cjx_session_new(&mut session), 0);
            assert_eq!(
                cjx_session_handle(session, u32::from(b'a'), 0, &mut snapshot),
                0
            );
            cjx_snapshot_free(snapshot);
            for (code, modifiers) in [(0xffff, 0), (32, 32)] {
                snapshot = ptr::dangling_mut();
                assert_eq!(
                    cjx_session_handle(session, code, modifiers, &mut snapshot),
                    -1
                );
                assert!(snapshot.is_null());
            }
            assert_eq!(cjx_session_handle(session, 32, 0, &mut snapshot), 0);
            cjx_session_free(session);
            let mut info = SnapshotInfo::default();
            assert_eq!(cjx_snapshot_info(snapshot, &mut info), 0);
            assert_eq!((info.visible, info.candidate_count), (1, 2));
            let mut length = 0;
            let bytes = cjx_snapshot_candidate(snapshot, 1, &mut length);
            assert_eq!(std::slice::from_raw_parts(bytes, length), "曰".as_bytes());
            assert!(cjx_snapshot_candidate(snapshot, 2, &mut length).is_null());
            assert_eq!(length, 0);
            assert!(cjx_snapshot_text(snapshot, 5, &mut length).is_null());
            cjx_snapshot_free(snapshot);
        }
    }

    #[test]
    fn nulls_and_missing_outputs_are_rejected_without_mutation() {
        // SAFETY: null handling is part of the ABI; other slots/handles are live.
        unsafe {
            assert_eq!(cjx_session_new(ptr::null_mut()), -1);
            assert_eq!(cjx_session_reset(ptr::null_mut()), -1);
            let mut snapshot = ptr::dangling_mut();
            assert_eq!(
                cjx_session_handle(ptr::null_mut(), 32, 0, &mut snapshot),
                -1
            );
            assert!(snapshot.is_null());
            let mut session = ptr::null_mut();
            assert_eq!(cjx_session_new(&mut session), 0);
            assert_eq!(
                cjx_session_handle(session, u32::from(b'a'), 0, ptr::null_mut()),
                -1
            );
            assert_eq!(cjx_session_handle(session, 32, 0, &mut snapshot), 0);
            assert_eq!((*snapshot).committed, " ");
            cjx_snapshot_free(snapshot);
            assert_eq!(cjx_session_reset(session), 0);
            cjx_session_free(session);
            let mut info = SnapshotInfo {
                candidate_count: 100,
                ..SnapshotInfo::default()
            };
            assert_eq!(cjx_snapshot_info(ptr::null(), &mut info), -1);
            assert_eq!(info.candidate_count, 0);
            assert_eq!(cjx_snapshot_info(ptr::null(), ptr::null_mut()), -1);
            let mut length = 100;
            assert!(cjx_snapshot_text(ptr::null(), 0, &mut length).is_null());
            assert_eq!(length, 0);
            assert!(cjx_snapshot_text(ptr::null(), 0, ptr::null_mut()).is_null());
            assert!(cjx_snapshot_candidate(ptr::null(), 0, &mut length).is_null());
            assert!(cjx_snapshot_candidate(ptr::null(), 0, ptr::null_mut()).is_null());
            cjx_session_free(ptr::null_mut());
            cjx_snapshot_free(ptr::null_mut());
        }
    }
}
