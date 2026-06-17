#include "tb.h"
#include "workload.h"

int main(int argc, char** argv) {
    // 預設將波形檔命名為 GLB_unit_test
    tb_init(argc, argv, "GLB_unit_test");
    
    run_workload();
    
    tb_close();
    return 0;
}
