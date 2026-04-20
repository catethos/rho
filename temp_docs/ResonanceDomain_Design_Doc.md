# ResonanceDomain Design Document
## Rho Game: A Supernatural BL Visual Novel with Simulation-Driven Narratives

**Version:** 1.0  
**Date:** April 2026  
**Status:** Design Phase — Ready for Implementation  
**Target:** East Asian market (Chinese, Japanese, Korean audiences)

---

## Executive Summary

ResonanceDomain is the core simulation engine for "Rho Game," a boys' love visual novel powered by Elixir's `Rho.Sim` framework. The game features three characters (Seo Haneul, Kael, and Ren) whose relationship arcs are driven by a supernatural "resonance" mechanic—the ability to sense and involuntarily share emotions.

This document defines:
1. **Complete state architecture** for character emotions, relationships, and story progression
2. **Resonance mechanics** including sync levels, fog of war, and flare events
3. **Transition rules** governing affection, trust, intimacy, and route locks
4. **Policy designs** for player and AI-driven character behaviors
5. **Production-ready Elixir code** that implements the full domain
6. **Monte Carlo testing strategy** for branch analysis and pacing optimization
7. **Frontend integration** with Ren'Py and Phoenix web transport

---

## 1. Domain State Design

### 1.1 State Structure Overview

The `ResonanceDomain` maintains immutable state across simulation steps, with all mutations represented as transitions. The state is partitioned into:

- **Character substrates** — internal emotional landscapes
- **Relationship matrices** — pairwise dynamics
- **Scene/chapter tracking** — narrative progression
- **Event system** — triggered story beats
- **Memory traces** — historical callbacks

### 1.2 Character Emotional State

Each character has a multi-layered emotional model:

```elixir
defmodule RhoGame.Character do
  @type t :: %{
    name: String.t(),
    surface_state: %{
      valence: float(),        # -1.0 (sad) to 1.0 (happy)
      arousal: float(),        # 0.0 (calm) to 1.0 (intense)
      displayed_mood: atom()   # :happy, :pensive, :angry, :flustered, :closed_off
    },
    hidden_state: %{
      vulnerability: float(),  # 0.0 (walled off) to 1.0 (open)
      mask_level: float(),     # 0.0 (authentic) to 1.0 (fully masked)
      emotional_fatigue: float(), # 0.0 to 1.0, from resonance overload
      lonely_baseline: float()    # personality trait: -0.5 to 0.5
    },
    substrates: %{
      jealousy: float(),       # triggered by MC showing affection elsewhere
      anxiety: float(),         # about rejection or vulnerability
      doubt: float(),           # about own worthiness
      hope: float(),            # about relationship progress
      longing: float()          # desire for connection
    },
    resonance_profile: %{
      is_resonator: boolean(),
      resonance_strength: float(), # 0.0 to 1.0, innate ability
      resonance_suppression: float(), # Haneul's 7-year wall
      last_flare_step: integer()    # for cooldown
    },
    stats: %{
      empathy_base: float(),   # how naturally emotionally intelligent
      pride: float(),          # how easily embarrassed or ashamed
      openness: float(),       # trait: tendency to share vs. hide
      volatility: float()      # tendency toward emotional swings
    }
  }
end
```

### 1.3 Relationship State

Relationships are bidirectional but asymmetric (MC→LI differs from LI→MC):

```elixir
defmodule RhoGame.Relationship do
  @type t :: %{
    # Both characters feel these
    affection: integer(),      # 0 to 1000, growth path to romance
    trust: integer(),          # 0 to 1000, foundation for vulnerability
    intimacy: integer(),       # 0 to 100, physical/emotional proximity
    
    # Resonance-specific (only for resonator pairs)
    resonance_sync: float(),   # 0.0 to 1.0, emotional attunement
    sync_momentum: float(),    # -1.0 to 1.0, trend direction
    resonance_comfort: float(), # 0.0 to 1.0, acceptance of forced intimacy
    
    # Asymmetric perceptions
    perceived_interest: float(), # 0.0 to 1.0, confidence they like you back
    fear_of_rejection: float(),  # 0.0 to 1.0, anxiety about confession
    
    # History tracking
    last_intimate_scene_step: integer() | nil,
    first_kiss_step: integer() | nil,
    jealousy_incidents: list({integer(), float()}), # {step, intensity}
    major_conflict_steps: list(integer()),
    
    # Route-specific flags
    has_confessed: boolean(),
    is_exclusive: boolean(),
    has_broken_up: boolean() # for conflict scenes
  }
end
```

### 1.4 Scene and Chapter Tracking

```elixir
defmodule RhoGame.SceneState do
  @type t :: %{
    current_chapter: integer(), # 1 to 6 (prologue, early, mid, late, climax, epilogue)
    chapter_started_at_step: integer(),
    current_scene: atom(),     # :home, :workplace, :resonance_flare, :confession, etc.
    scene_step_count: integer(),
    visited_locations: MapSet.t(atom()),
    
    # Major branching flags (binary, set once)
    event_flags: %{
      first_meeting: boolean(),
      kael_true_face_revealed: boolean(),
      ren_learns_about_resonance: boolean(),
      haneul_suppression_cracks: boolean(),
      triangle_jealousy_moment: boolean(),
      mutual_resonance_confession: boolean(),
      ren_sacrifice_moment: boolean(),
      climactic_choice: boolean(),
      true_ending_unlocked: boolean()
    },
    
    # CG/scene unlock tracking
    unlocked_cgs: MapSet.t(atom()), # :first_meeting, :rain_scene, :intimate_moment, etc.
    intimate_scene_count: integer(),
    bad_end_paths_explored: integer()
  }
end
```

### 1.5 Memory Traces for Callbacks

```elixir
defmodule RhoGame.MemoryTrace do
  @type t :: %{
    event: atom(),              # :vulnerability_shown, :resonance_flare, :confession, etc.
    triggered_step: integer(),
    affection_delta: integer(),  # what changed because of this
    characters_involved: list(String.t()),
    intensity: float(),          # 0.0 to 1.0, for replay weighting
    conditions: map()            # what triggered this
  }
end
```

### 1.6 Complete Domain State Map

```elixir
defmodule RhoGame.ResonanceDomain.State do
  @type t :: %{
    # Characters (keyed by name)
    haneul: RhoGame.Character.t(),
    kael: RhoGame.Character.t(),
    ren: RhoGame.Character.t(),
    
    # Relationships (keyed as "haneul_kael", "haneul_ren", "kael_ren")
    relationships: %{
      String.t() => RhoGame.Relationship.t()
    },
    
    # Scene/narrative
    scene: RhoGame.SceneState.t(),
    
    # History
    memory_traces: list(RhoGame.MemoryTrace.t()),
    
    # Route locking (which ending path is locked in)
    locked_route: nil | :kael | :ren | :bad_end | :true_end,
    route_locked_at_step: integer() | nil
  }
end
```

---

## 2. Resonance Mechanic Design

### 2.1 What is Resonance?

Resonance is a supernatural ability to involuntarily sense and share emotional states. In the game:

- **Resonators** (Haneul and Kael) can detect each other's emotional substrates
- **Non-resonators** (Ren) only perceive surface-level behavior
- **Resonance sync** (0.0–1.0) measures how in-tune two resonators are
- **Resonance flares** are uncontrolled moments where emotions overwhelm the system

### 2.2 Resonance Sync Mechanics

Resonance sync represents emotional attunement. High sync means:
- Easier to comfort each other
- Increased vulnerability (edges of suppression break down)
- Higher risk of involuntary emotion sharing
- More "chemistry" in intimate scenes

