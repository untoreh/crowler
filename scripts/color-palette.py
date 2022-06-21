#!/usr/bin/env python3

import random, colors

# get seeds https://color.adobe.com/create/color-wheel (choose "shades" radio, take "ABCD" colors)
# PRIMARY/A, SECONDARY/B, BACKGROUND/C, SURFACE/D
SEED = ["#616161", "#333333", "#FFFFFF", "#050505"]
mid = colors.rgb(125, 125, 125)

def from_hex(hex):
    hex = hex[1:]
    return colors.HexColor(hex)

def gen_palette():
    # if seed is not None:
    #     random.seed(seed)
    # random.seed(random.random())
    # cw = colors.ColorWheel()
    palette = {}
    palette["PRIMARY"] = from_hex(SEED[0])
    palette["LIGHT_PRIMARY"] = palette["PRIMARY"] + mid
    palette["DARK_PRIMARY"] = palette["PRIMARY"] - mid
    palette["SECONDARY"] = from_hex(SEED[1])
    palette["LIGHT_SECONDARY"] = palette["SECONDARY"] + mid
    palette["DARK_SECONDARY"] = palette["SECONDARY"] - mid

    palette["TEXT_PRIMARY_ON_LIGHT"] = palette["LIGHT_PRIMARY"].invert()
    palette["TEXT_PRIMARY_ON_DARK"] = palette["DARK_PRIMARY"].invert()
    palette["TEXT_SECONDARY_ON_LIGHT"] = palette["LIGHT_SECONDARY"].invert()
    palette["TEXT_SECONDARY_ON_DARK"] = palette["DARK_SECONDARY"].invert()
    palette["ON_PRIMARY"] = palette["SECONDARY"].invert()
    palette["ON_SECONDARY"] = palette["PRIMARY"].invert()

    palette["LIGHT_ON_PRIMARY"] = palette["LIGHT_SECONDARY"].invert()
    palette["LIGHT_ON_SECONDARY"] = palette["LIGHT_PRIMARY"].invert()
    palette["DARK_ON_PRIMARY"] = palette["DARK_SECONDARY"].invert()
    palette["DARK_ON_SECONDARY"] = palette["DARK_PRIMARY"].invert()

    palette["BACKGROUND"] = from_hex(SEED[2]) + mid
    palette["LIGHT_BACKGROUND"] = palette["BACKGROUND"] + mid
    palette["DARK_BACKGROUND"] = palette["LIGHT_BACKGROUND"].invert()
    palette["LIGHT_ON_BACKGROUND"] = palette["LIGHT_BACKGROUND"].invert()
    palette["DARK_ON_BACKGROUND"] = palette["DARK_BACKGROUND"].invert()

    palette["SURFACE"] = from_hex(SEED[3])
    palette["LIGHT_SURFACE"] = palette["SURFACE"] + mid
    palette["DARK_SURFACE"] = palette["LIGHT_SURFACE"].invert()
    palette["LIGHT_ON_SURFACE"] = palette["LIGHT_SURFACE"] - mid
    palette["DARK_ON_SURFACE"] = palette["DARK_SURFACE"] + mid

    # print({k: "#" + str(v.hex) for (k, v) in palette.items()})
    return palette


if __name__ == "__main__":
    import os
    import subprocess as sp
    from pathlib import Path

    colors_path = Path(os.environ["PROJECT_DIR"]) / "src" / "css" / "colors"
    target = colors_path / (os.environ["CONFIG_NAME"] + ".scss")
    template = colors_path / "template.scss"
    pal = gen_palette()
    for k, v in pal.items():
        os.environ[k] = "#" + str(v.hex)
    print(f"Writing to path: {target}")
    sp.run(f"envsubst < {template} > {target}", shell=True)
