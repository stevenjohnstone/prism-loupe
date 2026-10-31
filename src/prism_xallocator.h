#ifndef PRISM_XALLOCATOR_H
#define PRISM_XALLOCATOR_H

#include <stddef.h>

void *prism_trace_xmalloc(size_t size);
void *prism_trace_xcalloc(size_t nmemb, size_t size);
void *prism_trace_xrealloc(void *ptr, size_t size);
void prism_trace_xfree(void *ptr);

#define xmalloc  prism_trace_xmalloc
#define xcalloc  prism_trace_xcalloc
#define xrealloc prism_trace_xrealloc
#define xfree    prism_trace_xfree

#endif

