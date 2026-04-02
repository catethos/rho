# Intelligent Agent Systems

*A Unified Theory from Algebraic Effects to Production*

*Covering: Continuation Passing Style · Algebraic Effects ·
Probabilistic Programming*

*ReAct Loops · Actor Model · Agent-Based Modelling · DSL & Interpreter
Architecture*

*Sequential Monte Carlo · Program Synthesis · Rust NIFs ·
Commercialisation*

## Abstract

This paper presents a unified theoretical and practical framework for
building intelligent agent systems grounded in the mathematics of
computation rather than engineering folklore. We argue that the central
abstractions required — continuation passing style, algebraic effects,
probabilistic inference, actor-model concurrency, agent-based modelling,
and domain-specific language design — are not independent ideas
loosely connected by analogy but manifestations of a single underlying
structure: the separation of a program\'s intent from the strategy used
to execute it.

Beginning from first principles in programming language theory, we
derive each component of the stack from the one before it, showing how a
ReAct-style agent loop is structurally identical to a probabilistic
program, how the Erlang/Elixir actor model provides the natural
substrate for both, how agent-based modelling reframes multi-agent LLM
systems as emergent simulation, and how Sequential Monte Carlo over LLM
traces provides calibrated uncertainty that naive repeated sampling
fundamentally cannot.

The second half of the paper bridges theory to industry. We show how
this stack translates into a defensible commercial product, why the
particle distribution — not the structured output — is the sellable
artifact, how to make SMC economically viable through hierarchical
allocation and distillation, and how to structure a research programme
that generates enough revenue to sustain itself. The result is a
complete map from the most abstract theory to the most concrete
deployment decision.

# 1  Introduction
The engineering of LLM-based agent systems has proceeded largely without
theoretical grounding. Frameworks are assembled from pragmatic
observations: chain-of-thought improves reasoning, tool calls enable
action, retrieval augments memory. These observations are correct and
useful, but they do not explain why these techniques work, under what
conditions they fail, or how they compose into systems with predictable
properties at scale.

This paper argues that all of these techniques are surface expressions
of a single deeper structure, and that recognising this structure is not
merely academically satisfying — it is practically necessary for
building systems that are reliable, composable, improvable over time,
and commercially defensible.

The central claim is this: an LLM agent is a probabilistic program whose
effects are handled by an external interpreter. Once this is seen
clearly, the entire theoretical apparatus of programming language
theory, probabilistic inference, and concurrent systems becomes
available for engineering agent systems. The problem is not new; only
the substrate — large language models — is new.

## 1.1  The Convergence of Three Traditions
Three intellectual traditions, developed largely independently, converge
on the same set of abstractions:

**Programming language theory** developed continuation passing style,
monads, and algebraic effects to reason precisely about computational
effects — state, exceptions, nondeterminism, and input/output. The
central achievement of this tradition is the separation of what a
program computes from how those computations are executed.

**Probabilistic programming** developed languages in which randomness is
a first-class effect, and inference algorithms serve as the interpreters
of probabilistic programs. The central achievement is that the same
program can be run under different inference regimes — forward
sampling, MCMC, SMC, variational inference — without modification.

**Distributed systems** and specifically the Erlang/OTP tradition,
developed the actor model as a practical substrate for fault-tolerant
concurrent computation. The central achievement is that processes,
supervisors, and message passing provide isolation, composition, and
recovery that no shared-memory threading model can match.

These three traditions converge precisely at the point where LLM agent
systems live. An agent that reasons and acts is executing a
probabilistic program. That program has effects — LLM calls, tool
invocations, spawning sub-agents — that require handlers. Those
handlers run in a concurrent, fault-prone environment that demands the
actor model\'s guarantees. Recognising this convergence is the
foundation of everything that follows.

## 1.2  Structure of This Paper
The paper proceeds from the most abstract to the most concrete. Section
2 develops the theory of continuation passing style and algebraic
effects as the foundation. Section 3 shows how probabilistic programming
is a special case. Section 4 derives the ReAct agent loop from CPS.
Section 5 examines the Erlang/Elixir actor model as the natural
substrate. Section 6 connects agent-based modelling to multi-agent LLM
systems. Section 7 presents the DSL and interpreter architecture that
unifies everything. Section 8 addresses programs that write and improve
programs. Section 9 provides a rigorous analysis of Sequential Monte
Carlo vs naive sampling. Section 10 presents practical cost-reduction
strategies. Section 11 addresses commercialisation. Section 12 discusses
open problems.

# 2  Continuation Passing Style and Algebraic Effects
## 2.1  The Problem of Effects
A pure function maps inputs to outputs with no observable interaction
with the world outside its scope. Real programs are not pure: they read
files, make network calls, sample random numbers, throw exceptions,
update state. These interactions are called computational effects, and
managing them — reasoning about when they occur, in what order, and
how they compose — is one of the central problems of programming
language design.

The naive approach is to allow effects to happen implicitly wherever
they are called. This is what most programming languages do by default,
and it makes programs difficult to test, reason about, and compose. A
function that calls a network API is not just a computation — it is a
computation entangled with a specific network, a specific authentication
context, a specific failure mode. Changing any of these requires
changing the function.

The insight that unlocks everything is that effects can be treated as
values — as data that describes what the program wants to do, rather
than as imperative actions that it immediately performs. If an effect is
a value, it can be intercepted, transformed, reinterpreted, or replayed
by an external handler. The program and the execution strategy become
cleanly separable.

## 2.2  Continuation Passing Style
Continuation passing style (CPS) is the transformation that makes
effects first-class. In direct style, a function computes a result and
returns it to its caller. In CPS, a function receives an additional
argument — the continuation k — which represents the rest of the
computation that will consume the result. Rather than returning, the
function calls k with its result.

+———————————————————————--+
| \-- Direct style                                                      |
|                                                                       |
| add : Int -\> Int -\> Int                                             |
|                                                                       |
| add x y = x + y                                                       |
|                                                                       |
| result = add 3 4 \-- returns 7                                        |
|                                                                       |
| use result                                                            |
|                                                                       |
| \-- CPS transformation                                                |
|                                                                       |
| add_cps : Int -\> Int -\> (Int -\> r) -\> r                           |
|                                                                       |
| add_cps x y k = k (x + y)                                             |
|                                                                       |
| add_cps 3 4 (\\result -\> use result) \-- calls continuation with 7   |
+———————————————————————--+

This transformation seems mechanical, but its consequences are profound.
Once k is explicit, the function can do things with it that are
impossible in direct style: call it zero times (abort), call it multiple
times (nondeterminism), store it for later (coroutines, async), pass it
to another function (delegation), or wrap it in logging, caching, or
retry logic. The continuation is the rest of the computation, made
tangible and manipulable.

The trampoline pattern shows how CPS eliminates stack growth: instead of
nested function calls building a call stack, each CPS function calls the
next continuation and returns, allowing the runtime to reclaim stack
frames. The BEAM virtual machine implements exactly this — each Erlang
process is a trampolined CPS computation, with the mailbox as the
mechanism for passing continuation arguments between steps.

## 2.3  Delimited Continuations
Full continuations — captured with operators like call/cc —
represent the entire rest of the program, which makes them difficult to
reason about and compose. Delimited continuations, introduced by
Felleisen and refined through shift/reset and the family of related
operators, capture only a bounded portion of the computation — from
the current point up to a dynamically installed delimiter.

Delimited continuations are the precise mechanism underlying algebraic
effects. When a program performs an effect, it captures the delimited
continuation up to the nearest enclosing handler, hands that
continuation to the handler, and waits. The handler can resume the
continuation with a value (pure handler), resume it multiple times
(nondeterminism, SMC), or discard it (abort, rejection sampling). This
is the complete operational semantics of algebraic effects.

## 2.4  Algebraic Effects and Handlers
An algebraic effect system consists of two components: effect
declarations, which name and type the effects a program may perform, and
handlers, which provide the interpretation of those effects for a given
execution context. The program is parametrically polymorphic in its
handlers — it does not know or care which handler is installed, only
that some handler will interpret its effects.

+———————————————————————--+
| \-- Effect declarations: vocabulary of what programs can want         |
|                                                                       |
| effect LLMCall where                                                  |
|                                                                       |
| complete : Prompt -\> Options -\> String                              |
|                                                                       |
| effect ToolInvoke where                                               |
|                                                                       |
| invoke : ToolName -\> Args -\> Result                                 |
|                                                                       |
| effect Sample where                                                   |
|                                                                       |
| draw : Distribution a -\> a                                           |
|                                                                       |
| effect Spawn where                                                    |
|                                                                       |
| spawnAgent : AgentParams -\> AgentHandle                              |
|                                                                       |
| \-- A program uses effects without knowing how they will be handled   |
|                                                                       |
| researchAgent : Goal -\> Eff \[LLMCall, ToolInvoke, Sample\] Report   |
|                                                                       |
| researchAgent goal = do                                               |
|                                                                       |
| plan \<- complete (planningPrompt goal) defaultOpts                   |
|                                                                       |
| steps \<- parseSteps plan                                             |
|                                                                       |
| results \<- forM steps \$ \\step -\> do                               |
|                                                                       |
| shouldSearch \<- draw (bernoulli 0.8)                                 |
|                                                                       |
| if shouldSearch                                                       |
|                                                                       |
| then invoke WebSearch (queryFor step)                                 |
|                                                                       |
| else complete (reasonPrompt step) defaultOpts                         |
|                                                                       |
| complete (synthesisPrompt results) defaultOpts                        |
+———————————————————————--+

