//! Front door for fx's first-class persistent memory engine (R1.7).
//! Provides scoped long-term memory across sessions, threads, and subagents
//! with secret redaction, atomic JSONL persistence, non-destructive updates,
//! ranked recall, and bounded prompt-context rendering.

pub const redact = @import("redact.zig");
pub const store = @import("store.zig");

pub const Scope = store.Scope;
pub const Kind = store.Kind;
pub const Entry = store.Entry;
pub const Paths = store.Paths;
pub const SaveInput = store.SaveInput;
pub const UpdateInput = store.UpdateInput;
pub const SearchOptions = store.SearchOptions;
pub const ListOptions = store.ListOptions;
pub const ScoredEntry = store.ScoredEntry;
pub const StoreError = store.StoreError;

pub const default_context_max_bytes = store.default_context_max_bytes;

pub const save = store.save;
pub const update = store.update;
pub const forget = store.forget;
pub const search = store.search;
pub const list = store.list;
pub const loadScope = store.loadScope;
pub const renderContextBlock = store.renderContextBlock;

test {
    _ = redact;
    _ = store;
}
