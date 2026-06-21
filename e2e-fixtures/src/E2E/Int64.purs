-- | CLI-driven e2e fixture for the native 64-bit integer primitives (`Wasm.Int64`): the `i64.*`
-- | intrinsics added to lower Keccak's lo/hi split away. The export ABI is i32-only (the harness'
-- | `callI32x*`), so every probe computes with `Int64` *internally* and surfaces an i32 the test can
-- | assert: `loOf`/`hiOf` extract the low / high 32-bit word, and booleans (`eq`/`lt`) become `1`/`0`.
-- |
-- | Coverage is deliberately split so a failure localises:
-- |   * bitwise (`and`/`or`/`xor`/`complement`) over operands chosen so neither word is degenerate
-- |     (B is NOT ~A, so `and`/`or`/`xor` all differ in both words);
-- |   * arithmetic vs logical right shift on a sign-bit-set lane (`shr` vs `zshr` — the i64 analogue
-- |     of the i32 shr_s/shr_u trap);
-- |   * shifts AND rotates that cross the 32-bit boundary (offset 36 — a real Keccak ρ offset — and
-- |     >=32 shifts), the exact cases the manual lo/hi code got wrong;
-- |   * the `rotl` vs `shl` distinguisher: rotating the top bit wraps it to bit 0 (`1`), shifting
-- |     drops it (`0`);
-- |   * signed `lt` (must be `lt_s`, not `lt_u`): `lt (-1) 1` is true, `lt 1 (-1)` is false;
-- |   * a small composite "mix" (xor/and/complement/rotl/rotr in one expression) as a wiring smoke;
-- |   * i64-valued top-level CAFs (`loMaskG`/`allOnesG`) to exercise the i64 *global* path
-- |     (`defaultConst I64`) independently of the ops;
-- |   * runtime (non-constant-folded) rotates/shifts via parameterised x1/x2 exports.
-- |
-- | Operand vectors:
-- |   A = 0x0123456789ABCDEF   B = 0x0F1E2D3C4B5A6978
-- |   S = 0xF0F0F0F0F0F0F0F0   T = 0x8000000000000000
module E2E.Int64 where

import Prelude

import Wasm.Int64 (Int64)
import Wasm.Int64 as I

-- Build a 64-bit value from explicit hi/lo 32-bit words using only the Int64 surface. This stays
-- function-local i64 (no i64 globals), so the bulk of the op coverage does not depend on the i64
-- CAF-global path -- that path is checked separately by `loMaskG`/`allOnesG` below.
mk :: Int -> Int -> Int64
mk h l = I.or (I.shl (I.fromInt h) c32) (I.and (I.fromInt l) loMask)
  where
  c32 = I.fromInt 32
  loMask = I.zshr (I.fromInt (-1)) c32

-- Read the high / low 32-bit word of an Int64 back out as an i32 (the export ABI).
hiOf :: Int64 -> Int
hiOf x = I.toInt (I.zshr x (I.fromInt 32))

loOf :: Int64 -> Int
loOf = I.toInt

b2i :: Boolean -> Int
b2i b = if b then 1 else 0

-- Operand vectors as Unit-functions (not CAFs) to keep them out of i64 globals.
av :: Unit -> Int64
av _ = mk 19088743 (-1985229329) -- 0x0123456789ABCDEF

bv :: Unit -> Int64
bv _ = mk 253635900 1264216440 -- 0x0F1E2D3C4B5A6978

sv :: Unit -> Int64
sv _ = mk (-252645136) (-252645136) -- 0xF0F0F0F0F0F0F0F0  (sign bit set)

tv :: Unit -> Int64
tv _ = I.shl (I.fromInt 1) (I.fromInt 63) -- 0x8000000000000000  (only the top bit set)

-- NB: `mk (-2147483648) 0` would be ill-formed -- PureScript parses `-2147483648` as
-- `negate 2147483648`, and the bare literal `2147483648` overflows `Int` (maxBound + 1),
-- which the corefn decoder rejects. Constructing the top bit with `shl 1 63` sidesteps it.

