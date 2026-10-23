/* Search invariants under arbitrary, including nonmonotonic, trial outcomes.
 * clang -O1 -g -fsanitize=address,undefined -Ivendor/build/include
 *   scripts/check-jpeg-search.c -Lvendor/build/lib
 *   -ljpeg -lwebpmux -lwebpdemux -lwebp -lsharpyuv -lz -lm
 *   -o .build/check-jpeg-search && .build/check-jpeg-search
 */
#include "../Resim/Native/ResimCodecs.c"
#include <assert.h>

int main(void) {
    assert(rc_profile_attempts(3) == 10);
    assert(rc_profile_min_ssim_db(3) == 16.f);
    for (unsigned outcomes = 0; outcomes < 1024; outcomes++) {
        JPEGMaximumSearch search = {0};
        unsigned seen[101] = {0};
        for (int step = 0; step < rc_profile_attempts(3); step++) {
            int quality = jpeg_maximum_next_quality(&search);
            if (quality < 0) break;
            assert(quality >= 58 && quality <= 98);
            assert(!seen[quality]++);
            if (step < 7) assert(quality == rc_profile_quality(2, 0, step));
            search.qualities[search.count] = quality;
            search.potential[search.count++] = (outcomes >> step) & 1;
        }
        assert(search.count >= 7 && search.count <= 10);
    }
    puts("Maximum JPEG: 1024 outcome patterns; unique bounded qualities; Web prefix and 16 dB floor retained.");
    return 0;
}
