# Character Art Prompt Pack — BL VN Demo 1

**Project:** PG18 BL VN — Shanghai shikumen 副本, Demo 1 / Chapter 1
**Pipeline:** RunPod RTX 4090 + ComfyUI + Smooth Yaoi Boys v3.0 VPred + Niji-male-style LoRA + Elia x Jino / Magical Ahjussi LoRA
**Author use case:** Copy-paste prompts into the correct tool per the hybrid pipeline below. Regina runs everything on RunPod (ComfyUI pod + Nano Banana 2 Edit serverless). This document is the single production source for all Ch1 character art.
**Hard rule:** No character-name leakage (the LI is unnamed in Ch1 — file naming is `li_xxx.png`, not `[real name]_xxx.png`).

---

## ⚠ PIPELINE UPDATE (2026-04-18) — Hybrid approach

After validation testing, the primary pipeline shifted. ComfyUI + IP-Adapter proved unreliable for locking anime character identity across expression variants (tested FaceID Plus V2 and PLUS FACE presets — both drifted: wrong eye color, wrong hair length, red glowing eyes artifact, chromatic aberration). **Nano Banana 2 Edit (Google, via RunPod serverless) is the primary tool for expression/pose variants from a locked base reference.** ComfyUI stays for base 4-view generation + key CGs.

### Updated pipeline split

| Phase | Tool | Why |
|---|---|---|
| Base 4-view character sheets (P1, P13) | **ComfyUI + LoRA stack** | LoRA style baseline needed; no reference yet |
| Expression sheets (P2–P7, P14–P19) | **Nano Banana 2 Edit API** | Locked reference + prompt → consistent output; ~$0.09/image, ~30 sec |
| Sprites (P8–P10, P20–P22) | **Nano Banana 2 Edit API** | Same — from locked reference |
| Key CGs (P11, P23–P25 + intimate/aftercare CGs) | **ComfyUI + painterly LoRA + optional ControlNet** | Painterly polish + compositional control (especially P24 shadow) |
| Backgrounds | **ComfyUI** | Control + consistency |

### Nano Banana 2 Edit workflow

1. Upload the locked base character reference (e.g. `mc_faceref_v1.png` or the 4-view front-crop) as the edit input image
2. Write a positive prompt describing the desired expression/pose/clothing/background (see per-prompt templates below)
3. Call `google-nano-banana-2-edit` endpoint on RunPod serverless
4. Cost: ~$0.0875 per generation, ~30 sec wall time
5. Save output with version suffix (`_v1`, `_v2`) and log the API call id / prompt in `seeds.md`

### Nano Banana 2 positive prompt pattern (proven)

Start every expression/sprite prompt with:
`1boy, solo, same character, close up portrait, bust shot, [pose/framing tags], (short black hair:1.4, exactly same as the reference picture), (short hair not long:1.3), slightly messy but short hair, hair above ears, (dark black eyes:1.4), (dark black iris not blue:1.4), (29 years old:1.2), mature adult man not teenager, [expression tags], [clothing tags], [lighting tags], [background tags], anime illustration, korean manhwa style, chinese manhua style, muted colors, masterpiece, best quality, highres, detailed face, detailed eyes`

Key reinforcement phrase: `exactly same as the reference picture` inside the hair tag — signals Nano Banana 2 to preserve identity strongly.

### When to fall back to ComfyUI

- Key CGs needing painterly rendering (Prompts 11, 23, 24, 25 + intimate/aftercare CGs per W3 §8)
- ControlNet-dependent compositions (Prompt 24 — shadow on wall with forced 门头-lintel shape)
- If Nano Banana 2 quota/budget becomes constraining (unlikely at ~$0.09/image)

### Deprecated (kept as backup only)

- IPAdapter Unified Loader FaceID + FACEID PLUS V2 → drifted on anime faces (InsightFace trained on photoreal)
- IPAdapter Unified Loader + PLUS FACE → over-corrected, red eyes / chromatic aberration artifacts
- Keep the ComfyUI IP-Adapter workflows archived as `workflow_mc_ipadapter_faceid.json` / `workflow_mc_ipadapter_plusface.json` in case a future update to these nodes improves anime support. Do not use for Ch1 production.

---

## 0. How to use this document

1. Generate the **4-view character sheets first** (MC and LI). These are the IP-Adapter base images for every downstream prompt.
2. Pick the winning **front-facing view** per character → crop to square face/bust → that is your FaceID Plus v2 reference image for the rest of the pack.
3. Move through expression sheets → sprites → key CGs, in that order. Earlier outputs feed later ones via IP-Adapter.
4. When a generation lands right, record the **seed** in the "Seed" field of the prompt entry. Commit the file. That seed is now the reproducibility lock for that asset.
5. If face drift becomes visible across 5+ regenerations at strength 0.8 — train a custom character LoRA from 20–30 locked outputs per POC §5.

---

## 1. Pipeline reference (from POC §4 — copy this into every ComfyUI session)

**Checkpoint:**
- `smoothYaoiBoys_v30Vpred.safetensors` (path: `/workspace/runpod-slim/ComfyUI/models/checkpoints/`)

**Standard LoRA stack (every MC + LI prompt unless overridden):**
- `5byue5dnijistyleE291.cNux.safetensors` — **strength_model 0.70, strength_clip 1.00** (Niji male style baseline)
- `Elia_x_Jino__Magical_Ahjussi-000013.safetensors` — **strength 0.80** (BL manhwa character flavor)

**Optional painterly LoRA — key CGs only (intimacy, shadow reveal, 天井 climax-adjacent):**
- `nijij_thick_paint_male_style` — **strength 0.85**
- Add AFTER the two standard LoRAs (chain: checkpoint → niji → magical-ahjussi → thick-paint → KSampler)
- Do NOT stack on sprites or expression sheets — it bleeds the line work and breaks consistency with transparent-BG exports.

**KSampler (locked, every generation):**
| Param | Value |
|---|---|
| steps | **28** |
| cfg | **5.0** |
| sampler_name | **euler_ancestral** |
| scheduler | **normal** |
| denoise | **1.00** |
| control after generate | randomize (flip to `fixed` once a seed is locked) |

**VAE:** inherit from checkpoint (smoothYaoiBoys bakes a good VAE — do not override).

---

## 2. Resolution lock table (scene-consistency contract)

Regina: lock these per asset type. Every prompt header in this doc names its render resolution verbatim — do not deviate. Cross-scene consistency depends on width/height being identical within an asset category so faces/proportions stay stable.

| Asset type | Render res (KSampler) | Aspect | Final delivery | Ren'Py usage |
|---|---|---|---|---|
| BG (exterior/interior) | **1216 × 832** | 1.46:1 landscape | 1920 × 1080 (1.5× upscale) | Full-screen BG |
| CG (landscape, two-char) | **1216 × 832** | 1.46:1 landscape | 1920 × 1080 (1.5× upscale) | Scene CG overlay |
| CG (portrait / close intimate) | **832 × 1216** | 1:1.46 portrait | 1280 × 1872 (1.5× upscale) | Vertical CG |
| Character sprite (half-body / waist-up) | **832 × 1216** | 1:1.46 portrait, transparent BG | 1024 × 1498 (keep alpha) | In-front-of-BG sprite |
| Character full-body | **832 × 1216** | 1:1.46 portrait | 1024 × 1498 | Reference + occasional CG |
| Expression sheet (close-up face/bust) | **1024 × 1024** | 1:1 square | 1024 × 1024 | Expression swap, gallery thumb |
| 4-view character ref sheet | **1216 × 832** | 1.46:1 landscape | four poses in one frame, downstream for IP-Adapter base | Internal pipeline only |

**Upscaler:** `4x-UltraSharp.pth` at **1.5× scale**, tile size 512, overlap 64. Run through `Ultimate SD Upscale` node with denoise 0.2 (enough to resolve skin texture, not enough to redraw features). For backgrounds where file size matters in Ren'Py packaging, flatten to JPG quality 92 after upscale. For sprites, keep PNG with alpha.

---

## 3. Consistency strategy — IP-Adapter + reference flow

Character consistency is the single hardest problem in this pipeline. Ren'Py requires the same face across sprite/expression/CG/key art. Raw prompt-only generation will drift even with fixed seeds the moment a clothing or pose tag changes. Use this flow.

### Step 1 — Generate the 4-view character sheet (the base)
- Use the **4-view character sheet prompt** for MC and LI respectively.
- Render at 1216×832, four poses in one frame (front / 3-quarter / side / back).
- Generate 8–12 variants. Pick the one where the front view is cleanest — detailed eyes, clear facial proportions, no anatomy errors, correct hair length.
- Save this as `mc_4view_v1.png` and `li_4view_v1.png`. These are your **character root files.**

### Step 2 — Extract IP-Adapter reference
- Crop the front-view head-and-shoulders from the chosen 4-view.
- Save as `mc_faceref_v1.png` (512×512 or 768×768) and `li_faceref_v1.png`.
- These are what you feed to **IP-Adapter FaceID Plus v2** on every downstream generation.

### Step 3 — Downstream generation with IP-Adapter active
- Every expression sheet, sprite, and CG prompt in this pack assumes IP-Adapter FaceID Plus v2 is loaded with the matching character reference.
- **Strength 0.75 baseline.** If face drifts toward the base model's default, push to 0.80. If face looks too stiff / over-constrained / identical across poses, drop to 0.65.
- For two-character CGs (both MC and LI in frame): use the **IP-Adapter Advanced** node with two reference images and **regional masking** — MC's face ref masked to the left half, LI's to the right, or split by the compositional axis of the CG. Do not try to pass both refs through a single non-masked IP-Adapter node; it will average the faces into a chimera.

### Step 4 — When a character needs to evolve (e.g., anchor-degradation MC)
- Do NOT re-generate the character reference.
- Keep `mc_faceref_v1.png` as the base identity.
- In the prompt, modify lighting / skin saturation / eye focus language to signal the degraded state.
- Lower IP-Adapter strength to **0.65** so the prompt's degradation tags have more room to breathe without losing MC's identity.

### Step 5 — Suggested ComfyUI workflow node order (for all downstream prompts)