The handler is an entirely separate entity that gives meaning to these
declarations. Crucially, handlers can be composed — a logging handler
wraps a retry handler wraps a rate-limiting handler wraps a production
handler, each intercepting only the effects it cares about and passing
the rest through. This is middleware, but for the complete semantics of
computation rather than merely for HTTP requests.

  —————————————————————————-
  **Handler**         **LLMCall          **Sample           **Spawn
                      semantics**        semantics**        semantics**
  ——————- —————— —————— ——————
  ProductionHandler   Real API call      Draw from          BEAM process
                                         distribution       

  SMCHandler(n=100)   Fork continuation  Weighted draw,     Particle process
                      N times            resample           

  TestHandler         Return fixture     Deterministic seed Synchronous mock

  DebugHandler        Log + real call    Log + real draw    Log + real spawn

  CompilerHandler     Emit DAG node      Emit choice node   Emit fork node
  —————————————————————————-

  -- ———————————————————————
     *The central claim in practical terms: you write your agent code
     once, against the effect vocabulary. You swap execution strategies
     — testing, production, SMC inference, simulation — by swapping
     the handler. The agent code never changes.*

  -- ———————————————————————

## 2.5  The Algebraic Structure
The term \'algebraic\' in algebraic effects has a precise meaning: the
set of operations forms an algebra, and handlers are algebra
homomorphisms. This algebraic structure guarantees that effect handlers
compose correctly — a property that monad transformers struggle to
provide in the general case. For practical purposes, the consequence is
that you can layer handlers freely without worrying about interaction
effects between them, subject to the usual care about ordering.

The lineage of this idea runs from Moggi\'s computational lambda
calculus (1991) through Wadler\'s monads for functional programming
(1992), Filinski\'s layered monads (1999), Plotkin and Power\'s
algebraic effects (2001), Plotkin and Pretnar\'s handlers (2009), to
modern implementations in Koka, Eff, Frank, and the algebraic effects
proposal for OCaml. Your agent system is a practical instantiation of
ideas that took 30 years to formalise properly.

# 3  Probabilistic Programming as Algebraic Effects
## 3.1  Randomness as an Effect
A probabilistic program is a program in which randomness is a
first-class computational effect. The program draws samples from
distributions at arbitrary points in its execution, and the resulting
computation traces a path through a joint probability distribution over
all the random choices made. The goal of probabilistic programming is to
separate the model — the program that describes the joint distribution
— from the inference algorithm — the handler that computes
properties of that distribution.

This separation maps precisely onto the algebraic effects framework. The
Sample effect is a declaration that the program wants a random value
from a distribution. The inference engine is a handler that provides
that value, but also accumulates log-probabilities, manages the trace of
all random choices, and implements whatever inference algorithm has been
chosen. The program is completely unaware of which inference algorithm
is running.

## 3.2  The Trace as the Fundamental Object
When a probabilistic program executes under a forward-sampling handler,
it produces a trace: a record of every random choice made, the
distribution it was drawn from, and the value that was drawn. This trace
is itself a sample from the prior distribution over program executions.
The probability of a particular trace is the product of the
probabilities of each individual choice within it.

Conditioning on observations — the mechanism by which a probabilistic
program incorporates evidence — reweights traces by their likelihood
under the observed data. Traces that are inconsistent with observations
receive low or zero weight; traces that explain the observations well
receive high weight. The posterior distribution is the prior
distribution over traces, reweighted by likelihood.

This framework applies directly to LLM agent systems. A ReAct loop
produces a trace of (thought, action, observation) tuples. Each action
is a random draw from the LLM\'s output distribution. The trace has an
implicit probability — the product of the LLM\'s token probabilities
over all generations in the trace. Conditioning on successful task
completion, on high reward-model scores, or on human preference
annotations reweights this distribution. Inference algorithms over agent
traces are just inference algorithms over probabilistic program traces,
with the LLM as the generative model.

## 3.3  Inference Algorithms as Handlers
Different inference algorithms correspond to different handlers for the
Sample effect. Understanding this correspondence makes it clear what
each algorithm can and cannot do, and what information it requires from
the LLM API.

  ————————————————————————--
  **Inference        **Handler          **LLM API       **Typical Use Case**
  Algorithm**        Behaviour**        Requirement**   
  —————— —————— ————— ——————--
  Forward sampling   Draw from          Any completion  Baseline generation
                     distribution,                      
                     accumulate nothing                 

  Rejection sampling Draw, check        Any completion  Constrained outputs
                     constraint,                        
                     restart if                         
                     violated                           

  Self-consistency   Draw N times,      N completions   Reasoning robustness
                     majority vote                      

  Importance         Draw, compute      Logprobs for    Distribution
  sampling           weight, return     weighting       estimation
                     weighted sample                    

  SMC (particle      Maintain N         N completions   Sequential evidence
  filter)            particles,         per step        
                     resample at                        
                     observations                       

  MCMC (Metropolis)  Propose mutation,  Logprobs for    Posterior
                     accept/reject,     ratio           exploration
                     chain                              

  Variational        Optimise proposal  Gradient signal Amortised inference
  inference          toward posterior   (rare)          
  ————————————————————————--

When the LLM is accessed via API, only the top rows of this table are
directly available. However, as we show in Section 9, SMC can be
approximated effectively with output-space reweighting even without
token-level logprobs, and the BEAM process model makes the parallel
sampling required by SMC economically and architecturally natural.

## 3.4  The LLM as a Learned Prior
In traditional probabilistic programming, prior distributions are
hand-specified by the modeller. In the LLM agent setting, the LLM
provides the prior — a richly structured distribution over actions,
thoughts, and outputs that has been learned from vast human-generated
data. This prior is enormously more expressive than any hand-specified
distribution, but it comes with a crucial limitation: it cannot be
directly queried for log-probabilities in most API contexts, and its
internal structure is opaque.

This limitation motivates the practical techniques of Section 10. When
the prior is opaque, inference algorithms that require only samples (SMC
with output-space reweighting, rejection sampling, self-consistency) are
preferred over algorithms that require density evaluations (importance
sampling with exact weights, Metropolis-Hastings). The prior\'s
expressiveness more than compensates for this limitation in most
practical settings.

+———————————————————————--+
| **Connection to Fine-Tuning and RLHF**                                |
|                                                                       |
| Fine-tuning and RLHF can be understood as modifying the prior —     |
| shifting the LLM\'s output distribution toward a target. From the     |
| probabilistic programming perspective, these techniques are not       |
| alternatives to inference but complements: a better prior makes       |
| inference more efficient. Conversely, inference at runtime (SMC,      |
| best-of-N) can compensate for a weaker prior. The optimal system uses |
| both: a domain-adapted prior and runtime inference over its outputs.  |
+———————————————————————--+

# 4  The ReAct Loop as CPS
## 4.1  Structure of the ReAct Loop
The ReAct (Reason + Act) paradigm structures agent behaviour as an
interleaved sequence of reasoning steps (thoughts) and action steps
(acts), with observations from the environment interleaved after each
action. The loop terminates when the agent produces a final answer or
exhausts its step budget.

Operationally, each iteration of the loop is a fresh call to the
language model with the accumulated context — the original prompt, all
previous thoughts, actions, and observations — appended. The model
generates the next thought or action, the environment executes the
action and returns an observation, and the process repeats. There is no
persistent agent state beyond the context window; all state is explicit
in the message history.

## 4.2  The CPS Reading
The ReAct loop is continuation passing style with the LLM as the
function being continued and tool results as the continuation arguments.
Each tool call is a CPS function: it does not return its result inline
to the model; instead, the result is provided in the next invocation of
the model, which is the continuation of the computation at that point.

More precisely: the model at step t receives the history H_t and
generates action a_t. The environment executes a_t and produces
observation o_t. The model at step t+1 receives H\_{t+1} = H_t ++
\[(a_t, o_t)\] and continues. The observation o_t is the argument passed
to the continuation — the next LLM call — exactly as in CPS.

