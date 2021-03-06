{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{- |
 Module     : ISA.Semantics
 Copyright  : (c) Georgy Lukyanov 2019
 License    : MIT (see the file LICENSE)
 Maintainer : mail@gmail.com
 Stability  : experimental

 Semantics of ISA instructions
-}
module ISA.Semantics (
    instructionSemanticsS,
    instructionSemanticsM,
) where

import Prelude hiding (Monad, abs, div, mod, (>>=))
import qualified Prelude (abs, div, mod)

import Control.Selective
import FS
import ISA.Semantics.Overflow
import ISA.Types
import ISA.Types.Boolean
import ISA.Types.Instruction
import ISA.Types.Key
import ISA.Types.Symbolic.Address

-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
--------------- Semantics of instructions -----------------------------------
-----------------------------------------------------------------------------

-- | Halt the execution.
halt :: FS Key Applicative '[Boolean] a
halt _ write = write (F Halted) (pure true)

-- | Load a value from a memory cell to a register
load :: Register -> Address -> FS Key Functor '[] a
load reg addr read write = write (Reg reg) (read (Addr addr))

-- | Load a value referenced by another  value in a memory cell to a register
loadMI :: Register -> Address -> FS Key Monad '[Addressable, Show] a
loadMI reg pointer read write =
    read (Addr pointer) >>= \x ->
        case toAddress x of
            Nothing -> error $ "ISA.Semantics.loadMI: invalid address " <> show x
            -- instead we actually need to rise a processor exception
            --        write (Reg reg) (read (SymAddr x))
            Just addr -> write (Reg reg) (read (Addr addr))

-- | Write an immediate argument to a register
set :: Register -> Imm a -> FS Key Applicative '[] a
set reg (Imm imm) _ write =
    write (Reg reg) (pure imm)

-- | Store a value from a register to a memory cell
store :: Register -> Address -> FS Key Functor '[] a
store reg addr read write =
    write (Addr addr) (read (Reg reg))

arithm ::
    (Num a, Bounded a, Boolean a, BOrd a) =>
    (a -> a -> a) ->
    (a -> a -> a) ->
    Register ->
    Either Address (Imm a) ->
    FS Key Applicative '[Monoid, Num, Bounded, Boolean, BOrd] a
arithm op overflows src1 src2 read write =
    let arg1 = read (Reg src1)
        arg2 = either (read . Addr) (\(Imm x) -> pure x) src2
        o = overflows <$> arg1 <*> arg2
        result = op <$> arg1 <*> arg2
     in write (F Overflow) o *> write (Reg src1) result

add :: Register -> Address -> FS Key Applicative '[Monoid, Num, Bounded, Boolean, BOrd] a
add reg addr = arithm (+) addOverflows reg (Left addr)

addI :: Register -> Imm a -> FS Key Applicative '[Monoid, Num, Bounded, Boolean, BOrd] a
addI reg imm = arithm (+) addOverflows reg (Right imm)

sub :: Register -> Address -> FS Key Applicative '[Monoid, Num, Bounded, Boolean, BOrd] a
sub reg addr = arithm (-) subOverflows reg (Left addr)

subI :: Register -> Imm a -> FS Key Applicative '[Monoid, Num, Bounded, Boolean, BOrd] a
subI reg imm = arithm (-) subOverflows reg (Right imm)

mul :: Register -> Address -> FS Key Applicative '[Monoid, Integral, Bounded, Boolean, BOrd] a
mul reg addr = arithm (*) mulOverflows reg (Left addr)

div :: Register -> Address -> FS Key Applicative '[Monoid, Integral, Bounded, Boolean, BOrd] a
div reg addr read write =
    let arg1 = read (Reg reg)
        arg2 = read (Addr addr)
        o = divOverflows <$> arg1 <*> arg2
        z = (===) <$> arg2 <*> pure 0
        result = (Prelude.div) <$> arg1 <*> arg2
     in write (F Overflow) o *> write (F DivisionByZero) z *> write (Reg reg) result

mod :: Register -> Address -> FS Key Applicative '[Monoid, Integral, Bounded, Boolean, BOrd] a
mod reg addr read write =
    let arg1 = read (Reg reg)
        arg2 = read (Addr addr)
        o = modOverflows <$> arg1 <*> arg2
        z = (===) <$> arg2 <*> pure 0
        result = (Prelude.mod) <$> arg1 <*> arg2
     in write (F Overflow) o *> write (F DivisionByZero) z *> write (Reg reg) result

abs :: Register -> FS Key Applicative '[Monoid, Num, Bounded, Boolean, BOrd] a
abs reg read write =
    let arg = read (Reg reg)
        o = absOverflows <$> arg
        result = (Prelude.abs) <$> arg
     in write (F Overflow) o *> write (Reg reg) result

-- | Compare the values in the register and memory cell
cmpEq :: Register -> Address -> FS Key Selective '[Boolean, BEq, Monoid] a
cmpEq reg addr = \read write ->
    write (F Condition) ((===) <$> read (Reg reg) <*> read (Addr addr))

cmpGt :: Register -> Address -> FS Key Selective '[Boolean, BOrd, Monoid] a
cmpGt reg addr = \read write ->
    write (F Condition) (gt <$> read (Reg reg) <*> read (Addr addr))

cmpLt :: Register -> Address -> FS Key Selective '[Boolean, BOrd] a
cmpLt reg addr = \read write ->
    write (F Condition) (lt <$> read (Reg reg) <*> read (Addr addr))

-- | Perform jump if flag @Condition@ is set
jumpCt :: Imm a -> FS Key Selective '[Boolean, Num] a
jumpCt (Imm offset) read write =
    ifS
        (toBool <$> read (F Condition))
        (write IC ((+) <$> pure offset <*> read IC))
        (pure 0)

-- | Perform jump if flag @Condition@ is set
jumpCf :: Imm a -> FS Key Selective '[Boolean, Num] a
jumpCf (Imm offset) read write =
    ifS
        (toBool <$> read (F Condition))
        (pure 0)
        (write IC ((+) <$> pure offset <*> read IC))

-- | Perform unconditional jump
jump :: Imm a -> FS Key Applicative '[Num] a
jump (Imm offset) read write =
    write IC ((+) <$> pure offset <*> read IC)

-----------------------------------------------------------------------------

-- -- | Aha! fetching an instruction is Monadic!
-- fetchInstruction :: Value a => FS Key Prelude.Monad Value a
-- fetchInstruction read write =
--       read IC >>= \ic -> write IR (read (Prog ic))

instructionSemanticsS ::
    Instruction a ->
    FS Key Selective '[Monoid, Integral, Bounded, Boolean, BOrd] a
instructionSemanticsS (Instruction i) r w = case i of
    Halt -> halt r w
    Load reg addr -> load reg (literal addr) r w
    LoadMI _ _ -> pure mempty -- for now loadmi is a noop in selective semantics
    -- error $ "ISA.Semantics.instructionSemanticsS : "
    --      ++ "LoadMI does not have Selective semantics "
    Set reg imm -> set reg imm r w
    Store reg addr -> store reg (literal addr) r w
    Add reg addr -> add reg (literal addr) r w
    AddI reg imm -> addI reg imm r w
    Sub reg addr -> sub reg (literal addr) r w
    SubI reg imm -> subI reg imm r w
    Mul reg addr -> mul reg (literal addr) r w
    Div reg addr -> div reg (literal addr) r w
    Mod reg addr -> mod reg (literal addr) r w
    Abs reg -> abs reg r w
    Jump simm8 -> jump simm8 r w
    CmpEq reg addr -> cmpEq reg (literal addr) r w
    CmpGt reg addr -> cmpGt reg (literal addr) r w
    CmpLt reg addr -> cmpLt reg (literal addr) r w
    JumpCt simm8 -> jumpCt simm8 r w
    JumpCf simm8 -> jumpCf simm8 r w

instructionSemanticsM ::
    Instruction a ->
    FS Key Monad '[Show, Addressable, Monoid, Integral, Bounded, Boolean, BEq, BOrd] a
instructionSemanticsM (Instruction i) r w = case i of
    LoadMI reg addr -> loadMI reg (literal addr) r w
    _ -> instructionSemanticsS (Instruction i) r w
