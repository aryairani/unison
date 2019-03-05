{-# Language DeriveFoldable #-}
{-# Language DeriveFunctor #-}
{-# Language DeriveTraversable #-}
{-# Language FlexibleContexts #-}
{-# Language LambdaCase #-}
{-# Language OverloadedStrings #-}
{-# Language PartialTypeSignatures #-}
{-# Language StrictData #-}
{-# Language TupleSections #-}
{-# Language ViewPatterns #-}
{-# Language PatternSynonyms #-}
{-# Language DoAndIfThenElse #-}

module Unison.Runtime.IR where

import Control.Monad.State.Strict (StateT, gets, modify, runStateT, lift)
import Data.Bifunctor (first, second)
import Data.Foldable
import Data.Functor (void)
import Data.IORef
import Data.Int (Int64)
import Data.Map (Map)
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Word (Word64)
import Debug.Trace
import Unison.NamePrinter (prettyHashQualified)
import Unison.Symbol (Symbol)
import Unison.Term (AnnotatedTerm)
import Unison.Util.Monoid (intercalateMap)
import Unison.Var (Var)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Unison.ABT as ABT
import qualified Unison.Pattern as Pattern
import qualified Unison.PrettyPrintEnv as PPE
import qualified Unison.Reference as R
import qualified Unison.Runtime.ANF as ANF
import qualified Unison.Term as Term
import qualified Unison.TermPrinter as TP
import qualified Unison.Type as Type
import qualified Unison.Util.Pretty as P
import qualified Unison.Var as Var

type Pos = Int
type Arity = Int
type ConstructorId = Int
type Term v = AnnotatedTerm v ()

data CompilationEnv e
  = CompilationEnv { toIR' :: Map R.Reference (IR e)
                   , constructorArity' :: Map (R.Reference, Int) Int }

toIR :: CompilationEnv e -> R.Reference -> Maybe (IR e)
toIR = flip Map.lookup . toIR'

constructorArity :: CompilationEnv e -> R.Reference -> Int -> Maybe Int
constructorArity e r i = Map.lookup (r,i) $ constructorArity' e

-- SymbolC = Should this variable be compiled as a LazySlot?
data SymbolC =
  SymbolC { isLazy :: Bool
          , underlyingSymbol :: Symbol
          }-- deriving Show
instance Show SymbolC where
  show (SymbolC lazy s) = (if lazy then "'" else "") <> show s

makeLazy :: SymbolC -> SymbolC
makeLazy s = s { isLazy = True }

toSymbolC :: Symbol -> SymbolC
toSymbolC s = SymbolC False s

-- Values, in normal form
type RefID = Int
data Value e
  = I Int64 | F Double | N Word64 | B Bool | T Text
  | Lam Arity (UnderapplyStrategy e) (IR e)
  | Data R.Reference ConstructorId [Value e]
  | Sequence (Vector (Value e))
  | Ref RefID Symbol (IORef (Value e))
  | Pure (Value e)
  | Requested (Req e)
  | Cont (IR e)
  | UninitializedLetRecSlot Symbol [(Symbol, IR e)] (IR e)
  deriving (Eq)

-- would have preferred to make pattern synonyms
maybeToOptional :: Maybe (Value e) -> Value e
maybeToOptional = \case
  Just a  -> Data Type.optionalRef 1 [a]
  Nothing -> Data Type.optionalRef 0 []

unit :: Value e
unit = Data Type.unitRef 0 []

pair :: (Value e, Value e) -> Value e
pair (a, b) = Data Type.pairRef 0 [a, b]

-- When a lambda is underapplied, for instance, `(x y -> x) 19`, we can do
-- one of two things: we can substitute away the arguments that have
-- been applied, in this example, creating the lambda `x -> 19`. This
-- is called specialization and requires recompiling the lambda with its new
-- body.
--
-- The other option is to just stash the arguments until the rest of the
-- args are supplied later. This keeps the original lambda around and
-- doesn't involve recompiling. This would just create the closure
-- `((x y -> x) 19)`, which when given one more arg, would call the original
-- `x y -> x` function with both arguments.
--
-- Specialization can be done for any Unison term definition, like
--
--   blah x y = x + y
--
-- Closure formation is used for:
--
--   * builtin functions
--   * constructor functions
--
-- The reason is that builtins and constructor functions don't have a body
-- with variables that we could substitute - the functions only compute
-- to anything when all the arguments are available.

data UnderapplyStrategy e
  = FormClosure (Term SymbolC) [Value e] -- head is the latest argument
  | Specialize (Term SymbolC) [(SymbolC, Value e)] -- same
  deriving (Eq, Show)

decompileUnderapplied :: External e => UnderapplyStrategy e -> DS (Term Symbol)
decompileUnderapplied u = case u of -- todo: consider unlambda-lifting here
  FormClosure lam vals ->
    Term.apps' (Term.vmap underlyingSymbol lam) . reverse <$>
      traverse decompileImpl vals
  Specialize lam symvals -> do
    lam <- Term.apps' (Term.vmap underlyingSymbol lam) . reverse <$>
      traverse (decompileImpl . snd) symvals
    pure $ Term.betaReduce lam


-- Patterns - for now this follows Unison.Pattern exactly, but
-- we may switch to more efficient runtime representation of patterns
data Pattern
  = PatternI Int64 | PatternF Double | PatternN Word64 | PatternB Bool | PatternT Text
  | PatternData R.Reference ConstructorId [Pattern]
  | PatternSequence (Vector Pattern)
  | PatternPure Pattern
  | PatternBind R.Reference ConstructorId [Pattern] Pattern
  | PatternAs Pattern
  | PatternIgnore
  | PatternVar deriving (Eq,Show)

-- Leaf level instructions - these return immediately without using any stack
data Z e
  = Slot Pos
  | LazySlot Pos
  | Val (Value e)
  | External e
  deriving (Eq)

type IR e = IR' (Z e)

-- IR z
-- depth of a slot is just that slot
-- depth of a let is just depth
--
-- Computations - evaluation reduces these to values
data IR' z
  = Leaf z
  -- Ints
  | AddI z z | SubI z z | MultI z z | DivI z z
  | GtI z z | LtI z z | GtEqI z z | LtEqI z z | EqI z z
  | SignumI z | NegateI z | ModI z z
  -- Nats
  | AddN z z | DropN z z | SubN z z | MultN z z | DivN z z
  | GtN z z | LtN z z | GtEqN z z | LtEqN z z | EqN z z
  | ModN z z
  -- Floats
  | AddF z z | SubF z z | MultF z z | DivF z z
  | GtF z z | LtF z z | GtEqF z z | LtEqF z z | EqF z z
  -- Control flow
  | Let Symbol (IR' z) (IR' z)
  | LetRec [(Symbol, IR' z)] (IR' z)
  | MakeSequence [z]
  | Apply (IR' z) [z]
  | Construct R.Reference ConstructorId [z]
  | Request R.Reference ConstructorId [z]
  | Handle z (IR' z)
  | If z (IR' z) (IR' z)
  | And z (IR' z)
  | Or z (IR' z)
  | Not z
  -- pattern, optional guard, rhs
  | Match z [(Pattern, [Symbol], Maybe (IR' z), (IR' z))]
  deriving (Functor,Foldable,Traversable,Eq,Show)

prettyZ :: PPE.PrettyPrintEnv -> (e -> P.Pretty String) -> Z e -> P.Pretty String
prettyZ ppe prettyE z = case z of
  Slot i -> "@" <> P.shown i
  LazySlot i -> "'@" <> P.shown i
  Val v -> prettyValue ppe prettyE v
  External e -> "External" `P.hang` prettyE e

prettyIR :: PPE.PrettyPrintEnv -> (e -> P.Pretty String) -> IR e -> P.Pretty String
prettyIR ppe prettyE ir = case ir of
  Leaf z -> pz z
  AddI a b -> P.parenthesize $ "AddI" `P.hang` P.spaced [pz a, pz b]
  SubI a b -> P.parenthesize $ "SubI" `P.hang` P.spaced [pz a, pz b]
  MultI a b -> P.parenthesize $ "MultI" `P.hang` P.spaced [pz a, pz b]
  DivI a b -> P.parenthesize $ "DivI" `P.hang` P.spaced [pz a, pz b]
  GtI a b -> P.parenthesize $ "GtI" `P.hang` P.spaced [pz a, pz b]
  LtI a b -> P.parenthesize $ "LtI" `P.hang` P.spaced [pz a, pz b]
  GtEqI a b -> P.parenthesize $ "GtEqI" `P.hang` P.spaced [pz a, pz b]
  LtEqI a b -> P.parenthesize $ "LtEqI" `P.hang` P.spaced [pz a, pz b]
  EqI a b -> P.parenthesize $ "EqI" `P.hang` P.spaced [pz a, pz b]
  SignumI a -> P.parenthesize $ "SignumI" `P.hang` P.spaced [pz a]
  NegateI a -> P.parenthesize $ "NegateI" `P.hang` P.spaced [pz a]
  ModI a b -> P.parenthesize $ "ModI" `P.hang` P.spaced [pz a, pz b]

  AddN a b -> P.parenthesize $ "AddN" `P.hang` P.spaced [pz a, pz b]
  SubN a b -> P.parenthesize $ "SubN" `P.hang` P.spaced [pz a, pz b]
  DropN a b -> P.parenthesize $ "DropN" `P.hang` P.spaced [pz a, pz b]
  MultN a b -> P.parenthesize $ "MultN" `P.hang` P.spaced [pz a, pz b]
  DivN a b -> P.parenthesize $ "DivN" `P.hang` P.spaced [pz a, pz b]
  GtN a b -> P.parenthesize $ "GtN" `P.hang` P.spaced [pz a, pz b]
  LtN a b -> P.parenthesize $ "LtN" `P.hang` P.spaced [pz a, pz b]
  GtEqN a b -> P.parenthesize $ "GtEqN" `P.hang` P.spaced [pz a, pz b]
  LtEqN a b -> P.parenthesize $ "LtEqN" `P.hang` P.spaced [pz a, pz b]
  EqN a b -> P.parenthesize $ "EqN" `P.hang` P.spaced [pz a, pz b]
  ModN a b -> P.parenthesize $ "ModN" `P.hang` P.spaced [pz a, pz b]

  AddF a b -> P.parenthesize $ "AddF" `P.hang` P.spaced [pz a, pz b]
  SubF a b -> P.parenthesize $ "SubF" `P.hang` P.spaced [pz a, pz b]
  MultF a b -> P.parenthesize $ "MultF" `P.hang` P.spaced [pz a, pz b]
  DivF a b -> P.parenthesize $ "DivF" `P.hang` P.spaced [pz a, pz b]
  GtF a b -> P.parenthesize $ "GtF" `P.hang` P.spaced [pz a, pz b]
  LtF a b -> P.parenthesize $ "LtF" `P.hang` P.spaced [pz a, pz b]
  GtEqF a b -> P.parenthesize $ "GtEqF" `P.hang` P.spaced [pz a, pz b]
  LtEqF a b -> P.parenthesize $ "LtEqF" `P.hang` P.spaced [pz a, pz b]
  EqF a b -> P.parenthesize $ "EqF" `P.hang` P.spaced [pz a, pz b]
  ir @ (Let _ _ _) ->
    P.group $ "let" `P.hang` P.lines (blockElem <$> block)
    where
    block = unlets ir
    blockElem (Nothing, binding) = pir binding
    blockElem (Just name, binding) =
      (P.shown name <> " =") `P.hang` pir binding
  LetRec bs body -> P.group $ "letrec" `P.hang` P.lines ls
    where
    blockElem (Nothing, binding) = pir binding
    blockElem (Just name, binding) =
      (P.shown name <> " =") `P.hang` pir binding
    ls = fmap blockElem $ [ (Just n, ir) | (n,ir) <- bs ]
                       ++ [(Nothing, body)]
  MakeSequence vs -> P.group $
    P.surroundCommas "[" "]" (pz <$> vs)
  Apply fn args -> P.parenthesize $ pir fn `P.hang` P.spaced (pz <$> args)
  Construct r cid args -> P.parenthesize $
    ("Construct " <> prettyHashQualified (PPE.patternName ppe r cid))
    `P.hang`
    P.surroundCommas "[" "]" (pz <$> args)
  Request r cid args -> P.parenthesize $
    ("Request " <> prettyHashQualified (PPE.patternName ppe r cid))
    `P.hang`
    P.surroundCommas "[" "]" (pz <$> args)
  Handle h body -> P.parenthesize $
    P.group ("Handle " <> pz h) `P.hang` pir body
  If cond t f -> P.parenthesize $
    ("If " <> pz cond) `P.hang` P.spaced [pir t, pir f]
  And x y -> P.parenthesize $ "And" `P.hang` P.spaced [pz x, pir y]
  Or x y -> P.parenthesize $ "Or" `P.hang` P.spaced [pz x, pir y]
  Not x -> P.parenthesize $ "Not" `P.hang` pz x
  Match scrute cases -> P.parenthesize $
    P.group ("Match " <> pz scrute) `P.hang` P.lines (pcase <$> cases)
    where
    pcase (pat, vs, guard, rhs) = let
      lhs = P.spaced . P.nonEmpty $
              [ P.parenthesize (P.shown pat), P.shown vs, maybe mempty pir guard ]
      in (lhs <> " ->" `P.hang` pir rhs)
  where
  unlets (Let s hd tl) = (Just s, hd) : unlets tl
  unlets e = [(Nothing, e)]
  pz = prettyZ ppe prettyE
  pir = prettyIR ppe prettyE

prettyValue :: PPE.PrettyPrintEnv -> (e -> P.Pretty String) -> Value e -> P.Pretty String
prettyValue ppe prettyE v = case v of
  I i -> (if i >= 0 then "+" else "" ) <> P.string (show i)
  F d -> P.shown d
  N n -> P.shown n
  B b -> if b then "true" else "false"
  T t -> P.shown t
  Lam arity _u b -> P.parenthesize $
    ("Lambda " <> P.string (show arity)) `P.hang`
      prettyIR ppe prettyE b
  Data r cid vs -> P.parenthesize $
    ("Data " <> prettyHashQualified (PPE.patternName ppe r cid)) `P.hang`
      P.surroundCommas "[" "]" (prettyValue ppe prettyE <$> vs)
  Sequence vs -> P.surroundCommas "[" "]" (prettyValue ppe prettyE <$> vs)
  Ref id name _ -> P.parenthesize $
    P.sep " " ["Ref", P.shown id, P.shown name]
  Pure v -> P.surroundCommas "{" "}" [prettyValue ppe prettyE v]
  Requested (Req r cid vs cont) -> P.parenthesize $
    ("Request " <> prettyHashQualified (PPE.patternName ppe r cid))
      `P.hang`
      P.spaced [
        P.surroundCommas "[" "]" (prettyValue ppe prettyE <$> vs),
        prettyIR ppe prettyE cont
      ]
  Cont ir -> P.parenthesize $
    "Cont" `P.hang` prettyIR ppe prettyE ir
  UninitializedLetRecSlot s _ _ -> P.parenthesize $
    "Uninitialized " <> P.shown s

-- Contains the effect ref and ctor id, the args, and the continuation
-- which expects the result at the top of the stack
data Req e = Req R.Reference ConstructorId [Value e] (IR e)
  deriving (Eq,Show)

-- Appends `k2` to the end of the `k` continuation
-- Ex: if `k` is `x -> x + 1` and `k2` is `y -> y + 4`,
-- this produces a continuation `x -> let r1 = x + 1; r1 + 4`.
appendCont :: Symbol -> Req e -> IR e -> Req e
appendCont v (Req r cid args k) k2 = Req r cid args (Let v k k2)

-- Wrap a `handle h` around the continuation inside the `Req`.
-- Ex: `k = x -> x + 1` becomes `x -> handle h in x + 1`.
wrapHandler :: Value e -> Req e -> Req e
wrapHandler h (Req r cid args k) = Req r cid args (Handle (Val h) k)

-- Annotate all `z` values with the number of outer bindings, useful for
-- tracking free variables or converting away from debruijn indexing.
-- Currently used as an implementation detail by `specializeIR`.
annotateDepth :: IR' z -> IR' (z, Int)
annotateDepth ir = go 0 ir where
  go depth ir = case ir of
    -- Only the binders modify the depth
    Let v b body -> Let v (go depth b) (go (depth + 1) body)
    LetRec bs body -> let
      depth' = depth + length bs
      in LetRec (second (go depth') <$> bs) (go depth' body)
    Match scrute cases -> Match (scrute, depth) (tweak <$> cases) where
      tweak (pat, boundVars, guard, rhs) = let
        depth' = depth + length boundVars
        in (pat, boundVars, go depth' <$> guard, go depth' rhs)
    -- All the other cases just leave depth alone and recurse
    Apply f args -> Apply (go depth f) ((,depth) <$> args)
    Handle f body -> Handle (f,depth) (go depth body)
    If c a b -> If (c,depth) (go depth a) (go depth b)
    And a b -> And (a,depth) (go depth b)
    Or a b -> Or (a,depth) (go depth b)
    ir -> (,depth) <$> ir

-- Given an environment mapping of de bruijn indices to values, specialize
-- the given `IR` by replacing slot lookups with the provided values.
specializeIR :: Map Int (Value e) -> IR' (Z e) -> IR' (Z e)
specializeIR env ir = let
  ir' = annotateDepth ir
  go (s@(Slot i), depth) = maybe s Val $ Map.lookup (i - depth) env
  go (s@(LazySlot i), depth) = maybe s Val $ Map.lookup (i - depth) env
  go (s,_) = s
  in go <$> ir'

compile :: Show e => CompilationEnv e -> Term Symbol -> IR e
compile env t = compile0 env []
  (ABT.rewriteDown ANF.minimizeCyclesOrCrash $ Term.vmap toSymbolC t)

freeVars :: [(SymbolC,a)] -> Term SymbolC -> Set SymbolC
freeVars bound t =
  -- let fv = trace "free:" . traceShowId $ ABT.freeVars t
  --     bv = trace "bound:" . traceShowId $ Set.fromList (fst <$> bound)
  -- in trace "difference:" . traceShowId $ fv `Set.difference` bv
  ABT.freeVars t `Set.difference` Set.fromList (fst <$> bound)

-- Main compilation function - converts an arbitrary term to an `IR`.
-- Takes a way of resolving `Reference`s and an environment of variables,
-- some of which may already be precompiled to `V`s. (This occurs when
-- recompiling a function that is being partially applied)
compile0 :: Show e => CompilationEnv e -> [(SymbolC, Maybe (Value e))] -> Term SymbolC -> IR e
compile0 env bound t =
  if Set.null fvs then
    -- Annotates the term with this [(SymbolC, Maybe (Value e))]
    -- where a `Just v` indicates an immediate value, and `Nothing` indicates
    -- a stack lookup is needed at the stack index equal to the symbol's index.
    -- ABT.annotateBound' produces an initial annotation consisting of the a
    -- stack of bound variables, with the innermost bound variable at the top.
    -- We tag each of these with `Nothing`, and then tack on the immediates at
    -- the end.  Their indices don't correspond to stack positions (although
    -- they may reflect shadowing).
    let wrangle vars = ((,Nothing) <$> vars) ++ bound
        t0 = ANF.fromTerm' makeLazy t
        msg = "ANF form:\n" <>
               TP.pretty' (Just 80) mempty t0 <>
               "\n---------"
    in go (wrangle <$> trace msg (ABT.annotateBound' t0))
  else
    error $ "can't compile a term with free variables: " ++ show (toList fvs)
  where
  fvs = freeVars bound t
  go t = case t of
    Term.Nat' n -> Leaf . Val . N $ n
    Term.Int' n -> Leaf . Val . I $ n
    Term.Float' n -> Leaf . Val . F $ n
    Term.Boolean' n -> Leaf . Val . B $ n
    Term.Text' n -> Leaf . Val . T $ n
    Term.And' x y -> And (toZ "and" t x) (go y)
    Term.LamsNamed' vs body -> Leaf . Val $
      Lam (length vs)
        (Specialize (void t) [])
        (compile0 env (ABT.annotation body) (void body))
    Term.Or' x y -> Or (toZ "or" t x) (go y)
    Term.Let1Named' v b body -> Let (underlyingSymbol v) (go b) (go body)
    Term.LetRecNamed' bs body ->
      LetRec ((\(v,b) -> (underlyingSymbol v, go b)) <$> bs) (go body)
    Term.Constructor' r cid -> ctorIR con (Term.constructor()) r cid where
      con 0 r cid [] = Leaf . Val $ Data r cid []
      con _ r cid args = Construct r cid args
    Term.Request' r cid -> ctorIR (const Request) (Term.request()) r cid
    Term.Apps' f args -> Apply (go f) (map (toZ "apply-args" t) args)
    Term.Handle' h body -> Handle (toZ "handle" t h) (go body)
    Term.Ann' e _ -> go e
    Term.Match' scrutinee cases ->
      Match (toZ "match" t scrutinee) (compileCase <$> cases)
    ABT.Abs1NA' _ body -> go body
    Term.If' cond ifT ifF -> If (toZ "cond" t cond) (go ifT) (go ifF)
    Term.Var' _ -> Leaf $ toZ "var" t t
    Term.Ref' (toIR env -> Just ir) -> ir
    Term.Vector' vs -> MakeSequence . toList . fmap (toZ "sequence" t) $ vs
    _ -> error $ "TODO - don't know how to compile this term:\n"
              <> (P.render 80 . TP.prettyTop mempty $ void t)
    where
      compileVar _ v [] = unknown v
      compileVar i v ((v',o):tl) =
        if v == v' then case o of
          Nothing | isLazy v  -> LazySlot i
                  | otherwise -> Slot i
          Just v -> Val v
        else if isJust o then compileVar i v tl
        else compileVar (i + 1) v tl

      ctorIR :: (Int -> R.Reference -> Int -> [Z e] -> IR e)
             -> (R.Reference -> Int -> Term SymbolC)
             -> R.Reference -> Int -> IR e
      ctorIR con src r cid = case constructorArity env r cid of
        Nothing -> error $ "the compilation env is missing info about how "
                        ++ "to compile this constructor: " ++ show (r, cid) ++ "\n" ++ show (constructorArity' env)
        Just 0 -> con 0 r cid []
        -- Just 0 -> Leaf . Val $ Data "Optional" 0
        Just arity -> Leaf . Val $ Lam arity (FormClosure (src r cid) []) ir
          where
          -- if `arity` is 1, then `Slot 0` is the sole argument.
          -- if `arity` is 2, then `Slot 1` is the first arg, and `Slot 0`
          -- get the second arg, etc.
          -- Note: [1..10] is inclusive of both `1` and `10`
          ir = con arity r cid (reverse $ map Slot [0 .. (arity - 1)])

      unknown v = error $ "free variable during compilation: " ++ show v
      toZ _msg t (Term.Var' v) = compileVar 0 v (ABT.annotation t)
      toZ msg _t e = case go e of
        Leaf v -> v
        e -> error $ msg ++ ": ANF should have eliminated any non-Z arguments from: " ++ show e
      compileCase (Term.MatchCase pat guard rhs@(ABT.unabs -> (vs,_))) =
          (compilePattern pat, underlyingSymbol <$> vs, go <$> guard, go rhs)
      compilePattern pat = case pat of
        Pattern.Unbound -> PatternIgnore
        Pattern.Var -> PatternVar
        Pattern.Boolean b -> PatternB b
        Pattern.Int n -> PatternI n
        Pattern.Nat n -> PatternN n
        Pattern.Float n -> PatternF n
        Pattern.Text t -> PatternT t
        Pattern.Constructor r cid args -> PatternData r cid (compilePattern <$> args)
        Pattern.As pat -> PatternAs (compilePattern pat)
        Pattern.EffectPure p -> PatternPure (compilePattern p)
        Pattern.EffectBind r cid args k -> PatternBind r cid (compilePattern <$> args) (compilePattern k)
        _ -> error $ "todo - compilePattern " ++ show pat

type DS = StateT (Map Symbol (Term Symbol), Set RefID) IO

decompile :: External e => Value e -> IO (Term Symbol)
decompile v = do
  (body, (letRecBindings, _)) <- runStateT (decompileImpl v) mempty
  pure $ if null letRecBindings then body
         else Term.letRec' False (Map.toList letRecBindings) body

decompileImpl ::
  External e => Value e -> DS (Term Symbol)
decompileImpl v = case v of
  I n -> pure $ Term.int () n
  N n -> pure $ Term.nat () n
  F n -> pure $ Term.float () n
  B b -> pure $ Term.boolean () b
  T t -> pure $ Term.text () t
  Lam _ f _ -> decompileUnderapplied f
  Data r cid args ->
    Term.apps' <$> pure (Term.constructor() r cid)
               <*> traverse decompileImpl (toList args)
  Sequence vs -> Term.vector' () <$> traverse decompileImpl vs
  Ref id symbol ioref -> do
    seen <- gets snd
    symbol <- pure $ Var.freshenId (fromIntegral id) symbol
    if Set.member id seen then
      pure $ Term.var () symbol
    else do
      modify (second $ Set.insert id)
      t <- decompileImpl =<< lift (readIORef ioref)
      modify (first $ Map.insert symbol t)
      pure (Term.etaNormalForm t)
  Cont k -> Term.lam () contIn <$> decompileIR [contIn] k
    where contIn = Var.freshIn (boundVarsIR k) (Var.named "result")
  Pure a -> do
    -- `{a}` doesn't have a term syntax, so it's decompiled as
    -- `handle (x -> x) in a`, which has the type `Request ambient e a`
    a <- decompileImpl a
    pure $ Term.handle() id a
  Requested (Req r cid vs k) -> do
    -- `{req a b -> k}` doesn't have a term syntax, so it's decompiled as
    -- `handle (x -> x) in k (req a b)`
    vs <- traverse decompileImpl vs
    let v = Var.freshIn (boundVarsIR k) (Var.named "result")
    k <- decompileIR [v] k
    pure . Term.handle() id $
      Term.apps' (Term.lam() v k) [Term.apps' (Term.request() r cid) vs]
  UninitializedLetRecSlot _b _bs _body ->
    error "unpossible - decompile UninitializedLetRecSlot"
  where
    idv = Var.named "x"
    id = Term.lam () idv (Term.var() idv)


boundVarsIR :: IR e -> Set Symbol
boundVarsIR = \case
  Let v b body -> Set.singleton v <> boundVarsIR b <> boundVarsIR body
  LetRec bs body -> Set.fromList (fst <$> bs) <> foldMap (boundVarsIR . snd) bs <> boundVarsIR body
  Apply lam _ -> boundVarsIR lam
  Handle _ body -> boundVarsIR body
  If _ t f -> foldMap boundVarsIR [t,f]
  And _ b -> boundVarsIR b
  Or _ b -> boundVarsIR b
  Match _ cases -> foldMap doCase cases
    where doCase (_, _, b, body) = maybe mempty boundVarsIR b <> boundVarsIR body
  -- I added all these cases for exhaustiveness checking in the future,
  -- and also because I needed the patterns for decompileIR anyway.
  -- Sure is ugly though.  This ghc doesn't support Language MultiCase.
  -- I want to be able to say `_ -> mempty` where _ refers to exactly the other
  -- cases that existed at the time I wrote it!
  Leaf _ -> mempty
  AddI _ _ -> mempty
  SubI _ _ -> mempty
  MultI _ _ -> mempty
  DivI _ _ -> mempty
  GtI _ _ -> mempty
  LtI _ _ -> mempty
  GtEqI _ _ -> mempty
  LtEqI _ _ -> mempty
  EqI _ _ -> mempty
  SignumI _ -> mempty
  NegateI _ -> mempty
  ModI _ _ -> mempty
  AddN _ _ -> mempty
  DropN _ _ -> mempty
  SubN _ _ -> mempty
  MultN _ _ -> mempty
  DivN _ _ -> mempty
  GtN _ _ -> mempty
  LtN _ _ -> mempty
  GtEqN _ _ -> mempty
  LtEqN _ _ -> mempty
  EqN _ _ -> mempty
  ModN _ _ -> mempty
  AddF _ _ -> mempty
  SubF _ _ -> mempty
  MultF _ _ -> mempty
  DivF _ _ -> mempty
  GtF _ _ -> mempty
  LtF _ _ -> mempty
  GtEqF _ _ -> mempty
  LtEqF _ _ -> mempty
  EqF _ _ -> mempty
  MakeSequence _ -> mempty
  Construct _ _ _ -> mempty
  Request _ _ _ -> mempty
  Not _ -> mempty

class External e where
  decompileExternal :: e -> Term Symbol

decompileIR :: External e => [Symbol] -> IR e -> DS (Term Symbol)
decompileIR stack = \case
  -- added all these cases for exhaustiveness checking in the future,
  -- and also because I needed the patterns for decompileIR anyway.
  Leaf z -> decompileZ z
  AddI x y -> builtin "Int.+" [x,y]
  SubI x y -> builtin "Int.-" [x,y]
  MultI x y -> builtin "Int.*" [x,y]
  DivI x y -> builtin "Int./" [x,y]
  GtI x y -> builtin "Int.>" [x,y]
  LtI x y -> builtin "Int.<" [x,y]
  GtEqI x y -> builtin "Int.>=" [x,y]
  LtEqI x y -> builtin "Int.<=" [x,y]
  EqI x y -> builtin "Int.==" [x,y]
  SignumI x -> builtin "Int.signum" [x]
  NegateI x -> builtin "Int.negate" [x]
  ModI x y -> builtin "Int.mod" [x,y]
  AddN x y -> builtin "Nat.+" [x,y]
  DropN x y -> builtin "Nat.drop" [x,y]
  SubN x y -> builtin "Nat.sub" [x,y]
  MultN x y -> builtin "Nat.*" [x,y]
  DivN x y -> builtin "Nat./" [x,y]
  GtN x y -> builtin "Nat.>" [x,y]
  LtN x y -> builtin "Nat.<" [x,y]
  GtEqN x y -> builtin "Nat.>=" [x,y]
  LtEqN x y -> builtin "Nat.<=" [x,y]
  EqN x y -> builtin "Nat.==" [x,y]
  ModN x y -> builtin "Nat.mod" [x,y]
  AddF x y -> builtin "Float.+" [x,y]
  SubF x y -> builtin "Float.-" [x,y]
  MultF x y -> builtin "Float.*" [x,y]
  DivF x y -> builtin "Float./" [x,y]
  GtF x y -> builtin "Float.>" [x,y]
  LtF x y -> builtin "Float.<" [x,y]
  GtEqF x y -> builtin "Float.>=" [x,y]
  LtEqF x y -> builtin "Float.<=" [x,y]
  EqF x y -> builtin "Float.==" [x,y]
  Let v b body -> do
    b' <- decompileIR stack b
    body' <- decompileIR (v:stack) body
    pure $ Term.let1_ False [(v, b')] body'
  LetRec bs body -> do
    let stack' = reverse (fmap fst bs) ++ stack
        secondM f (x,y) = (x,) <$> f y
    bs' <- traverse (secondM $ decompileIR stack') bs
    body' <- decompileIR stack' body
    pure $ Term.letRec' False bs' body'
  MakeSequence args ->
    Term.vector() <$> traverse decompileZ args
  Apply lam args ->
    Term.apps' <$> decompileIR stack lam <*> traverse decompileZ args
  Construct r cid args ->
    Term.apps' (Term.constructor() r cid) <$> traverse decompileZ args
  Request r cid args ->
    Term.apps' (Term.request() r cid) <$> traverse decompileZ args
  Handle h body ->
    Term.handle() <$> decompileZ h <*> decompileIR stack body
  If c t f ->
    Term.iff() <$> decompileZ c <*> decompileIR stack t <*> decompileIR stack f
  And x y ->
    Term.and() <$> decompileZ x <*> decompileIR stack y
  Or x y ->
    Term.or() <$> decompileZ x <*> decompileIR stack y
  Not x -> builtin "Boolean.not" [x]
  Match scrutinee cases ->
    Term.match () <$> decompileZ scrutinee <*> traverse decompileMatchCase cases
  where
  builtin :: External e => Text -> [Z e] -> DS (Term Symbol)
  builtin t args =
    Term.apps' (Term.ref() (R.Builtin t)) <$> traverse decompileZ args
  at :: Pos -> Term Symbol
  at i = Term.var() (stack !! i)
  decompileZ :: External e => Z e -> DS (Term Symbol)
  decompileZ = \case
    Slot p -> pure $ at p
    LazySlot p -> pure $ at p
    Val v -> decompileImpl v
    External e -> pure $ decompileExternal e
  decompilePattern :: Pattern -> Pattern.Pattern
  decompilePattern = \case
    PatternI i -> Pattern.Int i
    PatternN n -> Pattern.Nat n
    PatternF f -> Pattern.Float f
    PatternB b -> Pattern.Boolean b
    PatternT t -> Pattern.Text t
    PatternData r cid pats ->
      Pattern.Constructor r cid (d <$> pats)
    PatternSequence v -> error "todo" v
      -- case vec of
      --   head +: tail -> ...
      --   init :+ last -> ...
      --   [] -> ...
      --   [1,2,3] -> ...
      --   [1,2,3] ++ mid ++ [7,8,9] -> ... maybe?
    PatternPure pat -> Pattern.EffectPure (d pat)
    PatternBind r cid pats k ->
      Pattern.EffectBind r cid (d <$> pats) (d k)
    PatternAs pat -> Pattern.As (d pat)
    PatternIgnore -> Pattern.Unbound
    PatternVar -> Pattern.Var
  d = decompilePattern
  decompileMatchCase (pat, vars, guard, body) = do
    let stack' = reverse vars ++ stack
    guard' <- traverse (decompileIR stack') guard
    body' <- decompileIR stack' body
    pure $ Term.MatchCase (d pat) guard' body'

instance Show e => Show (Z e) where
  show (LazySlot i) = "'#" ++ show i
  show (Slot i) = "#" ++ show i
  show (Val v) = show v
  show (External e) = "External:" <> show e

builtins :: Map R.Reference (IR e)
builtins = Map.fromList $ let
  -- slot = Leaf . Slot
  val = Leaf . Val
  underapply name = FormClosure (Term.ref() $ R.Builtin name) []
  var = Var.named "x"
  in [ (R.Builtin name, Leaf . Val $ Lam arity (underapply name) ir) |
       (name, arity, ir) <-
        [ ("Int.+", 2, AddI (Slot 1) (Slot 0))
        , ("Int.-", 2, SubI (Slot 1) (Slot 0))
        , ("Int.*", 2, MultI (Slot 1) (Slot 0))
        , ("Int./", 2, DivI (Slot 1) (Slot 0))
        , ("Int.<", 2, LtI (Slot 1) (Slot 0))
        , ("Int.>", 2, GtI (Slot 1) (Slot 0))
        , ("Int.<=", 2, LtEqI (Slot 1) (Slot 0))
        , ("Int.>=", 2, GtEqI (Slot 1) (Slot 0))
        , ("Int.==", 2, EqI (Slot 1) (Slot 0))
        , ("Int.increment", 1, AddI (Val (I 1)) (Slot 0))
        , ("Int.signum", 1, SignumI (Slot 0))
        , ("Int.negate", 1, NegateI (Slot 0))
        , ("Int.mod", 2, ModI (Slot 1) (Slot 0))
        , ("Int.isEven", 1, Let var (ModI (Slot 0) (Val (I 2)))
                                    (EqI (Val (I 0)) (Slot 0)))
        , ("Int.isOdd", 1, Let var (ModI (Slot 0) (Val (I 2)))
                                   (Let var (EqI (Val (I 0)) (Slot 0))
                                            (Not (Slot 0))))

        , ("Nat.+", 2, AddN (Slot 1) (Slot 0))
        , ("Nat.drop", 2, DropN (Slot 1) (Slot 0))
        , ("Nat.sub", 2, SubN (Slot 1) (Slot 0))
        , ("Nat.*", 2, MultN (Slot 1) (Slot 0))
        , ("Nat./", 2, DivN (Slot 1) (Slot 0))
        , ("Nat.<", 2, LtN (Slot 1) (Slot 0))
        , ("Nat.>", 2, GtN (Slot 1) (Slot 0))
        , ("Nat.<=", 2, LtEqN (Slot 1) (Slot 0))
        , ("Nat.>=", 2, GtEqN (Slot 1) (Slot 0))
        , ("Nat.==", 2, EqN (Slot 1) (Slot 0))
        , ("Nat.increment", 1, AddN (Val (N 1)) (Slot 0))
        , ("Nat.mod", 2, ModN (Slot 1) (Slot 0))
        , ("Nat.isEven", 1, Let var (ModN (Slot 0) (Val (N 2)))
                                    (EqN (Val (N 0)) (Slot 0)))
        , ("Nat.isOdd", 1, Let var (ModN (Slot 0) (Val (N 2)))
                                   (Let var (EqN (Val (N 0)) (Slot 0))
                                            (Not (Slot 0))))

        , ("Float.+", 2, AddF (Slot 1) (Slot 0))
        , ("Float.-", 2, SubF (Slot 1) (Slot 0))
        , ("Float.*", 2, MultF (Slot 1) (Slot 0))
        , ("Float./", 2, DivF (Slot 1) (Slot 0))
        , ("Float.<", 2, LtF (Slot 1) (Slot 0))
        , ("Float.>", 2, GtF (Slot 1) (Slot 0))
        , ("Float.<=", 2, LtEqF (Slot 1) (Slot 0))
        , ("Float.>=", 2, GtEqF (Slot 1) (Slot 0))
        , ("Float.==", 2, EqF (Slot 1) (Slot 0))

        , ("Boolean.not", 1, Not (Slot 0))

        , ("Text.empty", 0, val $ T "")
        , ("Sequence.empty", 0, val $ Sequence mempty)
        ]
  ]

-- boring instances

instance Eq SymbolC where
  SymbolC _ s == SymbolC _ s2 = s == s2

instance Ord SymbolC where
  SymbolC _ s `compare` SymbolC _ s2 = s `compare` s2

instance Var SymbolC where
  named s = SymbolC False (Var.named s)
  rename t (SymbolC i s) = SymbolC i (Var.rename t s)
  name (SymbolC _ s) = Var.name s
  clear (SymbolC _ s) = SymbolC False (Var.clear s)
  qualifiedName (SymbolC _ s) = Var.qualifiedName s
  freshenId n (SymbolC i s) = SymbolC i (Var.freshenId n s)
  freshIn vs (SymbolC i s) =
    SymbolC i (Var.freshIn (Set.map underlyingSymbol vs) s)

instance Show e => Show (Value e) where
  show (I n) = show n
  show (F n) = show n
  show (N n) = show n
  show (B b) = show b
  show (T t) = show t
  show (Lam n e ir) = "(Lam " <> show n <> " " <> show e <> " (" <> show ir <> "))"
  show (Data r cid vs) = "(Data " <> show r <> " " <> show cid <> " " <> show vs <> ")"
  show (Sequence vs) = "[" <> intercalateMap ", " show vs <> "]"
  show (Ref n s _) = "(Ref " <> show n <> " " <> show s <> ")"
  show (Pure v) = "(Pure " <> show v <> ")"
  show (Requested r) = "(Requested " <> show r <> ")"
  show (Cont ir) = "(Cont " <> show ir <> ")"
  show (UninitializedLetRecSlot b bs _body) =
    "(UninitializedLetRecSlot " <> show b <> " in " <> show (fst <$> bs)<> ")"

compilationEnv0 :: CompilationEnv e
compilationEnv0 = CompilationEnv builtins mempty

instance Semigroup (CompilationEnv e) where (<>) = mappend

instance Monoid (CompilationEnv e) where
  mempty = CompilationEnv mempty mempty
  mappend c1 c2 = CompilationEnv ir ctor where
    ir = toIR' c1 <> toIR' c2
    ctor = constructorArity' c1 <> constructorArity' c2