--------------------------------------------------------------------------------
-- Bitwise: and / or / xor / complement
--------------------------------------------------------------------------------

andABHi :: Int
andABHi = hiOf (I.and (av unit) (bv unit))

andABLo :: Int
andABLo = loOf (I.and (av unit) (bv unit))

orABHi :: Int
orABHi = hiOf (I.or (av unit) (bv unit))

orABLo :: Int
orABLo = loOf (I.or (av unit) (bv unit))

xorABHi :: Int
xorABHi = hiOf (I.xor (av unit) (bv unit))

xorABLo :: Int
xorABLo = loOf (I.xor (av unit) (bv unit))

notAHi :: Int
notAHi = hiOf (I.complement (av unit))

notALo :: Int
notALo = loOf (I.complement (av unit))

--------------------------------------------------------------------------------
-- Right shift: arithmetic (shr) vs logical (zshr) on a sign-bit-set lane (S)
--------------------------------------------------------------------------------

shrS4Hi :: Int
shrS4Hi = hiOf (I.shr (sv unit) (I.fromInt 4))

shrS4Lo :: Int
shrS4Lo = loOf (I.shr (sv unit) (I.fromInt 4))

zshrS4Hi :: Int
zshrS4Hi = hiOf (I.zshr (sv unit) (I.fromInt 4))

zshrS4Lo :: Int
zshrS4Lo = loOf (I.zshr (sv unit) (I.fromInt 4))

shlS4Hi :: Int
shlS4Hi = hiOf (I.shl (sv unit) (I.fromInt 4))

shlS4Lo :: Int
shlS4Lo = loOf (I.shl (sv unit) (I.fromInt 4))

--------------------------------------------------------------------------------
-- Cross-32-bit-boundary shifts (count >= 32)
--------------------------------------------------------------------------------

shlA36Hi :: Int
shlA36Hi = hiOf (I.shl (av unit) (I.fromInt 36))

shlA36Lo :: Int
shlA36Lo = loOf (I.shl (av unit) (I.fromInt 36))

zshrB36Lo :: Int
zshrB36Lo = loOf (I.zshr (bv unit) (I.fromInt 36))

shrS36Hi :: Int
shrS36Hi = hiOf (I.shr (sv unit) (I.fromInt 36))

shrS36Lo :: Int
shrS36Lo = loOf (I.shr (sv unit) (I.fromInt 36))

--------------------------------------------------------------------------------
-- Rotates: the headline. Offset 36 is a real Keccak ρ offset (crosses the boundary).
--------------------------------------------------------------------------------

rotlA36Hi :: Int
rotlA36Hi = hiOf (I.rotl (av unit) (I.fromInt 36))

rotlA36Lo :: Int
rotlA36Lo = loOf (I.rotl (av unit) (I.fromInt 36))

rotrA36Hi :: Int
rotrA36Hi = hiOf (I.rotr (av unit) (I.fromInt 36))

rotrA36Lo :: Int
rotrA36Lo = loOf (I.rotr (av unit) (I.fromInt 36))

-- rotl vs shl distinguisher: T has only the top bit. rotl wraps it to bit 0 (lo = 1); shl drops it.
rotlT1Lo :: Int
rotlT1Lo = loOf (I.rotl (tv unit) (I.fromInt 1))

shlT1Lo :: Int
shlT1Lo = loOf (I.shl (tv unit) (I.fromInt 1))

