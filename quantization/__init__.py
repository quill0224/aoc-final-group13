"""VGG-8 PTQ pipeline ported from AOC Lab 1.

Public API
----------
- model.VGG : VGG-8 with QuantStub/DeQuantStub for PTQ
- quantize.PowerOfTwoObserver : MinMaxObserver with power-of-2 scale rounding
- quantize.CustomQConfig : QConfig enum (POWER2 / DEFAULT)
- quantize.ptq_quantization : end-to-end PTQ entry point
"""