```
Load Checkpoint → Load LoRA (niji 0.70/1.00) → Load LoRA (magical-ahjussi 0.80) →
  [optional: Load LoRA (thick-paint 0.85) for key CGs only] →
  Load IP-Adapter Model → Load IP-Adapter Unified → Load CLIP Vision →
    (face ref image → IP-Adapter input) →
  Apply IP-Adapter (weight 0.75) → CLIP Text Encode (pos) → CLIP Text Encode (neg) →
  Empty Latent Image (res per asset type) → KSampler → VAE Decode → Save Image
```

For sprites that need transparent background: append `RemBG` node (or `BRIA RMBG 1.4`) after VAE Decode, before Save Image. Export as PNG with alpha channel.

### Step 6 — When IP-Adapter is not enough (fallback: custom LoRA)
If face drift exceeds tolerance across 5+ locked-seed regenerations at IP-Adapter strength 0.80, collect 20–30 outputs where the face IS correct and train a character-specific LoRA via `kohya_ss`: 10–15 epochs, LR 1e-4, batch 4, rank 16, resolution 768. ~1 hour on RTX 4090. Replace IP-Adapter with the custom LoRA in the stack and lock the character identity permanently.

---

## 4. Shared negatives (use on every prompt unless overridden)

```
lowres, bad anatomy, bad hands, bad proportions, extra fingers, missing fingers, fused fingers, malformed limbs, extra limbs, extra arms, extra legs, text, watermark, signature, username, error, worst quality, low quality, blurry, deformed, ugly, censored, censor bar, mosaic, female, girl, woman, breasts, chibi, child, shota, western medieval armor, halo, wings, horns, devil tail, flashy robes, long flowing robes, red eyes, glowing red eyes, gold eyes, glowing gold eyes, silver butterflies, dice, bone flute, sword, gun, modern branding, brand logo, logo text, visible logo, tattoo, piercings, makeup, heavy eyeshadow, lipstick, jewelry on both hands, necklace, earrings, dangling earring, bright neon colors, saturated colors, gaudy, overdesigned, frilly, lace, sequins, glitter, sparkles, floating particles, magical aura, energy effects, manga panel, speech bubble, chromatic aberration
```

**Negative add-ons by asset type:**

- **Full body / sprite add-on:** `short legs, stubby legs, fat, chubby, muscular body, bodybuilder, bara, crop cut off, head cut off, feet cut off`
- **Close-up expression add-on:** `multiple heads, extra face, extra eyes, heterochromia (unless intended), three eyes, cropped head`
- **Two-character CG add-on:** `face swap, fused faces, conjoined, identical twins, same face on both characters`
- **LI-specific add-on** (add to every LI prompt): `warm skin, bronze skin, orange skin, tanned, gold accessories, red clothing, patterned clothing, modern clothing, hoodie, t-shirt, jeans, sneakers, smartwatch, watch with LED, brand logo on sweater`
- **MC-specific add-on** (add to every MC prompt): `ring on right hand, ring on ring finger, ring on middle finger, multiple rings, wedding ring on ring finger, large ornate ring`

---

## 5. MC (林知行 / Lin Zhixing) pack

**Canonical MC art notes (carry in mental-model for every MC prompt):**
- **Age-up ~2 years from the pipeline's default** — reads 29–30, NOT 24. Single most important art note.
- 180cm, lean-tall, narrow shoulders, slightly concave posture, visible collarbone, not bara, not fragile
- Soft black hair, slightly overgrown, unstyled, falls across forehead when he looks down
- Dark brown almond eyes, heavy-lidded, sleepy-without-effort, slight circles under eyes ALWAYS (including smiles)
- Long oval face, clean jaw, cheekbones visible not sharp
- **Small plain silver ring on LEFT INDEX FINGER** (not ring finger, not right hand). Visible on every hand shot. Ungendered plain band.
- Palette: low-saturation neutrals — slate, stone, dusty blue, warm grey, cream. No reds, no brights.
- Default outfit: soft grey cashmere-blend cardigan (优衣库 register), dusty-blue or slate cotton oxford underneath, stone or navy chinos, worn black leather sneakers, brown leather belt
- Default expression: **mild attention** — polite listening, not sad, not blank, not tired-stereotyped

---

### Prompt 1 — MC 4-view character sheet — 1216×832 — **LOCKED (ComfyUI)**

**Asset:** Base character reference — front / 3-quarter / side / back, neutral standing pose, full body. This is the source file for all downstream MC assets (crop the front view → `mc_faceref_v1.png`).

**Method:** ComfyUI + LoRA stack. NO IP-Adapter (this IS the identity source).

**Positive (PROVEN working v5 — the one that produced the locked 4-view):**
```
character sheet, four view, turnaround, multiple views, same character, front view, three quarter view, side view, back view, 1boy, solo, handsome east asian man, (29 years old:1.3), (mature adult man:1.3), (late 20s:1.2), subtle worn features, not bishounen boy, not shonen protagonist, not teenager, tall, lean, slim, narrow shoulders, slight concave posture, 180cm tall, visible collarbone, (jet black hair:1.4), (pure black hair not brown:1.3), slightly overgrown hair, messy hair, unstyled hair, hair falling on forehead, (dark brown almost black eyes:1.4), (deep brown iris:1.3), eyes fully open and alert, eyes clearly open looking forward, visible iris, visible pupils, looking at viewer, slightly tired calm eyes, faint subtle undereye shadow, long oval face, clean jawline, cheekbones visible, mild attention expression, polite listening, neutral expression, mouth closed relaxed, dusty blue cotton oxford shirt underneath, (grey cashmere cardigan worn open:1.4), (layered clothing cardigan over oxford shirt:1.3), button-up cardigan visible, wearing cardigan, (beige chinos:1.3), (warm khaki trousers:1.3), warm stone color pants, taupe trousers, brown leather belt, worn black leather sneakers, silver ring on left index finger, plain silver band ring, small ring, left hand visible, standing pose, arms at sides, natural stance, relaxed shoulders, neutral lighting, even studio lighting, white background, clean background, model sheet, reference sheet, anime illustration, korean manhwa style, chinese manhua style, muted color palette, low saturation, masterpiece, best quality, highres, detailed face, detailed open eyes, detailed hands, good anatomy, good proportions
```

**Negative (PROVEN working — the full version with anti-drift weights):**
```
lowres, bad anatomy, bad hands, bad proportions, extra fingers, missing fingers, fused fingers, malformed limbs, extra limbs, extra arms, extra legs, text, watermark, signature, username, error, worst quality, low quality, blurry, deformed, ugly, censored, censor bar, mosaic, female, girl, woman, breasts, chibi, child, shota, western medieval armor, halo, wings, horns, devil tail, flashy robes, long flowing robes, red eyes, glowing red eyes, gold eyes, glowing gold eyes, silver butterflies, dice, bone flute, sword, gun, modern branding, brand logo, logo text, visible logo, tattoo, piercings, makeup, heavy eyeshadow, lipstick, jewelry on both hands, necklace, earrings, dangling earring, bright neon colors, saturated colors, gaudy, overdesigned, frilly, lace, sequins, glitter, sparkles, floating particles, magical aura, energy effects, manga panel, speech bubble, chromatic aberration, short legs, stubby legs, fat, chubby, muscular body, bodybuilder, bara, crop cut off, head cut off, feet cut off, ring on right hand, ring on ring finger, ring on middle finger, multiple rings, wedding ring on ring finger, large ornate ring, young boy, teenager, teen, boy, youthful baby face, childish face, smooth perfect youthful skin, anime shonen protagonist, generic pretty boy, (age 20:1.3), (bishounen boy:1.2), black pants, black trousers, dark trousers, single layer clothing, only oxford shirt, no cardigan, missing cardigan layer, (closed eyes:1.5), (eyes shut:1.4), (sleeping face:1.3), (eyes almost closed:1.4), (half closed eyes:1.4), squinting, slit eyes, narrow eyes, no visible iris, no visible pupils, sleepy expression, heavy lidded closed, drowsy, drooping eyelids, unconscious, brown hair, chestnut hair, auburn hair, dark brown hair, light hair, hair color drift, (green eyes:1.4), (hazel eyes:1.4), (gray eyes:1.4), (light colored eyes:1.3), blue eyes, colored contacts, inconsistent eye color, different eye color per view
```

**LoRA stack:** niji 0.70/1.00 + magical-ahjussi 0.80. No thick-paint.

**Sampler:** POC defaults (steps 28, cfg 5.0, euler_ancestral, normal, denoise 1.00).

**Resolution:** 1216 × 832 render → no upscale for this asset (kept at native for IP-Adapter / Nano Banana sourcing).

**Seed (LOCKED):** `1055135439356379`

**Locked output files:**
- `mc_4view_v1.png_00015_.png` — the master 4-view
- `mc_faceref_v1.png` — tight face crop (Nano Banana 2 Edit reference source)
- `mc_styleref_v1.png` — bust-width style reference
- `mc_sprite_rough_v1.png` — bonus bg-removed rough sprite (auto-extracted from this 4-view)

**Canonical MC clothing spec (anchor for all downstream prompts):**
- **Oxford shirt:** dusty blue cotton oxford (per bible §10 slate/dusty-blue/faded-charcoal palette) — note rendered output often drifts toward white/cream; enforce with weight if needed
- **Cardigan:** grey cashmere, worn open, slightly pilled
- **Trousers:** beige/warm khaki chinos (NOT black, NOT stone-cool grey)
- **Belt:** brown leather, worn pale at used buckle-hole
- **Shoes:** worn black leather sneakers
- **Ring:** silver plain band, LEFT INDEX FINGER only

**Iteration history (what broke on earlier runs, for reference):**
- v1 (original): face read too young, no cardigan, black pants, no eye circles
- v2: cardigan landed, pants still black
- v3: eyes drew closed from `sleepy eyes` + `heavy lidded` stacking — fixed by `(eyes fully open and alert:1.3)`
- v4: hair rendered as brown/chestnut — fixed by `(jet black hair:1.4)(pure black hair not brown:1.3)`
- v5: **LOCKED** (this version)

**Iteration notes (if regenerating):**
- Confirm front view reads 29–30, not early 20s
- Confirm silver ring on LEFT INDEX finger (critical — not ring finger)
- Confirm cardigan reads as soft/worn + layered over oxford
- Confirm eye-circles present
- Reject outputs where: hair reads K-pop idol, face <25, body muscular/bara, red/gold palette bleed, eyes any color other than dark brown/black

---

