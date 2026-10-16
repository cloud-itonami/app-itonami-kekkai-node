#include "../platform/apple/Native/KotobaPacketPlaneBridge.h"

#include <stdio.h>
#include <stdlib.h>

static void expect(const char *name, int64_t actual, int64_t expected) {
  if (actual != expected) {
    fprintf(stderr, "%s: expected %lld, got %lld\n", name,
            (long long)expected, (long long)actual);
    exit(1);
  }
  printf("ok %s = %lld\n", name, (long long)actual);
}

int main(void) {
  expect("authorized packet", kekkai_packet_decide_v1(4, 60, 1280, 1, 1), 100);
  expect("transport unavailable", kekkai_packet_decide_v1(4, 60, 1280, 1, 0), 12);
  expect("packet exceeds MTU", kekkai_packet_decide_v1(6, 1400, 1280, 1, 1), 11);
  expect("invalid family", kekkai_packet_decide_v1(7, 60, 1280, 1, 1), 0);
  expect("missing route decision", kekkai_packet_decide_v1(4, 60, 1280, 0, 1), 13);
  return 0;
}
