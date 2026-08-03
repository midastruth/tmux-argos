use crate::model::{Config, StateCenter};
use crate::protocol::{AgentState, Request};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct CountingAllocator;

thread_local! {
    static MEASURING: Cell<bool> = const { Cell::new(false) };
    static ALLOCATION_COUNT: Cell<usize> = const { Cell::new(0) };
    static ALLOCATED_BYTES: Cell<usize> = const { Cell::new(0) };
}

#[global_allocator]
static GLOBAL_ALLOCATOR: CountingAllocator = CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = System.alloc(layout);
        if !pointer.is_null() && MEASURING.try_with(Cell::get).unwrap_or(false) {
            ALLOCATION_COUNT.set(ALLOCATION_COUNT.get() + 1);
            ALLOCATED_BYTES.set(ALLOCATED_BYTES.get() + layout.size());
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let pointer = System.alloc_zeroed(layout);
        if !pointer.is_null() && MEASURING.try_with(Cell::get).unwrap_or(false) {
            ALLOCATION_COUNT.set(ALLOCATION_COUNT.get() + 1);
            ALLOCATED_BYTES.set(ALLOCATED_BYTES.get() + layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        System.dealloc(pointer, layout);
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new_pointer = System.realloc(pointer, layout, new_size);
        if !new_pointer.is_null() && MEASURING.try_with(Cell::get).unwrap_or(false) {
            ALLOCATION_COUNT.set(ALLOCATION_COUNT.get() + 1);
            ALLOCATED_BYTES.set(ALLOCATED_BYTES.get() + new_size);
        }
        new_pointer
    }
}

fn measure_allocations<T>(operation: impl FnOnce() -> T) -> (T, usize, usize) {
    ALLOCATION_COUNT.set(0);
    ALLOCATED_BYTES.set(0);
    MEASURING.set(true);
    let result = operation();
    MEASURING.set(false);
    (result, ALLOCATION_COUNT.get(), ALLOCATED_BYTES.get())
}

fn report(index: usize, sequence: u64) -> Request {
    Request::Report {
        tool: "custom".into(),
        pane_id: format!("%{index}"),
        process_generation: "allocation-benchmark".into(),
        sequence,
        state: AgentState::Idle,
        session_id: format!("${index}"),
        session_name: format!("work-{index}"),
    }
}

#[test]
fn state_hot_paths_stay_within_allocation_budgets() {
    const RECORDS: usize = 100;
    const MAX_REPORT_ALLOCATIONS: usize = 8;
    const MAX_REPORT_BYTES: usize = 512;
    const MAX_SNAPSHOT_ALLOCATIONS: usize = 3_000;
    const MAX_SNAPSHOT_BYTES: usize = 192 * 1024;

    let mut center = StateCenter::new("/nonexistent".into(), Config::test());
    for index in 1..=RECORDS {
        center.apply(report(index, 1)).unwrap();
    }

    let update = report(1, 2);
    let (result, report_allocations, report_bytes) = measure_allocations(|| center.apply(update));
    result.unwrap();

    let (snapshot, snapshot_allocations, snapshot_bytes) =
        measure_allocations(|| center.snapshot());
    assert_eq!(snapshot["records"].as_array().map(Vec::len), Some(RECORDS));

    eprintln!(
        "allocation budgets: report={report_allocations} allocations/{report_bytes} bytes, \
         snapshot({RECORDS})={snapshot_allocations} allocations/{snapshot_bytes} bytes"
    );
    assert!(
        report_allocations <= MAX_REPORT_ALLOCATIONS,
        "report allocations {report_allocations} exceed {MAX_REPORT_ALLOCATIONS}"
    );
    assert!(
        report_bytes <= MAX_REPORT_BYTES,
        "report allocated bytes {report_bytes} exceed {MAX_REPORT_BYTES}"
    );
    assert!(
        snapshot_allocations <= MAX_SNAPSHOT_ALLOCATIONS,
        "snapshot allocations {snapshot_allocations} exceed {MAX_SNAPSHOT_ALLOCATIONS}"
    );
    assert!(
        snapshot_bytes <= MAX_SNAPSHOT_BYTES,
        "snapshot allocated bytes {snapshot_bytes} exceed {MAX_SNAPSHOT_BYTES}"
    );
}