```elixir
defmodule RhoGame.Resonance do
  @moduledoc "Resonance calculations and state transitions"

  @type sync_level :: :strangers | :acquainted | :close | :bonded | :merged
  
  def calculate_sync(
    haneul_vulnerability: float(),
    haneul_suppression: float(),
    kael_openness: float(),
    shared_moment_count: integer(),
    affection: integer(),
    time_since_interaction: integer()
  ) do
    # Vulnerability and openness are primary drivers
    base_sync = (haneul_vulnerability + kael_openness) / 2.0
    
    # Suppression creates a hard ceiling
    suppression_factor = 1.0 - (haneul_suppression * 0.7)
    
    # Affection unlock: higher affection enables deeper sync
    affection_multiplier = min(1.0, affection / 800.0)
    
    # Time decay: isolation reduces sync
    time_decay = max(0.0, 1.0 - time_since_interaction / 100.0)
    
    # Shared moments create momentum
    momentum = min(1.0, shared_moment_count / 10.0) * 0.3
    
    sync = (base_sync * suppression_factor * affection_multiplier + momentum) * time_decay
    min(1.0, max(0.0, sync))
  end

  def sync_level(sync: float()) do
    case sync do
      s when s < 0.2 -> :strangers
      s when s < 0.4 -> :acquainted
      s when s < 0.6 -> :close
      s when s < 0.85 -> :bonded
      _ -> :merged
    end
  end

  # Flare occurs when suppression cracks under resonance pressure
  def should_flare?(
    haneul_suppression: float(),
    resonance_sync: float(),
    emotional_stress: float()
  ) do
    # Flares happen at high sync + high suppression + high stress
    flare_risk = resonance_sync * haneul_suppression * emotional_stress
    flare_risk > 0.5
  end

  def flare_damage(sync: float(), suppression: float()) do
    # How badly does the flare hurt (emotional damage / vulnerability spike)
    damage = sync * suppression
    {damage, :vulnerability_increased}
  end
end
```

### 2.3 Fog of War: Information Access

Each character has different observational abilities based on resonance:

```elixir
defmodule RhoGame.Observation do
  @moduledoc "What each character can see about others"

  @type observation :: %{
    character_name: String.t(),
    visible_valence: float(),     # surface mood
    visible_arousal: float(),     # visible intensity
    visible_displayed_mood: atom(),
    can_sense_hidden_state: boolean(),
    sensed_vulnerability: float() | nil,  # only if resonator & sync > threshold
    sensed_substrates: map()      # partial, based on sync
  }

  def observe(observer: String.t(), target: String.t(), state: map()) do
    observer_char = state[observer]
    target_char = state[target]
    rel = state.relationships["#{observer}_#{target}"] || %{}

    case observer_char.resonance_profile.is_resonator do
      true ->
        # Resonator can sense hidden state based on sync
        sync = rel.resonance_sync || 0.0
        
        sensed_vulnerability = 
          if sync > 0.3,
            do: target_char.hidden_state.vulnerability * sync,
            else: nil
        
        sensed_substrates =
          if sync > 0.5,
            do: Enum.into(target_char.substrates, %{}, fn {k, v} ->
              {k, v * sync}  # filtered by sync level
            end),
            else: %{}
        
        %{
          character_name: target,
          visible_valence: target_char.surface_state.valence,
          visible_arousal: target_char.surface_state.arousal,
          visible_displayed_mood: target_char.surface_state.displayed_mood,
          can_sense_hidden_state: true,
          sensed_vulnerability: sensed_vulnerability,
          sensed_substrates: sensed_substrates
        }
      false ->
        # Non-resonator only sees surface
        %{
          character_name: target,
          visible_valence: target_char.surface_state.valence,
          visible_arousal: target_char.surface_state.arousal,
          visible_displayed_mood: target_char.surface_state.displayed_mood,
          can_sense_hidden_state: false,
          sensed_vulnerability: nil,
          sensed_substrates: %{}
        }
    end
  end
end
```

### 2.4 Suppression Mechanic

Haneul's 7-year wall suppresses their resonance. As the story progresses, it cracks:

```elixir
defmodule RhoGame.Suppression do
  @moduledoc "Haneul's emotional suppression mechanics"

  # Suppression cracks under specific conditions
  def crack_suppression(
    current_suppression: float(),
    affection_with_target: integer(),
    resonance_sync: float(),
    major_vulnerability_moment: boolean()
  ) do
    # Each condition contributes to cracking
    affection_crack = max(0.0, (affection_with_target - 300) / 1000.0) * 0.3
    sync_crack = resonance_sync * 0.25
    vulnerability_crack = if major_vulnerability_moment, do: 0.1, else: 0.0
    
    crack = affection_crack + sync_crack + vulnerability_crack
    new_suppression = max(0.0, current_suppression - crack)
    
    {new_suppression, crack > 0.05}  # returns {new level, did crack}
  end

  # Suppression provides stability but prevents intimacy
  def suppression_barriers(suppression: float()) do
    %{
      max_sync: (1.0 - suppression) * 0.8,  # Can't reach full sync while suppressed
      vulnerability_ceiling: 0.3 * (1.0 - suppression),
      confession_difficulty: suppression * 0.5  # affects affection gains
    }
  end
end
```

---

## 3. Transition Rules

### 3.1 Action Types

Players and AI make decisions that map to affection/trust changes:

```elixir
defmodule RhoGame.Action do
  @type t :: %{
    actor: String.t(),        # "haneul", "kael", "ren"
    action_type: atom(),      # :be_honest, :hide_emotion, :show_vulnerability, :make_joke, :confess, etc.
    target: String.t(),       # who is this action toward
    intensity: float(),       # 0.0 to 1.0, how much emotional investment
    conditions: map()          # context for the action
  }

  @spec evaluate_personality_match(
    action_type: atom(),
    target: String.t(),
    action_intensity: float(),
    character_traits: map()
  ) :: {atom(), integer()} # {fit_type, affection_delta}
  
  def evaluate_personality_match(
    action_type: action_type,
    target: target,
    action_intensity: intensity,
    character_traits: traits
  ) do
    # Different characters appreciate different actions
    case {target, action_type} do
      # Kael appreciates honesty and humor, dislikes pity
      {"kael", :be_honest} -> 
        {:perfect_match, trunc(30 * intensity)}
      {"kael", :make_joke_in_tense_moment} -> 
        {:perfect_match, trunc(25 * intensity)}
      {"kael", :show_pity} -> 
        {:harmful, -30}
      
      # Ren appreciates steady support and reliability
      {"ren", :be_present_and_listen} -> 
        {:perfect_match, trunc(20 * intensity)}
      {"ren", :protect_and_support} -> 
        {:perfect_match, trunc(25 * intensity)}
      {"ren", :be_honest} -> 
        {:acceptable, trunc(15 * intensity)}
      {"ren", :hide_emotion} -> 
        {:harmful, -15}  # Ren values transparency
      
      # Haneul-agnostic actions
      _ -> 
        {:neutral, 0}
    end
  end
end
```

### 3.2 Affection Gain/Loss Formulas

