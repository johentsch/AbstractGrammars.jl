using AbstractGrammars

# imports for overloading
import AbstractGrammars: default
import Distributions: logpdf, BetaBinomial

# imports without overloading
using AbstractGrammars.ConjugateModels: DirCat, add_obs!
using Pitches: parsespelledpitch, Pitch, SpelledIC, MidiIC, midipc, alteration, @p_str, tomidi
using Underscores: @_

# named imports
# import AbstractGrammars.Headed
import HTTP, JSON

#############
### Utils ###
#############

default(::Type{SpelledIC}) = SpelledIC(0)
default(::Type{Pitch{I}}) where I = Pitch(default(I))

##############
### Chords ###
##############

@enum ChordForm MAJ MAJ6 MAJ7 DOM MIN MIN6 MIN7 MINMAJ7 HDIM7 DIM7 SUS

const chordform_strings = 
  ["^", "6", "^7", "7", "m", "m6", "m7", "m^7", "%7", "o7", "sus"]

chordform_string(form::ChordForm) = chordform_strings[Int(form) + 1]

function parse_chordform(str::AbstractString)
  i = findfirst(isequal(str), chordform_strings)
  @assert !isnothing(i) "$str cannot be parsed as a chord form"
  return ChordForm(i-1)
end

default(::Type{ChordForm}) = ChordForm(0)

@assert all(instances(ChordForm)) do form
  form |> chordform_string |> parse_chordform == form
end

struct Chord{R}
  root :: R
  form :: ChordForm
end

function default(::Type{Chord{R}}) where R 
  Chord(default(R), default(ChordForm))
end

default(Chord{Pitch{SpelledIC}})

const chord_regex = r"([A-G]b*|[A-G]#*)([^A-Gb#]+)" 

function parse_chord(str)
  m = match(chord_regex, str)
  @assert !isnothing(m) "$str cannot be parsed as a pitch-class chord"
  root_str, form_str = m.captures
  root = parsespelledpitch(root_str)
  # pitchclass_root = tomidi(spelled_root)
  form = parse_chordform(form_str)
  return Chord(root, form)
end

#####################
### Read treebank ###
#####################

# Tonal Pitch-Class Chord
const TPCC = Chord{Pitch{SpelledIC}}

function categorize_and_insert_unary_rules(tree; root=start_category(TPCC))
  function categorize(tree)
    if isleaf(tree)
      Tree(nonterminal_category(tree.label),Tree(terminal_category(tree.label)))
    else
      Tree(nonterminal_category(tree.label), map(categorize, tree.children))
    end
  end
  Tree(root, categorize(tree))
end

function preprocess_tree!(tune)
  remove_asterisk(label::String) = replace(label, "*" => "")

  if haskey(tune, "trees")
    tune["tree"] = @_ tune["trees"][1]["open_constituent_tree"] |> 
      dict2tree(remove_asterisk, __) |>
      map(parse_chord, __) |>
      categorize_and_insert_unary_rules(__)
  end

  return tune
end

treebank_url = "https://raw.githubusercontent.com/DCMLab/JazzHarmonyTreebank/master/treebank.json"
tunes = HTTP.get(treebank_url).body |> String |> JSON.parse .|> preprocess_tree!
treebank = filter(tune -> haskey(tune, "tree"), tunes)

#########################
### Construct grammar ###
#########################

all_chords = collect(
  Chord(parsespelledpitch(letter * acc), form) 
  for letter in 'A':'G'
  for acc in ("b", "#", "")
  for form in instances(ChordForm))

START = start_category(TPCC)
ts    = terminal_category.(all_chords)
nts   = nonterminal_category.(all_chords) 

rules = Set([
  [START --> nt for nt in nts]; # start rules
  [nt  --> t         for (nt, t) in zip(nts, ts)]; # termination rules
  [nt  --> (nt,nt)   for nt in nts]; # duplication rules
  # [nt1 --> (nt1,nt2) for nt1 in nts for nt2 in nts if nt1 != nt2]; #left-headed
  [nt2 --> (nt1,nt2) for nt1 in nts for nt2 in nts if nt1 != nt2]; #right-headed
  ])

# probability model
applicable_rules(all_rules, category) = filter(r -> r.lhs==category, all_rules)
flat_dircat(xs) = DirCat(Dict(x => 1 for x in xs))
prior_params() = Dict(
  nt => flat_dircat(applicable_rules(rules, nt)) for nt in [nts; START])

function logpdf(grammar::StdGrammar, lhs, rule)
  if lhs == rule.lhs
    logpdf(grammar.params[lhs], rule)
  else
    log(0)
  end
end

# supervised training by observation of trees
function observe_tree!(params, tree)
  for rule in tree2derivation(treelet2stdrule, tree)
    try
      add_obs!(params[rule.lhs], rule, 1)
    catch
      print("x")
    end
  end
