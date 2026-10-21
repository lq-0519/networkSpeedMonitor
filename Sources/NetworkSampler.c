// 只读采集器生命周期包装器。kqueue 阻塞等待事件，无轮询定时器、无管理员权限。
// 主程序的 stdin 管道关闭（包括崩溃、SIGKILL）时立即回收 nettop，避免 EOF 空转孤儿进程。
#include <sys/event.h>
#include <sys/wait.h>
#include <spawn.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <util.h>
#include <termios.h>
#include <poll.h>
#include "NativeRoutes.h"

/// 安全结束本包装器亲自创建的子进程；最多等待 0.5 秒，再强制回收，保证退出有界。
static void stop_child(pid_t child) {
    int status = 0;
    pid_t waited = waitpid(child, &status, WNOHANG);
    if (waited == child || (waited < 0 && errno == ECHILD)) return;
    kill(child, SIGTERM);
    for (int attempt = 0; attempt < 25; ++attempt) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return;
        usleep(20000);
    }
    kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}

/// 参数只有采集模式和白名单刷新间隔；可执行路径固定，绝不接收任意命令或 shell 文本。
int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "routes") && strcmp(argv[1], "applications") && strcmp(argv[1], "direct")) ||
        (strcmp(argv[2], "1") && strcmp(argv[2], "2") && strcmp(argv[2], "5"))) return 64;
    if (!strcmp(argv[1], "routes") && getenv("NSM_COMPATIBILITY_MODE") == NULL) {
        int native_result = nsm_run_native_routes(atoi(argv[2]));
        if (native_result == 0) return 0;
        // 协议或权限不兼容时重置首帧基线，再使用系统工具，避免累计量跳变。
        puts("#RESET"); fflush(stdout);
        fputs("NetworkSampler: native statistics unavailable, using system compatibility mode\n", stderr);
    }
    int input[2];
    if (pipe(input) != 0) { perror("NetworkSampler pipe"); return 71; }
    // nettop 对普通 stdout 管道会缓冲输出，PTY 使其逐行发送，避免几秒甚至长期不刷新。
    int terminal_read, terminal_write;
    if (openpty(&terminal_read, &terminal_write, NULL, NULL, NULL) != 0) return 71;
    struct termios terminal_settings;
    if (tcgetattr(terminal_write, &terminal_settings) == 0) {
        cfmakeraw(&terminal_settings);
        tcsetattr(terminal_write, TCSANOW, &terminal_settings);
    }
    int queue = kqueue();
    if (queue < 0) { perror("NetworkSampler kqueue"); return 71; }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, terminal_write, STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, input[0]);
    posix_spawn_file_actions_addclose(&actions, input[1]);
    posix_spawn_file_actions_addclose(&actions, terminal_read);
    posix_spawn_file_actions_addclose(&actions, terminal_write);
    // Darwin kqueue 不会继承到子进程；添加 close 动作反而会使 posix_spawn 返回 EBADF。
    posix_spawnattr_init(&attributes);
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGHUP); sigaddset(&defaults, SIGPIPE);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);
    // CLOEXEC_DEFAULT 仅保留显式继承的输出流，防止 nettop 意外持有主程序保活管道。
    posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO);
    // 直连必须由具有系统网络统计权限的 nettop 读取，普通权限的 QUIC provider 会静默漏源。
    // 常驻 direct 模式只筛选 AWDL，降低枚举与输出开销；外网明细仅用于按需排行或兼容回退。
    // Swift 再按真实接口校验计数，只保存进程及接口合计，不保存连接端点。
    char *arguments[] = {"/usr/bin/nettop", "-L", "0", "-s", argv[2], "-n", "-x", "-d",
                         "-J", "interface,bytes_in,bytes_out", "-t",
                         !strcmp(argv[1], "direct") ? "awdl" : "external", NULL};
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "LANG=C", NULL};
    pid_t child = -1;
    int error = posix_spawn(&child, arguments[0], &actions, &attributes, arguments, environment);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(input[0]); close(terminal_write);
    if (error) { fprintf(stderr, "NetworkSampler spawn: %s\n", strerror(error)); close(input[1]); close(queue); return 71; }
    struct kevent changes[6];
    EV_SET(&changes[0], STDIN_FILENO, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL);
    EV_SET(&changes[1], child, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[2], SIGTERM, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[3], SIGINT, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[4], SIGHUP, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    EV_SET(&changes[5], terminal_read, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL);
    if (kevent(queue, changes, 6, NULL, 0, NULL) != 0) {
        perror("NetworkSampler register events");
        stop_child(child); close(input[1]); close(queue); return 71;
    }
    int result = 0;
    for (;;) {
        struct kevent event;
        int count = kevent(queue, NULL, 0, &event, 1, NULL);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || (event.flags & EV_ERROR)) {
            fprintf(stderr, "NetworkSampler event: count=%d error=%d\n", count, count > 0 ? (int)event.data : errno);
            result = 71; break;
        }
        if (event.filter == EVFILT_PROC) { result = 1; break; }
        if (event.filter == EVFILT_SIGNAL) break;
        if (event.filter == EVFILT_READ && event.ident == STDIN_FILENO) {
            char buffer[64];
            if (read(STDIN_FILENO, buffer, sizeof(buffer)) <= 0) break;
        } else if (event.filter == EVFILT_READ) {
            // 以原始 write 转发，不引入第二层 stdio 缓冲；父进程断开时立即清理子进程。
            char buffer[65536];
            ssize_t length = read(terminal_read, buffer, sizeof(buffer));
            if (length <= 0) break;
            // nettop 的行缓冲会产生许多小块；只在收到数据后等待 5ms 合并同一帧。
            // 无数据时仍由 kqueue 无限阻塞，不引入周期性高频轮询。
            struct pollfd pending = { .fd = terminal_read, .events = POLLIN, .revents = 0 };
            while ((size_t)length < sizeof(buffer) && poll(&pending, 1, 5) > 0 && (pending.revents & POLLIN)) {
                ssize_t extra = read(terminal_read, buffer + length, sizeof(buffer) - (size_t)length);
                if (extra <= 0) break;
                length += extra;
            }
            ssize_t offset = 0;
            while (offset < length) {
                ssize_t written = write(STDOUT_FILENO, buffer + offset, (size_t)(length - offset));
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) { result = 1; break; }
                offset += written;
            }
            if (result) break;
        }
    }
    stop_child(child);
    close(input[1]); close(terminal_read); close(queue);
    return result;
}