### Prompt 2 — MC Expression: neutral-tired — 1024×1024 — **LOCKED v2 (Nano Banana)**

**Asset:** Default 2026 register. The "mild attention" face at slight exhaustion — how he looks at 7pm reheating a 4-day-old takeout bag.

**Method (primary):** Nano Banana 2 Edit. Reference: `mc_faceref_v1.png`.

**Positive (PROVEN working — used on final v2):**
```
1boy, solo, same character, close up portrait, bust shot, looking at viewer, (short black hair:1.4, exactly same as the reference picture), (short hair not long:1.3), slightly messy but short hair, hair above ears, (dark black eyes:1.4), (dark black iris not blue:1.4), (29 years old:1.2), mature adult man not teenager, mild attention expression, polite listening, quiet observing, subtly tired, faint dark circles under eyes, mouth closed relaxed soft, slight natural expression, grey cashmere cardigan collar visible, dusty blue oxford collar visible underneath, soft natural lighting from left, cool neutral tones, slate grey soft background, shallow depth of field, anime illustration, korean manhwa style, chinese manhua style, muted colors, masterpiece, best quality, highres, detailed face, detailed eyes, looking at viewer
```

**Reference image:** `mc_faceref_v1.png`

**Cost:** ~$0.0875 per generation, ~30 sec wall time.

**Locked output files:**
- `mc_expression_neutral_tired_v2.png` — **Nano Banana 2 Edit (LOCKED)** — heavy-lidded tired register correct
- `mc_expression_neutral_tired_v1.png` — ComfyUI + IP-Adapter PLUS FACE backup (slight navy hair drift, B-)
- `mc_expression_alt_softlisten_v1.png` — bonus alt variant (softer open-eye register, for alternate use)

**Iteration notes:**
- Expression should read "listening to a coworker describe their weekend while calculating their own laundry schedule" (W2 MC §10). Not sad. Not blank. Not depressed-stereotyped.
- Eye circles visible but not bruised — faint lavender-grey under-eye, not the "panda eyes" anime trope.
- **Heavy-lidded eyes are the key tell** for the "tired" register vs alert "mild-attention" (which is Prompt 3).
- If Nano Banana output drifts (hair too long, eyes wrong color, guarded expression), regenerate — at $0.09 it's cheaper to re-roll than to engineer further.
- Key prompt phrase that worked: `(short black hair:1.4, exactly same as the reference picture)` — the inline "exactly same as the reference picture" is a strong identity anchor.

**Deprecated fallback (ComfyUI + IP-Adapter):**
- LoRA: niji 0.70/1.00 + magical-ahjussi 0.80
- IP-Adapter: PLUS FACE preset, weight 0.50, reference `mc_faceref_v1.png`
- Sampler: POC defaults (28 / 5.0 / euler_ancestral / normal / 1.00)
- Resolution: 1024 × 1024
- Seed (ComfyUI v1): `535284471862092`
- Keep this path only if Nano Banana unavailable — output quality is B- (navy hair drift visible).

---

### Prompt 3 — MC Expression: mild-attention (polite listening) — 1024×1024 — **LOCKED v1 (Nano Banana)**

**Asset:** Baseline register. The face during scenes 2–5 pre-LI-reveal, walking through the lane, nodding at the silhouette.

**Method (primary):** Nano Banana 2 Edit. Reference: `mc_faceref_v1.png`.

**Positive (proven pattern applied — adapt for mild-attention register):**
```
1boy, solo, same character, close up portrait, bust shot, head slightly tilted, looking off to the side, (short black hair:1.4, exactly same as the reference picture), (short hair not long:1.3), slightly messy but short hair, hair above ears, (dark black eyes:1.4), (dark black iris not blue:1.4), (29 years old:1.2), mature adult man not teenager, quiet polite listening expression, gentle attentiveness, soft relaxed face, warm quiet gaze, eyes steady not narrowed, heavy lidded slightly, lips closed softly, soft relaxed eyebrows, not guarded not suspicious not skeptical, faint dark circles under eyes, grey cashmere cardigan worn open, dusty blue cotton oxford shirt visible underneath, layered clothing cardigan over oxford, soft ambient interior lighting, cool natural daylight, plain soft grey background, simple clean background, shallow depth of field, anime illustration, korean manhwa style, chinese manhua style, muted color palette, low saturation, masterpiece, best quality, highres, detailed face, detailed eyes, subtle expression
```

**Reference image:** `mc_faceref_v1.png`

**Cost:** ~$0.0875 per generation, ~30 sec wall time.

**Locked output:** `mc_expression_mild_attention_v1.png`

**Iteration notes:**
- Expression should read "politely listening, attending to a life adjacent to his own" (W2 MC §10). Quiet nod register — NOT scrutiny, NOT assessment.
- Watch for drift toward "suspicious sideways glance" — counter with `soft relaxed eyebrows, not guarded, not suspicious, not skeptical`.
- Watch for drift toward "stiff-collar coat" instead of cardigan+oxford — counter by keeping `layered clothing cardigan over oxford` and `no coat, no trench coat` in negative.
- Watch for industrial/machinery backgrounds — counter with `plain soft grey background, no machinery, simple clean background` + `no pipes, no vehicles, no industrial` in negative.
- Slight head tilt only (3–5°). Not a dramatic anime "curious" cocked-head pose.

**Deprecated fallback (ComfyUI):** Same workflow as Prompt 2 fallback (LoRA stack + IP-Adapter PLUS FACE weight 0.50). Expect quality drift per the pipeline-update section.
```

**Negative:** shared + close-up + MC-specific.

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.75.

**Iteration notes:**
- Read check: "politely listening, attending to a life adjacent to his own" (W2 MC §10). If it reads as "engaged conversation," it's too active. Eyes should be present, not performing interest.
- Slight head tilt — 3–5° maximum. Do not produce a cocked-head anime "curious" pose.

---

### Prompt 4 — MC Expression: polite-smile (warm-clinical) — 1024×1024

**Asset:** The smile he gives strangers. Not fake, not warm-warm. Kind but economical — the face a man makes when he is genuinely glad to see a stranger for thirty seconds.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, close up portrait, bust shot, soft polite smile, closed mouth smile, corners of mouth slightly lifted, eyes gently crinkled at corners, warm but reserved expression, kind eyes, dark brown almond eyes heavy lidded, faint circles under eyes still present, soft black hair slightly overgrown, long oval face, grey cashmere cardigan, dusty blue oxford collar, soft natural daylight, warm neutral lighting, cream background, shallow depth of field, anime illustration, korean manhwa style, chinese manhua style, masterpiece, best quality, highres, detailed face, detailed eyes, subtle warmth
```

**Negative:** shared + close-up + MC-specific + `open mouth smile, teeth showing, grin, laughing, wide smile, cheesy smile`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.75.

**Iteration notes:**
- **Closed-mouth smile only.** MC does not grin; his smile is a closed-lip small thing, eye-driven.
- If the smile reads performative / corporate-LinkedIn, drop IP-Adapter to 0.70 and emphasize `reserved smile, quiet smile, genuine but small`.
- Eye circles MUST persist in the smile. They are a continuity feature, not an expression feature.

---

### Prompt 5 — MC Expression: fear-stillness (eyes-still-not-narrowed) — 1024×1024

**Asset:** Scene 8 register — the 荒鸡 cries, MC freezes. His tell under pressure is not widening or narrowing eyes but **stillness of eyes.** Face does almost nothing visible; the stillness IS the expression.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, close up portrait, bust shot, looking straight ahead, frozen expression, very still face, dark brown almond eyes heavy lidded, eyes unnaturally still, focused stare not narrowed not widened, pupils held steady, lips slightly parted barely, jaw relaxed but held, subtle tension in temple, faint circles under eyes, soft black hair overgrown hair slightly disturbed, grey cashmere cardigan, dusty blue oxford, cool blue-green ambient lighting, lantern light from one side warm but dim, muted shadows, dusky palette, anime illustration, korean manhwa style, chinese manhua style, low saturation, masterpiece, best quality, highres, detailed face, detailed eyes, microexpression
```

**Negative:** shared + close-up + MC-specific + `wide eyes, shocked expression, open mouth, gasping, screaming, crying, narrowed eyes, squinting, angry, frowning, eyebrows furrowed`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.78.

**Iteration notes:**
- **Eyes must be open, steady, not narrowed, not widened.** This is the hardest MC expression to nail. If the model defaults to "shocked anime eyes," increase `very still face, held steady, minimal expression, quiet fear` and drop `frozen` (the word trips models into theatrical fear).
- Cool ambient + warm lantern side-light is the scene-8 lighting register — match it so the sprite can swap cleanly into the 天井 shadow scene.

---

### Prompt 6 — MC Expression: crying-small (Scene 9 pivot) — 1024×1024

**Asset:** Unshowy crying **during**, not after. MC does not notice he is crying. Small, wet-eyed, no sobbing. The single hardest expression to get anime models to produce correctly — they default to theatrical anime tears.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, close up portrait, bust shot, looking down or slightly off camera, soft unshowy crying, small tears, wet eyes, one or two tears on cheek, eyes slightly glassy not red, not puffy, not squeezed shut, lips soft slightly parted, jaw relaxed, face not contorted, quiet emotion, unaware of crying, dark brown almond eyes heavy lidded, faint circles under eyes, soft black hair slightly mussed, bare shoulder or soft white undershirt visible, warm low lamplight, dim interior lighting, cool background shadows, tender intimate lighting, anime illustration, korean manhwa style, chinese manhua style, muted palette, masterpiece, best quality, highres, detailed face, detailed eyes, detailed tears, delicate expression
```

**Negative:** shared + close-up + MC-specific + `sobbing, ugly crying, open mouth crying, screaming, streaming tears, flooding tears, red eyes from crying, swollen eyes, puffy eyes, runny nose, anime tears, comic tears, exaggerated emotion, theatrical, dramatic crying`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85** (intimate CG register — this is a painterly beat).

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.72 (slightly lower to let the emotional state through).

**Iteration notes:**
- "Crying during, not after." (W2 MC §6). If the model produces a face that is clearly performing emotion, it's wrong — regenerate.
- One or two tears, not streams. If tears multiply, add `(at most two tears:1.3)` and `single tear trail, minimal tears`.
- Eyes glassy but NOT red-rimmed. This is intimate-scene crying, not grief-scene crying.

---

