-- | CLI-driven e2e (ADR 0031 phase 5) of the native 64-bit integer primitives (`Wasm.Int64`): the
-- | `i64.*` intrinsics that replace Keccak's manual lo/hi split. The `E2E.Int64` fixture computes
-- | with `Int64` internally and exports i32 probes (low / high word, or `1`/`0` for booleans), built
-- | standalone by the real `purs-wasm build`. Expected values come from a 64-bit two's-complement
-- | reference, so the assertions pin exact bit patterns rather than re-deriving them with the same ops.
module Test.E2E.Cli.Int64 (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, callI32x1, callI32x2, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldNotEqual)

-- 0x80000000 as a signed i32 (Int minBound). Written as an in-range expression because the bare
-- literal 2147483648 overflows Int, and the source form would be parsed as `negate 2147483648`.
i32min :: Int
i32min = (-2147483647) - 1

spec :: Spec Unit
spec =
  describe "Wasm.Int64 i64 intrinsics (e2e/cli): build standalone -> instantiate -> run"
    $ before (liftEffect (cliFixture "E2E.Int64"))
    $ do
        it "bitwise and/or/xor/complement act on both 32-bit words" \inst -> do
          andHi <- liftEffect (callI32x0 inst "andABHi")
          andLo <- liftEffect (callI32x0 inst "andABLo")
          orHi <- liftEffect (callI32x0 inst "orABHi")
          orLo <- liftEffect (callI32x0 inst "orABLo")
          xorHi <- liftEffect (callI32x0 inst "xorABHi")
          xorLo <- liftEffect (callI32x0 inst "xorABLo")
          notHi <- liftEffect (callI32x0 inst "notAHi")
          notLo <- liftEffect (callI32x0 inst "notALo")
          [ andHi, andLo, orHi, orLo, xorHi, xorLo, notHi, notLo ] `shouldEqual`
            [ 16909604
            , 151669096
            , 255815039
            , -872681985
            , 238905435
            , -1024351081
            , -19088744
            , 1985229328
            ]

        it "arithmetic (shr) and logical (zshr) right shift disagree on a sign-bit-set lane" \inst -> do
          -- shr sign-fills the top nibble (hi stays negative); zshr zero-fills it (hi positive).
          aHi <- liftEffect (callI32x0 inst "shrS4Hi")
          aLo <- liftEffect (callI32x0 inst "shrS4Lo")
          lHi <- liftEffect (callI32x0 inst "zshrS4Hi")
          lLo <- liftEffect (callI32x0 inst "zshrS4Lo")
          [ aHi, aLo ] `shouldEqual` [ -15790321, 252645135 ]
          [ lHi, lLo ] `shouldEqual` [ 252645135, 252645135 ]
          aHi `shouldNotEqual` lHi

        it "shifts cross the 32-bit boundary (count >= 32)" \inst -> do
          shlS4Hi <- liftEffect (callI32x0 inst "shlS4Hi")
          shlS4Lo <- liftEffect (callI32x0 inst "shlS4Lo")
          shlA36Hi <- liftEffect (callI32x0 inst "shlA36Hi")
          shlA36Lo <- liftEffect (callI32x0 inst "shlA36Lo")
          zshrB36Lo <- liftEffect (callI32x0 inst "zshrB36Lo")
          shrS36Hi <- liftEffect (callI32x0 inst "shrS36Hi")
          shrS36Lo <- liftEffect (callI32x0 inst "shrS36Lo")
          [ shlS4Hi, shlS4Lo, shlA36Hi, shlA36Lo, zshrB36Lo, shrS36Hi, shrS36Lo ] `shouldEqual`
            [ 252645135
            , 252645120
            , -1698898192
            , 0
            , 15852243
            , -1
            , -15790321
            ]

        it "rotl/rotr by a boundary-crossing offset (Keccak rho = 36)" \inst -> do
          rlHi <- liftEffect (callI32x0 inst "rotlA36Hi")
          rlLo <- liftEffect (callI32x0 inst "rotlA36Lo")
          rrHi <- liftEffect (callI32x0 inst "rotrA36Hi")
          rrLo <- liftEffect (callI32x0 inst "rotrA36Lo")
          [ rlHi, rlLo, rrHi, rrLo ] `shouldEqual`
            [ -1698898192, 305419896, 2023406814, -267242410 ]

        it "rotl wraps the top bit where shl drops it" \inst -> do
          rotlLo <- liftEffect (callI32x0 inst "rotlT1Lo")
          shlLo <- liftEffect (callI32x0 inst "shlT1Lo")
          rotlLo `shouldEqual` 1
          shlLo `shouldEqual` 0
          rotlLo `shouldNotEqual` shlLo

        it "rotl 1 by 63 == 0x8000000000000000" \inst -> do
          hi <- liftEffect (callI32x0 inst "rotl63oneHi")
          lo <- liftEffect (callI32x0 inst "rotl63oneLo")
          [ hi, lo ] `shouldEqual` [ i32min, 0 ]

        it "eq, and signed lt (lt_s, not lt_u)" \inst -> do
          -- ltNeg = (lt (-1) 1) is true under signed compare; ltPos is false. A lt_u wiring flips both.
          eqaa <- liftEffect (callI32x0 inst "eqAA")
          eqab <- liftEffect (callI32x0 inst "eqAB")
          ltab <- liftEffect (callI32x0 inst "ltAB")
          ltba <- liftEffect (callI32x0 inst "ltBA")
          ltneg <- liftEffect (callI32x0 inst "ltNeg")
          ltpos <- liftEffect (callI32x0 inst "ltPos")
          [ eqaa, eqab, ltab, ltba, ltneg, ltpos ] `shouldEqual` [ 1, 0, 1, 0, 1, 0 ]

        it "composite xor/and/complement/rotl/rotr expression matches the reference" \inst -> do
          hi <- liftEffect (callI32x0 inst "mixHi")
          lo <- liftEffect (callI32x0 inst "mixLo")
          [ hi, lo ] `shouldEqual` [ 1383272977, -755771691 ]

        it "i64-valued top-level CAFs initialise correctly (i64 global path)" \inst -> do
          -- loMaskG = 0x00000000FFFFFFFF ; allOnesG = 0xFFFFFFFFFFFFFFFF
          mHi <- liftEffect (callI32x0 inst "globLoMaskHi")
          mLo <- liftEffect (callI32x0 inst "globLoMaskLo")
          oHi <- liftEffect (callI32x0 inst "globAllOnesHi")
          oLo <- liftEffect (callI32x0 inst "globAllOnesLo")
          [ mHi, mLo, oHi, oLo ] `shouldEqual` [ 0, -1, -1, -1 ]

        it "fromInt sign-extends and toInt wraps to the low 32 bits" \inst -> do
          w42 <- liftEffect (callI32x1 inst "wrapId" 42)
          wNeg <- liftEffect (callI32x1 inst "wrapId" (-7))
          [ w42, wNeg ] `shouldEqual` [ 42, -7 ]
          ePos <- liftEffect (callI32x1 inst "signExtHi" 7)
          eZero <- liftEffect (callI32x1 inst "signExtHi" 0)
          eNeg <- liftEffect (callI32x1 inst "signExtHi" (-1))
          eMin <- liftEffect (callI32x1 inst "signExtHi" (i32min))
          [ ePos, eZero, eNeg, eMin ] `shouldEqual` [ 0, 0, -1, -1 ]

        it "runtime (non-folded) shl bit positions across the boundary" \inst -> do
          h0 <- liftEffect (callI32x1 inst "oneShlHi" 0)
          l0 <- liftEffect (callI32x1 inst "oneShlLo" 0)
          h31 <- liftEffect (callI32x1 inst "oneShlHi" 31)
          l31 <- liftEffect (callI32x1 inst "oneShlLo" 31)
          h32 <- liftEffect (callI32x1 inst "oneShlHi" 32)
          l32 <- liftEffect (callI32x1 inst "oneShlLo" 32)
          h63 <- liftEffect (callI32x1 inst "oneShlHi" 63)
          l63 <- liftEffect (callI32x1 inst "oneShlLo" 63)
          [ h0, l0, h31, l31, h32, l32, h63, l63 ] `shouldEqual`
            [ 0, 1, 0, i32min, 1, 0, i32min, 0 ]

        it "runtime rotate and sign-fill/zero-fill shift" \inst -> do
          r63h <- liftEffect (callI32x2 inst "rotlRTHi" 1 63)
          r63l <- liftEffect (callI32x2 inst "rotlRTLo" 1 63)
          r32h <- liftEffect (callI32x2 inst "rotlRTHi" 1 32)
          r32l <- liftEffect (callI32x2 inst "rotlRTLo" 1 32)
          [ r63h, r63l, r32h, r32l ] `shouldEqual` [ i32min, 0, 1, 0 ]
          -- fromInt (-1) = 0xFFFFFFFFFFFFFFFF: shr keeps all ones, zshr clears the top nibble.
          sHi <- liftEffect (callI32x2 inst "shrRTHi" (-1) 4)
          sLo <- liftEffect (callI32x2 inst "shrRTLo" (-1) 4)
          zHi <- liftEffect (callI32x2 inst "zshrRTHi" (-1) 4)
          zLo <- liftEffect (callI32x2 inst "zshrRTLo" (-1) 4)
          [ sHi, sLo, zHi, zLo ] `shouldEqual` [ -1, -1, 268435455, -1 ]