+———————————————————————--+
| \-- The ReAct loop as explicit CPS                                    |
|                                                                       |
| react : History -\> Eff \[LLMCall, ToolInvoke\] Result                |
|                                                                       |
| react history =                                                       |
|                                                                       |
| \-- The LLM call IS the function                                      |
|                                                                       |
| output \<- complete (formatHistory history) opts                      |
|                                                                       |
| case parseOutput output of                                            |
|                                                                       |
| FinalAnswer result -\>                                                |
|                                                                       |
| pure result \-- computation terminates                                |
|                                                                       |
| Action tool args -\>                                                  |
|                                                                       |
| observation \<- invoke tool args \-- effect: tool call                |
|                                                                       |
| react (history ++ \[(output, observation)\]) \-- pass obs to          |
| continuation                                                          |
|                                                                       |
| \-- THIS IS k(observation)                                            |
+———————————————————————--+

The absence of an implicit call stack is significant. Unlike a recursive
program that accumulates frames, the ReAct loop is tail-recursive —
each iteration replaces the previous one. The history is the explicit
stack. This is not an implementation detail; it is why ReAct agents can
run indefinitely without memory leaks, and why they can be interrupted,
serialised, resumed, or branched at any step.

## 4.3  Multi-Agent Systems as Higher-Order CPS
When agents spawn sub-agents, we enter the territory of higher-order CPS
— continuations that themselves contain continuations. A planning
agent that delegates sub-tasks to specialist agents is passing a portion
of its continuation to each specialist: the specialist\'s result will
eventually be passed back to the planner as an observation, which the
planner will continue from.

This compositionality is exact, not approximate. The correctness of
multi-agent composition follows from the algebraic properties of effects
and handlers established in Section 2. Agents compose because effects
compose; sub-agent results flow back as continuation arguments because
that is what CPS guarantees.

Tree-of-Thought, graph-of-thought, and other structured reasoning
approaches are all specialisations of this higher-order structure —
they differ in the topology of the continuation graph, not in the
underlying mechanism.

## 4.4  Agent Memory as Explicit State
Persistent agent memory — episodic memory of past conversations,
semantic memory of domain knowledge, procedural memory of tool usage
patterns — is explicit state threaded through the continuation. This
is in contrast to human memory, which is implicit in the neural
substrate. The explicitness is both a limitation (context windows are
finite) and an advantage (memory can be inspected, edited, verified, and
optimised).

Retrieval-augmented generation (RAG) is, from the CPS perspective, a
handler for the Recall effect that implements memory retrieval as a side
effect of certain continuations. The retrieval query is the continuation
argument; the retrieved documents are the value passed back. The agent
program need not know whether memory is stored in a vector database, a
key-value store, or the context window itself — that is the handler\'s
concern.

# 5  The Actor Model as Effect Handler Substrate
## 5.1  Why Erlang/Elixir
The choice of substrate for running algebraic effect handlers is not
arbitrary. The substrate must provide: isolation between concurrent
computations (so that a failing handler does not corrupt others), cheap
concurrency (so that running N particles in parallel is economically
viable), message-passing semantics (so that continuation arguments can
be passed between handlers), and supervision (so that failing
computations can be restarted from known states).

The BEAM virtual machine, which underlies Erlang and Elixir, provides
all four. BEAM processes are lighter than OS threads (millions can run
concurrently), isolated by design (no shared heap), communicate
exclusively by message passing, and are managed by supervisors that
implement configurable restart strategies. These properties were
designed for telecommunications systems in the 1980s, but they map with
remarkable precision onto the requirements of a probabilistic agent
system in the 2020s.

## 5.2  Process as Suspended Continuation
A BEAM process blocked on receive is, precisely, a suspended
continuation. It holds the rest of its computation — its local
variables, its call stack, its program counter — frozen in memory,
waiting for a message to arrive. When a message arrives, it becomes the
argument to the continuation, and the process resumes.

This means that the BEAM scheduler is a trampoline for CPS computation.
The programmer does not write explicit trampolines or manually thread
continuations — the runtime handles it. The ReAct loop, written as a
GenServer receive loop, is automatically CPS-transformed by the BEAM\'s
process model.

+———————————————————————--+
| defmodule AgentProcess do                                             |
|                                                                       |
| use GenServer                                                         |
|                                                                       |
| \# This IS the suspended continuation                                 |
|                                                                       |
| \# process blocks here, waiting for k(observation)                    |
|                                                                       |
| def handle_info({:observation, obs}, state) do                        |
|                                                                       |
| new_history = state.history ++ \[obs\]                                |
|                                                                       |
| next_action = llm_call(new_history) \# propagate                      |
|                                                                       |
| case next_action do                                                   |
|                                                                       |
| {:tool, name, args} -\>                                               |
|                                                                       |
| \# Send to tool process — async, non-blocking                       |
|                                                                       |
| send(tool_pid(name), {:invoke, args, self()})                         |
|                                                                       |
| \# Process suspends here — THIS IS receive                          |
|                                                                       |
| {:noreply, %{state \| history: new_history}}                          |
|                                                                       |
| {:done, result} -\>                                                   |
|                                                                       |
| send(state.caller, {:result, result})                                 |
|                                                                       |
| {:stop, :normal, state}                                               |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
+———————————————————————--+

## 5.3  Supervisor Trees as Inference Algorithm Structure
An OTP supervisor tree is not merely a reliability mechanism — it is a
structural description of the inference algorithm being applied to the
agent system. The supervisor\'s restart strategy, its child
specifications, and its escalation policy together determine how the
system responds to failures, which is identical to how an inference
algorithm responds to rejected traces or degenerate particles.

  ————————————————————————--
  **Supervisor         **OTP Semantics**          **Inference Semantics**
  Strategy**                                      
  ——————-- ————————-- ————————--
  one_for_one          Restart only failed child  Resample failed particle,
                                                  keep others

  one_for_all          Restart all children       Restart entire SMC
                                                  population

  rest_for_one         Restart failed +           Resample particle +
                       dependents                 downstream dependencies

  simple_one_for_one   Dynamic pool of identical  Particle population of
                       workers                    identical samplers
  ————————————————————————--

The let-it-crash philosophy, which Erlang inherited from telecom
engineering, maps perfectly onto Monte Carlo trace rejection. A trace
that arrives at an impossible observation — zero likelihood — should
not attempt to recover; it should crash, and its supervisor should spawn
a replacement with a fresh sample. This is not a coincidence of
metaphor; it is the same decision procedure viewed from two different
disciplines.

## 5.4  Where Rust NIFs Are Required
The BEAM is excellent at orchestration — managing processes, routing
messages, supervising trees — but it is not a numerical computing
environment. For the inner loops of inference algorithms, where
floating-point arithmetic over large arrays dominates runtime, Rust NIFs
(Native Implemented Functions) accessed via the rustler crate provide
the necessary performance.

The critical constraint is the dirty scheduler. A NIF that runs for more
than approximately 1 millisecond without yielding will block one of the
BEAM\'s scheduler threads, defeating the entire concurrency model. All
computationally intensive NIFs must be declared as dirty CPU or dirty IO
NIFs, which run on separate scheduler threads and leave the main
scheduler pool available for process scheduling.

  ————————————————————————-
  **Task**              **Recommended      **Rust          **Dirty
                        Approach**         Crate(s)**      Scheduler?**
  ——————— —————— ————— —————-
  Local LLM forward     Rust NIF           candle, tch-rs  Yes (DirtyCpu)
  pass                                                     

  Embedding similarity  Rust NIF           ndarray, rayon  Yes (DirtyCpu)
  search                                                   

  MCMC / SMC kernel     Rust NIF           ndarray         Yes (DirtyCpu)
  computation                                              

  Tokenisation          Rust NIF           tokenizers (HF) Yes (DirtyCpu)

  Constrained decoding  Rust NIF           llguidance      Yes (DirtyCpu)
  automata                                                 

  Agent loop            Elixir GenServer   —             N/A
  orchestration                                            

  Tool call dispatch    Elixir             —             N/A
                        Task.Supervisor                    

  HTTP to external LLM  Elixir Finch/Req   —             N/A
  API                                                      

  JSON parsing of tool  Elixir Jason       —             N/A
  results                                                  
  ————————————————————————-

  -- ———————————————————————
     *The mental model: Elixir owns time — it decides what runs, when,
     how many times, and what to do when it fails. Rust owns math — it
     makes the inner numerical loops fast. Neither crosses into the
     other\'s domain without good reason.*

  -- ———————————————————————

# 6  Agent-Based Modelling and Emergence
## 6.1  ABM as the Right Mental Model
Agent-based modelling (ABM) is a computational approach to studying
complex systems in which global phenomena emerge from the local
interactions of individual agents. Each agent follows local rules,
perceives a local environment, and interacts with nearby agents; no
agent has access to global state or central coordination. The global
behaviour of the system — market dynamics, epidemic spread, opinion
polarisation, traffic flow — emerges from these local interactions in
ways that are often surprising and analytically intractable.

This is precisely the correct mental model for multi-agent LLM systems.
The mistake made by most multi-agent frameworks is to treat the system
as an orchestration problem — a central coordinator directs agents
toward a pre-specified global outcome. This approach fights against the
nature of the system. A better approach is to design local interaction
rules and communication topologies and allow the global behaviour to
emerge, using ABM theory to predict, measure, and steer emergent
properties.