### Prompt 7 — MC Expression: post-intimacy / aftercare-receiving — 1024×1024

**Asset:** Scene 9 end, cloth-fold aftercare. MC's face as he takes the cloth. Open-held, quiet, post-released. The expression of a man who just finished saying yes out loud for the first time in three years.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, close up portrait, bust shot, looking down at hands or ahead at low distance, very soft open expression, relaxed lips, slightly parted, eyes softened, gaze open not guarded, shoulders dropped, post intimacy register, quiet aftermath, dark brown almond eyes heavy lidded, eyes warm not tired, faint circles under eyes still present, soft black hair mussed from earlier, bare shoulder or soft loose white undershirt, low lamplight warm amber, cool shadow behind, tender intimate atmosphere, open hands near chest or lap, thermos steam faint in frame, anime illustration, korean manhwa style, chinese manhua style, muted warm palette, masterpiece, best quality, highres, detailed face, detailed eyes, subtle warmth, delicate expression, soft lighting
```

**Negative:** shared + close-up + MC-specific + `sleeping, eyes closed, crying now, distressed, flushed deeply, embarrassed, tense, guarded, defensive posture`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85**.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.72.

**Iteration notes:**
- The key beat: "open-held." Not a post-sex sultry face, not a post-cry exhausted face. Something softer and more adult — he has been asked to stay and he did.
- Circles under eyes remain. He is not "restored" by the intimacy; he is slightly more present.
- If the model produces post-sex afterglow in the generic anime-BL way, dial down thick-paint to 0.70 and add `not aroused, not sultry, quiet presence, aftercare`.

---

### Prompt 8 — MC Sprite: half-body default cardigan, mild-attention — 832×1216, transparent BG

**Asset:** The most-used sprite. Default register across scenes 1–5. Waist-up. Goes in front of every BG.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, half body portrait, waist up, standing upright, facing slightly three quarter toward viewer, arms relaxed at sides, hands visible at hip level, silver ring on left index finger, mild attention expression, polite listening, soft black hair slightly overgrown, dark brown almond eyes heavy lidded, faint circles under eyes, grey cashmere cardigan over dusty blue oxford shirt, collar of oxford visible, soft worn fabric, stone chinos visible at waistline, brown leather belt, soft even studio lighting, transparent background, isolated character, no background, anime illustration, korean manhwa style, chinese manhua style, muted color palette, low saturation, masterpiece, best quality, highres, detailed face, detailed eyes, detailed hands, full body proportions correct, clean edges for alpha
```

**Negative:** shared + full-body + MC-specific + `background, scenery, room, outdoor, indoor, furniture, wall, floor, patterns in background`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 832 × 1216 (portrait). Final delivery 1024 × 1498 with alpha.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.78 (slightly higher — sprite faces must be locked).

**Post-processing:** After generation, run through `BRIA RMBG 1.4` node to extract alpha. Verify clean hair edges (no halo). Export PNG.

**Iteration notes:**
- Confirm ring on LEFT INDEX finger, hand visible.
- Body posture slight concave (W2 MC §10) — not military-upright, not slouched.
- If the output crops head or feet, increase render to 832×1344 and crop post-hoc.

---

### Prompt 9 — MC Sprite: half-body, tired-eye-circles-deeper (Scene 1 register) — 832×1216, transparent BG

**Asset:** Scene 1 sprite. Register slightly more worn than default — the 7pm-kitchen-counter MC. Same outfit, deeper eye-circles, slight posture slump.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, half body portrait, waist up, facing three quarter, slight slump in shoulders, tired posture, hands in cardigan pockets, silver ring visible on left index finger, neutral tired expression, mild exhaustion, soft black hair slightly overgrown and slightly mussed, dark brown almond eyes heavy lidded, deeper circles under eyes, slightly darker under eye shadow, eyes focused on middle distance, lips closed soft, jaw relaxed, grey cashmere cardigan over dusty blue oxford, slightly wrinkled cardigan, soft worn fabric, stone chinos, soft ambient lighting cool evening tone, transparent background, isolated character, anime illustration, korean manhwa style, chinese manhua style, muted palette, low saturation, masterpiece, best quality, highres, detailed face, detailed eyes, detailed hands
```

**Negative:** shared + full-body + MC-specific + `background, scenery, room, sick, ill, pale sickly, gaunt, emaciated, heavy shadows on face, cry, distressed`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 832 × 1216, transparent BG.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.78.

**Iteration notes:**
- Tired but NOT sick. Tired but NOT depressed-coded. The register is "functional withdrawal" per W2 MC §3.
- Eye circles one tonal step deeper than default sprite. If they go beyond "bruised lavender," dial back with `subtle under eye shadow, not bruised`.
- Cardigan slightly wrinkled — do not go full "disheveled."

---

### Prompt 10 — MC Sprite: doorway-leaving, bag on shoulder (Scene 1 exit) — 832×1216, transparent BG

**Asset:** Scene 1 exit sprite. MC leaving his apartment toward 西康路. Bag on shoulder, cardigan now on properly, half-turned posture.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, half body portrait, waist up, half turned body, about to walk away, facing slightly away three quarter back, head turned toward viewer, one canvas messenger bag strap over left shoulder, dark grey canvas bag strap visible, grey cashmere cardigan fully on, dusty blue oxford collar, mild attention expression, silver ring visible on left index finger resting on bag strap, soft black hair slightly overgrown, dark brown almond eyes heavy lidded, faint circles under eyes, soft even lighting cool evening, transparent background, isolated character, anime illustration, korean manhwa style, chinese manhua style, muted palette, masterpiece, best quality, highres, detailed face, detailed eyes, detailed hands, detailed bag strap
```

**Negative:** shared + full-body + MC-specific + `backpack, full bag in frame, large bag, luxury bag, brand label on bag, modern logo, multiple bags, briefcase`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 832 × 1216, transparent BG.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.78.

**Iteration notes:**
- Bag is a plain canvas messenger strap. NO visible brand. If a logo appears, aggressively negative-prompt it and regenerate.
- Half-turn posture — body 30° away, head turned back toward viewer. A "leaving" sprite.

---

### Prompt 11 — MC Key CG #1: Kitchen counter, eating standing (optional CG, Scene 1) — 1216×832

**Asset:** Optional establishing CG. MC at his kitchen counter, cardigan not yet on (just oxford shirt), eating standing up from takeout bag. Silver ring on left hand visible. Dead pothos on windowsill in background blur.

**Positive:**
```
1boy, solo, bishounen, 29 years old, mature face, kitchen counter scene, modern apartment interior, MC standing at small kitchen counter, leaning hip against counter, eating from takeout container, chopsticks in right hand, left hand resting on counter showing silver ring on left index finger, dusty blue oxford shirt sleeves rolled up to forearms, no cardigan yet, grey cardigan visible draped over chair in background, stone chinos, bare feet on kitchen floor, oat milk carton on counter, takeout paper bag open, chopsticks, small potted pothos plant on windowsill in background softly out of focus dead dried stems, evening warm amber light from window, cool ambient fluorescent overhead, muted interior palette, slate cabinets, stone counter, domestic loneliness atmosphere, anime illustration, korean manhwa style, chinese manhua style, low saturation, masterpiece, best quality, highres, detailed face, detailed hands, detailed silver ring on left index finger, detailed environment
```

**Negative:** shared + full-body + MC-specific + `full meal spread, elaborate cooking, dining table set, crowded kitchen, many people, party, bright cheerful kitchen, modern logos, brand boxes, western kitchen, marble countertop glamorous`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults (no thick-paint — this is documentary register, not painterly).

**Resolution:** 1216 × 832 render → 1920 × 1080 upscale for Ren'Py BG layer.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at 0.70 (lower — this is a full scene, face occupies <30% of frame).

**Iteration notes:**
- Confirm **dead pothos on windowsill** — dried stems, no green leaves, visible but soft-focus. If alive, add `(dead plant:1.3), dried dead leaves, brown dried stems, no green`.
- Confirm **silver ring on LEFT index finger** visible on counter hand.
- Confirm eating standing — NOT sitting at a table. If the model places him at a dining table, re-emphasize `standing, leaning against counter, no chair, eating standing up`.
- Palette must feel "watercolor background until someone looks at him directly" (W2 MC §10).

---

### Prompt 12 — MC Anchor-degradation variant (Scene 11 register) — 1024×1024

**Asset:** 40% anchor state. Same base MC, with subtle wrongness. Slightly too saturated skin, eye-focus-delay hint, cardigan collar sitting wrong. This is a UI-adjacent asset — used for anchor-state visual cues in the Ren'Py UI or as a ghost-frame overlay in the 天井 climax lead-up.

**Positive:**
```
1boy, solo, bishounen, 29 years old, close up portrait, bust shot, looking at viewer but eye focus slightly delayed, gaze arriving a half beat late, subtle disorientation, very subtle wrongness in face, skin slightly too saturated, faintly over-warm skin tone, soft black hair slightly too perfect placement, dark brown almond eyes heavy lidded but pupils slightly dilated, faint circles under eyes, grey cashmere cardigan collar sitting wrong, cardigan collar flipped oddly or asymmetrical, dusty blue oxford collar slightly wrong, soft unsettling lighting, dim lantern light from wrong angle, faint greenish ambient cast, muted palette with slight desaturation drift, anime illustration, korean manhwa style, chinese manhua style, masterpiece, best quality, highres, detailed face, detailed eyes, uncanny
```

**Negative:** shared + close-up + MC-specific + `distressed, crying, panicked, visibly sick, zombie, horror, overt supernatural effects, glowing eyes, aura`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `mc_faceref_v1.png` at **0.65** (lower — degradation needs room to express).

**Iteration notes:**
- The wrongness must be **subtle.** If the output reads as "obvious zombie/possessed," back off — reduce saturation tags, remove greenish cast.
- Skin-saturation-uptick is the key tell. Think "iPhone photo with slightly wrong white balance" — it looks fine until you look twice.
- Eye focus delay is near-impossible to render directly in static art. Cheat it with very slightly-dilated pupils and a faint blur on the iris outer edge: `pupils slightly dilated, iris edge softly blurred, gaze slightly defocused`.
- Cardigan collar wrongness: one side folded incorrectly, or the collar sitting higher on one shoulder. Subtle asymmetry.

---

## 6. LI ("the tenant") pack

