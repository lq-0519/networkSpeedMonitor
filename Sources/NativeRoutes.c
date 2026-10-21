// Darwin 网络统计协议的最小只读实现。字段布局核对来源：
// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/ntstat.h
// 此协议不是稳定的公开 SDK。运行时验证消息长度/provider/接口，并在不兼容时回退到系统 nettop。
// 只读取普通物理接口根路由；直连由具有系统权限的 nettop 单独采集，覆盖 QUIC。
// 两类接口互斥，不解析或保存进程、地址及报文内容。
#include "NativeRoutes.h"
#include <sys/socket.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <signal.h>
#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/// 协议公共头；所有长度均在读取字段前校验。
typedef struct {
    uint64_t context;  // 请求标识，用于将异步通知与周期查询结果分开。
    uint32_t type;     // Darwin NSTAT 消息类型。
    uint16_t length;   // 包含公共头的消息长度。
    uint16_t flags;    // 版本保留及分段标志。
} NSMHeader;

/// 订阅路由 provider 的请求，使用大接收缓冲避免初始路由枚举被截断。
typedef struct {
    NSMHeader header;  // 公共头，type=1002。
    uint64_t filter;   // 仅启用大缓冲选项，不改变系统网络配置。
    uint64_t events;   // 不申请额外高频事件。
    uint32_t provider;// route provider=1。
    int32_t pid;      // 不按进程筛选。
    uint8_t uuid[16]; // 不按应用 UUID 筛选。
} NSMSubscribe;

/// 描述、计数和移除请求共用的源标识结构。
typedef struct {
    NSMHeader header; // 公共头。
    uint64_t source;  // 内核分配的源引用，不是可解引用指针。
} NSMReference;

/// 单条普通根路由的最近累计计数，用于计算周期增量。
typedef struct {
    uint64_t reference; // 源引用，0 表示未使用槽位。
    uint64_t received;  // 最近累计接收量。
    uint64_t sent;      // 最近累计发送量。
    unsigned interface;// 内核接口索引，显示前再解析为 BSD 名称。
    int baseline;      // 首次读取只建立基线，不显示为实时峰值。
} NSMRoute;

/// 按接口暂存尚未发布的增量；包括路由关闭时收到的最后计数。
typedef struct {
    unsigned interface; // 网络接口索引，0 表示未使用。
    uint64_t received;  // 自上次发布后的接收字节。
    uint64_t sent;      // 自上次发布后的发送字节。
} NSMTotal;

_Static_assert(sizeof(NSMHeader) == 16, "NSTAT header layout");
_Static_assert(sizeof(NSMSubscribe) == 56, "NSTAT subscription layout");
_Static_assert(sizeof(NSMReference) == 24, "NSTAT reference layout");

/// 从已验证长度的消息中读取无符号值，避免未对齐访问及类型别名问题。
static uint64_t read64(const unsigned char *bytes) { uint64_t value; memcpy(&value, bytes, 8); return value; }

/// 从已验证长度的消息中读取 32 位 provider 或接口索引。
static uint32_t read32(const unsigned char *bytes) { uint32_t value; memcpy(&value, bytes, 4); return value; }

/// 向本机内核发送固定格式只读统计请求，不经过 shell 或网络连接。
static int reference_request(int fd, uint32_t type, uint64_t context, uint64_t reference) {
    NSMReference request = {{context, type, sizeof(request), 0}, reference};
    return send(fd, &request, sizeof(request), 0) == sizeof(request) ? 0 : -1;
}

/// 在有界表中定位已报告的普通根路由，不枚举应用连接。
static NSMRoute *find_route(NSMRoute *routes, uint64_t reference, int allocate) {
    NSMRoute *empty = NULL;
    for (int i = 0; i < 1024; ++i) {
        if (routes[i].reference == reference) return &routes[i];
        if (!routes[i].reference && !empty) empty = &routes[i];
    }
    if (allocate && empty) { empty->reference = reference; return empty; }
    return NULL;
}