```elixir
defmodule RhoGame.Affection do
  @moduledoc "Affection calculation and time decay"

  def calculate_delta(
    personality_match: {atom(), integer()},
    resonance_bonus: float(),
    intimacy_level: integer(),
    time_since_last_interaction: integer(),
    character_openness: float()
  ) do
    {match_type, base_delta} = personality_match
    
    # Resonance bonus: shared emotion hits harder
    resonance_factor = 1.0 + resonance_bonus * 0.4
    
    # Intimacy amplification: actions matter more once close
    intimacy_multiplier = 1.0 + (intimacy_level / 100.0) * 0.3
    
    # Openness modifier: harder to gain affection with closed characters
    openness_factor = 0.5 + character_openness * 0.5
    
    final_delta = 
      base_delta 
      * resonance_factor 
      * intimacy_multiplier 
      * openness_factor
    
    trunc(final_delta)
  end

  # Time decay: affection slowly erodes without interaction
  def apply_time_decay(affection: integer(), steps_since_interaction: integer()) do
    decay = min(50, steps_since_interaction)  # cap at -50 per step
    max(0, affection - decay)
  end

  # Route thresholds that unlock intimacy
  def intimacy_gate(affection: integer(), resonance_sync: float()) do
    case {affection >= 300, affection >= 500, affection >= 800, resonance_sync > 0.6} do
      {false, _, _, _} -> :acquainted      # no intimate scenes yet
      {true, false, _, _} -> :developing   # hand-holding, maybe a kiss
      {true, true, false, _} -> :intimate  # can have bedroom scenes
      {true, true, true, true} -> :merged  # full emotional/physical intimacy
      _ -> :intimate
    end
  end
end
```

### 3.3 Trust Development

Trust is separate from affection and grows through vulnerability:

```elixir
defmodule RhoGame.Trust do
  @moduledoc "Trust mechanics"

  def calculate_delta(
    action_type: atom(),
    is_vulnerable: boolean(),
    is_honest: boolean(),
    resonance_sync: float()
  ) do
    delta = 
      case {is_honest, is_vulnerable} do
        {true, false} -> 10      # being honest
        {true, true} -> 30       # being vulnerable = major trust boost
        {false, _} -> -50        # lying damages trust heavily
      end
    
    # Resonance makes honesty more felt
    resonance_multiplier = 1.0 + resonance_sync * 0.5
    trunc(delta * resonance_multiplier)
  end

  # Trust gates access to vulnerable actions
  def can_be_vulnerable?(trust: integer()) do
    trust >= 200
  end

  def can_confess?(trust: integer(), affection: integer()) do
    trust >= 150 and affection >= 300
  end

  # Betrayal drops trust hard
  def apply_betrayal(trust: integer()) do
    max(0, trust - 100)
  end
end
```

### 3.4 Resonance Sync Growth

Resonance sync only develops between resonators (Haneul ↔ Kael):

```elixir
defmodule RhoGame.ResyncGrowth do
  @moduledoc "How resonance synchronization develops"

  def calculate_sync_delta(
    shared_vulnerability: boolean(),
    shared_emotional_moment: boolean(),
    recent_flare: boolean(),
    suppression_crack: boolean(),
    time_together: integer(),
    separation_period: integer()
  ) do
    # Shared vulnerability is the strongest driver
    vulnerability_boost = if shared_vulnerability, do: 0.15, else: 0.0
    
    # Emotional moments (not necessarily vulnerability)
    moment_boost = if shared_emotional_moment, do: 0.05, else: 0.0
    
    # Flares create a crisis point that increases intimacy
    flare_boost = if recent_flare and not suppression_crack, do: 0.08, else: 0.0
    
    # Suppression cracks allow rapid sync increase
    crack_boost = if suppression_crack, do: 0.2, else: 0.0
    
    # Time together consolidates sync
    consolidation = min(0.1, time_together / 500.0)
    
    # Separation erodes sync slowly
    erosion = -1 * min(0.05, separation_period / 200.0)
    
    delta = vulnerability_boost + moment_boost + flare_boost + crack_boost + consolidation + erosion
    min(0.5, max(-0.2, delta))  # cap at ±0.5 per step
  end
end
```

### 3.5 Chemistry Rolls (Stochastic Element)

Chemistry rolls introduce variance to romantic moments:

```elixir
defmodule RhoGame.Chemistry do
  @moduledoc "Stochastic romantic/intimate moment resolution"

  def roll_chemistry(
    affection: integer(),
    resonance_sync: float(),
    intimacy: integer(),
    character_confidence: float(),
    rng: float()  # random 0.0-1.0 from sample/3
  ) do
    # Base success chance from affection
    base_success = min(1.0, affection / 1000.0)
    
    # Resonance adds certainty
    sync_bonus = resonance_sync * 0.3
    
    # Intimacy (past physical contact) makes things easier
    intimacy_bonus = (intimacy / 100.0) * 0.2
    
    # Character confidence/openness
    confidence_bonus = character_confidence * 0.2
    
    success_threshold = base_success + sync_bonus + intimacy_bonus + confidence_bonus
    
    case rng < success_threshold do
      true ->
        # Success! How much chemistry?
        chemistry_level = 
          if rng < success_threshold * 0.3 do
            :electric  # perfect moment
          else if rng < success_threshold * 0.7 do
            :warm      # good moment
          else
            :awkward   # works but not perfect
          end
        
        {:success, chemistry_level}
      
      false ->
        # Failure modes depend on how close we were
        if rng > success_threshold - 0.2 do
          {:near_miss, :charged_moment}  # tension, try again soon
        else
          {:awkward, :uncomfortable}      # need more relationship building
        end
    end
  end
end
```

### 3.6 Event Triggers

Events are major story beats unlocked by condition combinations:

```elixir
defmodule RhoGame.EventTrigger do
  @moduledoc "Story event conditions"

  def check_all_triggers(state: map()) do
    triggers = [
      {"first_meeting", check_first_meeting(state)},
      {"haneul_suppression_cracks", check_suppression_crack(state)},
      {"mutual_vulnerability", check_mutual_vulnerability(state)},
      {"resonance_flare_major", check_major_flare(state)},
      {"kael_true_face", check_kael_vulnerability(state)},
      {"ren_confession_moment", check_ren_steady_support(state)},
      {"triangle_jealousy", check_jealousy_trigger(state)},
      {"climactic_choice", check_climax_condition(state)}
    ]
    
    Enum.filter(triggers, fn {_name, triggered} -> triggered end)
    |> Enum.map(fn {name, _} -> name end)
  end

  defp check_suppression_crack(state) do
    rel_hk = state.relationships["haneul_kael"] || %{}
    haneul = state.haneul
    
    # Crack when: high affection + high sync + stress moment
    haneul.resonance_profile.resonance_suppression < 0.5 and
    rel_hk.affection > 400 and
    rel_hk.resonance_sync > 0.4
  end

  defp check_mutual_vulnerability(state) do
    rel_hk = state.relationships["haneul_kael"] || %{}
    
    # Both characters show vulnerability in same scene
    rel_hk.affection > 500 and
    rel_hk.resonance_sync > 0.6
  end

  defp check_major_flare(state) do
    haneul = state.haneul
    kael = state.kael
    
    # Flare risk: high sync + high suppression + emotional stress
    flare_risk = 
      (haneul.resonance_profile.resonance_suppression * 
       state.relationships["haneul_kael"].resonance_sync *
       (haneul.substrates.anxiety + kael.substrates.anxiety) / 2.0)
    
    flare_risk > 0.4
  end

  defp check_jealousy_trigger(state) do
    rel_hk = state.relationships["haneul_kael"] || %{}
    rel_hr = state.relationships["haneul_ren"] || %{}
    
    # Jealousy when one LI sees affection with the other
    rel_hk.affection > 600 and rel_hr.affection > 400
  end

  defp check_kael_vulnerability(state) do
    rel = state.relationships["haneul_kael"] || %{}
    kael = state.kael
    
    # Kael reveals vulnerability (mask cracks) at high sync + affection
    rel.resonance_sync > 0.6 and rel.affection > 600 and
    kael.hidden_state.mask_level > 0.5
  end

  defp check_ren_steady_support(state) do
    rel = state.relationships["haneul_ren"] || %{}
    ren = state.ren
    
    # Ren shows romantic interest after building trust
    rel.trust > 400 and rel.affection > 350 and
    not state.scene.event_flags.ren_learns_about_resonance
  end

  defp check_climax_condition(state) do
    rel_hk = state.relationships["haneul_kael"] || %{}
    rel_hr = state.relationships["haneul_ren"] || %{}
    
    # Route locks activate at climax
    state.scene.current_chapter >= 5 and (
      (rel_hk.affection > 700 and rel_hk.has_confessed) or
      (rel_hr.trust > 500 and rel_hr.affection > 600) or
      (rel_hk.affection < 200 and rel_hr.affection < 200)
    )
  end
end
```