**Canonical LI art notes (carry in mental-model for every LI prompt — NO NAMING in any metadata):**
- Age: presents **31**. Not youthful, not middle-aged.
- 183cm, narrow shoulders, long-limbed, weight sits low, slight stoop through doorways
- Black hair, slightly overgrown, **parted on LEFT** (1990s Shanghai men's cut), slightly sharper-rendered than skin (one tonal step more resolved)
- Dark brown almost black eyes, almond long-tilted-up, **focus slightly late** — cheat via slightly-dilated pupils / soft iris blur / gaze drift
- Hands: long fingers, **second knuckle of right middle finger slightly enlarged** (pen-callus), thin comma-shaped white scar at web of left thumb, cool skin (bluish-gray highlights)
- **KNUCKLE-DARKENING TELL:** both hands' knuckles render faintly darker than surrounding skin — "newsprint bleeding through thin paper." Load-bearing. Specify as shadow-under-skin at joints in every hand close-up.
- **Signature clothing — dove-gray wool crewneck sweater, HEX #A8A9A1 (locked, non-negotiable).** White undershirt visible at collar. Dark charcoal cotton trousers. Worn leather belt. Resoled black leather shoes. Cold-scene overcoat: navy wool, single-breasted, collar stiff.
- Skin palette: cool ivory base (HSL ~30°, 12% sat, 85% light), shadows cool blue-gray. NEVER warm-bronze. NO lantern-warming on skin.
- Palette discipline: NO red, NO gold, NO chromatic accents, NO patterns, NO jewelry, NO brand marks, NO modern-2003+ items.

**Art direction anchor — include verbatim in prompt notes for every LI artist/contractor:**
> *"his body is a thin paper laid over a door. Render the paper first. Let the door show at the joints."*

**SHADOW TELL — surgical spec** (for scenes 5, 8, 10, and intimate CG):
- Shadow on wall: **carved stone lintel outline (石库门门头)** — wider than man-shadow, two symmetric vertical divisions where arms cast, carved arc at top. NOT a photo of a door — the OUTLINE.
- Light angle for visibility: 30°–60° off body, low-to-mid. Overhead light or flat frontal light hides it.
- On the ground: flattened, door-frame squares off, looks like a threshold laid on stones.

---

### Prompt 13 — LI 4-view character sheet — 1216×832 — **v2 (post-redesign)**

**Asset:** Base character reference. Four poses in one frame (front / 3-quarter / side / back). Standard outfit. No shadow tell visible (neutral light angle). Do NOT render the door-shadow in this asset — reference sheet lighting must be flat so the face captures the man, not the door.

**Redesign note (2026-04-18):** v1 came out too visually similar to MC. v2 adds **grey-green eyes, thin wire-rim glasses, light stubble, mid-ear hair length, slightly broader shoulders, and visible stoop** — all differentiators from MC while staying within bible §15 guardrails. W2 LI bible §3 has been updated to match.

**Method:** ComfyUI + LoRA stack. NO IP-Adapter (this IS the identity source).

**Positive (v2, differentiation-heavy):**
```
character sheet, four view, turnaround, multiple views, same character, front view, three quarter view, side view, back view, 1boy, solo, handsome east asian man, (31 years old:1.3), (mature adult man early 30s:1.3), subtle worn features, lived in face, not bishounen boy, not shonen protagonist, not teenager, tall lean, (slightly broader shoulders not narrow:1.3), shoulders broader than a slim protagonist, long limbs, 183cm tall, (visible slight stoop:1.3), weight sits low, posture of quiet tired man, (jet black hair:1.4), (pure black hair not brown:1.3), (hair reaching mid ear length:1.3), slightly longer than short but still mature cut, hair parted on left, 1990s Shanghai men's haircut not K-pop idol, hair one tonal step sharper rendered than skin, (thin wire rim reading glasses:1.5), (oval slight square 1990s style glasses:1.4), silver or dark metal thin frames, clear lens, NOT rimless NOT chunky acetate NOT round John Lennon NOT aviator NOT modern trendy, (pale grey green eyes:1.5), (grey iris with green undertone:1.4), cool grey green eye color, darker outer ring around iris, pupils slightly dilated, not brown eyes not blue eyes, almond shaped eyes tilted up at outer corner, long lashes, quiet gaze, mature observing still expression, eyes fully open and alert, visible iris visible pupils, (light five o clock shadow stubble:1.4), (soft stubble on jaw and upper lip:1.3), lived in adult face, not clean shaven not beard, cheekbones visible, clean jawline, long oval face, mouth closed relaxed, hands visible at sides or in trouser front pockets thumbs out, long fingers visible, (knuckles slightly darker than surrounding skin:1.3), subtle shadow at finger joints, newsprint bleeding through thin paper effect at knuckles, (cool ivory skin tone:1.3), no warm undertone, not tanned, (dove gray wool crewneck pullover sweater hex A8A9A1:1.6), (pullover no buttons no open front:1.5), (closed neckline sweater:1.4), unsaturated dove gray pullover, crew neck ribbed collar, slightly pilled elbow, (white undershirt collar visible peeking at neck:1.3), white cotton shirt collar underneath sweater at neckline only, NOT turtleneck, NOT cardigan, NOT zip up, (dark charcoal cotton trousers:1.3), pale worn leather belt, resoled black leather shoes, 1990s Shanghai residential men's wear, softened worn quality fabric, no jewelry, no rings, no watches, no patterns on clothing, no brand logos, no modern items, no floating birds, no decorative elements, no animals in frame, neutral flat even studio lighting, no directional shadow, white clean background, model sheet, reference sheet, anime illustration, korean manhwa style, chinese manhua style, muted color palette, very low saturation, cool palette, masterpiece, best quality, highres, detailed face, detailed open grey green eyes, detailed glasses, detailed hands, detailed knuckles, good anatomy, good proportions
```

**Negative (v2, heavy counter-prompts for known failure modes):**
```
lowres, bad anatomy, bad hands, bad proportions, extra fingers, missing fingers, fused fingers, malformed limbs, extra limbs, text, watermark, signature, error, worst quality, low quality, blurry, deformed, ugly, censored, mosaic, female, girl, woman, breasts, chibi, child, shota, western medieval armor, halo, wings, horns, devil tail, flashy robes, long flowing robes, (red eyes:1.5), glowing red eyes, (gold eyes:1.5), glowing gold eyes, silver butterflies, dice, bone flute, sword, gun, modern branding, brand logo, logo text, visible logo, tattoo, piercings, makeup, heavy eyeshadow, lipstick, (any jewelry:1.5), necklace, earrings, dangling earring, (rings on fingers:1.5), any ring visible, (wristwatch:1.4), smartwatch, LED watch, bracelets, bright neon colors, saturated colors, gaudy, overdesigned, frilly, lace, sequins, glitter, sparkles, floating particles, floating birds, doves in frame, flying birds, decorative animals, magical aura, energy effects, manga panel, speech bubble, chromatic aberration, short legs, stubby legs, fat, chubby, muscular body, bodybuilder, bara, crop cut off, head cut off, feet cut off, young boy, teenager, teen, boy, youthful baby face, childish face, smooth perfect youthful skin, anime shonen protagonist, generic pretty boy, (K-pop idol hair:1.4), modern K-pop style, trendy hairstyle, undercut, man bun, (age 20:1.3), (age 25:1.2), bishounen boy, clean shaven, no stubble, closed eyes, eyes shut, sleeping face, squinting, slit eyes, no visible iris, (brown eyes:1.5), (dark brown eyes:1.5), (black eyes:1.4), brown iris, dark iris, blue eyes, teal eyes, cyan eyes, (hazel eyes:1.4), amber eyes, colored contacts, brown hair, chestnut hair, auburn hair, light hair, (silver hair:1.5), (white hair:1.5), gray hair color on head, (warm bronze skin:1.5), (tanned skin:1.5), (orange skin:1.4), warm undertone, sun kissed, flushed cheeks warm, red clothing, gold clothing, yellow clothing, (patterned clothing:1.4), floral clothing, embroidery, striped clothing, plaid clothing, modern hoodie, t-shirt, jeans, casual modern sneakers, flip flops, (shadow on wall:1.5), (door shadow:1.5), (lintel shadow:1.5), any cast shadow visible, directional side lighting, dramatic lighting, (cardigan:1.6), (cardigan open:1.5), (open front garment:1.5), (V-neck with buttons:1.4), button up front, zippered sweater, zip up hoodie, (turtleneck:1.5), high neck turtleneck, polo neck, cowl neck, modern 2020s clothing, contemporary casual wear, rimless glasses, chunky acetate glasses, thick frame glasses, round John Lennon glasses, aviator glasses, sunglasses, tinted glasses, colored lens glasses, modern trendy glasses, rose gold frames, full beard, goatee, mustache alone, long beard, stubble on chin only
```

**LoRA stack:** niji 0.70/1.00 + magical-ahjussi 0.80. No thick-paint.

**Sampler:** POC defaults (28 / 5.0 / euler_ancestral / normal / 1.00).

**Resolution:** 1216 × 832 render → native for reference use.

**Seed:** _____________ (fill after lock)

**IP-Adapter:** OFF (this IS the base reference).

**Expected v1 failure modes to counter** (from first gen attempt — image failed on all these):
- Cardigan rendered instead of pullover → heavy `(cardigan:1.6)` negative
- Beige/cream instead of dove gray → `(hex A8A9A1:1.6)` positive
- Turtleneck underneath instead of white shirt collar → `(turtleneck:1.5)` negative
- Floating decorative doves (model hallucination) → `floating birds, doves in frame` negative
- Face too similar to MC → eye color shift (grey-green) + glasses + stubble + hair length differentiation

**Iteration notes (v2-specific):**
- **Grey-green eyes land subtle** — pale grey iris with green undertone, darker outer ring. If eyes render blue or bright green or hazel-warm, push `(pale cool grey green eyes:1.6), muted grey green iris`.
- **Glasses are non-negotiable** — thin wire-rim, NOT chunky. If rimless or modern frames render, push `(thin wire rim glasses:1.6), 1990s silver thin metal frames`.
- **Stubble must be LIGHT** — not full beard, not clean shaven. Push `(light stubble:1.4), soft facial hair, not beard, not clean shaven`.
- **Pullover NOT cardigan** — most likely failure mode. If open-front renders, regenerate.
- **Dove gray #A8A9A1** — unsaturated cool grey (between cool-charcoal and warm-stone). If beige/cream/blue, push hex harder.
- **Mid-ear hair length** differentiator — LI has slightly longer than MC's short cut. If hair renders identical to MC, push `(hair reaching mid ear:1.4), slightly longer hair than MC`.
- **Broader shoulders** differentiator — not MC's concave-narrow. Push `(broader shoulders:1.4), substantial shoulders not narrow` if rendering matches MC's frame.
- **Visible stoop** — slight slouch through posture. The bible's "stoops through doorways" made literal.
- Reject outputs where: face reads identical to MC, hair K-pop-idol styled, cardigan instead of pullover, any ring/watch/jewelry, any warm/bronze skin cast, any red/gold eye register, any floating decorative elements.

**Canonical LI clothing spec (v2-updated, anchor for all downstream LI prompts):**
- **Sweater:** dove-gray wool crewneck PULLOVER, hex #A8A9A1, slightly pilled elbow (NOT cardigan, NOT open front, NOT zippered)
- **Underneath:** white cotton undershirt, collar visible at neck only (NOT turtleneck, NOT full button-up oxford)
- **Trousers:** dark charcoal cotton
- **Belt:** pale worn leather
- **Shoes:** resoled black leather
- **Glasses:** thin wire-rim silver/dark metal, oval-slight-square, clear lens
- **Facial hair:** light 5-o'clock shadow stubble (soft, not beard)
- **Accessories:** NONE — no ring, no watch, no bracelets, no necklace, no earrings

---

### Prompt 14 — LI Expression: observing-still (default) — 1024×1024

**Asset:** Default register. Hands-in-pockets tenant-posture. Most-used expression across scenes 5–8 before intimacy.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, close up portrait, bust shot, looking at viewer, steady quiet gaze, observing still expression, mature quiet presence, eyes arrive half beat late slight focus delay, pupils slightly dilated subtle soft iris edge, dark brown almost black almond eyes tilted up at outer corner, black hair slightly overgrown parted on left, hair one tonal step sharper than skin, neutral lips closed relaxed, slight natural expression, no smile, no frown, cool ivory skin, no warm undertone, dove gray wool crewneck sweater hex A8A9A1, white undershirt collar visible, soft ambient lighting cool neutral tone, flat front lighting no directional shadow, stone gray background, shallow depth of field, anime illustration, korean manhwa style, chinese manhua style, muted cool palette, very low saturation, masterpiece, best quality, highres, detailed face, detailed eyes, subtle iris
```

**Negative:** shared + close-up + LI-specific + `warm bronze skin, orange skin, tan skin, warm lighting on skin, lantern warming skin, red cast, gold cast, shadow on wall visible, door shadow`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.78.

**Iteration notes:**
- The gaze-delay tell is the hardest LI feature. Emphasize `pupils slightly dilated, iris edge softly blurred, gaze slightly defocused, eyes arrive a half beat late`. If the eyes look perfectly sharp-focused (the model default), drop IP-Adapter to 0.72 and double the delay tags.
- Skin cool — if warm lantern light bleeds onto skin, add `cool skin tone preserved even in warm light, skin does not warm under lantern` and regenerate.

---

### Prompt 15 — LI Expression: half-smile (warm-without-teeth, "surprised by fondness") — 1024×1024

**Asset:** The rare register. One of maybe three scenes in Ch1 where his face warms. Closed-lip half-smile, corner of mouth just lifted, eyes gently warmer than baseline.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, close up portrait, bust shot, subtle half smile, closed mouth smile, one corner of lips softly lifted, surprised by fondness expression, gentle quiet warmth, eyes softened not crinkled, still observing still, gaze still slightly delayed, dark brown almost black almond eyes tilted up, black hair slightly overgrown parted on left, cool ivory skin, dove gray wool crewneck sweater hex A8A9A1, white undershirt collar visible, soft warm lamplight from side but skin stays cool, muted tones, shallow depth of field, anime illustration, korean manhwa style, chinese manhua style, very muted cool palette, masterpiece, best quality, highres, detailed face, detailed eyes, subtle expression, delicate
```

**Negative:** shared + close-up + LI-specific + `open mouth smile, teeth showing, grin, laughing, cheesy smile, warm skin glow, sun kissed`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.78.

**Iteration notes:**
- "Surprised by fondness" — the expression of a man who has not smiled in a while and just found himself doing it. If the smile reads confident or practiced, regenerate.
- Eyes do not crinkle heavily. The warming is in the mouth-corner and the soft eyes, not in visible laugh-lines.

---

### Prompt 16 — LI Expression: pale-after-sacrifice (Scene 8 荒鸡) — 1024×1024

**Asset:** After settling the 荒鸡. Paleness increased, slight cost-on-body, slower focus than baseline. Still observing-still register but visibly spent.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, close up portrait, bust shot, looking at viewer with slower late focus, eyes arrive clearly delayed, pupils dilated softer iris, subtle exhaustion in eyes, pale cool ivory skin slightly paler than usual, faint bluish undertone in shadows, hollow subtle tiredness under eyes, lips slightly pale, mouth closed relaxed, black hair slightly overgrown parted on left, dove gray wool crewneck sweater hex A8A9A1, white undershirt collar visible, cool dim lantern light from side warm color but skin does not warm, shadow on side of face cool blue gray, stone background dim, shallow depth of field, anime illustration, korean manhwa style, chinese manhua style, very muted cool palette, masterpiece, best quality, highres, detailed face, detailed eyes, subtle exhaustion
```

**Negative:** shared + close-up + LI-specific + `sick, ill, dying, zombie, skeletal, gaunt, pale blue skin, cyanotic, horror palette, warm glowing skin, healthy flush, energetic`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.75.

**Iteration notes:**
- Paleness: ONE tonal step below baseline LI. Not corpse-pale. Not sick-pale.
- Focus delay is MORE pronounced than in default LI — the cost on his body is legible in slower eyes.
- If the model leans into horror register, dial back: remove `pupils dilated` and use `soft focus in gaze, slightly defocused`.

---

### Prompt 17 — LI Expression: aftercare-present (Scene 9 end — folding cloth) — 1024×1024

**Asset:** Scene 9 aftercare. "Attention-without-demand." The expression of a man folding a cloth ten times to give MC something his hands can eventually want to take.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, close up portrait, bust shot, looking down slightly toward hands, gentle focused expression, no demand in face, quiet attentiveness, neutral relaxed mouth, eyes lowered soft, long lashes visible, hair slightly disarrayed from earlier, parted on left, dove gray sweater slightly rumpled at shoulder, white undershirt collar slightly askew, cool ivory skin, warm where implied earlier contact, cool low lamplight from one side, warm amber bulb faint, muted intimate atmosphere, tender aftermath register, anime illustration, korean manhwa style, chinese manhua style, very muted palette, masterpiece, best quality, highres, detailed face, detailed eyes, delicate expression
```

**Negative:** shared + close-up + LI-specific + `aroused, sultry, seductive, smirk, confident smile, predatory, possessive, looking directly at viewer intensely`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85**.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.72.

**Iteration notes:**
- "Attention without demand" (W2 LI §8). The expression is **not** post-sex afterglow. It is post-give-care, pre-dawn. Subtle difference. If the model leans sensual, add `no romantic intent in expression, quiet caregiving, paternal care not romantic`.
- Hair slightly mussed. Sweater slightly rumpled. He has been in the scene; the body shows a little.

---

### Prompt 18 — LI Expression: intimate-close (Scene 9 shadow-on-skin variant) — 1024×1024

**Asset:** Scene 9 close-up. The lantern angle catches correctly — the door-shadow falls across his face / collarbone. For use as a gallery bust crop of the intimate CG.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, close up portrait, shoulders and neck visible, looking slightly off camera downward, intimate quiet expression, lips slightly parted, dark brown almond eyes tilted up, softly focused gaze, black hair slightly overgrown mussed, parted on left, bare collarbone visible, dove gray sweater pushed down on one shoulder or off shoulder, white undershirt collar askew, cool ivory skin, knuckle darkening tell visible on hand near neck, hand resting near collarbone with subtle shadow under finger joints, low warm lantern light from 45 degree side angle, cool shadow on opposite side of face, stone lintel door shadow subtly falling across collarbone and upper chest, carved arc outline visible faintly on skin, door frame outline barely legible, intimate atmosphere, muted warm lamplight, anime illustration, korean manhwa style, chinese manhua style, very muted palette, painterly texture, masterpiece, best quality, highres, detailed face, detailed eyes, detailed collarbone, detailed hand
```

**Negative:** shared + close-up + LI-specific + `explicit nudity below shoulder, full naked body, penis, pubic hair, aggressive shadow obscuring face, pitch black background, horror lighting`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85**.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.72.

**Iteration notes:**
- **Shadow tell on skin** — the lintel outline lightly on the collarbone/sternum area. Must be legible to a careful viewer, not obvious to a casual one. Iterate light angle tags if shadow disappears or dominates.
- Knuckle-darkening on the hand near the neck — "newsprint bleeding through paper."
- **PG18 register.** Off-shoulder sweater + bare collarbone. No explicit frame below chest.

---

### Prompt 19 — LI Expression: 辛苦侬了-stillness (Scene 9 fracture) — 1024×1024

**Asset:** The half-second after he hears himself say the Shanghainese phrase. He has not said it in decades. Expression: observing-still but one degree too still — a man arrested mid-sentence by his own voice.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, close up portrait, bust shot, looking at viewer but arrested mid expression, unnaturally still face, subtle shock under surface, lips parted just slightly as if sentence still completing, eyes held open unnaturally steady, tiny microexpression of recognition, faintly caught off guard, dark brown almost black almond eyes tilted up, pupils still slightly dilated, black hair slightly overgrown parted on left mussed slightly, dove gray wool sweater slightly disarrayed, white undershirt collar visible, cool ivory skin, intimate low warm lamplight, shadow on opposite side of face cool, muted intimate tones, painterly texture, anime illustration, korean manhwa style, chinese manhua style, very muted cool palette, masterpiece, best quality, highres, detailed face, detailed eyes, microexpression, delicate expression
```

**Negative:** shared + close-up + LI-specific + `overt shock, dramatic gasp, wide eyes, open mouth gasp, theatrical, obvious emotion, sad, crying, angry, distressed`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85**.

**Sampler:** POC defaults.

**Resolution:** 1024 × 1024.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.75.

**Iteration notes:**
- **"Goes very still"** (W2 LI §4). The stillness is the emotion — if the face is doing anything visibly, it's wrong.
- The mouth-parted detail is the only tell that a sentence just escaped him. If the model closes the mouth, add `lips slightly parted, mouth slightly open as if word just left` but resist theatrical gasp.
- Hardest LI expression. Plan for 10–15 iteration attempts before locking.

---

### Prompt 20 — LI Sprite: half-body, dove-gray sweater, hands in pockets — 832×1216, transparent BG

**Asset:** Primary LI sprite. Observing-still. Used across scenes 5, 6, 7, 11.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, half body portrait, waist up, standing upright slight stoop, facing three quarter toward viewer, hands in trouser front pockets thumbs out, 1990s men's casual posture, shoulders relaxed downward, observing still expression, quiet gaze, eyes slightly delayed focus, black hair slightly overgrown parted on left, dark brown almost black almond eyes, cool ivory skin, dove gray wool crewneck sweater hex A8A9A1, sweater slightly pilled at elbow visible, white undershirt collar visible, dark charcoal cotton trousers waistband visible at waist, pale worn leather belt slight glimpse, soft flat lighting, no directional shadow, transparent background, isolated character, anime illustration, korean manhwa style, chinese manhua style, very muted cool palette, masterpiece, best quality, highres, detailed face, detailed eyes, detailed hands, clean edges for alpha
```

**Negative:** shared + full-body + LI-specific + `background, scenery, shadow on wall, door shadow`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 832 × 1216, transparent BG.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.78.

**Iteration notes:**
- Hands in FRONT pockets, thumbs out. This is a specific 1990s-Shanghai-man posture per W2 LI §13. Not side pockets, not back pockets, not crossed arms.
- Weight on left leg slightly more than right. If the model produces a model-runway wide stance, add `weight on left leg, contrapposto minimal, natural stance`.
- No cast shadows in sprite — sprite must composite against any BG cleanly. Shadow tell is reserved for key CGs.

---

### Prompt 21 — LI Sprite: half-body, turned-toward-MC (Scene 5 doorway first-look) — 832×1216, transparent BG

**Asset:** Scene 5 first-look sprite. LI in the 天井 doorway, just turned toward MC. Half-turn posture. No shadow tell yet (light is wrong in this scene per W2 LI §3).

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, half body portrait, waist up, half turned body facing three quarter, just turned toward viewer, head turned first then body following half beat later, quiet recognition expression, observing still, eyes slightly delayed focus, black hair slightly overgrown parted on left, cool ivory skin, dove gray wool crewneck sweater hex A8A9A1, white undershirt collar visible, dark charcoal trousers, one hand at side one hand resting on doorframe edge just visible, knuckle slightly darker than skin subtle tell, soft flat overhead lantern lighting from above hides lintel shadow, transparent background, isolated character, anime illustration, korean manhwa style, chinese manhua style, muted cool palette, masterpiece, best quality, highres, detailed face, detailed eyes, detailed hand
```

**Negative:** shared + full-body + LI-specific + `background, shadow on wall, door shadow, side lighting, dramatic angle, directional shadow, warm glow on skin`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 832 × 1216, transparent BG.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.78.

**Iteration notes:**
- Half-turn: body 30° away, head turned back. The gaze-delay tell is compounded — head turns first, body catches up a half-beat later. If static art cannot render motion, suggest it with body-shoulder axis misaligned from head axis.
- Overhead light only — this is the scene where the shadow tell is HIDDEN (per W2 LI §3). Do not let any 45°-side-lighting bleed in.

---

### Prompt 22 — LI Sprite: navy overcoat layered over sweater (cold 天井 variant, Scene 8 / 10) — 832×1216, transparent BG

**Asset:** Cold-scene LI. Navy wool overcoat over the dove-gray sweater. Collar of overcoat too stiff to sit flat. Hands in overcoat pockets.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, half body portrait, waist up, standing, slight stoop, facing three quarter, hands in overcoat front pockets, navy wool single breasted overcoat, overcoat collar stiff not sitting flat, collar slightly propped up awkwardly, dove gray wool crewneck sweater hex A8A9A1 visible at opening of overcoat, white undershirt collar visible above sweater, dark charcoal trousers visible below overcoat hem, late 1990s Shanghai menswear silhouette, observing still expression, eyes slightly delayed focus, black hair slightly overgrown parted on left, cool ivory skin, cold cheek color subtle faint chill, cold atmosphere breath does not fog, cool flat lighting dim lantern ambient, transparent background, isolated character, anime illustration, korean manhwa style, chinese manhua style, very muted cool palette, masterpiece, best quality, highres, detailed face, detailed eyes, detailed overcoat collar, detailed fabric
```

**Negative:** shared + full-body + LI-specific + `background, breath fog visible, visible exhale, warm atmosphere, modern coat, parka, down jacket, trench coat, belted coat, double breasted, brass buttons prominent, visible large buttons metallic`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80.

**Sampler:** POC defaults.

**Resolution:** 832 × 1216, transparent BG.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.78.

**Iteration notes:**
- **No breath fog.** Critical subtler tell per W2 LI §3 — his breath does not fog even in cold. If steam/fog renders, hard-reject.
- Overcoat collar stiff — do not let the model fold it flat. "Too stiff to sit flat" is the register.
- Cheek color: very faint chill (one notch of pale pink-blue), NOT ruddy warmth. Cool skin remains cool even at the margins.

---

### Prompt 23 — LI Key CG #1: First look in 天井 doorway (Priority CG #2, Scene 5) — 1216×832

**Asset:** CN-anchor key art candidate #2. LI in 天井 doorway backlit, MC's POV. Composition foreshadows the shadow tell — hint of lintel-shape on doorway stone behind him, but NOT legible on first pass. Landscape.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, full body three quarter view, standing in shikumen stone doorway, dove gray wool crewneck sweater hex A8A9A1, dark charcoal trousers, black leather shoes resoled, cool ivory skin, black hair parted on left, observing still expression, eyes slightly delayed focus, MC POV composition from viewer toward LI in doorway, 天井 stone courtyard behind viewer implied, stone doorframe behind character, carved stone lintel subtle above head shoulders visible faintly in shadow, carved arc at top of lintel barely legible, 1920s Shanghai shikumen stone lintel detail, muted interior gloom behind character, faint lantern backlight creating rim light on hair, overhead lantern light flat on face hiding directional shadow, cool ambient light in courtyard, warm amber lantern light behind, muted palette, cool neutral tones dominate, anime illustration, korean manhwa style, chinese manhua style, very muted cool palette, key art composition, cinematic framing, masterpiece, best quality, highres, detailed face, detailed stone texture, detailed environment
```

**Negative:** shared + full-body + LI-specific + `clear door shadow on wall, obvious lintel shape on wall, legible door outline, dramatic cast shadow, spooky horror lighting, red lantern prominent, neon, modern doorway`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85** (key CG — painterly).

**Sampler:** POC defaults.

**Resolution:** 1216 × 832 render → 1920 × 1080 upscale.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.72 (lower — full-scene CG).

**Iteration notes:**
- **Shadow tell must be present but not legible on first view.** A carved lintel outline behind him in the stone architecture, shaped like the shadow-tell motif — but rendered AS the stone itself, not as a shadow. On re-playthrough, viewers will decode that the doorframe behind him matches the shape he casts in scene 8.
- Backlit rim light on hair — warm amber. Face lit by overhead lantern (flat, non-revealing).
- Foreshadowing is the point — the image must READ as mysterious-stranger-in-doorway on first pass.

---

### Prompt 24 — LI Key CG #2: The shadow on the wall (Priority CG #3, Scene 8) — 1216×832

**Asset:** THE key CG. CN-reader anchor moment. LI's back with left palm flat on interior of 石库门 stone lintel, lantern-light angle 30–60° catches him right, **the 门头 shadow rendered CLEARLY on the wall behind him.** Non-negotiable fidelity. This image must survive as key marketing art.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature body, back view toward viewer, standing slightly from viewer, left palm flat pressed against interior stone lintel above, arm raised to shoulder height, body extended, dove gray wool crewneck sweater hex A8A9A1 from back, dark charcoal trousers, resoled black leather shoes, black hair slightly overgrown from back parted on left barely visible, cool ivory skin at hand and nape, long fingers of left hand flat on carved stone lintel, knuckles slightly darker than surrounding skin subtle newsprint bleeding effect, second knuckle on right middle finger slightly enlarged if visible, warm amber lantern light from 45 degree low side angle, critical 30 to 60 degree light angle, directional warm side lighting, shadow cast clearly on wall behind character, the shadow on wall is not a man shape but a carved stone lintel outline, shikumen door frame shadow, wider than shoulders shadow, two symmetric vertical door panel divisions in shadow, carved arc at top of shadow where head should be, 门头 石库门 lintel outline as shadow shape, stone carved threshold shadow crisp on wall, crisp legible shadow outline of doorway on wall behind him, 1920s Shanghai shikumen 天井 courtyard, stone lintel above palm carved arc lintel detail, dim cool ambient light in courtyard, cool blue gray shadows on his body opposite warm light, painterly texture thick paint, anime illustration, korean manhwa style, chinese manhua style, very muted cool palette with warm lantern accent, key art composition, cinematic dramatic framing, masterpiece, best quality, highres, detailed face if visible, detailed hand on stone, detailed stone carving, detailed shadow outline on wall, non negotiable shadow fidelity
```

**Negative:** shared + full-body + LI-specific + `shadow matches body shape, normal man shaped shadow, human silhouette shadow, shadow of arms and legs in wrong shape, chromatic effects, glowing shadow, supernatural aura, magical particles, red or gold lighting, neon`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85** (CN-anchor CG — fully painterly).

**Sampler:** POC defaults, **cfg 5.5** (slight bump — this CG needs prompt adherence locked, especially on the shadow).

**Resolution:** 1216 × 832 render → 1920 × 1080 upscale.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.70 (lower — back-view CG, face is minimal).

**Iteration notes:**
- **NON-NEGOTIABLE:** the shadow must be the carved stone lintel outline — wider than shoulders, two vertical door-panel divisions, carved arc at top. If the shadow resolves as a normal man-shape, HARD REJECT and regenerate. Plan for 20–40 iterations. This is the single hardest prompt in the pack.
- If the model refuses to render the shadow correctly, fallback plan: generate the character-on-wall base (no shadow or with placeholder shadow), then in post-production (Photoshop/Procreate) paint the correct lintel-shadow overlay manually. Document this as the fallback — Regina should not sink >1 hour trying to brute-force it prompt-only.
- If using ControlNet: generate a **reference shadow shape** (a doodled lintel outline at 30°-perspective) and use it as a ControlNet scribble/depth input to force the shadow shape. This is the most likely reliable path.
- Light angle MUST be 30°-60° from low side. Test with overhead light fallback — if shadow disappears, confirm angle is the fix.
- **Key marketing art.** Budget real time for this prompt. It is the one CN-reader viewers will pin and share.

---

### Prompt 25 — LI Key CG #3 (companion): 天井 under-the-window routine (Scene 10 setup) — 1216×832

**Asset:** Lower priority. LI standing under left 厢房 window looking up, arm's-length from wall, dawn-adjacent sky, grief-with-a-schedule pose register. Used as optional mood piece or scene 10 establishing CG.

**Positive:**
```
1boy, solo, bishounen, 31 years old, mature face, full body three quarter back view, standing under upper story window in stone courtyard, head tilted up looking at dark upper window, arms relaxed at sides, weight shifted to left leg, exactly arm's length from stone wall, quiet motionless posture, grief with a schedule pose register, dove gray wool crewneck sweater hex A8A9A1, dark charcoal trousers, resoled black leather shoes, black hair slightly overgrown parted on left, cool ivory skin, observing still eyes slightly delayed focus, 1920s Shanghai shikumen 天井 stone courtyard at dawn, dark empty upper story latticed window, stone wall textured behind him, faint 寅时 predawn sky above small framed patch of sky, rainwater vat subtly visible lower corner reflecting lanterns fading, cool blue dawn ambient light, faint warm lantern remnant in background, muted cool palette dominant, tender melancholy atmosphere, painterly texture thick paint, anime illustration, korean manhwa style, chinese manhua style, masterpiece, best quality, highres, detailed face if seen, detailed stone courtyard, detailed sky color transition
```

**Negative:** shared + full-body + LI-specific + `warm morning sunlight, bright sky, cheerful atmosphere, crowded scene, other people visible, bright window lit from inside, multiple windows lit`

**LoRA:** niji 0.70/1.00 + magical-ahjussi 0.80 + **thick-paint 0.85**.

**Sampler:** POC defaults.

**Resolution:** 1216 × 832 render → 1920 × 1080 upscale.

**Seed:** _____________

**IP-Adapter:** `li_faceref_v1.png` at 0.70.

**Iteration notes:**
- **Arm's length from the wall** (W2 LI §13 — 执念 tell made spatial). If the model puts him flush against the wall or far from it, correct via `exactly arm's length from wall, one arm distance between body and stone, specific spatial relationship`.
- Window dark — not lit from inside. A dead window. If the model lights it, hard-reject.
- Sky: 寅时 predawn, edges faintly bruising. Not blue-sky morning. Not night.

---

## 7. Post-generation workflow

### Upscaling (all assets)
- Node: `Ultimate SD Upscale` + `4x-UltraSharp.pth`
- Scale: **1.5×** (render resolution × 1.5 = final delivery resolution per the lock table)
- Tile size: 512, tile padding: 32, seam fix: band pass
- Denoise: **0.20** (enough for texture resolution, not enough to redraw faces)
- Steps per tile: 20, CFG 4.5, sampler euler_ancestral, scheduler normal
- For faces: run a second pass with `Face Detailer` node (BBOX: `face_yolov8m.pt`, SAM: `sam_vit_b_01ec64.pth`, denoise 0.35, prompt: the character's face tags only) — fixes face distortion introduced by tiling.

### Ren'Py import
- **Sprites (PNG with alpha):** name `mc_sprite_default.png`, `li_sprite_sweater.png`, etc. Drop in `game/images/characters/`. Reference as `image li_default = "characters/li_sprite_sweater.png"`.
- **BGs (JPG, quality 92):** name `bg_apartment_night.jpg`, `bg_tianjing_chou.jpg`, etc. Drop in `game/images/bg/`. JPG saves ~60% file size vs PNG at imperceptible quality loss for 1920×1080 BGs.
- **CGs (PNG, no alpha):** name `cg_scene08_shadow.png`, `cg_scene09_intimacy.png`, etc. Drop in `game/images/cg/`. Keep PNG — CGs are gallery pieces and need lossless.
- **Expression sheets (PNG, transparent if layered over sprite body, else no alpha):** name `exp_mc_crying_small.png`. If using Ren'Py's LayeredImage for expression swaps, export with alpha and mask to face region only.

### File naming conventions (LOCK)
- MC: `mc_<asset>_<variant>_v<N>.png` — e.g., `mc_expression_crying_v1.png`
- LI: `li_<asset>_<variant>_v<N>.png` — NEVER use the real name. `li_` prefix on everything.
- Seeds: append to filename when locked — `li_key_cg_shadow_v3_seed_3894201883.png`. This is the reproducibility contract.

---

## 8. When to regenerate vs use seed

### Use locked seed when:
- Expression or sprite needs a minor variant (e.g., adjust lighting, not the face). Lock the seed, change only the lighting tags. The face stays consistent.
- Producing a series of sprites for the same character — lock the base seed and iterate only the clothing/pose tags.
- Upscaling or post-processing a locked winning generation.

### Regenerate (new seed) when:
- The face is drifting across multiple generations at the same IP-Adapter strength. This indicates the base-model + LoRA chain is fighting the character, not the seed.
- A pose or lighting change is too dramatic for seed-locking to preserve. New scene = new seed is OK as long as IP-Adapter face reference holds.
- The prompt itself needs meaningful change (e.g., cold scene → warm scene). Lock the face ref, not the seed.

### Escalate to custom LoRA when:
- 5+ regenerations at IP-Adapter strength 0.80 still produce visible face drift.
- The character needs to appear in 20+ distinct scenes and IP-Adapter consistency is failing above ~15 generations.
- Two-character CGs (MC+LI) consistently bleed features between the two faces even with regional masking.

Custom LoRA training — per POC §5:
1. Collect 20–30 locked outputs where the face IS correct (front, 3-quarter, side, expression variants — not all identical poses).
2. Resize to 768×768 or 1024×1024, caption each (auto-caption with BLIP, then manually review — remove the character-defining tags from captions so the LoRA learns them as the default).
3. Train with `kohya_ss` via RunPod: rank 16, learning rate 1e-4, batch size 4, 10–15 epochs, resolution 768.
4. Training time: ~1 hour on RTX 4090.
5. Replace IP-Adapter with the custom LoRA in the stack. Drop IP-Adapter entirely. Face identity is now baked into the model chain.

---

## 9. Guardrail summary (the "never" list — confirm on every prompt)

From W2 LI §15 + MC §12, cross-referenced:

**LI-specific:**
- Never red eyes / gold eyes / glowing eyes
- Never long-flashy-robes / silver butterflies / bone flute / dice
- Never jewelry, watch, ring, brand marks
- Never patterned clothing, floral, embroidery
- Never modern (2003+) items visible
- Never warm-bronze skin / tanned / warm glow on skin
- Never name / name-hint in metadata or filename
- Dove-gray hex **#A8A9A1** appears in every LI clothing prompt
- Shadow tell: explicit door-frame-outline language in the positive prompt for scenes 8 + 9 + (foreshadowed in 5)

**MC-specific:**
- Ring is on **LEFT INDEX FINGER** only — never ring finger, never middle, never right hand
- Ring is **plain silver band** — small, ungendered, no ornament
- Never muscular/bara body
- Never red/gold/bright palette on clothing
- Age-up tags **always present** — he reads 29–30, not 24
- Eye-circles persist in every expression, including smiles
- Expression default is **mild attention** — not sad, not tired-stereotyped, not blank

**Shared:**
- PG18 register only — explicit intimacy CG allowed (scene 9) but no penetrative frames, no explicit genitalia, no censor-bar workarounds
- No Western-medieval-armor / halo / wings / horns
- No manga panels / speech bubbles / chromatic aberration
- No modern branding / logos / smartwatches / smartphones visible in period frames (phone only in scenes 1 and 13 — the boundary scenes)

---

## 10. Production sequencing (suggested order)

Week 1 — Base references:
1. MC 4-view (Prompt 1) → `mc_faceref_v1.png`
2. LI 4-view (Prompt 13) → `li_faceref_v1.png`

Week 2 — Expression + sprite sheets:
3. MC expressions × 6 (Prompts 2–7)
4. MC sprites × 3 (Prompts 8–10)
5. LI expressions × 6 (Prompts 14–19)
6. LI sprites × 3 (Prompts 20–22)

Week 3 — Key CGs (budget generous time for #24 — the shadow CG):
7. MC kitchen CG (Prompt 11)
8. MC anchor-degradation variant (Prompt 12)
9. LI doorway first-look CG (Prompt 23)
10. **LI shadow-on-wall CG (Prompt 24) — budget 2+ full sessions**
11. LI under-the-window CG (Prompt 25)

Week 4 — Intimacy CG + aftercare CG (separate doc — scope them per W3 §8 priority list 4 and 5; those are composition-heavy two-character scenes requiring regional masking and may want ControlNet pose references).

---

## 11. Appendix — Iteration discipline

- **Log every seed.** Keep a `seeds.md` in the art folder. Each entry: prompt number, date, seed, verdict (locked / reject / parent-for-LoRA-training).
- **Never delete rejected outputs for a week.** A reject today may be the best-available output next week if the pipeline shifts.
- **When a prompt produces wrong output 5+ times in a row:** stop. Re-read the W2 bible section for that character. Check whether a tag is fighting another tag (e.g., `age up` + `bishounen` can produce ambiguity — try `mature bishounen, 29 years old`). Check whether IP-Adapter strength is over-constraining a new expression.
- **Do not chase perfection on expression sheets.** "Good enough" at expression sheet is fine — the sprite + CG is where the character lives. Expression sheets are for UI swaps, not gallery pieces.
- **The shadow CG (Prompt 24) is the one exception** — budget real production time. It is the CN-anchor. Iterate until correct, or commit to ControlNet + manual post-production.
