## Entry script — main menu, language toggle, scene routing.

## ============================================================
## Character definitions
## ============================================================
##
## MC does not speak aloud in Scene 1 — all interior monologue.
## We use the narrator voice (no character tag, just "text") throughout
## for interior monologue. Direct speech characters predefined for
## future scenes.

define narrator = Character(None, what_color="#e8e0d0")
define mc = Character(_("知行"), color="#d4c9a8")
define li = Character("???", color="#c8d4e6")
define damuma = Character(_("大姆妈"), color="#d4c8c8")

## ============================================================
## Placeholder images — solid-color backgrounds with text labels.
## Replace each bg_xxx with a real PNG in game/images/bg_xxx.png
## when art arrives. File naming is the contract — keep names stable.
## ============================================================

image bg_splash = Composite(
    (1280, 720),
    (0, 0), Solid("#0b0f1a"),
    (0, 260), Text("{size=56}BL VN Demo — Scene 1 Prototype{/size}", xalign=0.5, text_align=0.5, color="#e8d4b0"),
    (0, 360), Text("{size=26}Placeholder art · pipeline validation build{/size}", xalign=0.5, text_align=0.5, color="#8a7f6e"),
)

image bg_longning_apartment = Composite(
    (1280, 720),
    (0, 0), Solid("#1a1f2e"),
    (0, 300), Text("{size=48}长宁区公寓 · Long Ning Apartment{/size}", xalign=0.5, text_align=0.5, color="#d4c9a8"),
    (0, 380), Text("{size=24}22:00 · Thursday · April 17{/size}", xalign=0.5, text_align=0.5, color="#8a7f6e"),
)

image bg_kitchen_counter = Composite(
    (1280, 720),
    (0, 0), Solid("#1c2030"),
    (0, 300), Text("{size=48}Kitchen Counter · 厨房料理台{/size}", xalign=0.5, text_align=0.5, color="#d4c9a8"),
    (0, 380), Text("{size=24}Night · overhead spill only{/size}", xalign=0.5, text_align=0.5, color="#8a7f6e"),
)

image bg_apartment_doorway = Composite(
    (1280, 720),
    (0, 0), Solid("#151822"),
    (0, 300), Text("{size=48}Apartment Doorway · 公寓门口{/size}", xalign=0.5, text_align=0.5, color="#d4c9a8"),
    (0, 380), Text("{size=24}Grey cardigan · bag · keys{/size}", xalign=0.5, text_align=0.5, color="#8a7f6e"),
)

image bg_changning_street = Composite(
    (1280, 720),
    (0, 0), Solid("#1f2638"),
    (0, 300), Text("{size=48}长宁路 · Long Ning Road{/size}", xalign=0.5, text_align=0.5, color="#d4c9a8"),
    (0, 380), Text("{size=24}22:37 · 20°C · 偏暖{/size}", xalign=0.5, text_align=0.5, color="#8a7f6e"),
)

image bg_subway_walk = Composite(
    (1280, 720),
    (0, 0), Solid("#1b2030"),
    (0, 300), Text("{size=48}Walk to Line 2 · 2号线入口{/size}", xalign=0.5, text_align=0.5, color="#d4c9a8"),
    (0, 380), Text("{size=24}240 meters · unhurried{/size}", xalign=0.5, text_align=0.5, color="#8a7f6e"),
)

image cg_mc_counter_placeholder = Composite(
    (1280, 720),
    (0, 0), Solid("#202536"),
    (0, 240), Text("{size=44}[CG PLACEHOLDER]{/size}", xalign=0.5, text_align=0.5, color="#c0a878"),
    (0, 320), Text("{size=32}MC at counter · cardigan · ring visible{/size}", xalign=0.5, text_align=0.5, color="#d4c9a8"),
    (0, 400), Text("{size=22}Low priority CG — optional{/size}", xalign=0.5, text_align=0.5, color="#7a6e5c"),
)

image bg_end_card = Composite(
    (1280, 720),
    (0, 0), Solid("#0a0d14"),
    (0, 260), Text("{size=56}End of Prototype{/size}", xalign=0.5, text_align=0.5, color="#e8d4b0"),
    (0, 360), Text("{size=26}Scene 1 complete.{/size}", xalign=0.5, text_align=0.5, color="#8a7f6e"),
)

## ============================================================
## Persistent state
## ============================================================

default persistent.language = "en"

## ============================================================
## Main entry label
## ============================================================

label start:
    scene bg_splash with fade
    pause 0.4

    menu language_select:
        "English":
            $ persistent.language = "en"
            jump scene1_en_start

        "简体中文":
            $ persistent.language = "cn"
            jump scene1_cn_start

## ============================================================
## End-of-prototype card — both scenes route here on completion.
## ============================================================

label end_of_demo_card:
    scene bg_end_card with fade
    if persistent.language == "cn":
        "第一场结束 — 原型验证通过。"
        "第二场《不在地图上的弄堂》将在后续版本实现。"
    else:
        "Scene 1 complete — prototype pipeline validated."
        "Scene 2 «The lane that wasn't on the map» arrives in a later build."
    return