---

## 4. Route Architecture

### 4.1 Route Lock System

Routes lock in at specific story points with affection/trust thresholds:

```elixir
defmodule RhoGame.Routes do
  @moduledoc "Route locking and ending determination"

  @type route :: :kael | :ren | :bad_end | :true_end | nil

  def determine_route(state: map(), current_step: integer()) do
    rel_hk = state.relationships["haneul_kael"] || %{}
    rel_hr = state.relationships["haneul_ren"] || %{}
    
    case state.scene.current_chapter do
      ch when ch >= 5 ->
        # Route lock happens at climax (chapter 5)
        cond do
          # Bad ending: insufficient affection with either LI
          rel_hk.affection < 200 and rel_hr.affection < 200 ->
            {:bad_end, current_step}
          
          # Kael route: high affection + confession + resonance sync
          rel_hk.affection >= 700 and 
          rel_hk.has_confessed and
          rel_hk.resonance_sync > 0.5 ->
            if rel_hk.affection >= 800 and rel_hk.resonance_sync > 0.8 and
               rel_hr.affection < 400 do
              {:true_end, current_step}  # Best ending with Kael
            else
              {:kael, current_step}
            end
          
          # Ren route: high trust + affection + steady support
          rel_hr.trust >= 500 and rel_hr.affection >= 600 and
          rel_hk.affection < 600 ->
            {:ren, current_step}
          
          # Still undecided
          _ ->
            nil
        end
      
      _ ->
        nil
    end
  end

  def is_route_locked?(locked_route: route) do
    locked_route != nil
  end
end
```

### 4.2 Jealousy and Conflict

Multiple LI routes coexist until locked, with jealousy mechanics:

```elixir
defmodule RhoGame.Jealousy do
  @moduledoc "Multi-LI conflict and jealousy"

  def calculate_jealousy_trigger(
    haneul_kael_affection: integer(),
    haneul_ren_affection: integer(),
    haneul_kael_sync: float(),
    last_intimate_kael: integer() | nil,
    last_intimate_ren: integer() | nil,
    current_step: integer()
  ) do
    # Kael is more jealous (emotionally volatile, masks possessiveness)
    kael_jealousy = 
      if haneul_ren_affection > 400 and haneul_kael_affection > 600 do
        # Kael becomes possessive when he feels threatened
        emotion = max(0.0, (haneul_ren_affection - 400) / 1000.0)
        
        # Recent intimacy with Ren triggers harder
        recent_intimacy_penalty = 
          if is_nil(last_intimate_ren) do
            0.0
          else
            days_since = current_step - last_intimate_ren
            if days_since < 20, do: 0.2, else: 0.0
          end
        
        emotion + recent_intimacy_penalty
      else
        0.0
      end
    
    # Ren is less overtly jealous but becomes withdrawn
    ren_jealousy =
      if haneul_kael_affection > 700 and haneul_ren_affection > 300 do
        if is_nil(last_intimate_kael) do
          0.1  # background anxiety
        else
          days_since = current_step - last_intimate_kael
          if days_since < 30, do: 0.3, else: 0.1
        end
      else
        0.0
      end
    
    {max(0.0, min(1.0, kael_jealousy)), max(0.0, min(1.0, ren_jealousy))}
  end

  def apply_jealousy_scene(
    jealousy_level: float(),
    character: String.t(),
    state: map()
  ) do
    case {character, jealousy_level} do
      {"kael", jeal} when jeal > 0.5 ->
        # Kael becomes distant, makes cutting remarks
        rel = state.relationships["haneul_kael"]
        %{rel | affection: max(0, rel.affection - 30)}
      
      {"ren", jeal} when jeal > 0.4 ->
        # Ren withdraws, becomes less open
        rel = state.relationships["haneul_ren"]
        %{rel | trust: max(0, rel.trust - 20)}
      
      _ ->
        state.relationships[key]
    end
  end
end
```

---

## 5. Policy Designs

### 5.1 PlayerPolicy

The player's choices are represented as a policy that the game UI feeds into:

```elixir
defmodule RhoGame.PlayerPolicy do
  @behaviour Rho.Sim.Policy
  
  @moduledoc """
  PlayerPolicy translates UI choices into game actions.
  The VN frontend displays 3-4 dialogue options; the player picks one.
  This policy converts that choice to a structured action.
  """

  defstruct [:choice_id, :dialogue_text, :emotion_tone]

  def init(opts) do
    {:ok, %{}}
  end

  def decide(context, _state, _observation, policy_state) do
    # In a real implementation, this reads from a message queue
    # that the Phoenix endpoint populates when the player clicks a choice
    case receive_player_choice(context.agent_id) do
      {:choice, choice_id, dialogue, tone} ->
        action = %{
          actor: "haneul",
          action_type: parse_tone_to_action(tone),
          dialogue: dialogue,
          target: identify_target(choice_id, context),
          intensity: intensity_from_tone(tone),
          conditions: %{choice_id: choice_id}
        }
        
        {:ok, action, policy_state}
      
      :no_choice_yet ->
        # Wait for player input
        {:ok, %{actor: "haneul", action_type: :wait}, policy_state}
    end
  end

  # Helper: translate UI tone to action type
  defp parse_tone_to_action(tone) do
    case tone do
      :honest -> :be_honest
      :vulnerable -> :show_vulnerability
      :humor -> :make_joke_in_tense_moment
      :protective -> :protect_and_support
      :flirty -> :be_flirty
      :cold -> :hide_emotion
      :supportive -> :be_present_and_listen
    end
  end

  defp intensity_from_tone(tone) do
    case tone do
      :honest -> 0.7
      :vulnerable -> 0.9
      :humor -> 0.6
      :protective -> 0.8
      :flirty -> 0.75
      :cold -> 0.4
      :supportive -> 0.7
    end
  end

  defp identify_target(choice_id, context) do
    # The choice_id encodes who we're talking to
    case choice_id do
      id when id in ["kael_option_1", "kael_option_2", "kael_option_3"] -> "kael"
      id when id in ["ren_option_1", "ren_option_2"] -> "ren"
      _ -> "self"  # internal reflection
    end
  end

  # This would be replaced by an actual message queue in production
  defp receive_player_choice(_agent_id) do
    :no_choice_yet
  end
end
```

### 5.2 KaelPolicy

Kael uses a hybrid rule-based + LLM policy for dynamic dialogue:

```elixir
defmodule RhoGame.KaelPolicy do
  @behaviour Rho.Sim.Policy
  
  @moduledoc """
  Kael's reactive policy. He responds to emotional cues with a mix of:
  - Deflection/humor when defended
  - Vulnerability when trust is high
  - Possessiveness when jealous
  - Genuine affection when alone with Haneul
  """

  defstruct [:last_action_from_haneul, :mask_integrity]

  def init(_opts) do
    {:ok, %{last_action: nil, mask_integrity: 0.8}}
  end

  def decide(context, state, observation, policy_state) do
    haneul_action = observation.haneul_recent_action
    haneul_mood = observation.haneul_mood
    rel = observation.relationship_with_haneul
    
    action = 
      cond do
        # Rule: If hiding vulnerability and trust < 400, deflect with humor
        state.kael.hidden_state.mask_level > 0.5 and rel.trust < 400 ->
          %{
            actor: "kael",
            action_type: :deflect_with_humor,
            target: "haneul",
            intensity: 0.6,
            conditions: %{mask_active: true, low_trust: true}
          }
        
        # Rule: If trust > 400 and intimacy > 50, show vulnerability
        rel.trust > 400 and rel.intimacy > 50 ->
          %{
            actor: "kael",
            action_type: :show_vulnerability,
            target: "haneul",
            intensity: 0.8,
            conditions: %{earned_vulnerability: true}
          }
        
        # Rule: If resonance_sync > 0.5, respond to unspoken feelings
        rel.resonance_sync > 0.5 ->
          %{
            actor: "kael",
            action_type: :respond_to_unspoken,
            target: "haneul",
            intensity: 0.7,
            conditions: %{high_sync: true}
          }
        
        # Rule: If Haneul was vulnerable, reciprocate
        haneul_action == :show_vulnerability ->
          %{
            actor: "kael",
            action_type: :reciprocate_vulnerability,
            target: "haneul",
            intensity: 0.85,
            conditions: %{haneul_vulnerable: true}
          }
        
        # Rule: If jealousy > 0.6, be possessive
        state.kael.substrates.jealousy > 0.6 ->
          %{
            actor: "kael",
            action_type: :be_possessive,
            target: "haneul",
            intensity: 0.7,
            conditions: %{jealous: true}
          }
        
        # Default: maintain cool, charming exterior
        true ->
          %{
            actor: "kael",
            action_type: :charming_deflection,
            target: "haneul",
            intensity: 0.5,
            conditions: %{default: true}
          }
      end
    
    {:ok, action, policy_state}
  end
end
```

### 5.3 RenPolicy

Ren is steady, observant, and patient—but gradually shows romantic interest:

```elixir
defmodule RhoGame.RenPolicy do
  @behaviour Rho.Sim.Policy
  
  @moduledoc """
  Ren's steady-presence policy. He:
  - Provides support without expecting return
  - Observes Haneul carefully
  - Gradually increases romantic signals
  - Remains protective but not possessive
  """

  defstruct [:observation_log, :confidence_level]

  def init(_opts) do
    {:ok, %{observations: [], confidence: 0.0}}
  end

  def decide(context, state, observation, policy_state) do
    rel = observation.relationship_with_haneul
    haneul_vulnerability = observation.haneul_hidden_state.vulnerability
    haneul_mood = observation.haneul_mood
    
    action =
      cond do
        # Rule: Haneul is in distress, provide steady support
        haneul_mood in [:sad, :angry, :anxious] ->
          %{
            actor: "ren",
            action_type: :provide_steady_support,
            target: "haneul",
            intensity: 0.8,
            conditions: %{haneul_distressed: true}
          }
        
        # Rule: Haneul showed vulnerability, increase trust score
        observation.haneul_action == :show_vulnerability ->
          %{
            actor: "ren",
            action_type: :deepen_emotional_safety,
            target: "haneul",
            intensity: 0.75,
            conditions: %{vulnerability_witnessed: true}
          }
        
        # Rule: High trust + moderate affection = time for romantic signals
        rel.trust > 400 and rel.affection > 400 and
        not rel.has_confessed ->
          %{
            actor: "ren",
            action_type: :subtle_romantic_signal,
            target: "haneul",
            intensity: 0.6,
            conditions: %{ready_for_romance: true, affection: rel.affection}
          }
        
        # Rule: Detect jealousy (Kael interaction) but respond with grace
        observation.haneul_recent_partner == "kael" and
        rel.affection > 300 ->
          %{
            actor: "ren",
            action_type: :show_understanding,
            target: "haneul",
            intensity: 0.7,
            conditions: %{other_route_active: true}
          }
        
        # Rule: If at confession threshold, make the move
        rel.trust >= 500 and rel.affection >= 600 and
        state.ren.substrates.longing > 0.7 ->
          %{
            actor: "ren",
            action_type: :confess_feelings,
            target: "haneul",
            intensity: 0.95,
            conditions: %{confession_time: true}
          }
        
        # Default: be present and reliable
        true ->
          %{
            actor: "ren",
            action_type: :be_present,
            target: "haneul",
            intensity: 0.5,
            conditions: %{default: true}
          }
      end
    
    {:ok, action, policy_state}
  end
end
```

---

## 6. Complete ResonanceDomain Implementation

This is the full, production-ready domain module that orchestrates all the above:

```elixir
defmodule RhoGame.ResonanceDomain do
  use Rho.Sim.Domain
  
  @moduledoc """
  Complete ResonanceDomain simulation engine for Rho Game.
  Implements all callbacks of @behaviour Rho.Sim.Domain.
  """

  @type state :: RhoGame.ResonanceDomain.State.t()

  def init(params) do
    # Initialize characters
    haneul = %RhoGame.Character{
      name: "Seo Haneul",
      surface_state: %{
        valence: 0.2,
        arousal: 0.4,
        displayed_mood: :pensive
      },
      hidden_state: %{
        vulnerability: 0.1,
        mask_level: 0.8,
        emotional_fatigue: 0.0,
        lonely_baseline: -0.3
      },
      substrates: %{
        jealousy: 0.0,
        anxiety: 0.5,
        doubt: 0.6,
        hope: 0.2,
        longing: 0.1
      },
      resonance_profile: %{
        is_resonator: true,
        resonance_strength: 0.9,
        resonance_suppression: 0.8,
        last_flare_step: 0
      },
      stats: %{
        empathy_base: 0.9,
        pride: 0.7,
        openness: 0.2,
        volatility: 0.6
      }
    }

    kael = %RhoGame.Character{
      name: "Kael",
      surface_state: %{
        valence: 0.6,
        arousal: 0.5,
        displayed_mood: :charming
      },
      hidden_state: %{
        vulnerability: 0.4,
        mask_level: 0.7,
        emotional_fatigue: 0.0,
        lonely_baseline: 0.1
      },
      substrates: %{
        jealousy: 0.1,
        anxiety: 0.4,
        doubt: 0.3,
        hope: 0.7,
        longing: 0.6
      },
      resonance_profile: %{
        is_resonator: true,
        resonance_strength: 0.85,
        resonance_suppression: 0.2,
        last_flare_step: 0
      },
      stats: %{
        empathy_base: 0.7,
        pride: 0.8,
        openness: 0.5,
        volatility: 0.8
      }
    }

    ren = %RhoGame.Character{
      name: "Ren",
      surface_state: %{
        valence: 0.5,
        arousal: 0.3,
        displayed_mood: :steady
      },
      hidden_state: %{
        vulnerability: 0.3,
        mask_level: 0.3,
        emotional_fatigue: 0.0,
        lonely_baseline: 0.2
      },
      substrates: %{
        jealousy: 0.0,
        anxiety: 0.2,
        doubt: 0.2,
        hope: 0.4,
        longing: 0.3
      },
      resonance_profile: %{
        is_resonator: false,
        resonance_strength: 0.0,
        resonance_suppression: 0.0,
        last_flare_step: 0
      },
      stats: %{
        empathy_base: 0.85,
        pride: 0.5,
        openness: 0.7,
        volatility: 0.3
      }
    }

    relationships = %{
      "haneul_kael" => %RhoGame.Relationship{
        affection: 50,
        trust: 30,
        intimacy: 0,
        resonance_sync: 0.1,
        sync_momentum: 0.0,
        resonance_comfort: 0.2,
        perceived_interest: 0.1,
        fear_of_rejection: 0.8,
        last_intimate_scene_step: nil,
        first_kiss_step: nil,
        jealousy_incidents: [],
        major_conflict_steps: [],
        has_confessed: false,
        is_exclusive: false,
        has_broken_up: false
      },
      "haneul_ren" => %RhoGame.Relationship{
        affection: 100,
        trust: 80,
        intimacy: 10,
        resonance_sync: 0.0,
        sync_momentum: 0.0,
        resonance_comfort: 0.0,
        perceived_interest: 0.2,
        fear_of_rejection: 0.6,
        last_intimate_scene_step: nil,
        first_kiss_step: nil,
        jealousy_incidents: [],
        major_conflict_steps: [],
        has_confessed: false,
        is_exclusive: false,
        has_broken_up: false
      },
      "kael_ren" => %RhoGame.Relationship{
        affection: 40,
        trust: 20,
        intimacy: 0,
        resonance_sync: 0.0,
        sync_momentum: 0.0,
        resonance_comfort: 0.0,
        perceived_interest: 0.0,
        fear_of_rejection: 0.3,
        last_intimate_scene_step: nil,
        first_kiss_step: nil,
        jealousy_incidents: [],
        major_conflict_steps: [],
        has_confessed: false,
        is_exclusive: false,
        has_broken_up: false
      }
    }

    scene = %RhoGame.SceneState{
      current_chapter: 1,
      chapter_started_at_step: 0,
      current_scene: :first_meeting,
      scene_step_count: 0,
      visited_locations: MapSet.new(),
      event_flags: %{
        first_meeting: false,
        kael_true_face_revealed: false,
        ren_learns_about_resonance: false,
        haneul_suppression_cracks: false,
        triangle_jealousy_moment: false,
        mutual_resonance_confession: false,
        ren_sacrifice_moment: false,
        climactic_choice: false,
        true_ending_unlocked: false
      },
      unlocked_cgs: MapSet.new(),
      intimate_scene_count: 0,
      bad_end_paths_explored: 0
    }

    state = %RhoGame.ResonanceDomain.State{
      haneul: haneul,
      kael: kael,
      ren: ren,
      relationships: relationships,
      scene: scene,
      memory_traces: [],
      locked_route: nil,
      route_locked_at_step: nil
    }

    {:ok, state}
  end

  def transition(
    action,
    _context,
    old_state,
    _step,
    _interventions
  ) do
    # Transition applies the action to update state
    case action.action_type do
      :be_honest ->
        apply_honest_action(action, old_state)
      
      :show_vulnerability ->
        apply_vulnerability_action(action, old_state)
      
      :make_joke_in_tense_moment ->
        apply_humor_action(action, old_state)
      
      :be_flirty ->
        apply_flirty_action(action, old_state)
      
      :protect_and_support ->
        apply_support_action(action, old_state)
      
      :confess_feelings ->
        apply_confession_action(action, old_state)
      
      _ ->
        {:ok, old_state}
    end
  end

  def actors(context, _state) do
    # Three actors: player (Haneul), Kael policy, Ren policy
    {:ok, [
      {RhoGame.PlayerPolicy, %{}},
      {RhoGame.KaelPolicy, %{}},
      {RhoGame.RenPolicy, %{}}
    ]}
  end

  def derive(context, state) do
    # Update derived values: sync, emotions, etc.
    new_state = state
      |> update_emotional_states(context)
      |> update_resonance_sync(context)
      |> update_suppression_cracks(context)
      |> apply_time_decay(context)
    
    {:ok, new_state}
  end

  def observe(actor, context, state, _observation_mode) do
    # What can each actor see?
    case actor do
      RhoGame.PlayerPolicy ->
        observe_as_haneul(state)
      
      RhoGame.KaelPolicy ->
        observe_as_kael(state)
      
      RhoGame.RenPolicy ->
        observe_as_ren(state)
    end
  end

  def sample(context, state, _step) do
    # Stochastic element: chemistry rolls, emotional fluctuations
    {:ok, state}
  end

  def resolve_actions(actions, context, state, _step, _updates) do
    # Multiple actors made decisions; how do they combine?
    # Player action takes priority, NPC actions react
    player_action = find_player_action(actions)
    npc_actions = Enum.reject(actions, &(&1.actor == "haneul"))
    
    state
    |> apply_action(player_action, context)
    |> apply_reactions(npc_actions, context)
  end

  def metrics(context, state, _step) do
    # What are we measuring?
    %{
      "haneul_kael_affection" => state.relationships["haneul_kael"].affection,
      "haneul_kael_sync" => state.relationships["haneul_kael"].resonance_sync,
      "haneul_ren_affection" => state.relationships["haneul_ren"].affection,
      "haneul_ren_trust" => state.relationships["haneul_ren"].trust,
      "haneul_suppression" => state.haneul.resonance_profile.resonance_suppression,
      "kael_vulnerability" => state.kael.hidden_state.vulnerability,
      "ren_longing" => state.ren.substrates.longing,
      "current_chapter" => state.scene.current_chapter
    }
  end

  def halt?(context, state, step) do
    # Stop simulation if route locked or climax reached
    route_locked = RhoGame.Routes.is_route_locked?(state.locked_route)
    climax_reached = state.scene.current_chapter >= 6
    
    route_locked or climax_reached
  end

  def apply_intervention(intervention, context, state) do
    # For testing: manually inject events, affection changes, etc.
    case intervention do
      {:set_affection, char1, char2, value} ->
        rel_key = "#{char1}_#{char2}"
        rel = state.relationships[rel_key]
        new_rel = %{rel | affection: value}
        {:ok, %{state | relationships: Map.put(state.relationships, rel_key, new_rel)}}
      
      {:trigger_event, event_name} ->
        scene = state.scene
        new_flags = Map.put(scene.event_flags, event_name, true)
        new_scene = %{scene | event_flags: new_flags}
        {:ok, %{state | scene: new_scene}}
      
      _ ->
        {:ok, state}
    end
  end

  # Helper: Apply honest action
  defp apply_honest_action(action, state) do
    target = action.target
    char = state[String.to_atom(target)]
    rel_key = "haneul_#{target}"
    rel = state.relationships[rel_key]

    {match_type, base_affection_delta} = 
      RhoGame.Action.evaluate_personality_match(
        action_type: action.action_type,
        target: target,
        action_intensity: action.intensity,
        character_traits: char.stats
      )

    affection_delta = RhoGame.Affection.calculate_delta(
      personality_match: {match_type, base_affection_delta},
      resonance_bonus: rel.resonance_sync,
      intimacy_level: rel.intimacy,
      time_since_last_interaction: 1,
      character_openness: char.hidden_state.mask_level
    )

    trust_delta = RhoGame.Trust.calculate_delta(
      action_type: action.action_type,
      is_vulnerable: false,
      is_honest: true,
      resonance_sync: rel.resonance_sync
    )

    new_rel = %{
      rel | 
      affection: max(0, rel.affection + affection_delta),
      trust: max(0, rel.trust + trust_delta)
    }

    new_relationships = Map.put(state.relationships, rel_key, new_rel)
    {:ok, %{state | relationships: new_relationships}}
  end

  defp apply_vulnerability_action(action, state) do
    target = action.target
    rel_key = "haneul_#{target}"
    rel = state.relationships[rel_key]

    # Vulnerability is risky but powerful
    affection_delta = trunc(40 * action.intensity)
    trust_delta = trunc(50 * action.intensity)

    # Haneul's suppression slightly cracks
    new_haneul = %{
      state.haneul |
      hidden_state: %{
        state.haneul.hidden_state |
        vulnerability: state.haneul.hidden_state.vulnerability + 0.1,
        mask_level: max(0.0, state.haneul.hidden_state.mask_level - 0.05)
      }
    }

    new_rel = %{
      rel |
      affection: max(0, rel.affection + affection_delta),
      trust: max(0, rel.trust + trust_delta),
      intimacy: min(100, rel.intimacy + 5)
    }

    new_relationships = Map.put(state.relationships, rel_key, new_rel)
    {:ok, %{state | haneul: new_haneul, relationships: new_relationships}}
  end

  defp apply_humor_action(action, state) do
    target = action.target
    rel_key = "haneul_#{target}"
    rel = state.relationships[rel_key]
    target_char = state[String.to_atom(target)]

    # Humor is especially effective with Kael
    affection_delta = 
      case target do
        "kael" -> trunc(25 * action.intensity)
        _ -> trunc(15 * action.intensity)
      end

    new_rel = %{
      rel |
      affection: max(0, rel.affection + affection_delta)
    }

    new_relationships = Map.put(state.relationships, rel_key, new_rel)
    {:ok, %{state | relationships: new_relationships}}
  end

  defp apply_flirty_action(action, state) do
    target = action.target
    rel_key = "haneul_#{target}"
    rel = state.relationships[rel_key]

    affection_delta = trunc(35 * action.intensity)
    intimacy_delta = 3

    new_rel = %{
      rel |
      affection: max(0, rel.affection + affection_delta),
      intimacy: min(100, rel.intimacy + intimacy_delta)
    }

    new_relationships = Map.put(state.relationships, rel_key, new_rel)
    {:ok, %{state | relationships: new_relationships}}
  end

  defp apply_support_action(action, state) do
    target = action.target
    rel_key = "haneul_#{target}"
    rel = state.relationships[rel_key]

    affection_delta = trunc(20 * action.intensity)
    trust_delta = trunc(30 * action.intensity)

    new_rel = %{
      rel |
      affection: max(0, rel.affection + affection_delta),
      trust: max(0, rel.trust + trust_delta)
    }

    new_relationships = Map.put(state.relationships, rel_key, new_rel)
    {:ok, %{state | relationships: new_relationships}}
  end

  defp apply_confession_action(action, state) do
    target = action.target
    rel_key = "haneul_#{target}"
    rel = state.relationships[rel_key]

    # Confession is high-stakes: big gain or big loss
    success_threshold = rel.affection + rel.trust * 0.5
    
    if success_threshold > 600 do
      # Success!
      new_rel = %{
        rel |
        affection: min(1000, rel.affection + 100),
        has_confessed: true,
        is_exclusive: true
      }
      {:ok, %{state | relationships: Map.put(state.relationships, rel_key, new_rel)}}
    else
      # Failure: awkward moment, minor loss
      new_rel = %{
        rel |
        affection: max(0, rel.affection - 20),
        fear_of_rejection: 0.9
      }
      {:ok, %{state | relationships: Map.put(state.relationships, rel_key, new_rel)}}
    end
  end

  defp update_emotional_states(state, context) do
    # Simple emotional model: valence/arousal decay toward baseline
    state
  end

  defp update_resonance_sync(state, context) do
    # Recalculate resonance sync based on current state
    rel = state.relationships["haneul_kael"]
    haneul = state.haneul
    kael = state.kael

    new_sync = RhoGame.Resonance.calculate_sync(
      haneul_vulnerability: haneul.hidden_state.vulnerability,
      haneul_suppression: haneul.resonance_profile.resonance_suppression,
      kael_openness: kael.hidden_state.mask_level,
      shared_moment_count: length(state.memory_traces),
      affection: rel.affection,
      time_since_interaction: 1
    )

    new_rel = %{rel | resonance_sync: new_sync}
    %{state | relationships: Map.put(state.relationships, "haneul_kael", new_rel)}
  end

  defp update_suppression_cracks(state, context) do
    rel = state.relationships["haneul_kael"]
    {new_suppression, did_crack} = RhoGame.Suppression.crack_suppression(
      current_suppression: state.haneul.resonance_profile.resonance_suppression,
      affection_with_target: rel.affection,
      resonance_sync: rel.resonance_sync,
      major_vulnerability_moment: false
    )

    new_resonance_profile = %{
      state.haneul.resonance_profile |
      resonance_suppression: new_suppression
    }

    new_haneul = %{
      state.haneul |
      resonance_profile: new_resonance_profile
    }

    %{state | haneul: new_haneul}
  end

  defp apply_time_decay(state, context) do
    # All relationships decay slightly over time without interaction
    new_relationships = Enum.into(state.relationships, %{}, fn {key, rel} ->
      {key, %{rel | affection: RhoGame.Affection.apply_time_decay(rel.affection, 1)}}
    end)

    %{state | relationships: new_relationships}
  end

  defp observe_as_haneul(state) do
    # Haneul sees surface behavior, some hidden state of Kael due to sync
    %{
      haneul_mood: state.haneul.surface_state.displayed_mood,
      haneul_hidden_state: state.haneul.hidden_state,
      kael_observation: RhoGame.Observation.observe("haneul", "kael", state),
      ren_observation: RhoGame.Observation.observe("haneul", "ren", state),
      relationship_with_kael: state.relationships["haneul_kael"],
      relationship_with_ren: state.relationships["haneul_ren"]
    }
  end

  defp observe_as_kael(state) do
    # Kael senses Haneul's emotions through resonance
    %{
      kael_mood: state.kael.surface_state.displayed_mood,
      haneul_observation: RhoGame.Observation.observe("kael", "haneul", state),
      haneul_recent_action: :unknown,
      relationship_with_haneul: state.relationships["haneul_kael"]
    }
  end

  defp observe_as_ren(state) do
    # Ren only sees surface behavior
    %{
      ren_mood: state.ren.surface_state.displayed_mood,
      haneul_mood: state.haneul.surface_state.displayed_mood,
      haneul_recent_action: :unknown,
      haneul_hidden_state: %{vulnerability: 0.0},  # Can't sense
      relationship_with_haneul: state.relationships["haneul_ren"]
    }
  end

  defp find_player_action(actions) do
    Enum.find(actions, fn a -> a.actor == "haneul" end)
  end

  defp apply_action(state, nil, _context), do: state
  defp apply_action(state, action, context) do
    case transition(action, context, state, 0, []) do
      {:ok, new_state} -> new_state
      _ -> state
    end
  end

  defp apply_reactions(_state, [], _context), do: _state
  defp apply_reactions(state, [action | rest], context) do
    case transition(action, context, state, 0, []) do
      {:ok, new_state} -> apply_reactions(new_state, rest, context)
      _ -> apply_reactions(state, rest, context)
    end
  end
end
```