## 6.2  The Formal Mapping
  ———————————————————————--
  **ABM Concept**     **LLM Multi-Agent            **Elixir
                      Equivalent**                 Implementation**
  ——————- —————————- ———————-
  Agent with local    GenServer with context       GenServer process
  state               window                       

  Local interaction   Tool calls, message passing, handle_info /
  rules               shared memory reads          handle_call

  Environment         External APIs, databases,    Tool process pool
                      world state                  

  Emergent global     Multi-agent reasoning        Observation of message
  behaviour           outcome, consensus           patterns

  Agent birth / death Spawn sub-agent / process    DynamicSupervisor
                      terminates                   start/stop

  Population          Distribution over outputs,   SMC particle
  statistics          self-consistency             population

  Network topology    Who communicates with whom   Supervisor tree shape

  Stigmergy           Blackboard / shared memory   Shared ETS table /
                      coordination                 Agent process

  Phase transition    Qualitative behaviour change Observable in metric
                      at parameter threshold       dashboards
  ———————————————————————--

## 6.3  Network Topology as a Design Parameter
One of the most important lessons from ABM research is that the network
topology — the graph structure of who communicates with whom —
determines the emergent properties of the system at least as much as the
local rules of individual agents. This insight is almost entirely absent
from multi-agent LLM frameworks, which typically default to fully
connected or hub-and-spoke topologies without considering alternatives.

ABM research has established that different topologies produce
characteristically different emergent behaviour:

-   Fully connected networks produce rapid information diffusion but are
    susceptible to cascade failures and echo chambers. Every agent
    immediately influences every other, which can produce rapid
    consensus but also rapid propagation of errors.

-   Small-world networks (high clustering, short average path length)
    balance local coherence with global reachability. They produce
    robust consensus with diversity preservation — agents form local
    communities that occasionally bridge to distant communities.

-   Scale-free networks (power-law degree distribution) have hubs that
    disproportionately influence the system. In agent terms, some agents
    — orchestrators, critics, synthesisers — receive and process
    information from many others while most agents have few connections.

-   Ring and lattice topologies produce slow but diverse information
    spread. Local groups develop distinct perspectives; global consensus
    is slow to form if it forms at all. Useful when diversity of
    approach is more valuable than speed.

Designing a multi-agent system is, in part, designing a network
topology. The choice should be driven by the properties you want the
system to exhibit: speed of convergence vs diversity of exploration,
robustness to individual agent failures vs sensitivity to expert agents,
uniformity of perspective vs richness of viewpoint.

## 6.4  Stigmergy: Coordination Without Direct Communication
Stigmergy is coordination that occurs through modification of a shared
environment rather than through direct agent-to-agent communication.
Ants coordinate foraging through pheromone trails — each ant both
follows and reinforces the trail, producing coordinated behaviour
without any ant communicating directly with any other.

This mechanism is underexplored in LLM multi-agent systems. A blackboard
architecture — in which agents read from and write to a shared
structured memory rather than messaging each other directly — is
stigmergic coordination. Agents do not need to know about each other;
they only need to know how to read and write the blackboard. The global
coordination emerges from the structure of the blackboard and the local
rules by which agents interact with it.

+———————————————————————--+
| defmodule Blackboard do                                               |
|                                                                       |
| use Agent                                                             |
|                                                                       |
| \# Agents write findings to the environment                           |
|                                                                       |
| def post(key, value, author, confidence) do                           |
|                                                                       |
| Agent.update(\_\_MODULE\_\_, fn state -\>                             |
|                                                                       |
| Map.put(state, key, %{value: value, author: author,                   |
|                                                                       |
| confidence: confidence, ts: DateTime.utc_now()})                      |
|                                                                       |
| end)                                                                  |
|                                                                       |
| end                                                                   |
|                                                                       |
| \# Agents read the environment state — no direct messaging          |
|                                                                       |
| def read_relevant(topic) do                                           |
|                                                                       |
| Agent.get(\_\_MODULE\_\_, fn state -\>                                |
|                                                                       |
| state \|\> Enum.filter(fn {k, \_} -\> related?(k, topic) end)         |
|                                                                       |
| end)                                                                  |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
+———————————————————————--+

## 6.5  Probabilistic ABM: Inference Over Simulations
The connection between ABM and probabilistic programming is
well-established in the scientific computing literature, where it is
called approximate Bayesian computation (ABC) or likelihood-free
inference. The setting is: you have an ABM with parameters θ, you
observe macro-level data y, and you want to infer P(θ \| y) — the
distribution over parameters consistent with the observed behaviour.

Since the ABM\'s likelihood P(y \| θ) is typically intractable (you
cannot write down a closed form for the probability that a given set of
agent rules produces a given macro-level pattern), ABC approximates it
by simulation: run the ABM with many parameter settings, keep the
settings that produce simulations close to y, and treat those as
approximate posterior samples.

This maps directly onto your LLM agent system. The agent rules are the
parameters θ (encoded in prompts, few-shot examples, tool
configurations). The observed macro-level data y is the desired system
behaviour (task completion rate, output quality, latency). You can run
the agent system under many configurations, score each run against y,
and identify the configurations that produce desired behaviour — this
is ABC applied to LLM agent systems.

# 7  The DSL and Interpreter Architecture
## 7.1  Programs as Data
The algebraic effects framework establishes the theoretical separation
between programs and their interpreters. The DSL and interpreter
architecture makes this separation concrete and usable. An agent program
written in the DSL is a data structure — an abstract syntax tree of
effect declarations, control flow operators, and combinators. This data
structure can be inspected, transformed, optimised, serialised,
transmitted, and interpreted by any compatible handler.

This is the ancient insight of Lisp, restated for agent systems: code is
data. The consequence is equally ancient: programs can be written,
modified, and analysed by other programs. In the agent context, this
means an LLM can write agent programs (program synthesis), an optimiser
can transform them (static analysis and optimisation), an inference
engine can run them multiple times with different outcomes
(probabilistic execution), and the system can learn which programs work
well and update its generative prior accordingly (meta-learning).

## 7.2  Initial vs Final Encoding
There are two canonical ways to represent a DSL in a host language. The
choice has significant practical consequences.

#### Initial Encoding (AST / Free Monad)
In the initial encoding, effects are represented as data constructors. A
program is a tree of constructor applications. Interpreters are
functions that pattern-match on constructors and provide their
semantics.

+———————————————————————--+
| \-- Initial encoding: effects as data                                 |
|                                                                       |
| data AgentProgram a                                                   |
|                                                                       |
| = Pure a                                                              |
|                                                                       |
| \| LLMCall Prompt Options (String -\> AgentProgram a)                 |
|                                                                       |
| \| ToolInvoke ToolName Args (Result -\> AgentProgram a)               |
|                                                                       |
| \| Sample (Distribution b) (b -\> AgentProgram a)                     |
|                                                                       |
| \| SpawnAgent AgentParams (Handle -\> AgentProgram a)                 |
|                                                                       |
| \| Sequence \[AgentProgram a\] (\[a\] -\> AgentProgram a)             |
|                                                                       |
| \-- An interpreter walks the tree                                     |
|                                                                       |
| interpret :: Handler -\> AgentProgram a -\> IO a                      |
|                                                                       |
| interpret h (Pure x) = return x                                       |
|                                                                       |
| interpret h (LLMCall p o k) = h.handleLLM p o \>\>= interpret h . k   |
|                                                                       |
| interpret h (ToolInvoke t a k) = h.handleTool t a \>\>= interpret h . |
| k                                                                     |
|                                                                       |
| interpret h (Sample d k) = h.handleSample d \>\>= interpret h . k     |
+———————————————————————--+

The initial encoding\'s key advantage is inspectability. Before running
a program, you can walk its AST to estimate cost, check for safety
violations, detect whether tools are called in the right order, or
compile it to a static execution DAG. This is impossible with direct
function calls.

#### Final Encoding (Tagless Final / Behaviour)
In the final encoding, effects are abstract operations of a typeclass or
behaviour. A program is a polymorphic function that works for any
implementation of the effect interface. The interpreter is an instance
of the typeclass.

+———————————————————————--+
| \# Final encoding in Elixir: effects as behaviour callbacks           |
|                                                                       |
| defmodule AgentEffects do                                             |
|                                                                       |
| \@callback llm_call(prompt :: String.t(), opts :: map()) ::           |
| String.t()                                                            |
|                                                                       |
| \@callback tool_invoke(name :: atom(), args :: map()) :: map()        |
|                                                                       |
| \@callback sample(dist :: Distribution.t()) :: term()                 |
|                                                                       |
| \@callback spawn_agent(params :: map()) :: pid()                      |
|                                                                       |
| end                                                                   |
|                                                                       |
| \# The agent program is parametric in its effects module              |
|                                                                       |
| defmodule ResearchAgent do                                            |
|                                                                       |
| def run(goal, effects) do \# effects is the interpreter               |
|                                                                       |
| plan = effects.llm_call(planning_prompt(goal), %{})                   |
|                                                                       |
| steps = parse_steps(plan)                                             |
|                                                                       |
| results = Enum.map(steps, fn step -\>                                 |
|                                                                       |
| if effects.sample(bernoulli(0.8)) do                                  |
|                                                                       |
| effects.tool_invoke(:web_search, %{q: step.query})                    |
|                                                                       |
| else                                                                  |
|                                                                       |
| effects.llm_call(reasoning_prompt(step), %{})                         |
|                                                                       |
| end                                                                   |
|                                                                       |
| end)                                                                  |
|                                                                       |
| effects.llm_call(synthesis_prompt(results), %{})                      |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
+———————————————————————--+

