#ifndef PRISM_WASM_SAN_RT_H
#define PRISM_WASM_SAN_RT_H

#include <stddef.h>
#include <stdint.h>

#ifdef PRISM_WASM_SANITIZE

void wasm_san_begin_run(void);
void wasm_san_finish_run(void);

uint8_t *wasm_san_alloc_input(const uint8_t *src, size_t size);
void wasm_san_free_input(uint8_t *buf);

void *wasm_san_heap_alloc(size_t size, size_t tracked);
void wasm_san_heap_free(void *user_ptr, size_t *out_size, size_t *out_tracked, int has_expected_size, size_t expected_size);
int wasm_san_heap_query(const void *user_ptr, size_t *out_size, size_t *out_tracked);

#endif

#endif
