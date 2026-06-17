// =============================================================================
// case_SRAM/main.c — SRAM_rtl unit test entry point
// =============================================================================

#include "tb.h"
#include "workload.h"

int main(int argc, char** argv) {
tb_init(argc, argv, "case_SRAM");
run_workload();
tb_close();
return (fail_count == 0) ? 0 : 1;
}