The final encoding\'s key advantage is zero overhead. There is no
intermediate data structure; the program compiles directly to whatever
the interpreter does. It is also more natural in most host languages.
The limitation is that you cannot inspect the program before running it
— you can only run it.

The optimal strategy for a production system is to use both: an initial
encoding for programs that are synthesised, analysed, or optimised
before execution, and a final encoding for programs that have been
verified and are being executed in production.

## 7.3  Handler Composition and the Middleware Stack
Handlers compose by wrapping: an outer handler intercepts effects,
performs some transformation or side effect, and delegates to the inner
handler. This produces a stack of handlers that each add a layer of
semantics to the program\'s execution.

+———————————————————————--+
| \# Handler composition: each layer adds semantics                     |
|                                                                       |
| def production_handler() do                                           |
|                                                                       |
| LoggingHandler.wrap( \# log every effect                              |
|                                                                       |
| MetricsHandler.wrap( \# emit Prometheus metrics                       |
|                                                                       |
| RetryHandler.wrap( \# retry on transient failure                      |
|                                                                       |
| RateLimitHandler.wrap( \# enforce API rate limits                     |
|                                                                       |
| CacheHandler.wrap( \# cache identical LLM calls                       |
|                                                                       |
| ProductionHandler.new() \# actually call the API                      |
|                                                                       |
| )                                                                     |
|                                                                       |
| )                                                                     |
|                                                                       |
| )                                                                     |
|                                                                       |
| )                                                                     |
|                                                                       |
| )                                                                     |
|                                                                       |
| end                                                                   |
|                                                                       |
| def smc_handler(n_particles) do                                       |
|                                                                       |
| SMCOuter.wrap( \# manage particle population                          |
|                                                                       |
| ParticleLogger.wrap( \# log per-particle traces                       |
|                                                                       |
| RateLimitHandler.wrap( \# shared rate limit across particles          |
|                                                                       |
| ProductionHandler.new()                                               |
|                                                                       |
| )                                                                     |
|                                                                       |
| ),                                                                    |
|                                                                       |
| n_particles: n_particles                                              |
|                                                                       |
| )                                                                     |
|                                                                       |
| end                                                                   |
+———————————————————————--+

## 7.4  The Reflective Tower
A reflective tower is a system in which each level can inspect and
modify the level below it. The MetaLisp tradition, formalised by Brian
Smith in his 1984 thesis on procedural reflection, established that a
sufficiently powerful programming system can be its own
meta-interpreter, enabling programs to reason about and modify their own
execution.

The agent system described in this paper is a reflective tower with at
least four levels. At the base, effects are primitive operations. Above
them, programs compose effects into agent behaviours. Above programs,
interpreters execute programs with chosen semantics. Above interpreters,
a meta-interpreter synthesises programs, selects interpreters, and
updates the prior based on outcomes. The tower can extend further: a
meta-meta-interpreter could rewrite interpreters themselves.

  —————————————————————————--
  **Tower Level**    **Content**              **Who Writes    **Basis for
                                              It**            Modification**
  —————— ———————— ————— —————--
  Level 0: Effects   LLMCall, ToolInvoke,     System designer Domain
                     Sample, Spawn                            requirements

  Level 1: Programs  Agent behaviours in the  LLM synthesiser Task requirements
                     effect DSL               or human        

  Level 2:           Execution strategies     Human engineer  Performance
  Interpreters       (SMC, prod, test)                        requirements

  Level 3:           Program synthesis,       LLM + inference Outcome scores
  Meta-interpreter   interpreter selection,                   
                     prior update                             

  Level 4+           Meta-meta-interpreter,   Advanced system Open research
                     interpreter rewriting                    problem
  —————————————————————————--

# 8  Programs Writing Programs: Bayesian Program Induction
## 8.1  The Cold Start Problem
A system that generates programs from scratch via random search will not
converge to useful behaviour on any reasonable timescale. The space of
all possible programs is infinite, and the density of useful programs
within it is vanishingly small. Some principled way to focus search on
the promising region of program space is required. This is the cold
start problem, and its solution is the prior.

A prior over programs encodes beliefs about what useful programs look
like before any evidence is observed. A good prior concentrates
probability mass on programs that are structurally plausible — that
use effects in sensible orders, that respect domain constraints, that
have the right shape for the task type. This prior can be specified by
domain experts (hand-crafted program templates), learned from data
(neural program synthesis), or both.

## 8.2  The LLM as Variational Approximation
In Bayesian inference, the variational approach approximates the true
posterior P(program \| evidence) with a tractable distribution Q(program
\| evidence) that is optimised to be close to the posterior in KL
divergence. The LLM, conditioned on the task goal and execution history,
is a variational approximation to the posterior over programs that solve
the goal.

This is not a loose analogy. The LLM has been trained on vast corpora of
code, reasoning chains, and problem solutions. Its output distribution
over programs is an implicit approximation to the posterior that a
Bayesian reasoner with access to that training data would compute.
Fine-tuning, few-shot prompting with successful examples, and
chain-of-thought scaffolding all serve to shift this approximation
closer to the task-specific posterior — they are all forms of
variational optimisation.

The practical implication is significant: you do not need to specify the
prior in closed form or implement a Bayesian inference algorithm
explicitly. You can use the LLM as the prior, and use execution feedback
(did the program work? how well did it score?) to iteratively improve
the LLM\'s approximation to the posterior. This is Bayesian program
induction with the LLM as the inference engine.

## 8.3  Inference Algorithms over Program Space
#### MCMC over Programs
Markov Chain Monte Carlo can be applied to program space by defining a
proposal distribution over program mutations — small, local changes
that preserve the structural validity of the program — and an
acceptance criterion based on execution score. The chain wanders through
program space, spending more time in high-scoring regions.

+———————————————————————--+
| def mcmc_program_search(goal, initial_program, n_steps) do            |
|                                                                       |
| Enum.reduce(1..n_steps, {initial_program, score(initial_program,      |
| goal)},                                                               |
|                                                                       |
| fn \_, {current, current_score} -\>                                   |
|                                                                       |
| \# Propose: LLM generates a small mutation                            |
|                                                                       |
| proposed = llm_mutate(current, goal)                                  |
|                                                                       |
| proposed_score = score(proposed, goal)                                |
|                                                                       |
| \# Metropolis-Hastings acceptance                                     |
|                                                                       |
| log_ratio = proposed_score - current_score                            |
|                                                                       |
| if :math.log(:rand.uniform()) \< log_ratio do                         |
|                                                                       |
| {proposed, proposed_score} \# accept                                  |
|                                                                       |
| else                                                                  |
|                                                                       |
| {current, current_score} \# reject                                    |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
|                                                                       |
| )                                                                     |
|                                                                       |
| end                                                                   |
+———————————————————————--+

#### SMC over Programs
Sequential Monte Carlo maintains a population of programs evolving in
parallel. Each SMC step extends programs by one execution step,
reweights by observed outcomes, and resamples to concentrate the
population on promising programs. This is particularly natural in the
BEAM — each particle is a process, resampling is process management,
and the supervisor orchestrates the population.

#### The DreamCoder Mechanism: Library Growth
The most powerful practical technique is library growth, formalised in
the DreamCoder system (Ellis et al., 2021). Successful programs are
abstracted into reusable primitives, which are added to the DSL\'s
vocabulary. Future programs can use these primitives directly,
compressing complex behaviours into single operations. The prior becomes
richer with experience; programs become shorter and more reliable;
search becomes faster.

+———————————————————————--+
| defmodule LibraryGrowth do                                            |
|                                                                       |
| def update_library(library, successful_traces, threshold \\\\ 5) do   |
|                                                                       |
| \# Find subprograms that appear in many successful traces             |
|                                                                       |
| candidates = successful_traces                                        |
|                                                                       |
| \|\> Enum.flat_map(&extract_subprograms/1)                            |
|                                                                       |
| \|\> Enum.frequencies()                                               |
|                                                                       |
| \|\> Enum.filter(fn {\_, count} -\> count \>= threshold end)          |
|                                                                       |
| \|\> Enum.sort_by(&elem(&1, 1), :desc)                                |
|                                                                       |
| \# Abstract each candidate into a named primitive                     |
|                                                                       |
| new_primitives = candidates                                           |
|                                                                       |
| \|\> Enum.map(fn {subprog, \_count} -\>                               |
|                                                                       |
| name = generate_name(subprog) \# LLM names the primitive              |
|                                                                       |
| %Primitive{name: name, body: subprog, usage_count: 0}                 |
|                                                                       |
| end)                                                                  |
|                                                                       |
| \# Add to library — future programs can use these directly          |
|                                                                       |
| %{library \| primitives: library.primitives ++ new_primitives}        |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
+———————————————————————--+

