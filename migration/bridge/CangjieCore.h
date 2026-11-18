#ifndef CANGJIEX_CORE_H
#define CANGJIEX_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CjxLookupResult CjxLookupResult;

/* All lengths are byte counts. Codes are 1–5 printable ASCII bytes; ASCII case
 * is ignored. This lookup is exact; wildcard composition uses the session API.
 * code must cover code_len readable bytes; output must be writable/aligned and
 * must not overlap code. Returns 0 on success, -1 for invalid input, -2 for panic.
 * An unknown valid code succeeds with an empty result. A non-null output slot
 * is cleared on failure. Free a successful result exactly once. */
int32_t cjx_lookup(const uint8_t *code, size_t code_len, CjxLookupResult **output);

/* result must be live or null. Null has count zero. */
size_t cjx_result_count(const CjxLookupResult *result);

/* Returns read-only UTF-8 bytes WITHOUT a NUL terminator. Copy before freeing
 * result. length must be writable/aligned and must not alias the result/data.
 * Null/out-of-range returns NULL and zero length (when length is non-null). */
const uint8_t *cjx_result_candidate(const CjxLookupResult *result, size_t index, size_t *length);

/* Null is harmless. Do not reuse/double-free a handle or free during a read. */
void cjx_result_free(CjxLookupResult *result);

typedef struct CjxSession CjxSession;
typedef struct CjxSnapshot CjxSnapshot;

/* These are normalized engine keys, never macOS hardware keycodes. Printable
 * ASCII uses its byte value (space = 32). Map other keys using these constants. */
enum {
    CJX_KEY_OTHER = 0,
    CJX_KEY_RETURN = 0x100,
    CJX_KEY_BACKSPACE = 0x101,
    CJX_KEY_ESCAPE = 0x102,
    CJX_KEY_UP = 0x103,
    CJX_KEY_DOWN = 0x104,
    CJX_KEY_PAGE_UP = 0x105,
    CJX_KEY_PAGE_DOWN = 0x106,
    CJX_KEY_LEFT = 0x107,
    CJX_KEY_RIGHT = 0x108,
    CJX_MOD_SHIFT = 1,
    CJX_MOD_COMMAND = 2,
    CJX_MOD_CONTROL = 4,
    CJX_MOD_OPTION = 8,
    CJX_MOD_CAPS_LOCK = 16,
    CJX_TEXT_READING = 0,
    CJX_TEXT_COMMITTED = 1,
    CJX_TEXT_LEARNED_CODE = 2,
    CJX_TEXT_LEARNED_VALUE = 3,
    CJX_TEXT_COMPOSING = 4,
    CJX_OPT_COMPOSE_WHILE_TYPING = 1,
    CJX_OPT_COMMIT_AT_MAXIMUM = 2,
    CJX_OPT_CLEAR_ON_ERROR = 4,
    CJX_OPT_DYNAMIC_FREQUENCY = 8,
    CJX_OPT_SPACE_SELECTS_FIRST = 16,
    CJX_OPT_SPACE_SELECTS_ONE_PAGE = 32,
    CJX_OPT_HALFWIDTH_PUNCTUATION = 64,
    CJX_OPT_SIMPLIFIED_OUTPUT = 128,
    CJX_OPT_ASSOCIATED_PHRASES = 256,
    CJX_OPT_FULLWIDTH_OUTPUT = 512,
    CJX_OPT_SIMPLEX = 1024,
    CJX_OPT_BOPOMOFO_CORRECTION = 2048,
    CJX_OPT_DAILY_CHARACTERS = 4096
};

typedef struct {
    uint8_t handled;
    uint8_t beep;
    uint8_t visible;
    size_t page;
    size_t highlight;
    size_t candidate_count;
    size_t per_page;
    uint8_t associated;
    uint8_t correction;
    size_t cursor; /* Unicode scalar offset into composing text, not UTF-16. */
} CjxSnapshotInfo;

