#pragma once
#ifdef __cplusplus
extern "C" {
#endif
    // 主要 workload 進入點
    // mode: 0 = small tile (M=1,K=1,N=1), 1 = full layer40
    void run_workload(int mode, uint32_t compressed_bytes);
#ifdef __cplusplus
}
#endif