-- rotl 1 by 63 == 0x8000000000000000 (the doc's canonical case).
rotl63oneHi :: Int
rotl63oneHi = hiOf (I.rotl (I.fromInt 1) (I.fromInt 63))

rotl63oneLo :: Int
rotl63oneLo = loOf (I.rotl (I.fromInt 1) (I.fromInt 63))

--------------------------------------------------------------------------------
-- Comparisons: eq, and signed lt (must be lt_s)
--------------------------------------------------------------------------------

eqAA :: Int
eqAA = b2i (I.eq (av unit) (av unit))

eqAB :: Int
eqAB = b2i (I.eq (av unit) (bv unit))

ltAB :: Int
ltAB = b2i (I.lt (av unit) (bv unit))

ltBA :: Int
ltBA = b2i (I.lt (bv unit) (av unit))

-- The signed-vs-unsigned trap: as signed i64, -1 < 1; as unsigned, it would not be.
ltNeg :: Int
ltNeg = b2i (I.lt (I.fromInt (-1)) (I.fromInt 1))

ltPos :: Int
ltPos = b2i (I.lt (I.fromInt 1) (I.fromInt (-1)))

--------------------------------------------------------------------------------
-- Composite wiring smoke: one wrong intrinsic perturbs the result.
--   mix = (A xor (B rotl 36)) and (complement A)  xor  (A rotr 17)
--------------------------------------------------------------------------------

mixV :: Int64
mixV =
  let
    t = I.xor (av unit) (I.rotl (bv unit) (I.fromInt 36))
    u = I.and t (I.complement (av unit))
  in
    I.xor u (I.rotr (av unit) (I.fromInt 17))

mixHi :: Int
mixHi = hiOf mixV

mixLo :: Int
mixLo = loOf mixV

--------------------------------------------------------------------------------
-- i64-valued top-level CAFs: exercise the i64 *global* path (defaultConst I64)
-- independently of the ops above.
--   loMaskG  = 0x00000000FFFFFFFF
--   allOnesG = 0xFFFFFFFFFFFFFFFF
--------------------------------------------------------------------------------

loMaskG :: Int64
loMaskG = I.zshr (I.fromInt (-1)) (I.fromInt 32)

allOnesG :: Int64
allOnesG = I.complement (I.fromInt 0)

globLoMaskLo :: Int
globLoMaskLo = loOf loMaskG

globLoMaskHi :: Int
globLoMaskHi = hiOf loMaskG

globAllOnesLo :: Int
globAllOnesLo = loOf allOnesG

globAllOnesHi :: Int
globAllOnesHi = hiOf allOnesG

--------------------------------------------------------------------------------
-- Parameterised (runtime, non-constant-folded) probes.
--------------------------------------------------------------------------------

-- toInt . fromInt is identity on the low 32 bits: recovers any i32.
wrapId :: Int -> Int
wrapId k = loOf (I.fromInt k)

-- fromInt sign-extends: high word is 0 for k >= 0, all-ones (-1) for k < 0.
signExtHi :: Int -> Int
signExtHi k = hiOf (I.fromInt k)

-- Bit position of (1 << n), observed through both words.
oneShlHi :: Int -> Int
oneShlHi n = hiOf (I.shl (I.fromInt 1) (I.fromInt n))

oneShlLo :: Int -> Int
oneShlLo n = loOf (I.shl (I.fromInt 1) (I.fromInt n))

-- Runtime rotate of a sign-extended word by n.
rotlRTHi :: Int -> Int -> Int
rotlRTHi w n = hiOf (I.rotl (I.fromInt w) (I.fromInt n))

rotlRTLo :: Int -> Int -> Int
rotlRTLo w n = loOf (I.rotl (I.fromInt w) (I.fromInt n))

-- Runtime sign-fill vs zero-fill right shift of a sign-extended word by n.
shrRTHi :: Int -> Int -> Int
shrRTHi w n = hiOf (I.shr (I.fromInt w) (I.fromInt n))

shrRTLo :: Int -> Int -> Int
shrRTLo w n = loOf (I.shr (I.fromInt w) (I.fromInt n))

zshrRTHi :: Int -> Int -> Int
zshrRTHi w n = hiOf (I.zshr (I.fromInt w) (I.fromInt n))

zshrRTLo :: Int -> Int -> Int
zshrRTLo w n = loOf (I.zshr (I.fromInt w) (I.fromInt n))