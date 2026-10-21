#ifndef NETWORK_SPEED_NATIVE_ROUTES_H
#define NETWORK_SPEED_NATIVE_ROUTES_H

/// 读取 Darwin 普通物理接口根路由，排除直连接口避免重复计数。0 为正常结束，非零需重建兼容基线。
int nsm_run_native_routes(int interval);

#endif