/// 累加同一接口的字节增量；容量异常时退出并回退，避免静默漏统计。
static int add_total(NSMTotal *totals, unsigned interface, uint64_t received, uint64_t sent) {
    NSMTotal *empty = NULL;
    for (int i = 0; i < 128; ++i) {
        if (totals[i].interface == interface) {
            totals[i].received += received; totals[i].sent += sent; return 0;
        }
        if (!totals[i].interface && !empty) empty = &totals[i];
    }
    if (!empty) return -1;
    *empty = (NSMTotal){interface, received, sent};
    return 0;
}

/// 根据真实接口识别直连；普通路由和直连连接采用互斥集合，避免同一字节重复相加。
static int is_direct_interface(unsigned interface) {
    char name[IF_NAMESIZE];
    return if_indextoname(interface, name) &&
        (!strcmp(name, "awdl0") || !strcmp(name, "llw0") || !strcmp(name, "nan0"));
}

/// 对同一源的累计值做差分；首次及计数回退均重新建基线，不把历史总量当实时速度。
static int consume_counts(NSMTotal *totals, NSMRoute *source, uint64_t received, uint64_t sent) {
    if (source->baseline && received >= source->received && sent >= source->sent &&
        add_total(totals, source->interface, received - source->received, sent - source->sent) != 0) return -1;
    source->received = received; source->sent = sent; source->baseline = 1;
    return 0;
}

/// 每个周期只输出一小批接口汇总；显式 flush，普通管道也能立即收到完整数据。
static int publish_totals(NSMTotal *totals, NSMRoute *routes) {
    printf(",bytes_in,bytes_out,\n");
    for (int i = 0; i < 128; ++i) {
        if (!totals[i].interface) continue;
        int present = 0;
        for (int j = 0; j < 1024; ++j) {
            if (routes[j].reference && routes[j].interface == totals[i].interface) { present = 1; break; }
        }
        char name[IF_NAMESIZE];
        if ((present || totals[i].received || totals[i].sent) && if_indextoname(totals[i].interface, name)) {
            printf("physical -> %s,%llu,%llu,\n", name,
                   (unsigned long long)totals[i].received, (unsigned long long)totals[i].sent);
        }
        if (!present) totals[i].interface = 0;
        totals[i].received = 0; totals[i].sent = 0;
    }
    return fflush(stdout) == 0 ? 0 : -1;
}