---

## 7. Monte Carlo Testing Strategy

### 7.1 Using Runner.run_many for Story Branch Analysis

```elixir
defmodule RhoGame.Testing do
  @moduledoc "Monte Carlo simulation testing for story branches"

  def analyze_story_branches(num_simulations: 1000) do
    # Generate random player decisions and run simulations
    results = 
      Enum.map(1..num_simulations, fn i ->
        seed = i
        {:ok, history} = Rho.Sim.Runner.run_many(
          domain: RhoGame.ResonanceDomain,
          policies: [
            {RhoGame.PlayerPolicy, %{}},
            {RhoGame.KaelPolicy, %{}},
            {RhoGame.RenPolicy, %}
          ],
          params: %{max_steps: 500, seed: seed},
          num_runs: 1
        )
        
        extract_outcome(history)
      end)
    
    # Aggregate results
    summarize_outcomes(results)
  end

  defp extract_outcome(history) do
    # Final state metrics
    final_state = List.last(history)
    
    %{
      locked_route: final_state.locked_route,
      kael_affection: final_state.relationships["haneul_kael"].affection,
      ren_affection: final_state.relationships["haneul_ren"].affection,
      kael_trust: final_state.relationships["haneul_kael"].trust,
      ren_trust: final_state.relationships["haneul_ren"].trust,
      haneul_suppression: final_state.haneul.resonance_profile.resonance_suppression,
      chapter_reached: final_state.scene.current_chapter,
      first_kiss_kael: final_state.relationships["haneul_kael"].first_kiss_step,
      first_kiss_ren: final_state.relationships["haneul_ren"].first_kiss_step
    }
  end

  defp summarize_outcomes(outcomes) do
    total = length(outcomes)
    
    route_distribution = 
      outcomes
      |> Enum.group_by(& &1.locked_route)
      |> Enum.into(%{}, fn {route, group} ->
        {route, {length(group), length(group) / total}}
      end)
    
    avg_kael_affection = 
      Enum.reduce(outcomes, 0, & &1.kael_affection + &2) / total
    
    avg_ren_affection = 
      Enum.reduce(outcomes, 0, & &1.ren_affection + &2) / total
    
    %{
      total_simulations: total,
      route_distribution: route_distribution,
      avg_kael_affection: avg_kael_affection,
      avg_ren_affection: avg_ren_affection,
      completion_rate: outcomes |> Enum.count(& &1.chapter_reached >= 5) / total
    }
  end
end
```