/* Session profile: five radicals, explicit composition, nine selection keys,
 * wrapping vertical pages, wildcard composition, no learning/glyph filtering.
 * Command/Control/Option events are not consumed and preserve pending input.
 * Session functions return 0 / -1 / -2 as above. Each session is independent;
 * serialize access to a session. Output slots must be writable/aligned and
 * disjoint from session/snapshot/data; output slots are cleared on failure.
 * Invalid keys/modifier bits or a caught panic leave the session unchanged. */
int32_t cjx_session_new(CjxSession **output);
/* Configured sessions use the flag values above. Unknown bits fail. Learned
 * order belongs to this session. Default constructor is unchanged. */
int32_t cjx_session_new_configured(uint32_t flags, CjxSession **output);
/* Copy a platform-provided Unicode coverage bitmap (0x110000 / 8 bytes).
 * Scalar n uses bit (n % 8) of byte (n / 8). Only accepted while idle;
 * invalid input leaves the session unchanged. Caller retains the bytes.
 * DAILY_CHARACTERS excludes private-use characters and requires coverage;
 * before a bitmap is supplied, that mode offers no candidates. */
int32_t cjx_session_set_character_coverage(CjxSession *session, const uint8_t *bitmap, size_t length);
/* Direct text from the host/input pipeline, not clipboard interception.
 * UTF-8 must cover 0..4096 readable bytes; empty text is not handled.
 * Same session/output ownership contract as cjx_session_handle. Invalid UTF-8
 * or length fails without mutation. Correction disabled/pending returns an
 * unhandled snapshot. Caller retains ownership of text. */
int32_t cjx_session_direct_text(CjxSession *session, const uint8_t *text, size_t length, CjxSnapshot **output);
/* Copy a learned row into the session's store. Pointer spans must be
 * readable; code=1..5 printable ASCII bytes, text=1..1024 UTF-8 bytes, count>0.
 * Unknown code/candidate pairs are ignored. No files are read or written. */
int32_t cjx_session_set_frequency(CjxSession *session, const uint8_t *code, size_t code_len,
                                  const uint8_t *text, size_t text_len, uint64_t count);
int32_t cjx_session_handle(CjxSession *session, uint32_t key, uint32_t modifiers, CjxSnapshot **output);
int32_t cjx_session_reset(CjxSession *session);
void cjx_session_free(CjxSession *session);

/* Each event returns an OWNED immutable snapshot, valid after further events,
 * reset, or session free. Free it once. committed/beep are one-shot effects:
 * apply them once for that event, even if rendering the snapshot again.
 * page is zero-based. For ordinary candidates highlight is relative to page;
 * associated=1 marks phrase hints with no highlighted candidate (legacy index 9).
 * per_page is authoritative (normally 9, or 10 when space is a selection key).
 * candidates contains the full list; getters 2/3 carry a one-shot learning row. */
int32_t cjx_snapshot_info(const CjxSnapshot *snapshot, CjxSnapshotInfo *output);
const uint8_t *cjx_snapshot_text(const CjxSnapshot *snapshot, uint32_t field, size_t *length);
const uint8_t *cjx_snapshot_candidate(const CjxSnapshot *snapshot, size_t index, size_t *length);
/* One-shot learning effect: text fields 2/3 and this count, zero if none. */
uint64_t cjx_snapshot_learning_count(const CjxSnapshot *snapshot);
void cjx_snapshot_free(CjxSnapshot *snapshot);

/* Snapshot getters require live or null handles and writable/aligned output
 * slots, disjoint from snapshot/data. Text/candidates are read-only UTF-8 with
 * byte lengths, WITHOUT NUL terminators. Copy before snapshot free. Invalid
 * text fields/indices/handles return NULL with length zero when possible.
 * Session/snapshot free accept NULL; do not double-free or read after free. */

#ifdef __cplusplus
}
#endif
#endif
