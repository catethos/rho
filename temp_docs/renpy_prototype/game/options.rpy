## Project options for BL VN Demo — Scene 1 Prototype

define config.name = _("BL VN Demo — Scene 1 Prototype")
define gui.show_name = True

define config.version = "0.1.0"

define gui.about = _p("""
Scene 1 bilingual (EN / Simplified Chinese) prototype.
Placeholder art only. Validates the Ren'Py production pipeline.
""")

## Window size. 1280x720 demo default; upgrade to 1920x1080 later if desired.
define config.screen_width = 1280
define config.screen_height = 720

## Save directory — shows up under ~/Library/RenPy/
define config.save_directory = "bl_vn_demo_prototype-1"

## Fonts — CJK font required for Simplified Chinese.
## If NotoSansSC-Regular.ttf is missing from game/fonts/, SC build shows tofu.
define gui.text_font = "fonts/NotoSansSC-Regular.ttf"
define gui.name_text_font = "fonts/NotoSansSC-Regular.ttf"
define gui.interface_text_font = "fonts/NotoSansSC-Regular.ttf"

## Build classification
init python:
    build.classify('game/**.rpy', None)
    build.classify('game/**.rpyc', 'all')
    build.classify('game/**.txt', 'all')
    build.classify('game/**.png', 'all')
    build.classify('game/**.jpg', 'all')
    build.classify('game/**.ttf', 'all')
    build.classify('game/**.otf', 'all')

define build.name = "BLVNPrototype"
