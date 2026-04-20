# Rho Game — Domain Strategy & Two-Product Roadmap

## The Two-Product Framework

You accidentally designed two products. Both are good. But they must be built in sequence, not parallel.

### Product A: "Rho" — The PG18 BL Visual Novel (SHIP FIRST)
- **What:** A traditional visual novel with pre-made story, characters, CGs (AI-generated), and animated scenes (Seedance)
- **Engine:** Ren'Py with custom UI
- **Monetization:** Patreon monthly chapters → Steam base game → DLsite 18+ version
- **Timeline:** 8 weeks to Chapter 1 on Patreon
- **Revenue target:** $500-2K/month by month 3
- **Why first:** Validates the audience, builds the community, generates revenue, creates the CHARACTER IP that Product B needs

### Product B: "Rho Intimate" — The Personalized PG18 Experience (BUILD AFTER)
- **What:** User uploads photo + voice → AI converts to anime character (four-view sheet via Seedance) → character anchor → user appears in PG18 scenes with game's love interests
- **Engine:** Web app (React/Next.js) + Seedance 2.0 API backend
- **Monetization:** Premium Patreon tier ($20-50/month) OR per-generation credits ($2-5 per scene)
- **Timeline:** Build after Product A has 200+ patrons (validation signal)
- **Revenue target:** 2-5x the base game revenue (personalization commands premium pricing)
- **Why second:** Needs established characters that users WANT to interact with. Without Product A's story creating emotional attachment to the LIs, nobody cares about being "in scenes" with them.

### Why This Order Matters
1. Product A creates the **characters people fall in love with**. Without that emotional hook, Product B is just "generic AI porn generator" — zero differentiation, zero pricing power.
2. Product A builds the **community** that becomes Product B's customer base. Your Patreon + Discord = built-in launch audience.
3. Product A **validates demand** before you invest in Seedance API costs and web infrastructure.
4. Product A revenue **funds** Product B development.
5. Product B becomes the **upsell** that 10-20% of Product A's audience pays premium for.

---

## Product A: Game Domain Design

### Setting: Modern Supernatural / Urban Fantasy (Recommended)

**Why this setting:**
- AI art excels at modern environments + supernatural elements (glowing effects, dramatic lighting)
- Lower worldbuilding burden than historical/xianxia (no accuracy debates)
- Supernatural elements justify dramatic, visually striking scenes
- Appeals across ALL target markets (JP, CN, KR, EN)
- Modern setting = relatable everyday moments + extraordinary events = emotional range

**The World:**
A version of our world where certain people are born with "resonance" — an ability to perceive and interact with supernatural phenomena that exist in the spaces between human emotions. Think of it as: strong emotions leave residue, and resonators can see/feel/manipulate that residue.

This isn't publicly known. Resonators operate in the shadows — some use their abilities to help (therapists, mediators, healers), some exploit them (manipulators, information brokers), and some are consumed by them.

The game is set in a major East Asian city (deliberately unnamed — lets players project Seoul, Tokyo, Taipei, Shanghai). Modern, stylish, neon-lit nights and sun-drenched rooftops. Think: the aesthetic of a good BL manhwa crossed with the atmosphere of Psycho-Pass or Banana Fish.

**Why "resonance" as the supernatural system:**
- It's inherently emotional → perfect for BL romance (feeling each other's emotions = instant intimacy mechanic)
- It creates natural conflict (can you trust someone who can read your emotions?)
- It explains why characters are drawn together (resonance between people)
- It provides visual spectacle for CGs without requiring full fantasy worldbuilding
- The "resonance" mechanic is what the Rho simulation engine can model — relationship dynamics as gameplay

### The Protagonist (MC): Seo Haneul (서하늘) / 星河

**Core concept:** A resonator who has spent his entire adult life suppressing his ability because the last time he used it, someone got hurt. He works a boring desk job at a consulting firm, drinks alone, and is very good at pretending he's normal.

