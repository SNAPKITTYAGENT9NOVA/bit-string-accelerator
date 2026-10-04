# Verification Contract

Reset is synchronous active-high. Reset cancels any uncompleted accelerator operation and suppresses its result. A read request completes on `mem_valid && !mem_write && mem_ready`; its data completes on `mem_rvalid`. A write request completes on `mem_valid && mem_write && mem_ready`. `result_valid` is a one-cycle pulse following operation completion. Memory faults terminate the operation with `error=1`.
