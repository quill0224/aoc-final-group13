"""Analytical modeling for the Final_project accelerator design.

Public surface
--------------
- eyeriss.EyerissAnalyzer    per-layer cost model
- eyeriss.EyerissMapper      DSE over (mapping, hardware) space
- eyeriss.parse_pytorch      extract Conv2D/MaxPool/Linear shapes from a torch.nn.Module
- eyeriss.plot_roofline      roofline visualization
"""