**Age:** 26. Old enough to have baggage, young enough to still change.

**Appearance:** Dark hair, tired but sharp eyes, lean build, tends to wear dark layers even in summer. Not a "pretty boy" — handsome in a worn, lived-in way. The kind of face that looks better when he actually smiles (which is rare).

**Personality:**
- Dry humor that masks genuine pain
- Observant (years of suppressing resonance made him hyper-aware of people)
- Stubborn about being independent ("I don't need anyone" = classic BL MC flaw)
- Secretly deeply empathetic — he suppresses resonance because he feels TOO much
- Not a pushover. Will fight back. Has opinions. Has flaws he doesn't apologize for.

**Why this MC works for the market:**
- Defined personality (East Asian market preference) but enough emotional range for player investment
- His suppressed ability = built-in character arc (learning to open up = falling in love)
- His "feeling too much" backstory resonates with BL fans who love emotionally complex MCs
- Modeled after what worked in Slow Damage (Towa) and Hashihime — protagonists who carry the story on their own complexity

### Love Interest #1 (Launch): Kael / 凯 / カエル

**Core concept:** A resonator who is the complete opposite of Haneul — he uses his ability openly, recklessly, and with apparent joy. He's the kind of person who walks into a room and everyone notices. Haneul finds him infuriating... and then slowly realizes why.

**Age:** 28. Slightly older, but doesn't feel like it because he acts younger.

**Appearance:** Silver-white hair (striking, memorable — great for character LoRA training), green eyes, tall, athletic build. Dresses expensively but casually. Always looks like he just rolled out of bed and it worked anyway.

**Personality:**
- Surface: Charming, flirtatious, doesn't take anything seriously
- Reality: Highly intelligent, deliberately uses his "careless" persona as armor
- Hides something significant about his past with resonance
- Genuinely kind underneath the act — but it takes time to see it
- When he drops the mask, he's intense and vulnerable

**Dynamic with MC:** Rivals/irritants → reluctant allies → trust → intimacy. Classic enemies-to-lovers but through the lens of two people who can literally feel each other's emotions and are terrified of that vulnerability.

**PG18 angle:** The resonance mechanic makes intimate scenes uniquely powerful — they don't just feel physical sensation, they feel each other's emotions during it. This creates opportunities for intimate scenes that are genuinely character development, not just fanservice. The "first time they let their guards down" scene practically writes itself.

### Love Interest #2 (Chapter 3-4): Ren / 仁 / レン

**Core concept:** A non-resonator. An ordinary human who works in law enforcement and is investigating a series of strange cases that turn out to be resonance-related. He meets Haneul while investigating one of these cases.

**Age:** 30. The most grounded of the three.

**Appearance:** Black hair, warm brown eyes, broader build — more rugged than pretty. Dresses practically. Has a scar on his jaw he doesn't talk about.