The library growth mechanism is the compounding advantage that
accumulates over time. Early in deployment, the system uses basic
primitives and generates verbose, inefficient programs. After months of
operation on real tasks, the library contains dozens of proven,
domain-specific abstractions. Programs become shorter, execution faster,
and search more effective. This accumulation cannot be replicated by a
competitor starting fresh — it is the data moat in its most defensible
form.

## 8.4  Safety Constraints on Self-Modification
A system that modifies its own programs must be constrained to prevent
runaway self-modification that optimises proxies rather than true goals,
explores dangerous action sequences, or consumes unbounded compute. The
algebraic effects architecture provides the natural framework for these
constraints: the interpreter, not the program, controls what effects can
be performed and with what consequences.

Concretely: a SafetyHandler wraps all other handlers and intercepts
effect requests before they reach the execution layer. It can reject
programs that request prohibited tool calls, impose budget limits on LLM
calls, enforce output schemas on synthesised programs, and flag programs
that exhibit anomalous patterns for human review. Since the program
cannot bypass the handler (it can only perform effects by requesting
them), the safety handler provides a strong containment boundary.

# 9  Sequential Monte Carlo vs Naive Repeated Sampling
## 9.1  The Precise Distinction
The claim that SMC is superior to naive repeated sampling is often met
with scepticism, because superficially the two approaches look similar:
both run the program multiple times and aggregate results. The
distinction is precise and significant, and understanding it is
necessary for knowing when SMC is worth its overhead and when naive
sampling suffices.

Naive repeated sampling draws N independent samples from P(output \|
prompt) and aggregates them (typically by majority vote or averaging).
It answers the question: what output is most probable under the model
given this prompt? SMC draws N particles from a sequence of
distributions that progressively incorporate evidence, reweighting and
resampling at each step. It answers the question: what output is most
consistent with all the evidence we have observed, and what is the
posterior distribution over outputs?

## 9.2  The Correlation Problem in Naive Sampling
The fundamental problem with naive sampling is that samples are
correlated through the prompt. Every sample is conditioned on exactly
the same context. If the prompt contains a systematic error — a
misleading framing, an ambiguous schema definition, an incorrect example
— every sample will be wrong in exactly the same direction. Majority
vote aggregates these correlated errors and returns a wrong answer with
high apparent confidence.

This is not a marginal concern. In enterprise document processing —
the primary application domain — prompts are often imperfect
approximations to complex domain knowledge. A schema that misses an edge
case will cause all samples to miss the same edge case. The false
confidence that naive sampling produces in this situation is worse than
knowing you don\'t know: it causes the system to confidently commit to
an error rather than escalating to human review.

SMC breaks this correlation through resampling. At each evidence
incorporation step, particles that are inconsistent with the evidence
are killed and replaced by copies of consistent particles. The surviving
particles are not independent samples from the prior — they are
samples that have survived a filtering process that enforces consistency
with all observed evidence. Their agreement is evidence that they are
correct, not merely that they were drawn from the same distribution.

## 9.3  Effective Sample Size as a Diagnostic
The effective sample size (ESS) of a weighted particle population
measures how many independent samples the population is equivalent to,
accounting for the concentration of weight:

ESS = (Σ_i w_i)² / Σ_i w_i²

where w_i are the normalised particle weights. ESS = N when all
particles have equal weight (maximum diversity); ESS = 1 when all weight
is concentrated on a single particle (complete degeneracy). ESS is the
key diagnostic for inference quality:

  ———————————————————————--
  **ESS /    **Inference State**     **Recommended Action**
  N**                                
  ———- ———————-- ————————————
  \> 0.9     Healthy: high           Accept output with high confidence
             agreement, low          
             uncertainty             

  0.5 -- 0.9 Moderate: some particle Accept with moderate confidence,
             collapse                flag borderline cases

  0.2 -- 0.5 Concerning: significant Increase N or add resampling steps
             collapse                before committing

  0.1 -- 0.2 Degenerate: most weight Prompt or schema may be wrong; human
             on few particles        review recommended

  \< 0.1     Collapsed: catastrophic Strong evidence of systematic error;
             degeneracy              do not use output
  ———————————————————————--

ESS is a diagnostic that naive sampling simply cannot compute. With
naive sampling, you have N binary outcomes — right or wrong — with
no information about the degree of confidence or the pattern of failure.
With SMC, ESS tells you not just how confident to be but whether the
confidence itself is trustworthy.

## 9.4  Sequential Evidence Incorporation
The second major advantage of SMC over naive sampling is sequential
evidence incorporation. Many document processing tasks involve multiple
pieces of evidence that must be incorporated jointly: the document
header constrains the document type, the clause structure constrains
interpretation, the numerical values must be consistent with each other,
and the overall structure must match the schema.

Naive sampling conditions on all evidence simultaneously, in a single
prompt. This requires the LLM to correctly integrate all evidence in one
pass, which becomes increasingly difficult as the number of evidence
pieces grows. SMC incorporates evidence sequentially — after each
piece of evidence, particles inconsistent with that evidence are
reweighted and potentially resampled. Particles that survive to the end
are consistent with all evidence jointly, not merely individually
plausible.

+———————————————————————--+
| def smc_extraction(document, schema) do                               |
|                                                                       |
| particles = initialise_particles(n: 100)                              |
|                                                                       |
| particles                                                             |
|                                                                       |
| \# Step 1: condition on document structure                            |
|                                                                       |
| \|\> propagate(:parse_structure, document)                            |
|                                                                       |
| \|\> reweight_by(:schema_conformance, schema)                         |
|                                                                       |
| \|\> resample_if_ess_below(0.5)                                       |
|                                                                       |
| \# Step 2: condition on header fields                                 |
|                                                                       |
| \|\> propagate(:extract_header, document)                             |
|                                                                       |
| \|\> reweight_by(:header_plausibility, document)                      |
|                                                                       |
| \|\> resample_if_ess_below(0.5)                                       |
|                                                                       |
| \# Step 3: condition on body fields, constrained by header            |
|                                                                       |
| \|\> propagate(:extract_body, document)                               |
|                                                                       |
| \|\> reweight_by(:cross_field_consistency)                            |
|                                                                       |
| \|\> reweight_by(:numerical_plausibility)                             |
|                                                                       |
| \|\> resample_if_ess_below(0.5)                                       |
|                                                                       |
| \# Step 4: final synthesis                                            |
|                                                                       |
| \|\> propagate(:synthesise, schema)                                   |
|                                                                       |
| \|\> weighted_majority()                                              |
|                                                                       |
| end                                                                   |
+———————————————————————--+

## 9.5  Calibration
A confidence estimate is calibrated if it matches empirical accuracy:
when the system says it is 90% confident, it should be correct 90% of
the time. Calibration is the property that makes confidence scores
actionable — if you cannot trust the confidence score, you cannot use
it to make decisions about when to escalate to human review.

Naive sampling confidence scores (typically derived from majority vote
proportions or model softmax outputs) are systematically miscalibrated.
The proportion of samples voting for the majority answer is not a
calibrated probability of correctness — it is influenced by prompt
phrasing, temperature, and the correlation structure of the sample
population in ways that are difficult to correct.

SMC produces confidence estimates that are asymptotically calibrated
under mild regularity conditions. The weighted proportion of particles
supporting a given answer converges to the true posterior probability as
N → ∞. For finite N, calibration can be empirically measured and
correction applied. This is a qualitative difference that matters
enormously in high-stakes applications where the cost of acting on an
incorrect high-confidence prediction is large.

# 10  Making SMC Economically Viable
## 10.1  The Cost Structure of SMC
A naive implementation of SMC with N=100 particles and K=5 sequential
steps requires 500 LLM calls per document. At \$0.01 per call, this is
\$5 per document — acceptable for high-value documents, prohibitive
for routine workloads. The practical engineering challenge is reducing
average cost while preserving the statistical guarantees that make SMC
valuable.

The key observation is that the three operations of SMC have very
different costs. Propagation (advancing particles by one step via LLM
call) is expensive. Reweighting (updating particle weights using a
scoring function) is cheap — it requires no LLM call, only evaluation
of a scoring function that can typically be computed in microseconds.
Resampling (killing low-weight particles and cloning high-weight ones)
is free — it is pure bookkeeping.

Most cost-reduction strategies focus on minimising propagation calls
while running reweight+resample cycles liberally between propagation
steps.

## 10.2  Hierarchical Allocation
The most effective single technique is hierarchical allocation: use a
cheap model with few particles for an initial coarse pass, and escalate
to expensive models and more particles only when the coarse pass signals
uncertainty. The majority of documents — those with clear, unambiguous
content — resolve at the coarse level. Only the genuinely difficult
tail receives full SMC treatment.

