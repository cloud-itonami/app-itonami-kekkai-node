#include "KotobaPacketPlaneBridge.h"
#include "kotoba_ios_host.h"

#include <stdlib.h>

#ifndef KEKKAI_KOTOBA_TARGET_PROFILE
#define KEKKAI_KOTOBA_TARGET_PROFILE "aarch64-ios-kotoba-v1"
#endif

int64_t kekkai_packet_decide_v1(int64_t family, int64_t packet_length,
                                int64_t mtu, int64_t route_action,
                                int64_t transport_ready) {
  struct kotoba_ios_request_v1 request = {0};
  struct kotoba_ios_result_v1 result = {0};
  request.abi_version = KOTOBA_IOS_HOST_ABI_V1;
  request.arity = 5;
  request.target_profile = KEKKAI_KOTOBA_TARGET_PROFILE;
  request.args[0] = family;
  request.args[1] = packet_length;
  request.args[2] = mtu;
  request.args[3] = route_action;
  request.args[4] = transport_ready;
  if (kotoba_ios_execute_static_v1(&request, &result) != KOTOBA_IOS_OK ||
      result.status != KOTOBA_IOS_OK) {
    return 0;
  }
  return result.value;
}
