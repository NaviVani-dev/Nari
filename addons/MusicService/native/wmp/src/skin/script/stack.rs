use std::cell::Cell;

pub(super) const MAX_STACK_BYTES: usize = 160 * 1024;

thread_local! {
    static BASE: Cell<usize> = const { Cell::new(0) };
}

#[inline(always)]
fn here() -> usize {
    let marker = 0u8;
    std::hint::black_box(&marker as *const u8) as usize
}

pub(super) fn mark() {
    BASE.with(|base| base.set(here()));
}

#[inline]
pub(super) fn exceeded() -> bool {
    let start = BASE.with(Cell::get);
    start != 0 && start.abs_diff(here()) > MAX_STACK_BYTES
}
