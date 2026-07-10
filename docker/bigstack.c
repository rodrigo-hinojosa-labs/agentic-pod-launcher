/* 016 (BUG 4): override pthread_create so worker threads get an 8 MB stack
 * instead of musl's 128 KB default. node-llama-cpp's tokenizer/grammar uses deep
 * std::regex recursion that SIGSEGVs on musl's small default stack (glibc's
 * 2-10 MB default is fine, so this is never preloaded there). Preloaded via
 * LD_PRELOAD ONLY for `qmd embed`, scoped by scripts/lib/qmd_index.sh::_qmd_run.
 *
 * Grows two thread classes to the 8 MB floor: (1) default-attributes threads
 * (attr == NULL), and (2) threads created with an explicit attr whose stacksize
 * is below the floor — on musl an attr initialized without pthread_attr_setstacksize
 * reports the 128 KB default, so libgomp/OpenMP-style workers are covered too.
 * Callers that already asked for >= 8 MB are passed through untouched. Delegates
 * to the real symbol via dlsym(RTLD_NEXT).
 * Build: gcc -shared -fPIC -o bigstack.so bigstack.c -ldl */
#define _GNU_SOURCE
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>

typedef int (*pthread_create_fn)(pthread_t *, const pthread_attr_t *,
                                 void *(*)(void *), void *);

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void *), void *arg) {
  static pthread_create_fn real = 0;
  if (!real) {
    real = (pthread_create_fn)dlsym(RTLD_NEXT, "pthread_create");
  }
  const size_t min_stack = 8 * 1024 * 1024;
  pthread_attr_t local;
  int use_local = 0;
  if (attr == 0) {
    pthread_attr_init(&local);
    use_local = 1;
  } else {
    size_t cur = 0;
    /* musl: an attr initialized without setstacksize reports the 128 KB default,
     * so grow anything below the floor while preserving large-stack callers. */
    if (pthread_attr_getstacksize(attr, &cur) == 0 && cur < min_stack) {
      /* musl pthread_attr_t is a POD union and this .so is Alpine-only, so a
       * shallow copy of the caller's attr is safe. */
      memcpy(&local, attr, sizeof(local));
      use_local = 1;
    }
  }
  if (use_local) {
    pthread_attr_setstacksize(&local, min_stack);
    int rc = real(thread, &local, start_routine, arg);
    /* Only destroy the attr WE initialized. A memcpy'd copy of the caller's attr
     * shares no owned resources with the original, so leave it untouched. */
    if (attr == 0) {
      pthread_attr_destroy(&local);
    }
    return rc;
  }
  return real(thread, attr, start_routine, arg);
}