end

grammar = StdGrammar([START], rules, prior_params())
foreach(tune -> observe_tree!(grammar.params, tune["tree"]), treebank)

############################
### Test with dummy data ###
############################

# terminalss = collect([H.terminal_cat(c)]
#   for c in [Chord(p"C", MAJ7), Chord(p"G", DOM), Chord(p"C", MAJ7)])
# terminalss = fill([terminal_category(Chord(p"C", MAJ7))], 50)
terminalss = [[terminal_category(rand(all_chords))] for _ in 1:50]
scoring = WDS(grammar) # weighted derivation scoring
@time chart = chartparse(grammar, scoring, terminalss)
@time sample_derivations(scoring, chart[1,length(terminalss)][START], 1) .|> 
  (app -> arity(app.rule))

##########################
### Test with treebank ###
##########################

# using Distributed
# using SharedArrays

# addprocs(6)
# workers()
# @everywhere using AbstractGrammars

function calc_accs(grammar, treebank, startsymbol; treekey="tree")
  scoring = BestDerivationScoring()
  accs = zeros(length(treebank))
  for i in eachindex(treebank)
    print(i, ' ', treebank[i]["title"], ' ')
    tree = treebank[i][treekey]
    terminalss = [[c] for c in leaflabels(tree)]
    chart = chartparse(grammar, scoring, terminalss)
    apps = chart[1, length(terminalss)][startsymbol].apps
    derivation = [app.rule for app in apps]
    accs[i] = tree_similarity(tree, apply(derivation, startsymbol))
    println(accs[i])
  end
  return accs
end

# @time accs = calc_accs(grammar, treebank[1:150], START)
# sum(accs) / length(accs)

########################
### Read rhythm data ###
########################

function chord_durations(tune)
  bpm = tune["meter"]["numerator"] # beats per measure
  ms  = tune["measures"]
  bs  = tune["beats"]
  n   = length(tune["chords"])

  @assert n == length(ms) == length(bs) "error in treebank's rhythm data"
  ds = zeros(Int, n) # initialize list of durations
  for i in 1:n-1
    b1, b2 = bs[i:i+1] # current and next beat
    m1, m2 = ms[i:i+1] # measure of current and next beat
    # The chord on the current beat offsets either at the next chord or
    # the end of the current measure.
    # This is by convention of the treebank annotations.
    ds[i] = m1 == m2 ? b2 - b1 : bpm + 1 - b1
  end
  ds[n] = bpm + 1 - bs[n]

  @assert all(d -> 0 < d, ds) "bug in chord-duration calculation or data"
  return ds
end

function leaf_durations(tune)
  ds = chord_durations(tune)
  ls = leaflabels(tune["tree"])
  if length(ds) == length(ls)
    ds
  elseif length(ds) + 1 == length(ls) # tune ends on its first chord
    [ds; sum(ds)]
  elseif length(ds) > length(ls) # turnaround is omitted in the tree
    [ds[1:length(ls)-1]; sum(ds[length(ls):end])]
  else # much more chords than chord durations
    error("list of chord durations not long enough")
  end
end

function normalized_duration_tree(tune)
  lds = normalize(Rational.(leaf_durations(tune)))
  k = 0 # leaf index
  next_leafduration() = (k += 1; lds[k])

  function relabel(tree) 
    if isleaf(tree)
      Tree(next_leafduration())
    elseif length(tree.children) == 1
      child = relabel(tree.children[1])
      Tree(child.label, child)
    elseif length(tree.children) == 2
      left  = relabel(tree.children[1])
      right = relabel(tree.children[2])
      Tree(left.label + right.label, left, right)
    else
      error("tree is not (even weakly) binary")
    end
  end

  return relabel(dict2tree(tune["trees"][1]["open_constituent_tree"]))
end

for tune in tunes
  if haskey(tune, "tree")
    tune["rhythm_tree"] = categorize_and_insert_unary_rules(
      normalized_duration_tree(tune), 
      root=start_category(Rational{Int}))
  end
end

# @time chord_durations(tune)
# @time leaf_durations(tune)
# @time normalized_duration_tree.(treebank)
# @time chord_durations.(tunes);

# failed = 0
# for tune in tunes
#   try
#     chord_durations(tune)
#   catch
#     failed += 1
#     println(tune["title"])
#   end
# end
# failed

######################
### Rhythm Grammar ###
######################

import AbstractGrammars: arity, apply, push_completions!

const RhythmCategory = StdCategory{Rational{Int}}

# possible tags: start, termination, split
struct RhythmRule <: AbstractRule{RhythmCategory}
  tag   :: Tag
  ratio :: Rational{Int}
end

