{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

{- |
 Module     : ISA.Types.Symbolic
 Copyright  : (c) Georgy Lukyanov 2019
 License    : MIT (see the file LICENSE)
 Maintainer : mail@gmail.com
 Stability  : experimental

 Untyped symbolic expressions syntax
-}
module ISA.Types.Symbolic (
    -- * Concrete values
    Concrete (..),

    -- * Symbolic expressions
    Sym (..),
    conjoin,
    disjoin,

    -- ** substitute an expression for a variable
    subst,

    -- ** simplify an expression
    simplify,

    -- ** try to concertise symbolic values
    getValue,
    tryFoldConstant,
    tryReduce,
    toCAddress,
    toImm,
    toInstructionCode,
) where

import Control.DeepSeq
import Data.Aeson (
    FromJSON,
    ToJSON,
    defaultOptions,
    genericToEncoding,
    toEncoding,
 )
import Data.Foldable
import Data.Int (Int32, Int8)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable
import Data.Word (Word16)
import GHC.Generics
import GHC.Stack
import Prelude hiding (not)

import ISA.Types
import ISA.Types.Boolean

-----------------------------------------------------------------------------

-- | Concrete values: either signed or unsigned integers, or booleans
data Concrete where
    CInt32 :: Int32 -> Concrete
    CWord :: Word16 -> Concrete
    CBool :: Bool -> Concrete

deriving instance Eq Concrete
deriving instance Ord Concrete
deriving instance Generic Concrete
deriving instance Read Concrete
instance ToJSON Concrete where
    toEncoding = genericToEncoding defaultOptions
instance FromJSON Concrete
instance NFData Concrete

instance Show Concrete where
    show (CInt32 i) = show i
    show (CWord w) = show w
    show (CBool b) = if b then "⊤" else "⊥"

instance Num Concrete where
    (CInt32 x) + (CInt32 y) = CInt32 (x + y)
    (CWord x) + (CWord y) = CWord (x + y)
    (CWord x) + (CInt32 y) = CWord (x + fromIntegral y)
    (CInt32 x) + (CWord y) = CInt32 (x + fromIntegral y)
    x + y =
        error $
            "Concrete.Num.+: non-integer arguments " <> show x <> " "
                <> show y
    (CInt32 x) * (CInt32 y) = CInt32 (x + y)
    x * y =
        error $
            "Concrete.Num.*: non-integer arguments " <> show x <> " "
                <> show y
    abs (CInt32 x) = CInt32 (abs x)
    abs x = error $ "Concrete.Num.abs: non-integer argument " <> show x

    signum (CInt32 x) = CInt32 (signum x)
    signum x = error $ "Concrete.Num.signum: non-integer argument " <> show x

    fromInteger x = CInt32 (fromInteger x)

    negate (CInt32 x) = CInt32 (negate x)
    negate x = error $ "Concrete.Num.negate: non-integer argument " <> show x

instance Enum Concrete where
    toEnum x = CInt32 (fromIntegral x)

    fromEnum (CInt32 x) = fromIntegral x
    fromEnum (CWord x) = fromIntegral x
    fromEnum (CBool x) = if x then 1 else 0

instance Real Concrete where
    toRational (CInt32 x) = toRational x
    toRational (CWord x) = toRational x
    toRational (CBool x) = error $ "Concrete.Real.toRational: non integer argument " <> show x

instance Integral Concrete where
    (CInt32 x) `quotRem` (CInt32 y) = let (q, r) = x `quotRem` y in (CInt32 q, CInt32 r)
    (CWord x) `quotRem` (CWord y) = let (q, r) = x `quotRem` y in (CWord q, CWord r)
    x `quotRem` y =
        error $ "Concrete.Integral.quotRem: incompatible arguments " <> show x <> " " <> show y

    toInteger (CInt32 x) = toInteger x
    toInteger (CWord x) = toInteger x
    toInteger (CBool x) =
        error $ "Concrete.Integral.toInteger: non integer argument " <> show x

instance Bounded Concrete where
    maxBound = CInt32 (maxBound :: Int32)
    minBound = CInt32 (minBound :: Int32)

instance Boolean Concrete where
    toBool (CBool b) = b
    toBool x = error $ "Concrete.Boolean.toBool: non-boolean argument " <> show x
    true = CBool True

    fromBool b = (CBool b)

    not (CBool b) = CBool (not b)
    not x = error $ "Concrete.Boolean.not: non-boolean argument " <> show x

    (CBool x) ||| (CBool y) = CBool (x || y)
    x ||| y =
        error $ "Concrete.Num.|||: non-boolean arguments " <> show x <> " " <> show y

    (CBool x) &&& (CBool y) = CBool (x && y)
    x &&& y =
        error $ "Concrete.Num.&&&: non-boolean arguments " <> show x <> " " <> show y

-- | Symbolic expressions
data Sym where
    SConst :: Concrete -> Sym
    SAny :: Text -> Sym
    -- | a tentative variant of points-to with arbitrary lvalue
    -- which actually will be either a concrete address or a variable
    SPointer :: Sym -> Sym
    SIte :: Sym -> Sym -> Sym -> Sym
    SAdd :: Sym -> Sym -> Sym
    SSub :: Sym -> Sym -> Sym
    SMul :: Sym -> Sym -> Sym
    SDiv :: Sym -> Sym -> Sym
    SMod :: Sym -> Sym -> Sym
    SAbs :: Sym -> Sym
    SEq :: Sym -> Sym -> Sym
    SGt :: Sym -> Sym -> Sym
    SLt :: Sym -> Sym -> Sym
    SAnd :: Sym -> Sym -> Sym
    SOr :: Sym -> Sym -> Sym
    SNot :: Sym -> Sym

deriving instance Eq Sym
deriving instance Ord Sym
deriving instance Typeable Sym
deriving instance Generic Sym
instance ToJSON Sym where
    toEncoding = genericToEncoding defaultOptions
instance FromJSON Sym
instance NFData Sym

instance Show Sym where
    show (SAdd x y) = "(" <> show x <> " + " <> show y <> ")"
    show (SSub x y) = "(" <> show x <> " - " <> show y <> ")"
    show (SMul x y) = "(" <> show x <> " * " <> show y <> ")"
    show (SDiv x y) = "(" <> show x <> " / " <> show y <> ")"
    show (SMod x y) = "(" <> show x <> " % " <> show y <> ")"
    show (SAbs x) = "abs " <> show x
    show (SConst x) = show x
    show (SAnd x y) = "(" <> show x <> " && " <> show y <> ")"
    show (SOr x y) = "(" <> show x <> " || " <> show y <> ")"
    show (SAny n) = "$" <> Text.unpack n
    show (SPointer x) = "(&" <> show x <> ")"
    show (SIte i t e) = "ite(" <> show i <> ", " <> show t <> ", " <> show e <> ")"
    show (SEq x y) = "(" <> show x <> " == " <> show y <> ")"
    show (SGt x y) = "(" <> show x <> " > " <> show y <> ")"
    show (SLt x y) = "(" <> show x <> " < " <> show y <> ")"
    show (SNot b) = "not " <> show b

instance Num Sym where
    x + y = SAdd x y
    x - y = SSub x y
    x * y = SMul x y
    abs x = SAbs x
    signum _ = error "Sym.Num: signum is not defined"
    fromInteger x = SConst (CInt32 $ fromInteger x)
    negate _ = error "Sym.Num: negate is not defined"

instance Enum Sym where
    toEnum x = SConst (CInt32 (fromIntegral x))

    fromEnum x = case getValue x of
        Nothing -> error $ "Sym.Enum.fromEnum: symbolic value " <> show x
        Just val -> fromEnum val

instance Real Sym where
    toRational x = case getValue x of
        Nothing -> error $ "Sym.Real.toRational: symbolic value " <> show x
        Just val -> toRational val

instance Integral Sym where
    x `div` y = SDiv x y
    x `mod` y = SMod x y

    _ `quotRem` _ = error $ "Sym.Integral.quotRem: not implemented"
    toInteger _ = error $ "Sym.Integral.toInteger: not implemented"

instance Bounded Sym where
    maxBound = SConst maxBound
    minBound = SConst minBound

instance Semigroup Sym where
    x <> y = SAdd x y

instance Monoid Sym where
    mempty = SConst 0

instance Boolean Sym where
    true = SConst (CBool True)
    false = SConst (CBool False)
    fromBool b = SConst (CBool b)

    toBool x = case getValue x of
        Nothing -> True
        Just (CBool b) -> b
        Just x ->
            error $
                "ISA.Symbolic.Sym.toBool: non-boolean concrete value "
                    <> show x
    not x = SNot x

    x ||| y = SOr x y
    x &&& y = SAnd x y

instance BEq Sym where
    x === y = (SEq x y)

instance BOrd Sym where
    lt x y = (SLt x y)
    gt x y = (SGt x y)

conjoin :: [Sym] -> Sym
conjoin cs = foldl' SAnd true cs

disjoin :: [Sym] -> Sym
disjoin cs = foldl' SOr false cs

-----------------------------------------------------------------------------

-- | Substitute a variable named @name with @expr
subst :: Sym -> Text -> Sym -> Sym
subst expr name = \case
    n@(SAny var) -> if var == name then expr else n
    n@(SConst _) -> n
    (SPointer p) -> SPointer (subst expr name p)
    (SIte i t e) -> SIte (subst expr name i) (subst expr name t) (subst expr name e)
    (SAdd p q) -> SAdd (subst expr name p) (subst expr name q)
    (SSub p q) -> SSub (subst expr name p) (subst expr name q)
    (SMul p q) -> SMul (subst expr name p) (subst expr name q)
    (SDiv p q) -> SDiv (subst expr name p) (subst expr name q)
    (SMod p q) -> SMod (subst expr name p) (subst expr name q)
    (SAbs x) -> SAbs (subst expr name x)
    (SAnd p q) -> SAnd (subst expr name p) (subst expr name q)
    (SOr p q) -> SOr (subst expr name p) (subst expr name q)
    (SNot x) -> SNot (subst expr name x)
    (SEq p q) -> SEq (subst expr name p) (subst expr name q)
    (SGt p q) -> SGt (subst expr name p) (subst expr name q)
    (SLt p q) -> SLt (subst expr name p) (subst expr name q)

{- | Try to perform constant folding and get the resulting value. Return 'Nothing' on
   encounter of a symbolic variable.
-}
getValue :: Sym -> Maybe Concrete
getValue = \case
    (SAny _) -> Nothing
    (SConst x) -> Just x
    (SPointer _) -> Nothing
    (SIte _ _ _) -> Nothing
    (SAdd p q) -> (+) <$> getValue p <*> getValue q
    (SSub p q) -> (-) <$> getValue p <*> getValue q
    (SMul p q) -> (*) <$> getValue p <*> getValue q
    (SDiv p q) -> Prelude.div <$> getValue p <*> getValue q
    (SMod p q) -> (Prelude.mod) <$> getValue p <*> getValue q
    (SAbs x) -> Prelude.abs <$> getValue x
    (SAnd p q) -> (&&&) <$> getValue p <*> getValue q
    (SOr p q) -> (|||) <$> getValue p <*> getValue q
    (SNot x) -> not <$> getValue x
    (SEq p q) -> CBool <$> ((==) <$> getValue p <*> getValue q)
    (SGt p q) -> CBool <$> ((>) <$> getValue p <*> getValue q)
    (SLt p q) -> CBool <$> ((<) <$> getValue p <*> getValue q)

{- | Constant-fold the expression if it only contains 'SConst' leafs; return the
   unchanged expression otherwise.
-}
tryFoldConstant :: Sym -> Sym
tryFoldConstant x =
    let maybeVal = getValue x
     in case maybeVal of
            Just val -> SConst val
            Nothing -> x

tryReduce :: Sym -> Sym
tryReduce = \case
    SNot x -> SNot (tryReduce x)
    -- 0 + y = y
    (SAdd (SConst 0) y) -> tryReduce y
    -- x + 0 = x
    (SAdd x (SConst 0)) -> tryReduce x
    (SAdd (SConst x) (SConst y)) -> SConst (x + y)
    (SAdd x y) -> tryReduce x `SAdd` tryReduce y
    -- x - 0 = x
    (SSub x (SConst 0)) -> tryReduce x
    (SSub (SConst x) (SConst y)) -> SConst (x - y)
    (SSub x y) -> tryReduce x `SSub` tryReduce y
    -- T && y = y
    (SAnd (SConst (CBool True)) y) -> tryReduce y
    -- x && T = x
    (SAnd x (SConst (CBool True))) -> tryReduce x
    (SAnd x y) -> tryReduce x `SAnd` tryReduce y
    -- F || y = y
    (SOr (SConst (CBool False)) y) -> tryReduce y
    -- x || F = x
    (SOr x (SConst (CBool False))) -> tryReduce x
    (SOr x y) -> tryReduce x `SOr` tryReduce y
    (SEq (SConst (CInt32 0)) (SConst (CInt32 0))) -> SConst (CBool True)
    (SEq x y) -> tryReduce x `SEq` tryReduce y
    (SGt (SConst (CInt32 0)) (SConst (CInt32 0))) -> SConst (CBool False)
    (SGt x y) -> tryReduce x `SGt` tryReduce y
    (SLt (SConst 0) (SConst 0)) -> SConst (CBool False)
    (SLt x y) -> tryReduce x `SLt` tryReduce y
    (SPointer x) -> SPointer (tryReduce x)
    s -> s

simplify :: (Maybe Int) -> Sym -> Sym
simplify steps =
    let actualSteps = case steps of
            Nothing -> defaultSteps
            Just s -> s
     in last . take actualSteps . iterate (tryFoldConstant . tryReduce)
  where
    defaultSteps = 1000

-----------------------------------------------------------------------------

{- | Try to convert a symbolic value into a memory/program address,
   possibly doing constant folding.
   Return @Left@ in cases of symbolic value, concrete boolean and non-Word16 value
-}
toCAddress :: HasCallStack => Sym -> Either Sym CAddress
toCAddress sym =
    case getValue (simplify (Just 100) sym) of
        Just (CWord _) -> error "ISA.Types.Symbolic.toCAddress: not implemented for CWord"
        Just (CInt32 i) ->
            if (i >= fromIntegral (minBound :: CAddress))
                && (i <= fromIntegral (maxBound :: CAddress))
                then Right (fromIntegral i)
                else
                    error $
                        "ISA.Types.Symbolic.toAddress: "
                            <> "the value "
                            <> show i
                            <> " is out of address space"
        Just (CBool _) -> error "ISA.Types.Symbolic.toAddress: not implemented for CBool"
        Nothing -> Left sym

toImm :: Sym -> Either Sym (Imm Int32)
toImm sym =
    case getValue (simplify Nothing sym) of
        Just (CWord _) -> error "ISA.Types.Symbolic.toImm: not implemented for CWord"
        Just (CInt32 i) ->
            if (i >= fromIntegral (minBound :: Int8))
                && (i <= fromIntegral (maxBound :: Int8))
                then Right (Imm $ fromIntegral i)
                else
                    error $
                        "ISA.Types.Symbolic.toImm: "
                            <> "the value "
                            <> show i
                            <> "is not a valid immediate"
        Just (CBool _) -> error "ISA.Types.Symbolic.toImm: not implemented for CBool"
        Nothing -> Left sym

toInstructionCode :: Sym -> Either Sym InstructionCode
toInstructionCode sym =
    case getValue (simplify (Just 100) sym) of
        Just (CInt32 a) ->
            Right (fromIntegral a)
        -- error $ "ISA.Types.Symbolic.toInstructionCode: " <>
        --         "not implemented for CInt32"
        Just (CWord w) -> Right (InstructionCode w)
        Just (CBool _) ->
            error $
                "ISA.Types.Symbolic.toInstructionCode: "
                    <> "not implemented for CBool"
        Nothing -> Left sym

--------------------------------------------------------------------------------
