/*
 * fanctl —— Intel Mac 风扇 / 温度 SMC 命令行工具
 *
 * 通过 IOKit 的 AppleSMC 服务直接读写 SMC 键值。
 * 读取（风扇转速、各类温度传感器）通常允许普通用户；
 * 写入（F0Md / F0Tg）必须以 root 身份执行，因此本工具
 * 由 installer 安装为 setuid root（/usr/local/bin/fanctl），
 * 让普通用户级的 GUI 无需每次输密码。
 *
 * 编译：
 *   clang -O2 -Wall -Wextra -o fanctl fanctl.c -framework IOKit -framework CoreFoundation
 *
 * 用法：
 *   fanctl list              输出 JSON：风扇状态 + 温度
 *   fanctl set <fan> <rpm>   强制指定转速（自动夹取到 [F0Mn, F0Mx]）
 *   fanctl auto [fan|all]    恢复系统自动控制（清除强制位）
 *   fanctl read <KEY>        读单个键（如 F0Ac / TC0P）
 *   fanctl watch             终端实时刷新（调试用，Ctrl-C 退出）
 *   fanctl diag              自检信息
 *   fanctl version
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <IOKit/IOKitLib.h>

/* ---------- Apple SMC 数据结构（与 Apple 开源 AppleSMC 一致） ---------- */

typedef struct {
    char major;
    char minor;
    char build;
    char reserved;
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef unsigned char SMCBytes_t[32];

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    SMCBytes_t bytes;
} SMCVal_t;

/* 结构体布局一旦错位，所有 SMC 调用都会静默失败，编译期兜底检查 */
_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t must be 80 bytes");

#define KERNEL_INDEX_SMC        2
#define SMC_CMD_READ_BYTES      5
#define SMC_CMD_WRITE_BYTES     6
#define SMC_CMD_READ_KEYINFO    9

static io_connect_t gConn = 0;

/* ---------------------------- 基础封装 ---------------------------- */

static kern_return_t smcOpen(void)
{
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"));
    if (!svc) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &gConn);
    IOObjectRelease(svc);
    return kr;
}

static void smcClose(void)
{
    if (gConn) { IOServiceClose(gConn); gConn = 0; }
}

static UInt32 str2key(const char *s)
{
    UInt32 v = 0;
    int i;
    for (i = 0; i < 4; i++)
        v = (v << 8) | (UInt32)(unsigned char)(s[i] ? s[i] : ' ');
    return v;
}

static void key2str(UInt32 k, char out[5])
{
    out[0] = (char)((k >> 24) & 0xff);
    out[1] = (char)((k >> 16) & 0xff);
    out[2] = (char)((k >> 8) & 0xff);
    out[3] = (char)(k & 0xff);
    out[4] = 0;
}

static kern_return_t smcRead(UInt32 key, SMCVal_t *val)
{
    SMCKeyData_t in, out;
    size_t outSize;
    kern_return_t kr;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    memset(val, 0, sizeof(*val));

    outSize = sizeof(out);
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kr = IOConnectCallStructMethod(gConn, KERNEL_INDEX_SMC,
                                   &in, sizeof(in), &out, &outSize);
    if (kr != kIOReturnSuccess) return kr;

    val->dataSize = out.keyInfo.dataSize;
    val->dataType = out.keyInfo.dataType;
    if (val->dataSize > 32) val->dataSize = 32;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    outSize = sizeof(out);
    in.key = key;
    in.data8 = SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize = val->dataSize;
    kr = IOConnectCallStructMethod(gConn, KERNEL_INDEX_SMC,
                                   &in, sizeof(in), &out, &outSize);
    if (kr != kIOReturnSuccess) return kr;

    memcpy(val->bytes, out.bytes, sizeof(val->bytes));
    return kIOReturnSuccess;
}

static kern_return_t smcWrite(UInt32 key, UInt32 dataSize, const UInt8 *bytes)
{
    SMCKeyData_t in, out;
    size_t outSize = sizeof(out);

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = dataSize;
    if (dataSize > 32) dataSize = 32;
    memcpy(in.bytes, bytes, dataSize);

    return IOConnectCallStructMethod(gConn, KERNEL_INDEX_SMC,
                                     &in, sizeof(in), &out, &outSize);
}

/* ------------------------- 类型解码 / 编码 ------------------------- */

static UInt16 be16(const UInt8 *b)
{
    return (UInt16)(((UInt16)b[0] << 8) | (UInt16)b[1]);
}