/// 以 kqueue 等待内核统计、父进程退出及低频采样计时器，不创建 nettop 子进程。
int nsm_run_native_routes(int interval) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return 78;
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, "com.apple.network.statistics", sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info) != 0) { close(fd); return 78; }
    struct sockaddr_ctl address = {0};
    address.sc_len = sizeof(address); address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL; address.sc_id = info.ctl_id;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return 78; }
    int buffer_size = 1024 * 1024;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer_size, sizeof(buffer_size)) != 0) { close(fd); return 78; }
    NSMSubscribe subscription = {{1, 1002, sizeof(subscription), 0}, 0x2000000000ULL, 0, 1, 0, {0}};
    if (send(fd, &subscription, sizeof(subscription), 0) != sizeof(subscription)) { close(fd); return 78; }
    int queue = kqueue();
    if (queue < 0) { close(fd); return 78; }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
    struct kevent changes[6];
    EV_SET(&changes[0], fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[1], STDIN_FILENO, EVFILT_READ, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[2], SIGTERM, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[3], SIGINT, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[4], SIGHUP, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[5], 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 0, 250, NULL);
    if (kevent(queue, changes, 6, NULL, 0, NULL) != 0) { close(queue); close(fd); return 78; }
    NSMRoute *routes = calloc(1024, sizeof(*routes));
    NSMTotal *totals = calloc(128, sizeof(*totals));
    if (!routes || !totals) { free(routes); free(totals); close(queue); close(fd); return 78; }
    uint64_t sequence = 10;
    int querying = 0, result = 0;
    for (;;) {
        struct kevent event;
        int count = kevent(queue, NULL, 0, &event, 1, NULL);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || (event.flags & EV_ERROR)) { result = 78; break; }
        if (event.filter == EVFILT_SIGNAL) break;
        if (event.filter == EVFILT_TIMER) {
            if (querying || reference_request(fd, 1004, sequence++, UINT64_MAX) != 0) { result = 78; break; }
            querying = 1;
            EV_SET(&changes[5], 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 0, interval * 1000, NULL);
            if (kevent(queue, &changes[5], 1, NULL, 0, NULL) != 0) { result = 78; break; }
            continue;
        }
        if (event.ident == STDIN_FILENO) {
            char keep_alive[64];
            if (read(STDIN_FILENO, keep_alive, sizeof(keep_alive)) <= 0) break;
            continue;
        }
        unsigned char buffer[65536];
        ssize_t length = recv(fd, buffer, sizeof(buffer), 0);
        if (length <= 0) { result = 78; break; }
        size_t offset = 0;
        while (offset + sizeof(NSMHeader) <= (size_t)length) {
            NSMHeader header;
            memcpy(&header, buffer + offset, sizeof(header));
            if (header.length < sizeof(header) || offset + header.length > (size_t)length) { result = 78; break; }
            const unsigned char *message = buffer + offset;
            if (header.type == 10001) {
                if (header.length != 32) { result = 78; break; }
                if (read32(message + 24) != 1 || reference_request(fd, 1005, 2, read64(message + 16)) != 0) { result = 78; break; }
            } else if (header.type == 10003) {
                // 精确验证本机已测试的 route descriptor 布局，未来布局变化直接回退。
                if (header.length != 160 || read32(message + 32) != 1) { result = 78; break; }
                uint64_t reference = read64(message + 16), parent = read64(message + 48);
                unsigned interface = read32(message + 148);
                char name[IF_NAMESIZE];
                if (parent || !if_indextoname(interface, name) || !strncmp(name, "lo", 2) || !strncmp(name, "utun", 4) || is_direct_interface(interface)) {
                    if (reference_request(fd, 1003, 4, reference) != 0) { result = 78; break; }
                } else {
                    NSMRoute *route = find_route(routes, reference, 1);
                    if (!route || add_total(totals, interface, 0, 0) != 0) { result = 78; break; }
                    route->interface = interface;
                    // 新路由立即建立基线，避免第一次周期查询把历史累计量计入当前速度。
                    if (reference_request(fd, 1004, 3, reference) != 0) { result = 78; break; }
                }
            } else if (header.type == 10004) {
                if (header.length != 144) { result = 78; break; }
                NSMRoute *route = find_route(routes, read64(message + 16), 0);
                if (route && consume_counts(totals, route, read64(message + 40), read64(message + 56)) != 0) { result = 78; break; }
            } else if (header.type == 10002 && header.length >= 24) {
                NSMRoute *route = find_route(routes, read64(message + 16), 0);
                if (route) memset(route, 0, sizeof(*route));
            } else if (header.type == 0 && header.context >= 10) {
                querying = 0;
                if (publish_totals(totals, routes) != 0) { result = 0; goto finished; }
            } else if (header.type == 1) {
                // 描述请求的源可能已关闭；其他错误（含缓冲溢出）必须回退而不是漏计。
                if (header.length < 24 || !((header.context == 2 || header.context == 3 || header.context == 4)
                    && (read32(message + 16) == ENOENT || read32(message + 16) == EINVAL))) { result = 78; break; }
            }
            offset += header.length;
        }
        if (!result && offset != (size_t)length) result = 78;
        if (result) break;
    }
finished:
    free(routes); free(totals); close(queue); close(fd);
    return result;
}
