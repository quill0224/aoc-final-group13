#include "kernel_cpu.h"

// [TODO]: Implement the improved versions of all kernel functions below.

void conv_maxpooling(uint32_t input_C, uint32_t input_H, uint32_t input_W,
                     uint8_t* activation, uint32_t filter_N, uint32_t filter_C,
                     uint32_t filter_H, uint32_t filter_W, int8_t* filter,
                     int32_t* bias, uint32_t padding, uint8_t* output,
                     uint32_t scale, void* scratch) {
    /*! <<<========= Implement here =========>>> */
        uint32_t pad_H = input_H + 2 * padding;
    uint32_t pad_W = input_W + 2 * padding;
    int8_t* pad_buf = (int8_t*)scratch;

    int8_t* p_dst = pad_buf;
    uint8_t* p_src = activation;
    for (uint32_t c = 0; c < input_C; c++) {
        for (uint32_t p = 0; p < padding * pad_W; p++) *p_dst++ = 0;
        for (uint32_t h = 0; h < input_H; h++) {
            for (uint32_t p = 0; p < padding; p++) *p_dst++ = 0;
            for (uint32_t w = 0; w < input_W; w++) {
                *p_dst++ = (int8_t)((int32_t)(*p_src++) - 128); 
            }
            for (uint32_t p = 0; p < padding; p++) *p_dst++ = 0;
        }
        for (uint32_t p = 0; p < padding * pad_W; p++) *p_dst++ = 0;
    }

    uint32_t out_H = input_H >> 1;
    uint32_t out_W = input_W >> 1;

    for (uint32_t n = 0; n < filter_N; n++) {
        for (uint32_t h = 0; h < out_H; h++) {
            for (uint32_t w = 0; w < out_W; w++) {
                int32_t sum00 = bias[n], sum01 = bias[n];
                int32_t sum10 = bias[n], sum11 = bias[n];
                
                int8_t* w_ptr = &filter[n * input_C * filter_H * filter_W];

                for (uint32_t c = 0; c < input_C; c++) {
                    uint32_t base = c * pad_H * pad_W;
                    for (uint32_t fh = 0; fh < filter_H; fh++) {
                        int8_t* p_ptr0 = &pad_buf[base + (h * 2 + fh) * pad_W + (w * 2)];
                        int8_t* p_ptr1 = &pad_buf[base + (h * 2 + 1 + fh) * pad_W + (w * 2)];
                        for (uint32_t fw = 0; fw < filter_W; fw++) {
                            int32_t weight = *w_ptr++; 
                            sum00 += p_ptr0[fw] * weight;
                            sum01 += p_ptr0[fw + 1] * weight;
                            sum10 += p_ptr1[fw] * weight;
                            sum11 += p_ptr1[fw + 1] * weight;
                        }
                    }
                }

                int32_t max = sum00;
                if(sum01 > max) max = sum01;
                if(sum10 > max) max = sum10;
                if(sum11 > max) max = sum11;

                output[n * out_H * out_W + h * out_W + w] = requant(relu(max), scale);
            }
        }
    }


};

void conv(uint32_t input_C, uint32_t input_H, uint32_t input_W,
          uint8_t* activation, uint32_t filter_N, uint32_t filter_C,
          uint32_t filter_H, uint32_t filter_W, int8_t* filter, int32_t* bias,
          uint32_t padding, uint8_t* output, uint32_t scale, void* scratch) {
    /*! <<<========= Implement here =========>>> */
    uint32_t pad_H = input_H + 2 * padding;
    uint32_t pad_W = input_W + 2 * padding;
    int8_t* pad_buf = (int8_t*)scratch;

    int8_t* p_dst = pad_buf;
    uint8_t* p_src = activation;
    for (uint32_t c = 0; c < input_C; c++) {
        for (uint32_t p = 0; p < padding * pad_W; p++) *p_dst++ = 0;
        for (uint32_t h = 0; h < input_H; h++) {
            for (uint32_t p = 0; p < padding; p++) *p_dst++ = 0;
            for (uint32_t w = 0; w < input_W; w++) {
                *p_dst++ = (int8_t)((int32_t)(*p_src++) - 128);
            }
            for (uint32_t p = 0; p < padding; p++) *p_dst++ = 0;
        }
        for (uint32_t p = 0; p < padding * pad_W; p++) *p_dst++ = 0;
    }

    for (uint32_t n = 0; n < filter_N; n++) {
        for (uint32_t h = 0; h < input_H; h++) {
            uint32_t w = 0;
            for (; w <= input_W - 4; w += 4) {
                int32_t sum0 = bias[n], sum1 = bias[n], sum2 = bias[n], sum3 = bias[n];
                int8_t* w_ptr = &filter[n * input_C * filter_H * filter_W];

                for (uint32_t c = 0; c < input_C; c++) {
                    uint32_t base = c * pad_H * pad_W;
                    for (uint32_t fh = 0; fh < filter_H; fh++) {
                        int8_t* p_ptr = &pad_buf[base + (h + fh) * pad_W + w];
                        for (uint32_t fw = 0; fw < filter_W; fw++) {
                            int32_t weight = *w_ptr++; 
                            sum0 += p_ptr[fw] * weight;
                            sum1 += p_ptr[fw + 1] * weight;
                            sum2 += p_ptr[fw + 2] * weight;
                            sum3 += p_ptr[fw + 3] * weight;
                        }
                    }
                }
                
                output[n * input_H * input_W + h * input_W + w]     = requant(relu(sum0), scale);
                output[n * input_H * input_W + h * input_W + w + 1] = requant(relu(sum1), scale);
                output[n * input_H * input_W + h * input_W + w + 2] = requant(relu(sum2), scale);
                output[n * input_H * input_W + h * input_W + w + 3] = requant(relu(sum3), scale);
            }
            for (; w < input_W; w++) {
                int32_t sum = bias[n];
                int8_t* w_ptr = &filter[n * input_C * filter_H * filter_W];
                for (uint32_t c = 0; c < input_C; c++) {
                    uint32_t base = c * pad_H * pad_W;
                    for (uint32_t fh = 0; fh < filter_H; fh++) {
                        int8_t* p_ptr = &pad_buf[base + (h + fh) * pad_W + w];
                        for (uint32_t fw = 0; fw < filter_W; fw++) {
                            sum += p_ptr[fw] * (*w_ptr++);
                        }
                    }
                }
                output[n * input_H * input_W + h * input_W + w] = requant(relu(sum), scale);
            }
        }
    }

};