static double decodeValue(UInt32 dataType, const UInt8 *b)
{
    char t[5];
    key2str(dataType, t);

    if (!strcmp(t, "sp78")) {
        /* 有符号 8.8 定点，温度常见；电池可能为负 */
        return (double)((int16_t)be16(b)) / 256.0;
    }
    if (!strcmp(t, "sp87")) return (double)((int16_t)be16(b)) / 128.0;
    if (!strcmp(t, "sp5a")) return (double)((int16_t)be16(b)) / 1024.0;
    if (!strcmp(t, "fpe2")) return (double)be16(b) / 4.0;
    if (!strcmp(t, "flt ")) {
        float f = 0.0f;
        memcpy(&f, b, 4);
        return (double)f;
    }
    if (!strcmp(t, "ui8 ")) return (double)b[0];
    if (!strcmp(t, "ui16")) return (double)be16(b);
    if (!strcmp(t, "ui32")) {
        return (double)(((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) |
                        ((UInt32)b[2] << 8) | (UInt32)b[3]);
    }
    if (!strcmp(t, "si16")) return (double)((int16_t)be16(b));
    if (!strcmp(t, "flag")) return (double)b[0];
    /* 未知类型：按 fpe2 兜底（风扇转速最常见） */
    return (double)be16(b) / 4.0;
}

static int encodeValue(const char *t, double v, UInt8 *out, UInt32 *outSize)
{
    memset(out, 0, 32);

    if (!strcmp(t, "flt ")) {
        float f = (float)v;
        memcpy(out, &f, 4);
        *outSize = 4;
        return 0;
    }
    if (!strcmp(t, "fpe2")) {
        double x = v * 4.0;
        UInt16 u;
        if (x < 0) x = 0;
        if (x > 65535) x = 65535;
        u = (UInt16)(x + 0.5);
        out[0] = (UInt8)(u >> 8);
        out[1] = (UInt8)(u & 0xff);
        *outSize = 2;
        return 0;
    }
    if (!strcmp(t, "sp78")) {
        double x = v * 256.0;
        int16_t s;
        if (x > 32767) x = 32767;
        if (x < -32768) x = -32768;
        s = (int16_t)x;
        out[0] = (UInt8)((UInt16)s >> 8);
        out[1] = (UInt8)((UInt16)s & 0xff);
        *outSize = 2;
        return 0;
    }
    if (!strcmp(t, "ui8 ") || !strcmp(t, "flag")) {
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        out[0] = (UInt8)v;
        *outSize = 1;
        return 0;
    }
    if (!strcmp(t, "ui16")) {
        UInt16 u = (UInt16)(v < 0 ? 0 : (v > 65535 ? 65535 : v));
        out[0] = (UInt8)(u >> 8);
        out[1] = (UInt8)(u & 0xff);
        *outSize = 2;
        return 0;
    }
    if (!strcmp(t, "ui32")) {
        UInt32 u = (UInt32)(v < 0 ? 0 : v);
        out[0] = (UInt8)(u >> 24);
        out[1] = (UInt8)((u >> 16) & 0xff);
        out[2] = (UInt8)((u >> 8) & 0xff);
        out[3] = (UInt8)(u & 0xff);
        *outSize = 4;
        return 0;
    }
    return -1;
}

/* ------------------------------ 便捷层 ------------------------------ */

static int readVal(const char *key, SMCVal_t *v)
{
    return smcRead(str2key(key), v) == kIOReturnSuccess ? 0 : -1;
}

static double readDouble(const char *key, int *ok)
{
    SMCVal_t v;
    if (readVal(key, &v) != 0) {
        if (ok) *ok = 0;
        return 0.0;
    }
    if (ok) *ok = 1;
    return decodeValue(v.dataType, v.bytes);
}

static int writeDouble(const char *key, double value)
{
    SMCVal_t v;
    char t[5];
    UInt8 buf[32];
    UInt32 size = 0;

    if (readVal(key, &v) != 0) return -1;
    key2str(v.dataType, t);
    if (encodeValue(t, value, buf, &size) != 0) return -2;
    if (smcWrite(str2key(key), size, buf) != kIOReturnSuccess) return -3;
    return 0;
}

/* ---------------- 风扇强制位 -----------------
 * 新机型（约 2013+）用 F<idx>Md：1 = 强制，0 = 自动。
 * 老机型（2011 及更早，如 MacBookPro8,x）没有 F<idx>Md 这个键，
 * 强制位在 FS! —— 一个 ui16 位掩码，bit N 对应第 N 个风扇。
 * 老机器上只写 F0Tg（目标转速）不写 FS! 的话，系统 SMC 会立刻
 * 覆盖回去，表现为「能读数、能改目标值，但转速完全不受控」。
 */

static int keyUsable(const char *key, SMCVal_t *v)
{
    if (readVal(key, v) != 0) return 0;
    return v->dataSize > 0 && v->dataType != 0;
}

static int forcedState(int fan)
{
    char kMd[8];
    SMCVal_t v;

    snprintf(kMd, sizeof(kMd), "F%dMd", fan);
    if (keyUsable(kMd, &v))
        return decodeValue(v.dataType, v.bytes) != 0 ? 1 : 0;

    if (keyUsable("FS! ", &v) && v.dataSize >= 2)
        return (int)((be16(v.bytes) >> fan) & 1);
    return 0;
}

static int setForced(int fan, int on)
{
    char kMd[8];
    SMCVal_t v;
    UInt16 cur, nv;
    UInt8 buf[2];

    snprintf(kMd, sizeof(kMd), "F%dMd", fan);
    if (keyUsable(kMd, &v))
        return writeDouble(kMd, on ? 1.0 : 0.0) == 0 ? 0 : -3;

    /* 老机型：读-改-写 FS! 的对应 bit，别踩掉其它风扇的位 */
    if (!keyUsable("FS! ", &v) || v.dataSize < 2) return -1;

    cur = be16(v.bytes);
    nv = on ? (UInt16)(cur | (1u << fan)) : (UInt16)(cur & ~(1u << fan));
    buf[0] = (UInt8)(nv >> 8);
    buf[1] = (UInt8)(nv & 0xff);
    if (smcWrite(str2key("FS! "), 2, buf) != kIOReturnSuccess) return -3;
    return 0;
}

/* ---------------------------- 温度传感器 ---------------------------- */

typedef struct { const char *key; const char *name; } TempKey;

static const TempKey gTempKeys[] = {
    { "TC0P", "CPU 附近"  },
    { "TC0D", "CPU 二极管" },
    { "TC0E", "CPU E"      },
    { "TC0F", "CPU F"      },
    { "TC0H", "CPU 散热片" },
    { "TC1C", "核心 1"     },
    { "TC2C", "核心 2"     },
    { "TC3C", "核心 3"     },
    { "TC4C", "核心 4"     },
    { "TG0P", "GPU 附近"   },
    { "TG0D", "GPU 二极管" },
    { "TN0P", "北桥"       },
    { "TH0P", "硬盘位"     },
    { "TB0T", "电池"       },
    { "TB1T", "电池 2"     },
    { "TA0P", "环境"       },
    { "TS0P", "掌托"       },
};
#define TEMP_COUNT ((int)(sizeof(gTempKeys) / sizeof(gTempKeys[0])))

static int fanCount(void)
{
    int ok = 0;
    double n = readDouble("FNum", &ok);
    if (!ok || n <= 0 || n > 8) return 1;
    return (int)n;
}

/* ------------------------------ 子命令 ------------------------------ */

static void cmdList(void)
{
    char k[8];
    int i, n, first;
    double maxTemp = 0.0;

    n = fanCount();

    printf("{\"ok\":true,\"root\":%s,\"pid\":%d,\"fans\":[",
           geteuid() == 0 ? "true" : "false", (int)getpid());

    for (i = 0; i < n; i++) {
        int okAc = 0, okMn = 0, okMx = 0, okTg = 0;
        double ac, mn, mx, tg;
        int md;

        snprintf(k, sizeof(k), "F%dAc", i); ac = readDouble(k, &okAc);
        snprintf(k, sizeof(k), "F%dMn", i); mn = readDouble(k, &okMn);
        snprintf(k, sizeof(k), "F%dMx", i); mx = readDouble(k, &okMx);
        snprintf(k, sizeof(k), "F%dTg", i); tg = readDouble(k, &okTg);
        md = forcedState(i);

        if (!okMn || mn <= 0) mn = 1200;
        if (!okMx || mx <= 0) mx = 6200;
        if (!okTg) tg = ac;
        if (!okAc) ac = 0.0;

        printf("%s{\"i\":%d,\"ac\":%.1f,\"mn\":%.1f,\"mx\":%.1f,"
               "\"tg\":%.1f,\"md\":%d}",
               i ? "," : "", i, ac, mn, mx, tg, (int)md);
    }

    printf("],\"temps\":[");
    first = 1;
    for (i = 0; i < TEMP_COUNT; i++) {
        int ok = 0;
        double v = readDouble(gTempKeys[i].key, &ok);
        if (!ok) continue;
        if (v < 1.0 || v > 125.0) continue;
        if (v > maxTemp) maxTemp = v;
        printf("%s{\"k\":\"%s\",\"n\":\"%s\",\"v\":%.1f}",
               first ? "" : ",", gTempKeys[i].key, gTempKeys[i].name, v);
        first = 0;
    }
    printf("],\"maxtemp\":%.1f}\n", maxTemp);
}

static int cmdSet(int fan, double want)
{
    char kAc[8], kMn[8], kMx[8], kTg[8];
    int ok = 0, e1, e2;
    double mn, mx, ac, tg;

    if (fan < 0 || fan > 7) {
        printf("{\"ok\":false,\"err\":\"风扇编号越界\"}\n");
        return 1;
    }

    snprintf(kAc, sizeof(kAc), "F%dAc", fan);
    snprintf(kMn, sizeof(kMn), "F%dMn", fan);
    snprintf(kMx, sizeof(kMx), "F%dMx", fan);
    snprintf(kTg, sizeof(kTg), "F%dTg", fan);

    mn = readDouble(kMn, &ok);
    if (!ok || mn <= 0) mn = 1200;
    mx = readDouble(kMx, &ok);
    if (!ok || mx <= 0) mx = 6200;

    /* 下限放到 0：允许用户手动关停风扇。
     * 低于硬件 F0Mn 的请求是否真正生效由 SMC 自行决定（多数机型会夹取）。 */
    if (want < 0) want = 0;
    if (want > mx) want = mx;
    (void)mn;

    /* 顺序：先给目标值，再置强制位，避免瞬间跳转到旧目标 */
    e1 = writeDouble(kTg, want);
    e2 = setForced(fan, 1);

    usleep(120000);

    ac = readDouble(kAc, &ok);
    tg = readDouble(kTg, &ok);

    printf("{\"ok\":%s,\"i\":%d,\"want\":%.1f,\"tg\":%.1f,\"ac\":%.1f,"
           "\"err\":\"%s\"}\n",
           (e1 == 0 && e2 == 0) ? "true" : "false",
           fan, want, tg, ac,
           (e1 == 0 && e2 == 0) ? "" :
           (e1 != 0 ? "写入目标转速失败" : "写入强制模式失败"));

    return (e1 == 0 && e2 == 0) ? 0 : 1;
}

static int cmdAuto(int fan)
{
    int i, n, e;
    int allOk = 1;

    if (fan >= 0) {
        e = setForced(fan, 0);
        if (e != 0) allOk = 0;
        printf("{\"ok\":%s,\"i\":%d,\"err\":\"%s\"}\n",
               e == 0 ? "true" : "false", fan,
               e == 0 ? "" : "恢复自动控制失败（请确认已安装 setuid 辅助工具）");
        return e == 0 ? 0 : 1;
    }

    n = fanCount();
    for (i = 0; i < n; i++) {
        if (setForced(i, 0) != 0) allOk = 0;
    }
    printf("{\"ok\":%s,\"fans\":%d,\"err\":\"%s\"}\n",
           allOk ? "true" : "false", n,
           allOk ? "" : "部分风扇恢复自动控制失败");
    return allOk ? 0 : 1;
}

static int cmdRead(const char *key)
{
    SMCVal_t v;
    char t[5];

    if (strlen(key) != 4) {
        printf("{\"ok\":false,\"err\":\"键名必须为 4 个字符\"}\n");
        return 1;
    }
    if (readVal(key, &v) != 0) {
        printf("{\"ok\":false,\"err\":\"读取失败\"}\n");
        return 1;
    }
    key2str(v.dataType, t);
    printf("{\"ok\":true,\"k\":\"%s\",\"type\":\"%s\",\"size\":%u,\"v\":%.3f}\n",
           key, t, (unsigned)v.dataSize, decodeValue(v.dataType, v.bytes));
    return 0;
}

static void cmdWatch(void)
{
    for (;;) {
        char k[8];
        int i, n = fanCount();
        int ok = 0;
        double maxT = 0.0;

        printf("[%ld] ", (long)time(NULL));
        for (i = 0; i < n; i++) {
            double ac;
            snprintf(k, sizeof(k), "F%dAc", i);
            ac = readDouble(k, &ok);
            printf("FAN%d=%.0frpm ", i, ac);
        }
        for (i = 0; i < TEMP_COUNT; i++) {
            double v = readDouble(gTempKeys[i].key, &ok);
            if (ok && v > 1.0 && v > maxT) maxT = v;
        }
        printf("MAX=%.1fC\n", maxT);
        fflush(stdout);
        sleep(2);
    }
}

static void cmdDiag(void)
{
    SMCVal_t v;
    char t[5];
    int ok = 0;

    printf("fanctl 1.2.0\n");
    printf("euid : %d (%s)\n", (int)geteuid(),
           geteuid() == 0 ? "root，可写 SMC" : "普通用户，可能只能读取");
    if (readVal("FNum", &v) == 0) {
        key2str(v.dataType, t);
        printf("FNum : %s (type=%s size=%u)\n", "OK", t, (unsigned)v.dataSize);
        printf("风扇数量 : %d\n", (int)decodeValue(v.dataType, v.bytes));
    } else {
        printf("FNum : 读取失败\n");
    }

    /* 强制位：新机型 F<idx>Md；老机型（2011 及更早）没有这个键，走 FS! 位掩码 */
    if (keyUsable("F0Md", &v)) {
        key2str(v.dataType, t);
        printf("F0Md : 存在 (type=%s size=%u) 值=%.1f\n",
               t, (unsigned)v.dataSize, decodeValue(v.dataType, v.bytes));
    } else {
        printf("F0Md : 不存在 —— 老机型，强制位改走 FS! \n");
    }
    if (keyUsable("FS! ", &v) && v.dataSize >= 2) {
        printf("FS!  : 存在，位掩码 0x%04x (bit0=%d)\n",
               (unsigned)be16(v.bytes), (int)((be16(v.bytes) >> 0) & 1));
    } else {
        printf("FS!  : 不存在 —— 强制位无处可写\n");
    }
    printf("强制位 : %s\n", forcedState(0) ? "ON（转速已锁定）"
                                           : "OFF（系统自动控制）");

    if (readVal("F0Tg", &v) == 0) {
        key2str(v.dataType, t);
        printf("F0Tg 类型 : %s  当前目标 : %.1f\n",
               t, decodeValue(v.dataType, v.bytes));
    }
    if (readVal("F0Ac", &v) == 0) {
        key2str(v.dataType, t);
        printf("F0Ac 类型 : %s  实际转速 : %.1f\n",
               t, decodeValue(v.dataType, v.bytes));
    }
    printf("TC0P : %.1f C\n", readDouble("TC0P", &ok));
    printf("TG0P : %.1f C\n", readDouble("TG0P", &ok));
}

/* -------------------------------- main -------------------------------- */

static void usage(void)
{
    fprintf(stderr,
        "fanctl 1.2.0  —— Intel Mac 风扇控制\n"
        "  fanctl list               输出风扇/温度 JSON\n"
        "  fanctl set <fan> <rpm>    强制转速（fan 从 0 开始）\n"
        "  fanctl auto [fan|all]     恢复系统自动控制\n"
        "  fanctl read <KEY>         读取单个 SMC 键\n"
        "  fanctl watch              终端实时刷新，Ctrl-C 退出\n"
        "  fanctl diag               自检\n"
        "  fanctl version\n");
}

int main(int argc, char **argv)
{
    kern_return_t kr;
    int rc = 0;

    if (argc < 2) { usage(); return 2; }

    if (!strcmp(argv[1], "version")) {
        printf("fanctl 1.2.0\n");
        return 0;
    }
    if (!strcmp(argv[1], "help") || !strcmp(argv[1], "-h") ||
        !strcmp(argv[1], "--help")) {
        usage();
        return 0;
    }

    kr = smcOpen();
    if (kr != kIOReturnSuccess) {
        printf("{\"ok\":false,\"fans\":[],\"temps\":[],\"maxtemp\":0,"
               "\"err\":\"无法连接 AppleSMC（kr=0x%x）%s\"}\n",
               (unsigned)kr,
               geteuid() == 0 ? "" : "，写操作需要 root 权限");
        return 1;
    }

    if (!strcmp(argv[1], "list")) {
        cmdList();
    } else if (!strcmp(argv[1], "set")) {
        if (argc < 4) { usage(); rc = 2; }
        else rc = cmdSet(atoi(argv[2]), atof(argv[3]));
    } else if (!strcmp(argv[1], "auto")) {
        if (argc >= 3 && strcmp(argv[2], "all") != 0)
            rc = cmdAuto(atoi(argv[2]));
        else
            rc = cmdAuto(-1);
    } else if (!strcmp(argv[1], "read")) {
        if (argc < 3) { usage(); rc = 2; }
        else rc = cmdRead(argv[2]);
    } else if (!strcmp(argv[1], "watch")) {
        cmdWatch();
    } else if (!strcmp(argv[1], "diag")) {
        cmdDiag();
    } else {
        usage();
        rc = 2;
    }

    smcClose();
    return rc;
}