const rhythm_start_category = start_category(Rational{Int})
const rhythm_start_rule = RhythmRule("start", default(Rational{Int}))
const rhythm_termination = RhythmRule("termination", default(Rational{Int}))

rhythm_split_rule(ratio) = RhythmRule("split", ratio)
arity(rule::RhythmRule) = "split" ⊣ rule ? 2 : 1

function apply(rule::RhythmRule, category::RhythmCategory)
  if "start" ⊣ rule && "start" ⊣ category
    tuple(nonterminal_category(1//1))
  elseif "termination" ⊣ rule && "nonterminal" ⊣ category
    tuple(terminal_category(category))
  elseif "split" ⊣ rule && "nonterminal" ⊣ category
    tuple(
      nonterminal_category(rule.ratio * category.val), 
      nonterminal_category((1 - rule.ratio) * category.val))
  else
    nothing
  end
end

mutable struct RhythmGrammar{P} <: AbstractGrammar{RhythmRule}
  rules  :: Set{RhythmRule}
  params :: P

  function RhythmGrammar(rules, params::P) where P
    @assert rhythm_start_rule in rules && rhythm_termination in rules
    new{P}(rules, params)
  end
end

function push_completions!(::RhythmGrammar, stack, category)
  if "terminal" ⊣ category
    push!(stack, App(nonterminal_category(category), rhythm_termination))
  elseif "nonterminal" ⊣ category
    push!(stack, App(rhythm_start_category, rhythm_start_rule))
  end
end

function push_completions!(grammar::RhythmGrammar, stack, c1, c2)
  if "nonterminal" ⊣ c1 && "nonterminal" ⊣ c2
    s = sum(c1.val + c2.val)
    ratio = c1.val / s
    rule = rhythm_split_rule(ratio)
    if rule in grammar.rules
      push!(stack, App(nonterminal_category(s), rule))
    end
  end
end

function logpdf(grammar::RhythmGrammar, lhs, rule)
  if "start" ⊣ lhs && "start" ⊣ rule
    log(1)
  elseif "nonterminal" ⊣ lhs && rule in grammar.rules
    logpdf(grammar.params, rule)
  else # not applicable
    log(0)
  end
end

split_rules = Set([rhythm_split_rule(d//n) for d in 1:100 for n in d+1:100])
rhythm_rules = union(split_rules, [rhythm_start_rule, rhythm_termination])
params = flat_dircat([rhythm_termination; collect(split_rules)])
rhythm_grammar = RhythmGrammar(rhythm_rules, params)

tune = treebank[30]
terminalss = [[terminal_category(d)] for d in normalize(Rational.(chord_durations(tune)))]
scoring = WDS(rhythm_grammar)
@time chart = chartparse(rhythm_grammar, scoring, terminalss)
chart[1,length(terminalss)][rhythm_start_category]

# @time accs = calc_accs(rhythm_grammar, treebank, rhythm_start_category, treekey="rhythm_tree")
# sum(accs) / length(accs)

function treelet2rhythmrule(treelet)
  root = treelet.root_label
  children = treelet.child_labels
  if arity(treelet) == 1
    child = children[1]
    if "start" ⊣ root && nonterminal_category(1//1) == child
      rhythm_start_rule
    elseif "nonterminal" ⊣ root && "terminal" ⊣ child && root.val == child.val
      rhythm_termination
    else
      error("cannot convert unary $treelet into a rhythm rule")
    end
  elseif arity(treelet) == 2 && "nonterminal" ⊣ (root, children...) &&
         root.val == children[1].val + children[2].val
    rhythm_split_rule(children[1].val // root.val)
  else
    error("cannot convert binary $treelet into a rhythm rule")
  end
end

function observe_rhythm_tree!(params, tree)
  for rule in tree2derivation(treelet2rhythmrule, tree)
    if !("start" ⊣ rule)
      try
        add_obs!(params, rule, 1)
      catch
        print("x")
      end
    end
  end
end

for tune in treebank 
  observe_rhythm_tree!(params, tune["rhythm_tree"])
end

# @time accs = calc_accs(rhythm_grammar, treebank, rhythm_start_category, treekey="rhythm_tree")
# sum(accs) / length(accs)

#######################
### Product Grammar ###
#######################

struct ProductRule{C1, C2, R1 <: AbstractRule{C1}, R2 <: AbstractRule{C2}} <:  
    AbstractRule{Tuple{C1, C2}}
  rule1 :: R1
  rule2 :: R2

  function ProductRule(rule1::R1, rule2::R2) where 
      {C1, C2, R1 <: AbstractRule{C1}, R2 <: AbstractRule{C2}}
    @assert arity(rule1) == arity(rule2)
    new{C1, C2, R1, R2}(rule1, rule2)
  end
end

import Base: getindex
function getindex(rule::ProductRule, i)
  if i == 1
    rule.rule1
  elseif i == 2
    rule.rule2
  else
    BoundsError(rule, i)
  end
end

arity(rule::ProductRule) = arity(rule[1])

function apply(rule::ProductRule{C1,C2}, category::Tuple{C1,C2}) where {C1,C2}
  rhs1 = apply(rule[1], category[1])
  rhs2 = apply(rule[2], category[2])
  if isnothing(rhs1) || isnothing(rhs2)
    nothing
  else
    tuple(zip(rhs1, rhs2)...)
  end
end

rule = ProductRule(rand(rules), rand(split_rules))
arity(rule)
c = (rule[1].lhs, nonterminal_category(1//1))
rhs = apply(rule, c)
@assert rhs[1] isa Tuple && typeof(rhs[1]) == typeof(rhs[2])

# not thread safe
# for parallelization use one product grammar per thread
mutable struct ProductGrammar{
    C1, R1<:AbstractRule{C1}, G1<:AbstractGrammar{R1}, 
    C2, R2<:AbstractRule{C2}, G2<:AbstractGrammar{R2},
    P
  } <: AbstractGrammar{ProductRule{C1,C2,R1,R2}}
  grammar1 :: G1
  grammar2 :: G2
  stacks   :: Tuple{Vector{App{C1, R1}}, Vector{App{C2, R2}}}
  params   :: P

  function ProductGrammar(grammar1::G1, grammar2::G2, params::P) where {
      C1, R1<:AbstractRule{C1}, G1<:AbstractGrammar{R1}, 
      C2, R2<:AbstractRule{C2}, G2<:AbstractGrammar{R2},
      P
    }
    stacks = tuple(Vector{App{C1, R1}}(), Vector{App{C2, R2}}())
    new{C1,R1,G1,C2,R2,G2,P}(grammar1, grammar2, stacks, params)
  end
end

function getindex(grammar::ProductGrammar, i)
  if i == 1
    grammar.grammar1
  elseif i == 2
    grammar.grammar2
  else
    BoundsError(grammar, i)
  end
end
# product_grammar
# product_grammar isa AbstractGrammar{ProductRule{StdCategory{TPCC}, RhythmCategory}}

# function foo(grammar::G) where {C,R <: AbstractRule{C},G <: AbstractGrammar{R}}
#   println.([C, R, G])
# end

# foo(product_grammar)

# function push_completions!(grammar::ProductGrammar, stack, category)
#   push_completions!(grammar[1], grammar.stacks[1], category[1])
#   push_completions!(grammar[2], grammar.stacks[2], category[2])
  
#   for app1 in grammar.stacks[1], app2 in grammar.stacks[2]
#     app = App((app1.lhs, app2.lhs), ProductRule(app1.rule, app2.rule))
#     push!(stack, app)
#   end

#   empty!(grammar.stacks[1])
#   empty!(grammar.stacks[2])
#   return nothing
# end

function push_completions!(grammar::ProductGrammar, stack, categories...)
  function unzip(xs)
    n = length(first(xs))
    ntuple(i -> map(x -> x[i], xs), n)
  end

  rhss = unzip(categories) # right-hand sides
  push_completions!(grammar[1], grammar.stacks[1], rhss[1]...)
  push_completions!(grammar[2], grammar.stacks[2], rhss[2]...)
  
  for app1 in grammar.stacks[1], app2 in grammar.stacks[2]
    app = App((app1.lhs, app2.lhs), ProductRule(app1.rule, app2.rule))
    push!(stack, app)
  end

  empty!(grammar.stacks[1])
  empty!(grammar.stacks[2])
  return nothing
end

function logpdf(
    grammar::ProductGrammar{C1, R1, G1, C2, R2, G2, <:BetaBinomial}, lhs, rule
  ) where {C1, R1, G1, C2, R2, G2}

  beta_bernoulli = grammar.params
  @assert 1 <= arity(rule) <= 2
  arity_logprob = logpdf(beta_bernoulli, arity(rule)-1)
  *(
    arity_logprob,
    logpdf(grammar[1], lhs[1], rule[1]),
    logpdf(grammar[2], lhs[2], rule[2]))
end

product_grammar = ProductGrammar(grammar, rhythm_grammar, BetaBinomial(1, 1, 1))

# grammar
# rhythm_grammar

tune = treebank[30]
chords = leaflabels(tune["tree"])
durations = terminal_category.(normalize(Rational.(leaf_durations(tune))))
terminalss = [[(c,d)] for (c, d) in zip(chords, durations)]
scoring = WDS(product_grammar)
@time chart = chartparse(product_grammar, scoring, terminalss)
chart[1,length(terminalss)][(START, rhythm_start_category)]


