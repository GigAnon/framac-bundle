/* Eva sample: uses Frama-C's own libc headers (preprocessed by the bundled
   preprocessor) and contains one possible division by zero. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <stdlib.h>

volatile int nondet;
int t[10];

int main(void)
{
  int32_t s = 0;
  char buf[16];
  for (int i = 0; i < 10; i++) { t[i] = i; s += t[i]; }
  strcpy(buf, "hello");
  int d = nondet % 3;            /* d may be 0 */
  printf("%d %zu\n", s, strlen(buf));
  return (int)(s / d) + (INT_MAX > 0 ? 0 : 1);
}