+———————————————————————--+
| def hierarchical_smc(document, schema) do                             |
|                                                                       |
| \# Stage 1: cheap model, few particles                                |
|                                                                       |
| coarse = run_smc(document, schema,                                    |
|                                                                       |
| model: :haiku, n: 10, steps: \[:structure, :header\]                  |
|                                                                       |
| )                                                                     |
|                                                                       |
| cond do                                                               |
|                                                                       |
| ess_ratio(coarse) \> 0.85 -\>                                         |
|                                                                       |
| {:high_confidence, weighted_majority(coarse), cost: 10}               |
|                                                                       |
| ess_ratio(coarse) \> 0.50 -\>                                         |
|                                                                       |
| \# Moderate uncertainty: refine top particles with better model       |
|                                                                       |
| top = top_k_particles(coarse, 5)                                      |
|                                                                       |
| refined = run_smc(top, schema,                                        |
|                                                                       |
| model: :sonnet, n: 5, steps: \[:body, :verify\]                       |
|                                                                       |
| )                                                                     |
|                                                                       |
| {:moderate_confidence, weighted_majority(refined), cost: 35}          |
|                                                                       |
| true -\>                                                              |
|                                                                       |
| \# Genuine difficulty: full SMC, consider escalation                  |
|                                                                       |
| full = run_smc(document, schema,                                      |
|                                                                       |
| model: :sonnet, n: 20, steps: \[:all\]                                |
|                                                                       |
| )                                                                     |
|                                                                       |
| if ess_ratio(full) \< 0.10 do                                         |
|                                                                       |
| {:escalate, top_k_particles(full, 3), cost: 110}                      |
|                                                                       |
| else                                                                  |
|                                                                       |
| {:lower_confidence, weighted_majority(full), cost: 110}               |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
|                                                                       |
| end                                                                   |
+———————————————————————--+

## 10.3  Cheap Reweighting Between Propagations
Between LLM propagation steps, multiple rounds of reweighting and
resampling can be performed at negligible cost. The reweighting function
uses deterministic scoring that requires no LLM call: regular expression
matching, JSON schema validation, cross-field consistency checks,
numerical range validation, local named entity recognition using
lightweight models, and ontology membership checks.

These cheap reweighting steps kill particles that are implausible on
local grounds before the next propagation step, so that expensive LLM
calls are spent propagating particles that are already filtered by local
constraints. The result is that each LLM call is doing useful work —
advancing particles that have already survived local plausibility
filtering — rather than advancing particles that will be killed
immediately afterward.

## 10.4  Particle-Level Caching
After resampling, the particle population contains duplicates — clones
of high-weight particles. If two particles are in identical states,
their next propagation will produce identical LLM calls and identical
results. Caching by particle state hash ensures that the LLM is called
once for a given state, with all clones receiving the same result from
cache. In later SMC steps, where resampling has concentrated the
population, cache hit rates of 60--80% are common.

## 10.5  The Pilot Particle Pattern
A single pilot particle is run before committing to the full particle
population. If the pilot\'s output meets a confidence threshold
(estimated by comparing it to cheap alternative outputs), the
computation terminates with cost of one LLM call. Only when the pilot
fails to achieve confidence is the full SMC run. Given that 60% of
enterprise documents are routine and unambiguous, this pattern reduces
the expected cost by approximately 60%.

## 10.6  Distillation: SMC as a Data Generator
The long-game cost reduction strategy is distillation. SMC, run on
production traffic, generates high-quality labelled data as a side
effect — high-confidence SMC outputs are approximately correct labels
for the corresponding inputs. This data is used to fine-tune a
domain-specific model on the task, producing a cheap, accurate proposal
distribution that replaces the generic model in future SMC runs.

The compounding effect is significant. A fine-tuned proposal model
concentrates particles in the correct region of output space from the
first step, reducing the number of propagation steps required and
increasing ESS. Better ESS means fewer particles are needed for the same
confidence. Fewer particles means lower cost. Lower cost means more
documents can be processed with SMC. More SMC outputs means more
training data. The cycle accelerates.

  ——————————————————————————
  **Phase**          **Proposal Model** **Avg         **Avg LLM    **Estimated
                                        Particles**   Calls**      Cost**
  —————— —————— ————- ———— ————-
  Month 1 (baseline) Generic haiku      50            150          \$1.50 / doc

  Month 3 (some      Generic + 10k      30            80           \$0.80 / doc
  data)              fine-tune                                     

  Month 6 (rich      Domain fine-tuned  15            35           \$0.35 / doc
  data)                                                            

  Month 12 (mature)  Specialist model   8             12           \$0.12 / doc
  ——————————————————————————

  -- ———————————————————————
     *The distillation flywheel is the most defensible moat: SMC generates
     training data that makes SMC cheaper, which processes more data,
     which generates better training data. A competitor starting fresh
     cannot replicate this without replicating the entire operational
     history.*

  -- ———————————————————————

## 10.7  Budget Allocation by Document Value
Not all documents merit equal inference effort. A contract worth \$10M
deserves substantially more inference compute than a \$200 invoice. The
particle budget should be allocated proportional to the cost of error,
not uniformly. This is not merely economic common sense — it is
optimal Bayesian decision theory. The value of perfect information is
proportional to the stakes, and inference effort should be proportional
to the value of perfect information.

  —————————————————————————
  **Document Category** **Error Cost** **Particle   **Approx LLM **LLM Cost**
                                       Budget**     Calls**      
  ——————— ————-- ———— ———— ————
  High-value contract   Very high      100          \~300        \~\$3.00
  (\>\$1M)                             particles                 

  Standard contract     High           30 particles \~80         \~\$0.80
  (\$10k-\$1M)                                                   

  Regulatory filing     High           50 particles \~130        \~\$1.30
                        (compliance)                             

  Routine invoice       Low            Pilot only   \~1          \~\$0.01
  (\<\$10k)                                                      

  Internal memo         Very low       Single pass  1            \~\$0.01
  —————————————————————————

# 11  Commercialisation Strategy
## 11.1  The Correct Framing
The theoretical depth of the stack described in this paper creates a
temptation to lead with theory in commercial contexts. This is a
mistake. Enterprises buy solutions to specific, expensive problems, not
elegant abstractions. The commercialisation strategy must translate the
theoretical advantages of the stack into concrete, measurable,
customer-facing outcomes, while keeping the theory as an internal
competitive advantage.

The correct framing is not \"we use SMC and algebraic effects\" but \"we
tell you not just what the answer is, but how confident to be in it, why
it might be wrong, and exactly when to involve a human — with
calibration curves to prove it.\" The theory is the engine; the customer
sees only the outcome.

## 11.2  What Is Actually Defensible
Much of what is marketed as differentiation in the LLM application space
is not defensible. Structured outputs via tool calling are available
from every major provider. Audit logging is provided by observability
platforms. Retry logic is a wrapper. These features can be replicated in
days.

What is defensible from the stack described in this paper:

-   Calibrated confidence with verifiable calibration curves. A
    confidence score that can be shown to be 90% accurate when it says
    90% is qualitatively different from an uncalibrated score. This
    requires SMC; it cannot be produced by a single sample or by naive
    repeated sampling.

-   Near-miss traces. The record of what the system considered and
    almost chose is diagnostic information that no single-pass system
    can produce. In regulated industries, demonstrating that the system
    considered and rejected alternative interpretations is a compliance
    requirement.

-   Principled escalation via ESS. Knowing when to escalate based on
    particle collapse — a genuine signal of document ambiguity — is
    different from escalating on an arbitrary confidence threshold. The
    former can be explained and justified; the latter cannot.

-   Domain prior library accumulated from real traces. After months of
    operation, the system\'s prior over agent programs for a specific
    domain reflects real accumulated experience. This library cannot be
    purchased, copied, or rapidly replicated.

-   Distilled domain-specific models. A model fine-tuned on
    high-confidence SMC outputs for a specific vertical is faster,
    cheaper, and more accurate than a general-purpose model for that
    vertical\'s tasks. Building it requires operational history that
    competitors lack.

## 11.3  Three-Phase Commercial Path
#### Phase 1: Sell Reliability (0--12 months)
The immediate enterprise pain is that LLM-based document processing
fails silently, produces inconsistent outputs, and cannot be trusted
without expensive human review. The Phase 1 product addresses this with
three concrete offerings: calibrated confidence scores that reduce human
review to genuinely uncertain cases, near-miss audit traces that satisfy
regulatory requirements, and ESS-based escalation that reduces
escalation false positives and false negatives.

Target verticals for Phase 1: legal contract processing (high error
cost, repetitive structure, existing budget for automation), financial
document extraction (regulatory filings, earnings call transcripts,
structured data from unstructured sources), and clinical notes and
medical coding (compliance requirements, high volume, costly errors).
All three verticals have established willingness to pay for accuracy and
auditability.

