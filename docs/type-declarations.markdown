draft draft draft

# Type Declarations in Unison

```haskell
data DataDeclaration' v a = DataDeclaration {
  annotation :: a,
  bound :: [v],
  constructors' :: [(a, v, AnnotatedType v a)]
  -- isStructural :: IsStructural
  -- isOpaque :: Set (AnnotatedTerm v a)
} deriving (Eq, Show, Functor)

-- type IsStructural = Structural | Unique GUID
```

## Structural Types

Structural types are defined uniquely by their structure. Every constructor has a unique signature, which intrinsically defines the meaning of the constructor. For example, the following types are identical and interoperable:

```haskell
structural type Maybe a = Nothing | Just a
structural type Optional t = Some t | None
```

These definitions would also be identical and interoperable (although they maybe shouldn't be):

```haskell
structural type Validation e a = Success a | Failure e
structural type Either a b = Left a | Right b
```

It should be an error if two constructors of a structural type have the same signature, indicating that the semantics are defined outside of the structure.

The identity of a structural type is determined by normalizing the constructor order by <todo: explain how> and then hashing their types.

## Unique types
Unique types are have extrinsic semantics, not completely defined by the constructor types.  Their representation includes a GUID, along with the constructors.  The constructors types need not be unique.  The GUID is typically auto-generated, but can be specified as part of the type declaration, in order to use a textual representation to declare an identical type.

```haskell
unique type Day = Mon | Tue | Wed | ...

unique[<guid>]
type Day = Mon | Tue | Wed | ...
```

Order of constructors having the same type is stable, but the relative constructor order of differently typed constructors is (currently) unspecified.

## Opaque Types

An opaque type has a structure and a block of terms that can inspect structure. The hash of those terms is part of the type ID.  They have a flag in the decl so typechecker can prevent access.

``` haskell
opaque type Socket = Socket Nat
opaque type Handle = Handle Text
```

Q: How do you declare a definition that can inspect two opaque types?
Q: How do *we* create and inspect Sockets?  We don't want to create public accessors, but we do want some way for privileged code to construct those values.  I guess it's straightforward for types with a single constructor, but we may end up needing some deterministic way of distinguishing the other constructors.

For reference and comparison: https://docs.scala-lang.org/sips/opaque-types.html
Notes re Scala opaque types:
* They are a type alias (no boxing) that is only equal for definitions inside a corresponding companion object/module.
* We (Unison) do need to "box" values within a constructor to give them a hash corresponding to their type identity.

## Combinations?

_Structural + Unique:_ No.
_Structural + Opaque:_ No.
_Unique + Opaque:_ Sure why not.  Example where you want Opaque without Unique: `SortedSet` -- the exposed methods define the semantics.  Example where you want Unique + Opaque: `Socket`, `Handle` -- the exposed methods may necessarily dictate that the two types are not the same.

## Misc scenarios / questions:

I was just editing some Haskell code.

```haskell
-- InputPatterns accept some fixed number of Required arguments of various
-- types, followed by a variable number of a single type of argument.
data IsOptional
  = Optional -- 0 or 1, at the end
  | Required -- 1, at the start
  | ZeroPlus -- 0 or more, at the end
  | OnePlus -- 1 or more, at the end
  deriving Show
```

I decided to move `Required` to the top for clarity since, as the comments state, InputPattern arg lists start with some number of `Required` arguments.

```haskell
data IsOptional
  = Optional -- 0 or 1, at the end
  | Required -- 1, at the start
  | ZeroPlus -- 0 or more, at the end
  | OnePlus -- 1 or more, at the end
  deriving Show
```
I still want this to be the same type.  None of the semantics have changed, I just reordered the constructors for readability.  I don't think this would be possible with any of our current proposed type implementations.  Yes, I could create a new unique type, and refactor everything to use that, but that strikes me as unappealing, especially from a code-sharing perspective.  

Thoughts?

* @pchiusano - I'd say that "constructor display order" should be a bit of metadata that can be attached to a data declaration, and you should be able to edit this metadata somehow (perhaps by default, the `add` / `update` command can suggest "metadata edits" in reponse to this sort of thing).

## Old stuff: Algebraic Types?

Algebraic types are defined by their structure and a set of laws relating their fields.  Note that the laws may involve more than one type.

```
algebraic Monoid a = Monoid { mempty : a, mappend : a -> a -> a }
where m a -> (mappend m) (mempty m) a == a
      m a -> (mappend m) a (mempty m) == a
      m a b c -> (mappend m) a ((mappend m) b c) ==
                 (mappend m) ((mappend m) a b) c
```
