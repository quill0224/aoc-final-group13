# GEMM Dump Tool for VGG16 ImageNet100 INT8

This project runs single-image inference on the trained VGG16 ImageNet100 power-of-two INT8 checkpoint and dumps layer tensors plus GEMM-format test data for hardware verification.

## Run

```powershell
cd aoc-final-group13\GEMM
C:\Users\user\anaconda3\Scripts\conda.exe run -n ai_project python main.py --model-path ..\weights\vgg16_imagenet100_pruned_power2_int8.pth --image <image_path> --output-dir .\outputs --target-layer features.0 --device cpu
```

If `conda.exe` is not under `C:\Users\user\anaconda3\Scripts`, check common locations such as `C:\Users\user\miniconda3\Scripts\conda.exe`, or run the environment Python directly, for example `C:\Users\user\anaconda3\envs\ai_project\python.exe main.py ...`.

Useful options:

- `--target-layer features.0`: dump one layer.
- `--target-layer all`: dump all supported Conv2d / Linear layers.
- `--max-layers N`: limit how many matched layers are dumped.
- `--device cpu|cuda|auto`: quantized PyTorch inference is forced to CPU for portability.

The image loader converts RGB, resizes directly to `224x224`, normalizes with ImageNet mean/std, and adds batch dimension, producing `[1, 3, 224, 224]` NCHW. Center crop is not used in the current implementation.

## Output Structure

```text
outputs/
  input/
    input_tensor_nchw.txt
    input_meta.txt
  layer_00_conv/
    layer_meta.txt
    quant_meta.txt
    pytorch/
      input_activation_nchw.txt
      weight_oihw.txt
      bias.txt
      output_nchw.txt
    gemm/
      A_im2col_mk.txt
      B_weight_kn.txt
      bias_n.txt
      psum_mn.txt
      output_mn.txt
    hw/
      input_A_txt.txt
      input_B_txt.txt
      input_bias_txt.txt
      golden_psum_txt.txt
      golden_output_txt.txt
    verify.txt
  summary.txt
```

All `.txt` tensor files use row-major order and one value per line. Header lines start with `#` and include shape, dtype, layout, and tensor name.

## GEMM Definition

Conv2d input is `[1, Cin, Hin, Win]`, weight is `[Cout, Cin, Kh, Kw]`, and output is `[1, Cout, Hout, Wout]`.

- `M = Hout * Wout`
- `K = Cin * Kh * Kw`
- `N = Cout`
- `A_im2col` shape is `[M, K]`
- `B_weight` shape is `[K, N]`
- `psum` shape is `[M, N]`

Conv im2col order:

```python
for oh in range(Hout):
    for ow in range(Wout):
        row = oh * Wout + ow
        for cin in range(Cin):
            for kh in range(Kh):
                for kw in range(Kw):
                    col = cin * Kh * Kw + kh * Kw + kw
                    A[row, col] = input[0, cin, ih, iw]
```

Weight reshape order:

```python
for cin in range(Cin):
    for kh in range(Kh):
        for kw in range(Kw):
            k = cin * Kh * Kw + kh * Kw + kw
            for cout in range(Cout):
                B[k, cout] = weight[cout, cin, kh, kw]
```

Linear uses `A = [Batch, In_features]` and `B = weight.T = [In_features, Out_features]`.

## Quantization Metadata

`quant_meta.txt` records:

- `input_scale`, `input_zero_point`
- `weight_scale`, `weight_zero_point`
- `bias_scale`
- `output_scale`, `output_zero_point`
- `power2_weight_scale`, `power2_weight_exponent`
- `power2_activation_scale`, `power2_activation_exponent`
- `requant_scale`, `requant_shift`

If metadata cannot be extracted from PyTorch quantized tensors or modules, the value is written as `not_found` and summarized in `summary.txt`.

For quantized layers, A/B txt files dump raw integer tensor values. The converter uses zero-point corrected values for `psum_mn.txt` int32 accumulation. `output_mn.txt` and `hw/golden_output_txt.txt` are PyTorch quantized layer `int_repr()` values laid out as `[M, N]`, so final golden output matches the backend exactly. `quant_meta.txt` still records the requant scale/shift needed by hardware.

## Verification

`verify.txt` reports:

- `max_abs_error`
- `mean_abs_error`
- `num_mismatch`
- `mismatch_ratio`
- `pass`
- first mismatch indices when failed

FP32 layers use `atol=1e-4, rtol=1e-4`. Quantized layers compare integer values exactly.

## Current Limits

- Batch size is fixed to 1.
- Only txt output is implemented.
- Hex output is not implemented yet.
- MaxPool and ReLU are not converted to GEMM.
- The provided checkpoint is loaded as quantized VGG16 with Conv+BN fused and ReLU kept separate so Conv hooks capture raw pre-ReLU Conv2d module outputs.