**Personality:**
- Steady, reliable, observant in a human (non-supernatural) way
- Represents "normal life" — what Haneul wants but thinks he can't have
- Not naïve about the supernatural — skeptical but open-minded
- Protective without being possessive
- His love language is acts of service (brings you soup when you're sick, fixes your door lock without being asked)

**Dynamic with MC:** The "gentle" route. Where Kael's route is fire and intensity, Ren's is slow-burn warmth. He can't feel Haneul's emotions through resonance — he has to learn them the human way, by paying attention. This makes his understanding of Haneul feel earned.

**PG18 angle:** The contrast of a non-resonator in bed with a resonator. Haneul feels everything amplified; Ren doesn't. This creates a unique dynamic where Haneul has to actually communicate instead of relying on resonance as a shortcut. Tender, emotionally intense scenes.

### Love Interest #3 (Chapter 5-6): ???

**Deliberately left undefined.** Release LI#1 and LI#2, see which dynamic the audience responds to more, then design LI#3 to fill the gap. This is the Patreon advantage — real-time audience data.

**Possible archetypes based on what the first two don't cover:**
- If fans want more intensity: A morally grey antagonist figure (resonance user who's gone too far)
- If fans want more softness: A younger, more vulnerable character who needs protecting
- If fans want chaos: A seke/switch character who doesn't fit neatly into any role

---

## Product B: Personalization Feature (Post-Validation)

### How It Would Work (Technical)

```
User Flow:
1. Upload 1-3 selfie photos
2. System generates anime character sheet via Seedance 2.0 Character API
   → 4-panel turnaround (front/back/side/action)
   → User reviews and approves their anime self
3. (Optional) Record 5-15 seconds of voice for voice anchoring
4. Select a scene: "Intimate moment with Kael" / "Date with Ren" / etc.
5. System uses @character:<user_id> anchor + scene prompt → generates video/animated CG
6. User receives their personalized PG18 scene (10-30 second animated clip)
```

### Technical Architecture

```
Frontend: Next.js / React web app (your frontend dev's strength)
Backend: Python API server
  → Receives user photos
  → Calls Seedance 2.0 Character API for turnaround sheet
  → Calls Seedance 2.0 consistent_video() with user anchor + scene prompt
  → Returns generated video
Storage: Cloud storage for user assets + generated content
Auth: Simple email + password (don't overcomplicate)
Payments: Patreon integration (premium tier) OR Stripe/crypto for per-generation
```

### Why NOT Ren'Py for This
- Ren'Py CAN call Python/APIs, but it's designed for pre-made content playback
- Personalized generation requires: upload UI, progress indicator, video playback, account management
- A web app does all of this better and is more accessible (no download required)
- Keep Ren'Py for Product A (the traditional VN). Use web for Product B.

### Pricing for Product B
- **Option 1:** Premium Patreon tier ($20-30/month for X generations per month)
- **Option 2:** Credit-based ($3-5 per scene generation)
- **Option 3:** Both (monthly sub gives credits, buy more à la carte)

### When to Build
- After Product A has 200+ Patreon patrons
- After characters have emotional resonance with the audience (they need to WANT to be in scenes with Kael/Ren)
- After Seedance 2.0 API pricing is stable and you can calculate per-generation costs
- Estimated: 3-6 months after Product A launch

---

## Chapter 1 Script Outline (Product A)

### Opening (10 minutes of gameplay)

**Scene 1: The Incident**
Cold open. Haneul is 19, in a crowd. Something happens — his resonance flares uncontrollably. Someone collapses. Screaming. Haneul's perspective: overwhelming sensory overload of other people's emotions. Cut to black.

**Scene 2: Seven Years Later**
Haneul, 26, wakes up in his small apartment. Alarm. Coffee. Routine. He's aggressively normal. Goes to work at a consulting firm. The narration establishes: he's been suppressing his resonance for 7 years. It's worked. He's fine. (He's not fine.)

**Scene 3: The Meeting**
At a bar after work (drinking alone, of course). Someone sits next to him uninvited. Silver-white hair, green eyes, irritating smile. This is Kael.

Kael says something that shouldn't be possible — he references Haneul's resonance. He knows. The first line of actual dialogue should be something that hooks:

> "You're the worst liar I've ever met. Your resonance is screaming even though you've got it locked down so tight you've forgotten what your own emotions feel like."

Haneul's world cracks open.

### Rising Action (30-40 minutes)

**Scene 4-6: The Case**
Kael reveals there's a problem — someone is weaponizing resonance, and people are getting hurt. He needs Haneul's help because Haneul has a specific ability (established later) that's rare.

Haneul refuses. Multiple times. Kael keeps showing up. They argue. There's tension — the kind where you're not sure if they want to punch each other or kiss each other.

**Scene 7: The First Resonance**
A situation forces Haneul to use his ability for the first time in 7 years. Kael is there. Their resonances touch. It's overwhelming and intimate — they feel each other's emotions without consent or warning. Both are shaken.

This is the first CG moment. Animated with Seedance — the visual representation of two resonances intertwining.

**Scene 8-9: Reluctant Alliance**
Haneul agrees to help. Temporarily. They begin investigating together. Banter. Friction. Moments of unexpected vulnerability. The audience starts falling for both characters.

### Climax of Chapter 1 (15-20 minutes)

**Scene 10: The First Real Danger**
They confront the threat. Action/tension scene. Kael gets hurt protecting Haneul.

**Scene 11: The Aftermath**
Haneul tends to Kael's injuries. Quiet, tense scene. Physical proximity. Emotional walls start cracking. Kael drops his careless mask for the first time. Haneul sees the real person underneath.

**PG18 Scene (Patreon exclusive):**
Not full intimacy yet — this is Chapter 1. But a charged, physical moment. A kiss that neither planned. Resonance flaring between them. The feeling of someone else's desire mixed with your own. Haneul pulling back. Kael letting him.

This scene should feel inevitable but also like a beginning, not a resolution. Leave them wanting more.

### Cliffhanger

**Scene 12: The Reveal**
A phone call. A name. Something from Kael's past that he's been hiding — connected to what happened to Haneul seven years ago. The person who made Haneul's resonance go out of control... Kael knows them. Maybe was involved.

Cut to black. "Chapter 2 coming next month."

---

## Asset List for Chapter 1

### Characters
- **Haneul (MC):** 8 expressions (neutral, tired, annoyed, surprised, vulnerable, angry, smiling-rare, resonance-active)
- **Kael (LI#1):** 8 expressions (charming, teasing, serious, hurt, mask-dropped-vulnerable, flirtatious, intense, resonance-active)
- **Side characters:** 2-3 NPCs with 3 expressions each (coworker, bartender, threatening figure)

### Backgrounds (8-10)
1. Haneul's apartment (morning/night variants)
2. Office/consulting firm
3. Bar (where they meet)
4. City street (day/night)
5. Kael's place (modern, expensive, messy)
6. Alley/rooftop (investigation scenes)
7. Resonance visual space (abstract/supernatural — great for AI art)
8. Hospital/recovery room

### CGs (6-8 total)
1. **Opening incident** — young Haneul, resonance overload (dramatic)
2. **The meeting** — Kael sitting next to Haneul at the bar (establishing shot)
3. **First resonance** — their abilities intertwining (ANIMATED — Seedance hero CG)
4. **Action scene** — confrontation with threat
5. **Kael injured** — Haneul tending to him (emotional)
6. **The kiss** — PG18 scene, resonance visual effects (ANIMATED — Seedance hero CG)
7. **Cliffhanger reveal** — Kael's expression when the truth surfaces

### Explicit CGs (Patreon tier, 1-2)
1. The kiss scene extended — more physical, resonance fully active, both characters losing control
2. (Optional for launch) A suggestive "morning after" or intimate moment that implies more to come

### Music/SFX (source from royalty-free libraries initially)
- Quiet/melancholy theme (Haneul's daily life)
- Urban/modern BGM (city scenes)
- Tension/mystery theme (investigation)
- Intimate/emotional theme (character moments)
- Resonance SFX (otherworldly hum/shimmer when abilities activate)
- Action/danger theme

---

## Next Steps (This Week)

1. **Regina:** Share the projects/rho files so we can assess the simulation engine
2. **Writer (me + your writer):** Flesh out this outline into full script (targeting 10,000-12,000 words for Ch.1)
3. **Artist:** Start character sheets for Haneul + Kael based on descriptions above
4. **Regina + AI/ML:** Begin LoRA training prep once character sheets are ready
5. **Frontend dev:** Set up Ren'Py project, prototype the custom UI
6. **CEOs:** Set up Patreon page draft, create Discord server
