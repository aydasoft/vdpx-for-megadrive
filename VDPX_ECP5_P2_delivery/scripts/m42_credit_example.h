/* Restricted finite experiment, NOT a sustained streaming API.
 * Call epoch_init only after a real, completed shared reset and idle qualification.
 * Reset cancels pending operations. No read/poll can replenish these credits. */
#ifndef M42_CREDIT_EXAMPLE_H
#define M42_CREDIT_EXAMPLE_H
#include <stdint.h>
struct m42_epoch { unsigned remaining; };
static inline void m42_epoch_init(struct m42_epoch *s) { s->remaining=16; }
/* Single producer only; caller provides measured minimum idle/setup/hold timing. */
static inline int m42_write_word(struct m42_epoch *s, unsigned offset, uint16_t value) {
    if (!s->remaining || (offset & 1) || offset > 14) return 0;
    --s->remaining;
    *(volatile uint16_t *)(uintptr_t)(0xA12000u + offset) = value;
    return 1; /* issued, NOT acknowledged/applied */
}
#endif