The minimum viable product for Phase 1 is the SMC extraction pipeline
with calibration measurement, ESS monitoring, and near-miss logging,
integrated with one customer\'s workflow via a simple REST API. A single
case study with measured accuracy improvement — ideally expressed as
reduction in error rate and reduction in human review hours — is worth
more than any technical whitepaper.

#### Phase 2: Sell Improvement (12--24 months)
Once production traffic is flowing and execution traces are
accumulating, the library growth mechanism becomes active. The Phase 2
product is agents that improve measurably over time at the customer\'s
specific tasks, with improvement curves that can be shown to the
customer. This is distinct from generic LLM capability improvements —
it is improvement on the customer\'s own data, on the customer\'s own
task distribution, compounding over time.

The distillation pipeline (Section 10.6) is the core technology of Phase
2. Customers see decreasing cost, increasing accuracy, and increasing
processing speed over the contract term. This creates strong retention
incentives — switching to a competitor means losing the accumulated
prior, starting the improvement curve from scratch.

#### Phase 3: Sell the Platform (24+ months)
With a validated stack, a domain library, and a distillation pipeline,
the system can be opened to third-party developers as a platform.
Developers build agent applications using the effect DSL, deploying
their programs on the inference infrastructure and accessing the domain
primitive library. Revenue shifts from per-document processing fees to
platform access fees, primitive library subscriptions, and inference
compute charges. This is the highest-margin outcome and the one that
most closely resembles the compounding economics of a software platform
rather than a services business.

## 11.4  Research Sustainability
The research programme described in this paper — probabilistic agent
systems, program synthesis, inference algorithm design, distillation —
requires sustained investment over multiple years. Commercial revenue
must fund this investment without crowding it out. The following
structural commitments are recommended:

-   Fixed research time allocation from day one. A minimum of 30% of
    engineering time reserved for research, non-negotiable regardless of
    product pressure. Research is the long-term asset; sacrificing it
    for short-term product velocity destroys the moat.

-   Research-product coupling. Research directions are chosen partly
    based on which open problems, if solved, would produce the largest
    commercial advantage. The academic ideal of curiosity-driven
    research is compatible with this constraint but must be balanced
    against it.

-   Publication strategy. Publishing research that is 12--18 months
    ahead of commercial implementation establishes credibility, attracts
    talent, and seeds the research community without giving away
    immediate competitive advantage. The implementation details — the
    distillation pipeline, the specific prompt engineering, the domain
    prior library — remain proprietary.

-   Talent flywheel. Research publication and conference presence
    attract researchers who are interested in applied work. Applied work
    generates interesting problems that attract more researchers. The
    research programme must be positioned as genuinely interesting work,
    not as academic cover for a services business.

## 11.5  Risk Analysis
  —————————————————————————————-
  **Risk**          **Probability**   **Impact**   **Mitigation**
  —————-- —————-- ———— —————————————
  Foundation model  High              High         Moat is in domain library and distilled
  providers build                                  models, not infrastructure. Providers
  equivalent                                       build general tools; you build domain
  features                                         depth.

  Commoditisation   Certain           Low          Already commoditised. Stop competing on
  of structured                                    this; compete on calibration, near-miss
  output APIs                                      traces, and improvement over time.

  Research stalls   Medium            High         Structural 30% research time
  under product                                    commitment. Track research output as a
  demand                                           metric alongside product metrics.

  Insufficient      Medium            Medium       Target high-volume verticals (10k+
  trace volume to                                  docs/month) as first customers. Volume
  drive library                                    is required; choose customers
  growth                                           accordingly.

  SMC cost exceeds  Low               High         Hierarchical allocation (Section 10.2)
  customer                                         reduces average cost to \~3x single
  willingness to                                   pass. Budget allocation by document
  pay                                              value makes cost proportional to value.

  Misalignment in   Low initially,    Very high    Safety handler architecture (Section
  self-modifying    growing                        8.4) provides containment. Human review
  program system                                   of synthesised programs required above
                                                   a capability threshold.
  —————————————————————————————-

# 12  Open Problems and Research Directions
## 12.1  Convergence of Program Search
The most fundamental open problem is convergence: does the iterative
program synthesis loop described in Section 8 converge to useful
programs, and under what conditions? The theoretical analysis of
convergence in neural program synthesis is largely open. DreamCoder
provides empirical evidence of convergence on structured domains;
whether it extends to the open-ended domains of enterprise document
processing or general reasoning is unknown.

A partial answer may come from connecting program synthesis to the
theory of stochastic approximation — the framework that establishes
convergence of reinforcement learning algorithms. If the program search
can be cast as stochastic gradient descent in a suitable space,
convergence results from that theory may apply. This is an active area
of research.

## 12.2  Evaluating Agent Programs Without Ground Truth
Scoring a program\'s execution requires an evaluation function. In
structured tasks with clear correct answers — document extraction with
known ground truth — evaluation is straightforward. In open-ended
reasoning tasks, evaluation requires a judge model, human raters, or a
surrogate metric. Each of these is imperfect: judge models can be gamed,
human raters are expensive and inconsistent, and surrogate metrics may
not capture true task performance.

The problem of evaluation without ground truth is fundamental to the
self-improvement loop. A program that optimises a surrogate metric will
eventually discover ways to score well on the metric without achieving
the intended goal — Goodhart\'s Law applied to program synthesis.
Robust evaluation methods, possibly drawing on adversarial evaluation,
multi-criteria assessment, or causal evaluation, are needed.

## 12.3  Formal Guarantees for Composed Handlers
The handler composition described in Section 7.3 is operationally clear
but formally underspecified. When handlers interact — a retry handler
wrapping a rate-limit handler wrapping a caching handler — the
composed semantics may not be the naive composition of individual
semantics. Formal verification of handler composition, particularly for
safety-critical properties, is an open problem in the algebraic effects
literature.

## 12.4  Inference-Time Compute Scaling Laws
Recent empirical work (notably in the OpenAI o-series models) suggests
that inference-time compute — additional computation spent at
inference time rather than training time — follows power-law scaling
relationships analogous to training compute scaling laws. If these laws
generalise to the SMC setting, they would provide principled guidance
for particle count selection as a function of task difficulty and
accuracy requirements. Establishing these laws empirically for the
document processing setting described in Section 10 is a tractable
research programme.

## 12.5  Alignment in Self-Modifying Systems
Section 8.4 introduces safety handlers as a containment mechanism for
self-modifying agent programs. But the safety handler itself must be
correct, and the specification of what constitutes safe behaviour is
non-trivial. As the system\'s capability grows through library
accumulation and distillation, the safety handler must grow
correspondingly more sophisticated. The problem of maintaining alignment
in a system that is improving its own capabilities is a central open
problem in AI safety, and the architecture described in this paper is a
concrete instance of it.

# 13  Conclusion
This paper has presented a unified theoretical and practical framework
for intelligent agent systems, beginning from the mathematics of
continuation passing style and algebraic effects and deriving from it a
complete stack: probabilistic programming as the inference framework,
the Erlang/Elixir actor model as the execution substrate, agent-based
modelling as the design methodology, DSL and interpreter architecture as
the engineering pattern, and Sequential Monte Carlo as the runtime
inference algorithm.

The central claim — that an LLM agent is a probabilistic program whose
effects are handled by an external interpreter — is not a loose
analogy. It is a precise structural claim that makes the entire
theoretical apparatus of programming language theory and probabilistic
inference available for agent engineering. The practical consequences
are concrete: programs and execution strategies are cleanly separated,
allowing different inference algorithms to be applied to the same agent
code; calibrated uncertainty is produced by SMC and cannot be produced
by naive sampling; the system improves over time through library growth
and distillation; and the safety properties of the system can be
reasoned about formally through the handler architecture.

The commercial path that emerges from this stack is also clear. The
sellable artifact is not structured output, reliability, or
observability — these are commoditised. The sellable artifact is the
particle distribution: calibrated confidence that can be proven correct,
near-miss traces that satisfy regulatory requirements, principled
escalation that reduces human review cost, and improvement over time
that compounds with operational history. Each of these properties
follows directly from the theoretical stack and cannot be replicated by
simpler approaches.

The most important practical implication is that the theory and the
product are the same flywheel. Research that advances inference
algorithm quality produces a better product. A better product attracts
customers. Customers generate execution traces. Traces drive library
growth and distillation. Library growth and distillation generate
interesting research problems. The feedback loop is genuine and
self-sustaining, provided that the structural commitment to research is
maintained alongside the commercial programme.

The ideas described here have deep roots — CPS from the 1970s,
algebraic effects from the 2000s, probabilistic programming from the
1980s through today, ABM from the 1990s. The novelty is not in any
individual idea but in their convergence on the same practical problem:
building agent systems that are reliable, composable, improvable, and
aligned with human intent. The convergence is not accidental. These
ideas were always pointing at the same structure. Large language models,
for all their novelty, have simply made that structure concretely
useful.

*— End of Paper —*
