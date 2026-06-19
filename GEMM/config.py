from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent
REPO_ROOT = PROJECT_DIR.parent

default_model_path = REPO_ROOT / "weights" / "vgg16_imagenet100_pruned_power2_int8.pth"
default_output_dir = PROJECT_DIR / "outputs"

input_size = 224
resize_size = 224
center_crop = False

imagenet_mean = (0.485, 0.456, 0.406)
imagenet_std = (0.229, 0.224, 0.225)

dump_dtype = "auto"
dump_dtype_choices = ("auto", "fp32", "int")

default_target_layer = "all"
dump_all_layers = True
dump_conv_linear_only = True
supported_layer_kinds = ("Conv2d", "Linear", "ReLU", "MaxPool2d")
default_module_types = "Conv2d,Linear"

gemm_layout = "row-major"
txt_value_format = "one value per line"

fp32_atol = 1e-4
fp32_rtol = 1e-4
int_exact_atol = 0.0
int_exact_rtol = 0.0
