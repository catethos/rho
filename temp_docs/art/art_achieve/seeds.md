# MC + LI Seed Log

Track every locked-winning seed so any asset can be regenerated reproducibly.

---

## MC (林知行 / Lin Zhixing)

### LOCKED: mc_4view_v1 — base 4-view character sheet
- **Seed:** `1055135439356379`
- **Date locked:** 2026-04-18
- **Resolution:** 1216 × 832
- **Prompt ref:** Prompt 1 (iteration 5 final — jet black hair + dark eyes + beige chinos + grey cardigan)
- **Status:** LOCKED — `control_after_generate` should be `fixed` if regenerating
- **Derived files:**
  - `mc_4view_v1.png_00015_.png` — full 4-view
  - `mc_faceref_v1.png` — tight face crop (IP-Adapter FaceID source)
  - `mc_styleref_v1.png` — bust style reference
  - `mc_sprite_rough_v1.png` — bg-removed rough sprite

### Downstream MC prompts (Prompt 2+)
IP-Adapter FaceID Plus v2 holds face identity via `mc_faceref_v1.png`. Seed lock matters less — can re-roll freely per generation. Record winning seeds below as they're produced.

| Asset | Seed | Date | Resolution | Notes |
|---|---|---|---|---|
| mc_expression_neutral_tired | `535284471862092` | 2026-04-18 | 1024×1024 | **LOCKED** — IP-Adapter PLUS FACE preset, weight 0.50, ref `mc_faceref_v1.png`. Dual LoRA stack (Niji 0.7 + Magical Ahjussi 0.8). |
| mc_expression_mild_attention | Nano Banana 2 Edit (no seed) | 2026-04-18 | Nano Banana native | **LOCKED v1** — ref `mc_faceref_v1.png`, API id `sync-eb4b5df3-3045...` |
| mc_expression_polite_smile | Nano Banana 2 Edit (no seed) | 2026-04-18 | Nano Banana native | **LOCKED v1** — ref `mc_faceref_v1.png`, API id `sync-33fc5ec6-1e9c...` |
| mc_expression_fear_stillness | Nano Banana 2 Edit (no seed) | 2026-04-18 | Nano Banana native | **LOCKED v1** — ref `mc_faceref_v1.png`, API id `sync-3cbe91ee-6e47...` |
| mc_expression_crying_small | Nano Banana 2 Edit (no seed) | 2026-04-18 | Nano Banana native | **LOCKED v1** — ref `mc_faceref_v1.png`, API id `sync-1ad7cf62-6194...` |
| mc_expression_aftercare | Nano Banana 2 Edit (no seed) | 2026-04-18 | Nano Banana native | **LOCKED v1** — ref `mc_faceref_v1.png`, API id `sync-ff429a73-c97d...` | Bonus: usable as secondary Scene 9 aftercare CG — thermos + folded cloth + bed visible |
| mc_sprite_default_v2 | Nano Banana 2 Edit (no seed) | 2026-04-18 | native portrait | **LOCKED v2** — single-pose regeneration, three-quarter angle, ring visible, cardigan+oxford+chinos locked |
| mc_sprite_turn_v2 | Nano Banana 2 Edit (no seed) | 2026-04-18 | native portrait | **LOCKED v2** — secondary sprite, alternate three-quarter angle, ring visible |
| mc_sprite_tired | Nano Banana 2 Edit (no seed) | 2026-04-18 | native portrait | **LOCKED v1** — hands in pockets, tired-functional register, ref `mc_4view_v2.png`, API id `sync-1e5f248e-a0d8...` |
| mc_sprite_leaving | Nano Banana 2 Edit (no seed) | 2026-04-18 | native portrait | **LOCKED v1** — half-turn over-the-shoulder exit pose, canvas bag strap, ref `mc_4view_v2.png`, API id `sync-174c4dca-da31...` |
| mc_cg_kitchen_counter | Nano Banana 2 Edit (no seed) | 2026-04-18 | native landscape | **LOCKED v1** — Scene 1 establishing CG, all diegetic details landed (dead pothos, oat milk carton, takeout bag, warm/cool lighting). Ref `mc_styleref_v1.png`, API id `sync-ed92e5a8-ea80...` |
| mc_anchor_degraded | Nano Banana 2 Edit (no seed) | 2026-04-18 | native square | **LOCKED v1** — subtle wrongness regenerated (cleaner uncanny: slight warm-greenish cast, cardigan collar asymmetry, face present-but-not-quite). Ref `mc_faceref_v1.png`, API id `sync-ca22bc63-9c32...` (replaced earlier `sync-52d02c29-e89e...`) |

---

## LI ("the tenant")

### Base references
| Asset | Status |
|---|---|
| li_4view_v1 (Prompt 13 v4) | **LOCKED 2026-04-20** — ComfyUI, LoRA stack (Niji 0.70/1.00 + Magical Ahjussi 0.80), silver temples + glasses + stubble + grey-green eyes + pullover pale gray with undershirt peek |
| li_faceref_v1.png | **LOCKED** — cropped from `li_4view_v1.png` detail bust, resized 768×768, centered on face with silver temple + glasses visible |

### LI asset seeds
| Asset | Seed | Date | Resolution | Notes |
|---|---|---|---|---|
| li_4view_v1 | — | — | 1216×832 | Pending |
| li_expression_observing_still | — | — | 1024×1024 | Pending |
| ... | | | | |

---

## Regeneration protocol

To re-create any LOCKED asset exactly:
1. Load the workflow JSON saved alongside that asset
2. Paste this seed into KSampler
3. Set `control_after_generate` → `fixed`
4. Confirm all LoRA strengths match the prompt pack
5. Queue

If IP-Adapter is in the chain (Prompts 2+), also confirm the reference image file path and strength match this log.
