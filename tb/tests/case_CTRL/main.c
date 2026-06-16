#include "tb.h"
#include "workload.h"

int main(int argc, char** argv) {
    tb_init(argc, argv, "CTRL_unit_test");
    run_workload();
    tb_close();
    return 0;
}
