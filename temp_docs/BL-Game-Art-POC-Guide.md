# BL Visual Novel — Art Pipeline POC Guide

## Goal
Prove we can generate consistent, high-quality PG18 BL male character art using AI. 

**POC Status: VALIDATED** — We successfully generated commercial-quality BL art using the pipeline below.

---

## Quick Summary (What Worked)

| Component | Choice | Why |
|-----------|--------|-----|
| Cloud GPU | RunPod RTX 4090 ($0.60/hr) | Fast, cheap, no local GPU needed |
| Base Model | Smooth Yaoi Boys v3.0 VPred | Purpose-built for BL/yaoi, 5-star rated |
| Style LoRA | Niji-male-style (86MB) | Clean handsome anime males, 544 upvotes |
| Character LoRA | Elia x Jino / Magical Ahjussi (218MB) | BL manhwa character style |
| UI | ComfyUI | Node-based, flexible, production-ready |
| Art Style | Anime (Korean/Chinese hybrid trend) | Best-selling style in BL game market |

**Total POC cost: ~RM15-25 for an afternoon of experimentation.**

---

## Part 1: RunPod Setup (30 minutes)

### Step 1: Create RunPod Account
1. Go to [runpod.io](https://runpod.io)
2. Sign up, add **$10 USD credits** (~RM45) — this gives you 10+ hours of GPU time

### Step 2: Set Up SSH Key (do this BEFORE deploying pods)
1. On your Mac terminal, check if you have a key: `cat ~/.ssh/id_ed25519.pub`
2. If not, generate one: `ssh-keygen -t ed25519 -C "your@email.com"`
3. Go to RunPod **Settings → SSH Public Keys**
4. Paste your public key and save
5. **Important:** SSH keys only get injected when a pod is CREATED. If you add the key after deploying, terminate and redeploy.

### Step 3: Create a Network Volume (persistent storage)
1. Go to **Storage → Network Volumes**
2. Create volume: **50 GB**, name: `bl-game-models`
3. Pick a region (EU-RO-1 is usually cheapest)
4. Cost: ~$3.50/month — keeps your models between sessions

### Step 4: Deploy a GPU Pod
1. Go to **Pods → Deploy**
2. Template: Search **"ComfyUI"** — use the official `runpod/comfyui:latest`
3. GPU: **RTX 4090 (24GB VRAM)** — ~$0.60/hr
4. Attach your network volume
5. Container disk: 100GB is enough
6. Click **Deploy On-Demand**
7. Wait 2-3 minutes for startup

### Step 5: Access ComfyUI
1. Click **Connect** on your pod
2. Click the **HTTP port 8188** link — opens ComfyUI in browser
3. Wait 1-2 mins if it doesn't load immediately

---

## Part 2: Download Models

### Option A: Download directly on RunPod (fastest)

Open **Web Terminal** from pod dashboard.

**Login to HuggingFace (one-time):**
```bash
pip install -q huggingface_hub
hf auth login --token YOUR_HF_TOKEN
```
Get a free token from [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

**Download Illustrious XL (base model — for testing):**
```bash
cd /workspace/runpod-slim/ComfyUI/models/checkpoints
hf download OnomaAIResearch/Illustrious-xl-early-release-v0 Illustrious-XL-v0.1.safetensors --local-dir .
```

**Note:** The ComfyUI path on RunPod's official template is `/workspace/runpod-slim/ComfyUI/` (not `/workspace/ComfyUI/`).

### Option B: Upload from your Mac via SCP

Find your pod's SSH details in the Connect panel. Then from your Mac terminal:

```bash
cd ~/Downloads

# Upload checkpoint
scp -P PORT -i ~/.ssh/id_ed25519 smoothYaoiBoys_v30Vpred.safetensors root@POD_IP:/workspace/runpod-slim/ComfyUI/models/checkpoints/

# Upload LoRAs
scp -P PORT -i ~/.ssh/id_ed25519 5byue5dnijistyleE291.cNux.safetensors root@POD_IP:/workspace/runpod-slim/ComfyUI/models/loras/
scp -P PORT -i ~/.ssh/id_ed25519 Elia_x_Jino__Magical_Ahjussi-000013.safetensors root@POD_IP:/workspace/runpod-slim/ComfyUI/models/loras/
```

Replace `PORT` and `POD_IP` with the values from your pod's SSH connection info.

---

## Part 3: Models to Download

### Base Models (pick one — goes in `models/checkpoints/`)

| Model | Source | Size | Notes |
|-------|--------|------|-------|
| **Smooth Yaoi Boys v3.0 VPred** (RECOMMENDED) | [Civitai /models/980679](https://civitai.com/models/980679/smooth-yaoi-boys) | 6.5GB | Purpose-built for BL/yaoi. 5 stars, 378 reviews. Best results for our use case. |
| Illustrious XL v0.1 | [HuggingFace](https://huggingface.co/OnomaAIResearch/Illustrious-xl-early-release-v0) | 6.9GB | General anime base model. Good but not BL-specific. |
| MALE-ggmix Illustrious | [Civitai /models/1652753](https://civitai.com/models/1652753/male-ggmix-illustrious) | 6.5GB | Male-focused anime checkpoint. |

### LoRA Models (stack on top — goes in `models/loras/`)

| Model | Source | Size | Notes |
|-------|--------|------|-------|
| **Niji-male-style** (RECOMMENDED) | [Civitai /models/1028032](https://civitai.com/models/1028032/niji-male-style) | 86MB | Handsome anime males, Niji aesthetic. 154K+ generations, very popular. Strength: 0.6-0.7 |
| **Elia x Jino / Magical Ahjussi** | [Civitai /models/1802942](https://civitai.com/models/1802942/elia-x-jino-or-magical-ahjussi) | 218MB | BL manhwa character LoRA. Illustrious compatible. Strength: 0.8 |
| Nijij Thick Paint Male Style | [Civitai /models/1051777](https://civitai.com/models/1051777/nijij-thick-paint-male-style) | 218MB | Painterly CG style. Great for key romantic scenes. Strength: 0.8-1.0 |
| Semi-Detailed Anime Males | [Civitai /models/1477529](https://civitai.com/models/1477529/semi-detailed-anime-males) | — | Better male anatomy and proportions |
| Manhwa Artstyle / Webtoon | [Civitai /models/257995](https://civitai.com/models/257995/manhwa-artstyle-or-webtoon-or-lora) | — | Korean manhwa/webtoon style |
| GameCG Style Alicesoft | [Civitai /models/1174730](https://civitai.com/models/1174730/gamecg-cg-style-alicesoft) | — | Visual novel CG aesthetic |

### BL Male Character LoRA Lists (browse for more)
- [Part 1: Anime/Cartoon Characters](https://civitai.com/articles/5581/mature-masculine-male-characters-lora-list-part-1-wip)
- [Part 2: Game Characters](https://civitai.com/articles/5975/mature-masculine-male-characters-lora-list-part-2-wip)
- [Part 3: BL/Yaoi/Otome Characters](https://civitai.com/articles/9796/mature-masculine-male-characters-lora-list-part-3-wip) (need Civitai login)

---

## Part 4: ComfyUI Workflow Setup

### Node Setup (build this manually)

Create these nodes and connect them in order:

```
Load Checkpoint → Load LoRA → CLIP Text Encode (positive) → KSampler → VAE Decode → Save Image
                            → CLIP Text Encode (negative) ↗
                  Empty Latent Image ↗
```

**Wiring:**
1. Load Checkpoint `MODEL` → Load LoRA `model`
2. Load Checkpoint `CLIP` → Load LoRA `clip`
3. Load Checkpoint `VAE` → VAE Decode `vae`
4. Load LoRA `MODEL` → KSampler `model`
5. Load LoRA `CLIP` → CLIP Text Encode (positive) `clip`
6. Load LoRA `CLIP` → CLIP Text Encode (negative) `clip`
7. CLIP Text Encode (positive) `CONDITIONING` → KSampler `positive`
8. CLIP Text Encode (negative) `CONDITIONING` → KSampler `negative`
9. Empty Latent Image `LATENT` → KSampler `latent_image`
10. KSampler `LATENT` → VAE Decode `samples`
11. VAE Decode `IMAGE` → Save Image `images`

### Settings

**Load Checkpoint:** `smoothYaoiBoys_v30Vpred.safetensors`

**Load LoRA:** `5byue5dnijistyleE291.cNux.safetensors` (Niji style), strength_model: 0.70, strength_clip: 1.00

**KSampler:**
| Parameter | Value |
|-----------|-------|
| steps | 28 |
| cfg | 5.0 |
| sampler_name | euler_ancestral |
| scheduler | normal |
| denoise | 1.00 |
| control after generate | randomize |

**Empty Latent Image:**
| Aspect | Width | Height | Use Case |
|--------|-------|--------|----------|
| Landscape | 1216 | 832 | Two-character scenes, CGs |
| Portrait | 832 | 1216 | Single character, full body |
| Square | 1024 | 1024 | Close-up faces, busts |

### Example Prompts

**Positive (two-character BL scene):**
```
2boys, yaoi, couple, bishounen, black hair boy and silver hair boy, handsome, detailed face, detailed eyes, anime illustration, slim, tall, muscular, attractive, bare chest, shirtless, intimate, romantic, embracing, bedroom, soft lighting, blushing, eye contact, masterpiece, best quality, highres
```

**Positive (single character, full body):**
```
1boy, solo, bishounen, black hair, blue eyes, tall, slim, handsome, detailed face, detailed eyes, anime illustration, white shirt, black pants, standing, full body, long legs, good proportions, warm lighting, cafe background, masterpiece, best quality, highres
```

**Positive (single character, expressions — change the expression tags):**
```
1boy, solo, bishounen, black hair, blue eyes, sharp jawline, handsome, detailed face, detailed eyes, anime illustration, [EXPRESSION], [SCENE], upper body, masterpiece, best quality
```
Expression options: `smiling, happy expression` / `sad expression, teary eyes` / `blushing, embarrassed` / `serious expression` / `angry expression`

**Negative (use for all):**
```
lowres, bad anatomy, bad hands, text, error, worst quality, low quality, blurry, deformed, ugly, extra limbs, female, girl, censored, censor bar
```

**Additional negative for full body shots:**
```
chibi, short legs, bad proportions, fat, chubby
```

---

## Part 5: Character Consistency (Next Steps)

### IP-Adapter (face-locking)
Install on RunPod terminal:
```bash
cd /workspace/runpod-slim/ComfyUI/custom_nodes
git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git
cd ComfyUI_IPAdapter_plus && pip install -r requirements.txt
```
Use IP-Adapter FaceID Plus v2 with weight 0.7-0.8 and a reference image to keep the same face across different scenes.

### Custom LoRA Training (production pipeline)
- Artist draws 50-100 reference images per character
- Train with kohya_ss: 10-20 epochs, learning rate 1e-4 to 5e-5, batch size 4
- Training time: 1-2 hours on RTX 4090
- Output: custom LoRA that generates YOUR characters consistently

### Animation (subtle CG motion)
```bash
cd /workspace/runpod-slim/ComfyUI/custom_nodes
git clone https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved.git
```
Generates 2-3 second animated loops (breathing, hair movement, blinking) from static CGs.

---

## Part 6: Cost Summary

| Item | Cost |
|------|------|
| RunPod RTX 4090 (per hour) | ~$0.60 (~RM2.70) |
| Network volume 50GB (per month) | ~$3.50 (~RM15) |
| All models & software | Free (open source) |
| Civitai LoRAs | Free |
| HuggingFace account | Free |
| **Typical POC session (4 hours)** | **~$6 (~RM27)** |

---

## Part 7: Market Context

- BL/otome games market: ~$5.69B (2025), growing at 9.27% CAGR
- Core audience: women 18-34, high payer conversion
- Art style that sells: anime (Korean/Chinese hybrid trending — Love and Deepspace made $100M+)
- Monetization: gacha, episodic content, subscriptions
- Platforms: Steam (PC leads at 55%), itch.io, mobile

---

## Part 8: Legal Structure (Malaysia)

- Register company in Singapore (business-friendly, tax treaty with Malaysia, permissive on adult content)
- Malaysian developers work as freelancers for the Singapore entity
- Must declare worldwide income to Malaysian IRB
- Consult a Malaysian tax accountant before structuring
- Steam and itch.io both accept adult content with proper tagging

---

## What's Next

1. [x] Art pipeline POC — VALIDATED
2. [ ] Test LoRA combinations for optimal BL art style
3. [ ] Artist creates character sheets for custom LoRA training
4. [ ] Train custom LoRAs for game-specific characters
5. [ ] Set up IP-Adapter for face consistency across scenes
6. [ ] Adapt Rho framework for relationship simulation engine
7. [ ] Build demo: one route, one love interest, ~2hrs gameplay
8. [ ] Launch free demo on itch.io
9. [ ] Validate demand with BL community

---

## Team Roles

| Role | Responsibility |
|------|---------------|
| Writer | Story, dialogue, branching logic, character personalities |
| CEO/PM #1 | Project management, timeline, coordination, weekly syncs |
| CEO/PM #2 | Market research, community building, legal/business setup |
| AI/ML Engineer #1 (Regina) | Art pipeline, LoRA training, ComfyUI workflows |
| AI/ML Engineer #2 | Model training, Rho engine adaptation |
| Artist (CEO's friend) | Character sheets, style guide, quality passes on AI output |
| Frontend/UI-UX | Game engine (Ren'Py or web), UI design, marketing site |

---

## Useful Links

- [ComfyUI GitHub](https://github.com/comfyanonymous/ComfyUI)
- [Civitai — Browse Models](https://civitai.com/models)
- [RunPod](https://runpod.io)
- [kohya_ss LoRA Training](https://github.com/bmaltais/kohya_ss)
- [IP-Adapter for ComfyUI](https://github.com/cubiq/ComfyUI_IPAdapter_plus)
- [AnimateDiff for ComfyUI](https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved)
- [Ren'Py Visual Novel Engine](https://www.renpy.org/)
- [Rho Framework (our multi-agent engine)](https://github.com/your-repo/rho)