void linear_relu(uint32_t input_size, uint32_t output_size, uint8_t* activation,
                 uint8_t* output, int8_t* filter, int32_t* bias, uint32_t scale,
                 void* scratch) {
    /*! <<<========= Implement here =========>>> */
        uint32_t o = 0;
    for (; o <= output_size - 4; o += 4) {
        int32_t sum0 = bias[o], sum1 = bias[o+1], sum2 = bias[o+2], sum3 = bias[o+3];
        
        int8_t* f0 = &filter[o * input_size];
        int8_t* f1 = &filter[(o + 1) * input_size];
        int8_t* f2 = &filter[(o + 2) * input_size];
        int8_t* f3 = &filter[(o + 3) * input_size];
        uint8_t* act_ptr = activation; 

        for (uint32_t i = 0; i < input_size; i++) {
            int32_t act = (int32_t)(*act_ptr++) - 128; 
            sum0 += act * (*f0++);
            sum1 += act * (*f1++);
            sum2 += act * (*f2++);
            sum3 += act * (*f3++);
        }
        
        output[o]     = requant(relu(sum0), scale);
        output[o + 1] = requant(relu(sum1), scale);
        output[o + 2] = requant(relu(sum2), scale);
        output[o + 3] = requant(relu(sum3), scale);
    }
    
    for (; o < output_size; o++) {
        int32_t sum = bias[o];
        int8_t* f = &filter[o * input_size];
        uint8_t* act_ptr = activation;
        for (uint32_t i = 0; i < input_size; i++) {
            sum += ((int32_t)(*act_ptr++) - 128) * (*f++);
        }
        output[o] = requant(relu(sum), scale);
    }


};

void linear(uint32_t input_size, uint32_t output_size, uint8_t* activation,
            uint8_t* output, int8_t* filter, int32_t* bias, uint32_t scale,
            void* scratch) {
    /*! <<<========= Implement here =========>>> */
        uint32_t o = 0;
    for (; o <= output_size - 4; o += 4) {
        int32_t sum0 = bias[o], sum1 = bias[o+1], sum2 = bias[o+2], sum3 = bias[o+3];
        
        int8_t* f0 = &filter[o * input_size];
        int8_t* f1 = &filter[(o + 1) * input_size];
        int8_t* f2 = &filter[(o + 2) * input_size];
        int8_t* f3 = &filter[(o + 3) * input_size];
        uint8_t* act_ptr = activation;

        for (uint32_t i = 0; i < input_size; i++) {
            int32_t act = (int32_t)(*act_ptr++) - 128;
            sum0 += act * (*f0++);
            sum1 += act * (*f1++);
            sum2 += act * (*f2++);
            sum3 += act * (*f3++);
        }
        
        output[o]     = (uint8_t)((int8_t)(sum0 >> scale) + 128);
        output[o + 1] = (uint8_t)((int8_t)(sum1 >> scale) + 128);
        output[o + 2] = (uint8_t)((int8_t)(sum2 >> scale) + 128);
        output[o + 3] = (uint8_t)((int8_t)(sum3 >> scale) + 128);
    }
    
    for (; o < output_size; o++) {
        int32_t sum = bias[o];
        int8_t* f = &filter[o * input_size];
        uint8_t* act_ptr = activation;
        for (uint32_t i = 0; i < input_size; i++) {
            sum += ((int32_t)(*act_ptr++) - 128) * (*f++);
        }
        output[o] = (uint8_t)((int8_t)(sum >> scale) + 128);
    }


};
