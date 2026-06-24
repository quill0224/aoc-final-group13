# GEMM Dump Tool for VGG16 ImageNet100 INT8

This project runs single-image inference on the trained VGG16 ImageNet100 power-of-two INT8 checkpoint and dumps layer tensors plus GEMM-format test data for hardware verification.

## Run

Useful options:

- `--target-layer features.0`: dump one layer.
- `--target-layer features.40`: dumps to `outputs/layer_40_conv`.
- `--target-layer all`: dump all matched module types.
- `--module-types Conv2d,Linear`: default GEMM-capable layers.
- `--module-types Conv2d,ReLU,MaxPool2d`: also dump activation/pool outputs.
- `--include-activations --include-pool`: shortcut to add ReLU and MaxPool2d.
- `--emit-bitmask`: for Conv2d / Linear, additionally emit sparse-friendly `hw_bitmask/` files.
- `--max-layers N`: limit how many matched layers are dumped.
- `--device cpu|cuda|auto`: quantized PyTorch inference is forced to CPU for portability.

The image loader converts RGB, resizes directly to `224x224`, normalizes with ImageNet mean/std, and adds batch dimension, producing `[1, 3, 224, 224]` NCHW. Center crop is not used in the current implementation.
```
  # run specific layer
  python main.py `
  --model-path ..\weights\vgg16_imagenet100_pruned_power2_int8.pth `
  --image .\images\fish.JPEG `
  --output-dir .\outputs `
  --target-layer features.40 `
  --emit-bitmask `
  --device cuda

# run number of max-layer layer
  python main.py `
  --model-path ..\weights\vgg16_imagenet100_pruned_power2_int8.pth `
  --image .\images\fish.JPEG `
  --output-dir .\outputs `
  --target-layer all `
  --module-types Conv2d,ReLU,MaxPool2d `
  --max-layers 5 `
  --emit-bitmask `
  --device cuda
```
## Output Structure

```text
outputs/
  layer_40_conv/
    summary.txt
    layer_meta.txt
    quant_meta.txt
    verify.txt
    pytorch/
      input_activation_nchw.txt
      weight_oihw.txt
      bias.txt
      output_nchw.txt
    gemm/
      local_summary.txt
      A_im2col_mk.txt
      B_weight_kn.txt
      bias_n.txt
      psum_mn.txt
      output_mn.txt
    hw/
      local_summary.txt
      input_A_hex.txt
      input_B_hex.txt
      input_bias_hex.txt
      golden_psum_hex.txt
      golden_output_hex.txt
    hw_bitmask/
      local_summary.txt
      input_A_values_hex.txt
      input_A_bitmask_64b_hex.txt
      input_B_values_hex.txt
      input_B_bitmask_64b_hex.txt
      golden_output_values_hex.txt
      golden_output_bitmask_64b_hex.txt
```
*output經過relu為uint8*  
Layer folder names come from the real module name. For example, `features.40` becomes `layer_40_conv`; `classifier` becomes `layer_classifier_00_linear`. A per-layer `summary.txt` is written inside each layer folder. For multi-layer dumps, `outputs/global_summary.txt` lists all dumped layers. The root `outputs/summary.txt` and `outputs/input/input_tensor_nchw.txt` are not generated.

`gemm/*.txt` files are pure decimal values: one value per line, row-major, no header. Metadata that used to be in headers is written to `gemm/local_summary.txt`.

`hw/*.txt` files are pure hexadecimal values: one value per line, no `0x` prefix, no header. Signed values use two's complement. INT8 uses 2 hex digits, INT16 uses 4, and INT32 uses 8. Hardware metadata is written to `hw/local_summary.txt`.

With `--emit-bitmask`, `hw_bitmask/` stores sparse-friendly A/B/output data. Each dense row-major matrix is flattened, split into 64-element blocks, and represented as:

- `*_values_hex.txt`: non-zero values only, in row-major scan order.
- `*_bitmask_64b_hex.txt`: one 64-bit mask per 64 values, fixed 16 hex digits, no `0x`; bit `i` maps to element `i` in that block and bit0 is LSB.

`hw_bitmask/local_summary.txt` records original shapes, total elements, non-zero counts, sparsity, bitmask word counts, value bitwidths, filenames, and reconstruction pass/fail for A, B, and output. Bias, psum, requant, and scale metadata remain in the original dense `hw/`, `gemm/`, `quant_meta.txt`, and summary files.

`pytorch/*.txt` files may keep debug headers because they are reference dumps, not direct hardware inputs.

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

If metadata cannot be extracted from PyTorch quantized tensors or modules, the value is written as `not_found` and summarized in the layer `summary.txt`.

For quantized layers, A/B txt files dump raw integer tensor values. The converter uses zero-point corrected values for `psum_mn.txt` int32 accumulation. `output_mn.txt` and `hw/golden_output_hex.txt` are PyTorch quantized layer `int_repr()` values laid out as `[M, N]`, so final golden output matches the backend exactly. `quant_meta.txt` still records the requant scale/shift needed by hardware.

## Verification

`verify.txt` reports:

- `max_abs_error`
- `mean_abs_error`
- `num_mismatch`
- `mismatch_ratio`
- `pass`
- first mismatch indices when failed

FP32 layers use `atol=1e-4, rtol=1e-4`. Quantized layers compare integer values exactly.

ReLU and MaxPool2d are hook-only dumps by default. They are not converted to GEMM and do not create `gemm/` or `hw/`. Their `verify.txt` records `verify_method: hook_only` and `pass: true` when hook output is captured.

Because this loader fuses Conv+BN while preserving the original `nn.Sequential` indices, BN slots become `Identity`. For example, around the last block this model has `features.40 = Conv2d`, `features.41 = Identity`, `features.42 = ReLU`, and `features.43 = MaxPool2d`. Target the real module name shown by the loaded model.

## Current Limits

- Batch size is fixed to 1.
- GEMM outputs are txt decimal; HW outputs are txt hex.
- FP32 hex output is not supported; INT8/UINT8/INT16/INT32 hex is supported.
- MaxPool and ReLU are not converted to GEMM.
- The provided checkpoint is loaded as quantized VGG16 with Conv+BN fused and ReLU kept separate so Conv hooks capture raw pre-ReLU Conv2d module outputs.