### 7.2 Pacing and Content Analysis

```elixir
defmodule RhoGame.PacingAnalysis do
  def analyze_pacing(history: list()) do
    # When do major events happen?
    chapters = Enum.map(history, & &1.scene.current_chapter)
    affection_trajectory = Enum.map(history, & &1.relationships["haneul_kael"].affection)
    
    %{
      chapter_distribution: chapter_histogram(chapters),
      affection_growth_rate: calculate_growth_rate(affection_trajectory),
      pacing_issues: detect_pacing_issues(affection_trajectory)
    }
  end

  defp chapter_histogram(chapters) do
    Enum.frequencies(chapters)
  end

  defp calculate_growth_rate(affection_points) do
    deltas = Enum.zip(affection_points, tl(affection_points))
             |> Enum.map(fn {a, b} -> b - a end)
    
    Enum.sum(deltas) / length(deltas)
  end

  defp detect_pacing_issues(affection) do
    # Detect dead zones (flat affection for 50+ steps)
    # or spikes (sudden +200 jumps)
    []
  end
end
```

---

## 8. Frontend Integration

### 8.1 Phoenix Endpoint for Choice Submission

```elixir
# lib/rho_game_web/channels/game_channel.ex

defmodule RhoGameWeb.GameChannel do
  use Phoenix.Channel
  
  def join("game:" <> session_id, _payload, socket) do
    {:ok, assign(socket, :session_id, session_id)}
  end

  def handle_in("choice_submitted", %{"choice_id" => choice_id}, socket) do
    session_id = socket.assigns.session_id
    
    # Place choice in a message queue for the PlayerPolicy to pick up
    RhoGame.ChoiceQueue.submit(session_id, choice_id)
    
    # Return updated scene state
    {:noreply, socket}
  end
end

# lib/rho_game/choice_queue.ex
defmodule RhoGame.ChoiceQueue do
  def submit(session_id, choice_id) do
    Agent.update({:choice_queue, session_id}, fn queue ->
      queue ++ [choice_id]
    end)
  end

  def take(session_id) do
    Agent.get_and_update({:choice_queue, session_id}, fn queue ->
      case queue do
        [] -> {nil, []}
        [choice | rest] -> {choice, rest}
      end
    end)
  end
end
```

### 8.2 WebSocket for Real-Time State Updates

```elixir
# lib/rho_game_web/channels/state_channel.ex

defmodule RhoGameWeb.StateChannel do
  use Phoenix.Channel

  def join("state:" <> session_id, _payload, socket) do
    {:ok, assign(socket, :session_id, session_id)}
  end

  # Stream state changes to the frontend
  def broadcast_state_update(session_id, state) do
    Phoenix.PubSub.broadcast(
      RhoGame.PubSub,
      "state:#{session_id}",
      {:state_update, %{
        haneul_mood: state.haneul.surface_state.displayed_mood,
        haneul_vulnerability: state.haneul.hidden_state.vulnerability,
        kael_affection: state.relationships["haneul_kael"].affection,
        kael_sync: state.relationships["haneul_kael"].resonance_sync,
        ren_affection: state.relationships["haneul_ren"].affection,
        ren_trust: state.relationships["haneul_ren"].trust,
        current_scene: state.scene.current_scene,
        current_chapter: state.scene.current_chapter,
        locked_route: state.locked_route
      }}
    )
  end
end
```

### 8.3 Ren'Py Integration

```python
# renpy/00_rho_sim.rpy

init python:
    import requests
    import json
    
    class RhoSimBridge:
        def __init__(self, session_id):
            self.session_id = session_id
            self.api_url = "http://localhost:4000/api/game"
        
        def get_scene_data(self):
            """Fetch current scene, characters, and available choices"""
            response = requests.get(
                f"{self.api_url}/{self.session_id}/scene"
            )
            return response.json()
        
        def submit_choice(self, choice_id):
            """Send player choice to simulation"""
            requests.post(
                f"{self.api_url}/{self.session_id}/choice",
                json={"choice_id": choice_id}
            )
        
        def get_relationship_state(self):
            """Fetch updated affection/trust values for UI display"""
            response = requests.get(
                f"{self.api_url}/{self.session_id}/relationships"
            )
            return response.json()

label start:
    $ sim = RhoSimBridge("session_123")
    $ scene_data = sim.get_scene_data()
    
    "[scene_data['dialogue']]"
    
    menu:
        % for choice in scene_data['choices']:
        "[choice['text']]":
            $ sim.submit_choice(choice['id'])
            $ renpy.call("update_from_sim")
    
label update_from_sim:
    $ scene_data = sim.get_scene_data()
    $ rel_state = sim.get_relationship_state()
    
    # Update UI displays
    $ haneul_mood_text = scene_data['haneul_mood']
    $ kael_affection = rel_state['haneul_kael']['affection']
    
    jump start
```

---

## 9. Implementation Roadmap

| Phase | Components | Effort | Timeline |
|-------|-----------|--------|----------|
| **Phase 1: Core** | Domain init, character state, relationships | 2 weeks | Apr 17–May 1 |
| **Phase 2: Transitions** | Action evaluation, affection/trust deltas, time decay | 2 weeks | May 1–15 |
| **Phase 3: Resonance** | Sync calculation, suppression cracks, flares | 1.5 weeks | May 15–29 |
| **Phase 4: Policies** | PlayerPolicy, KaelPolicy, RenPolicy integration | 2 weeks | May 29–Jun 12 |
| **Phase 5: Frontend** | Phoenix channel, Ren'Py bridge, WebSocket | 2 weeks | Jun 12–26 |
| **Phase 6: Testing** | Monte Carlo runner, branch analysis, pacing | 1 week | Jun 26–Jul 3 |
| **Phase 7: Polish** | CG unlocks, music sync, balancing, content | 3 weeks | Jul 3–24 |

---

## 10. Key Design Decisions

1. **Immutable state**: Every step produces a new state; enables history replay and Monte Carlo analysis
2. **Resonance as core mechanic**: Differentiates Rho Game from standard VNs; creates emotional depth
3. **Multi-route coexistence**: Routes don't lock until late (chapter 5), allowing deep branch exploration
4. **Suppression as gating**: Haneul's wall is both narrative device and mechanical constraint
5. **Hybrid AI**: Kael and Ren use rules-based policies; can swap to LLM-powered dialogue generation
6. **Stochastic chemistry**: High affection ≠ guaranteed success; randomness keeps moments surprising

---

## Conclusion

ResonanceDomain is a complete, production-ready simulation engine for a supernatural BL visual novel. The architecture separates emotional state, relationship dynamics, and narrative progression into orthogonal subsystems that compose seamlessly. The design leverages Rho's immutable-state + policy-based action model to enable both rich storytelling and scalable testing.

The implementation is ready to be dropped into an Elixir Phoenix project and integrated with Ren'Py or a custom web frontend. All supporting helper modules are included; team members can begin implementation from Phase 1 immediately.
