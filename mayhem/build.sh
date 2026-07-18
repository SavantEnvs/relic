#!/usr/bin/env bash
#
# mayhem/build.sh — build the RELIC fuzz harnesses + the upstream test suite.
#
# Targets built (parity with the fork's Mayhem run history + OSS-Fuzz):
#   * cryptofuzz-relic  — the OSS-Fuzz differential harness (RELIC vs Botan oracle) over RELIC's
#                         bignum / ECC / digest / cipher operations. libFuzzer.
#   * fuzz_bn           — the fork's direct libFuzzer harness over RELIC bignum arithmetic.
#   * fuzz_bn-standalone— run-once reproducer for fuzz_bn (StandaloneFuzzTargetMain).
#
# Third-party sources (Botan 3.8.1, cryptofuzz, Boost 1.84 headers) are PRE-FETCHED into /deps by
# mayhem/Dockerfile, so this script needs no network and re-runs offline (SPEC §6.5). It rebuilds
# everything that depends on RELIC (the code under test) so the PATCH tier re-grades correctly.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — unset when empty.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

# Edge-coverage instrumentation for everything a fuzzer links (the library code, not just the
# harness TU) — without it libFuzzer/Mayhem see ~0 edges from RELIC/Botan/cryptofuzz internals.
FUZZ_COV="-fsanitize=fuzzer-no-link"
# RELIC's CMake consumes the CFLAGS ENV VAR (not -DCOMP); it must carry the sanitizer +
# coverage + debug flags or librelic_s.a ends up completely uninstrumented.
RELIC_CFLAGS="-pipe -std=c99 -O2 -funroll-loops -fno-omit-frame-pointer $SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS"

DEPS=/deps
cd "$SRC"   # $SRC == /mayhem == the RELIC source root

# ------------------------------------------------------------------------------------------------
# 1) RELIC, instrumented, RAND=CALL — cryptofuzz drives RELIC's RNG through the CALL callback.
#    cryptofuzz's modules/relic Makefile hardcodes $RELIC_PATH/build/{lib,include}, so build in-tree.
# ------------------------------------------------------------------------------------------------
rm -rf "$SRC/build" && mkdir "$SRC/build" && cd "$SRC/build"
CFLAGS="$RELIC_CFLAGS" cmake .. -DCMAKE_C_COMPILER="$CC" \
    -DQUIET=on -DRAND=CALL -DSHLIB=off -DSTBIN=off -DTESTS=0 -DBENCH=0 -DALLOC=DYNAMIC -DARCH=X64
make -j"$MAYHEM_JOBS"
cd "$SRC"

# ------------------------------------------------------------------------------------------------
# 2) Botan 3.8.1 (the differential ORACLE), instrumented to match. Cached across offline re-runs.
# ------------------------------------------------------------------------------------------------
CF_CXXFLAGS="$SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS -DCRYPTOFUZZ_NO_OPENSSL -Wno-deprecated-literal-operator"
cd "$DEPS/botan"
if [ ! -f libbotan-3.a ]; then
    ./configure.py --cc-bin="$CXX" --cc-abi-flags="$CF_CXXFLAGS" --disable-shared \
        --disable-modules=locking_allocator --build-targets=static --without-documentation
    make -j"$MAYHEM_JOBS"
fi

