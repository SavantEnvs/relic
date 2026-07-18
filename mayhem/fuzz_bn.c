#include <stdint.h>
#include <stdlib.h>
#include <relic/relic.h>

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    if (core_init() != RLC_OK) return -1;
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 2) return 0;

    bn_t a, b, c;
    bn_null(a); bn_null(b); bn_null(c);

    RLC_TRY {
        bn_new(a); bn_new(b); bn_new(c);

        size_t half = size / 2;
        bn_read_bin(a, data, half);
        bn_read_bin(b, data + half, size - half);

        bn_add(c, a, b);
        bn_sub(c, a, b);
        bn_mul(c, a, b);
        bn_sqr(c, a);
        bn_gcd(c, a, b);

        if (!bn_is_zero(b)) {
            bn_div(c, a, b);
            if (bn_sign(b) == RLC_POS) {
                bn_mod(c, a, b);
            }
        }
    } RLC_CATCH_ANY {}

    bn_free(a); bn_free(b); bn_free(c);
    return 0;
}

#ifdef STANDALONE
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 2) return 1;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);
    uint8_t *buf = malloc(sz);
    if (!buf) { fclose(f); return 1; }
    fread(buf, 1, sz, f);
    fclose(f);
    LLVMFuzzerInitialize(NULL, NULL);
    LLVMFuzzerTestOneInput(buf, sz);
    free(buf);
    return 0;
}
#endif
