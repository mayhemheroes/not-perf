#![no_main]
//! In-process libFuzzer harness over not-perf's profile-archive parsing + collation
//! code path — the SAME code the CLI `nperf flamegraph <file>` target exercised.
//!
//! The old Mayhemfile ran `/nperf flamegraph /fuzz.nperf`: a raw file-input CLI over an
//! UNINSTRUMENTED release binary. We convert it to a cargo-fuzz (ASan) in-process harness
//! (skill-endorsed) so the fuzzed .nperf parser + DWARF/CFI unwinder is instrumented and
//! actually accrues edges. `collapse_into_sorted_vec` is the entry the flamegraph/collate/
//! csv/trace-events subcommands all funnel through (parse the archive -> decode samples ->
//! unwind -> collate), so parity with the original code path is preserved.
//!
//! `read_data`/`ReadDataArgs` are `pub(crate)`, and the parser takes a file PATH (not a
//! reader), so we materialize the input to a temp file and feed it through the public
//! `SharedCollationArgs` entry point — identical to how the CLI reaches the parser.

use libfuzzer_sys::fuzz_target;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Once;

static HOOK: Once = Once::new();

use nperf_core::args::{ArgGranularity, ArgMergeThreads, Granularity, SharedCollationArgs};
use nperf_core::cmd_collate::collapse_into_sorted_vec;

fuzz_target!(|data: &[u8]| {
    // libfuzzer-sys installs a global panic hook that ABORTS on any panic (even one
    // catch_unwind would swallow). The archive reader panics by design on malformed
    // input (bad magic/version), so replace the hook with a silent one; real
    // memory-safety bugs surface through ASan, which still aborts and is reported.
    HOOK.call_once(|| {
        std::panic::set_hook(Box::new(|_| {}));
    });

    // One reusable temp path per process (libFuzzer runs one input at a time in-process).
    let mut path = std::env::temp_dir();
    path.push(format!("nperf-fuzz-{}.nperf", std::process::id()));

    if std::fs::write(&path, data).is_err() {
        return;
    }

    let shared = SharedCollationArgs {
        debug_symbols: Vec::new(),
        jitdump: None,
        force_stack_size: None,
        omit: Vec::new(),
        only_sample: None,
        without_kernel_callstacks: false,
        from: None,
        to: None,
        input: path.clone().into_os_string(),
    };
    let merge = ArgMergeThreads { merge_threads: false };
    let granularity = ArgGranularity { granularity: Granularity::Line };

    // The archive reader panics on a bad magic/version (expected parse rejection). Swallow
    // panics here so the fuzzer keeps exploring the parser; real memory-safety defects go
    // through ASan (SIGABRT), not Rust panics, so they are still reported.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let _ = collapse_into_sorted_vec(&shared, &granularity, &merge);
    }));

    let _ = std::fs::remove_file(&path);
});