# ------------------------------------------------------------------------------------------------
# 3) cryptofuzz with the RELIC + Botan modules -> /mayhem/cryptofuzz-relic (OSS-Fuzz target name).
# ------------------------------------------------------------------------------------------------
export RELIC_PATH="$SRC"
export LIBFUZZER_LINK="$LIB_FUZZING_ENGINE"
export LIBBOTAN_A_PATH="$DEPS/botan/libbotan-3.a"
export BOTAN_INCLUDE_PATH="$DEPS/botan/build/include"
export CXXFLAGS="$CF_CXXFLAGS -DCRYPTOFUZZ_RELIC -DCRYPTOFUZZ_BOTAN -DCRYPTOFUZZ_BOTAN_IS_ORACLE"
cd "$DEPS/cryptofuzz"
# Botan >=3.7 dropped these exception types cryptofuzz's Botan module still references (idempotent).
sed -i 's/::Botan::Invalid_Argument&\?/std::exception/g' modules/botan/bn_ops.cpp
sed -i 's/::Botan::Invalid_State&\?/std::exception/g'    modules/botan/bn_ops.cpp
sed -i 's/::Botan::Encoding_Error&\?/std::exception/g'   modules/botan/bn_ops.cpp
python3 gen_repository.py
# extra_options.h pins the exact operation/curve/digest/cipher set the OSS-Fuzz target enables.
{
  printf '"'
  printf -- '--force-module=relic '
  printf -- '--operations=BignumCalc,ECC_PrivateToPublic,ECC_ValidatePubkey,ECDSA_Sign,ECDSA_Verify,Digest,HMAC,KDF_X963,SymmetricEncrypt,SymmetricDecrypt,ECC_Point_Add,ECC_Point_Mul,ECC_Point_Dbl,ECC_Point_Neg '
  printf -- '--curves=secp256k1,secp256r1 '
  printf -- '--digests=NULL,SHA224,SHA256,SHA384,SHA512,BLAKE2S160,BLAKE2S256 '
  printf -- '--ciphers=AES_128_CBC,AES_192_CBC,AES_256_CBC '
  printf -- '--calcops=Abs,Add,Bit,ClearBit,Cmp,CmpAbs,Div,ExpMod,GCD,InvMod,IsEven,IsOdd,IsZero,Jacobi,LCM,LShift1,Mod,Mul,Neg,NumBits,RShift,SetBit,Sqr,Sqrt,Sub '
  printf '"'
} > extra_options.h
make -B -C modules/relic -j"$MAYHEM_JOBS"
make -B -C modules/botan -j"$MAYHEM_JOBS"
make -B -j"$MAYHEM_JOBS"
cp cryptofuzz "$SRC/cryptofuzz-relic"

# ------------------------------------------------------------------------------------------------
# 4) fuzz_bn — the fork's direct RELIC bignum harness. Needs a self-seeding RELIC (RAND=HASHD).
#    Built as a libFuzzer target AND a run-once standalone reproducer.
# ------------------------------------------------------------------------------------------------
BN_INST="$SRC/build-bn/install"
rm -rf "$SRC/build-bn" && mkdir "$SRC/build-bn" && cd "$SRC/build-bn"
CFLAGS="$RELIC_CFLAGS" cmake .. -DCMAKE_C_COMPILER="$CC" \
    -DQUIET=on -DRAND=HASHD -DSHLIB=off -DSTBIN=off -DTESTS=0 -DBENCH=0 -DALLOC=DYNAMIC -DARCH=X64 \
    -DCHECK=on -DCMAKE_INSTALL_PREFIX="$BN_INST"
make -j"$MAYHEM_JOBS" relic_s
make install
cd "$SRC"
$CC $SANITIZER_FLAGS $FUZZ_COV $DEBUG_FLAGS $LIB_FUZZING_ENGINE -I"$BN_INST/include" \
    mayhem/fuzz_bn.c "$BN_INST/lib/librelic_s.a" -o "$SRC/fuzz_bn"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/standalone_main.o -I"$BN_INST/include" \
    mayhem/fuzz_bn.c "$BN_INST/lib/librelic_s.a" -o "$SRC/fuzz_bn-standalone"

# ------------------------------------------------------------------------------------------------
# 5) The upstream RELIC test suite, built with the project's NORMAL flags (a clean, un-sanitized
#    build) so mayhem/test.sh only RUNS it. Default self-seeding RNG so the modules can execute.
# ------------------------------------------------------------------------------------------------
rm -rf "$SRC/build-tests" && mkdir "$SRC/build-tests" && cd "$SRC/build-tests"
cmake .. -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
    -DSHLIB=off -DSTBIN=off -DTESTS=1 -DBENCH=0 -DALLOC=DYNAMIC -DARCH=X64
make -j"$MAYHEM_JOBS"

echo "build.sh: OK — cryptofuzz-relic, fuzz_bn(+standalone), and the RELIC test suite are built."
