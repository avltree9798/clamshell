// SPDX-License-Identifier: GPL-3.0-or-later
//
// A tiny 3DS homebrew for the CTR core's tests. It talks to the kernel and
// services the way libctru does (same SVC register conventions and IPC
// layouts) but needs no SDK: build.sh compiles it with clang and packs a .3dsx.
//
// It fills the top screen with a colour that depends on the A button, runs a
// second thread that takes a mutex, and exits after 4 VBlanks.

#include <stdint.h>
typedef uint32_t u32; typedef int32_t s32; typedef uint8_t u8; typedef uint16_t u16; typedef int64_t s64;

// ---- SVCs, with libctru's register conventions ----

static u32 svc_control_memory(u32 *out, u32 a0, u32 a1, u32 size, u32 op, u32 perm) {
    register u32 r0 asm("r0") = op, r1 asm("r1") = a0, r2 asm("r2") = a1, r3 asm("r3") = size, r4 asm("r4") = perm;
    asm volatile("svc 0x01" : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r3), "+r"(r4) :: "memory", "r12", "lr");
    *out = r1; return r0;
}
static u32 svc_create_thread(u32 *handle, void (*entry)(u32), u32 arg, u32 stack_top, s32 prio, s32 cpu) {
    register u32 r0 asm("r0") = prio, r1 asm("r1") = (u32)entry, r2 asm("r2") = arg, r3 asm("r3") = stack_top, r4 asm("r4") = cpu;
    asm volatile("svc 0x08" : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r3), "+r"(r4) :: "memory", "r12", "lr");
    *handle = r1; return r0;
}
static void svc_exit_thread(void) { asm volatile("svc 0x09" ::: "memory"); }
static void svc_sleep(s64 ns) {
    register u32 r0 asm("r0") = (u32)ns, r1 asm("r1") = (u32)(ns >> 32);
    asm volatile("svc 0x0A" : "+r"(r0), "+r"(r1) :: "memory", "r2", "r3", "r12", "lr");
}
static u32 svc_create_mutex(u32 *handle, int locked) {
    register u32 r0 asm("r0") = 0, r1 asm("r1") = locked;
    asm volatile("svc 0x13" : "+r"(r0), "+r"(r1) :: "memory", "r2", "r3", "r12", "lr");
    *handle = r1; return r0;
}
static u32 svc_release_mutex(u32 h) {
    register u32 r0 asm("r0") = h;
    asm volatile("svc 0x14" : "+r"(r0) :: "memory", "r1", "r2", "r3", "r12", "lr");
    return r0;
}
static u32 svc_create_event(u32 *handle, u32 reset) {
    register u32 r0 asm("r0") = 0, r1 asm("r1") = reset;
    asm volatile("svc 0x17" : "+r"(r0), "+r"(r1) :: "memory", "r2", "r3", "r12", "lr");
    *handle = r1; return r0;
}
static u32 svc_map_memory_block(u32 h, u32 addr, u32 my, u32 other) {
    register u32 r0 asm("r0") = h, r1 asm("r1") = addr, r2 asm("r2") = my, r3 asm("r3") = other;
    asm volatile("svc 0x1F" : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r3) :: "memory", "r12", "lr");
    return r0;
}
static u32 svc_wait1(u32 h, s64 ns) {
    register u32 r0 asm("r0") = h, r1 asm("r1") = 0, r2 asm("r2") = (u32)ns, r3 asm("r3") = (u32)(ns >> 32);
    asm volatile("svc 0x24" : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r3) :: "memory", "r12", "lr");
    return r0;
}
static u32 svc_connect_to_port(u32 *handle, const char *name) {
    register u32 r0 asm("r0") = 0, r1 asm("r1") = (u32)name;
    asm volatile("svc 0x2D" : "+r"(r0), "+r"(r1) :: "memory", "r2", "r3", "r12", "lr");
    *handle = r1; return r0;
}
static u32 svc_send_sync_request(u32 h) {
    register u32 r0 asm("r0") = h;
    asm volatile("svc 0x32" : "+r"(r0) :: "memory", "r1", "r2", "r3", "r12", "lr");
    return r0;
}
static void svc_output_debug_string(const char *s, u32 n) {
    register u32 r0 asm("r0") = (u32)s, r1 asm("r1") = n;
    asm volatile("svc 0x3D" : "+r"(r0), "+r"(r1) :: "memory", "r2", "r3", "r12", "lr");
}
static void svc_exit_process(void) { asm volatile("svc 0x03" ::: "memory"); }

static u32 *ipc(void) { u32 tls; asm volatile("mrc p15, 0, %0, c13, c0, 3" : "=r"(tls)); return (u32 *)(tls + 0x80); }
static void say(const char *s) { u32 n = 0; while (s[n]) n++; svc_output_debug_string(s, n); }

// ---- srv ----

static u32 srv;
static u32 get_service(const char *name) {
    u32 *cmd = ipc();
    cmd[0] = 0x00050100; cmd[1] = 0; cmd[2] = 0;
    u32 n = 0; while (name[n] && n < 8) { ((char *)&cmd[1])[n] = name[n]; n++; }
    cmd[3] = n; cmd[4] = 0;
    svc_send_sync_request(srv);
    return cmd[1] == 0 ? cmd[3] : 0;
}

// ---- results the test reads back ----

struct report { u32 magic, frames, color, a_seen, worker_ran, mutex_ok, gsp_first, sleep_ok; };
volatile struct report report = { 0x52455054 /* "TPER" */ };

static u32 mutex;
static volatile u32 worker_counter;
static u8 worker_stack[0x1000] __attribute__((aligned(8)));

static void worker(u32 arg) {
    if (svc_wait1(mutex, -1) == 0) {
        worker_counter += arg;
        svc_release_mutex(mutex);
    }
    report.worker_ran = 1;
    svc_exit_thread();
}

int main(void) {
    say("hello from the 3DS");
    if (svc_connect_to_port(&srv, "srv:")) return 1;
    u32 *cmd = ipc();
    cmd[0] = 0x00010002; cmd[1] = 0x20; cmd[2] = 0;  // RegisterClient
    svc_send_sync_request(srv);

    u32 gsp = get_service("gsp::Gpu"), hid = get_service("hid:USER");
    if (!gsp || !hid) return 2;

    u32 gsp_event;
    svc_create_event(&gsp_event, 0);
    cmd[0] = 0x00130042; cmd[1] = 1; cmd[2] = 0; cmd[3] = gsp_event;  // RegisterInterruptRelayQueue
    svc_send_sync_request(gsp);
    report.gsp_first = cmd[1] == 0x2A07;
    u32 thread_index = cmd[2], gsp_mem_handle = cmd[4];
    u8 *gsp_mem = (u8 *)0x10002000;
    svc_map_memory_block(gsp_mem_handle, (u32)gsp_mem, 3, 0x10000000);
    cmd[0] = 0x00160042; cmd[1] = 0; cmd[2] = 0; cmd[3] = 0xFFFF8001;  // AcquireRight
    svc_send_sync_request(gsp);

    cmd[0] = 0x000A0000;  // GetIPCHandles
    svc_send_sync_request(hid);
    u32 *hid_mem = (u32 *)0x10003000;
    svc_map_memory_block(cmd[3], (u32)hid_mem, 1, 0x10000000);

    u32 fb;
    if (svc_control_memory(&fb, 0, 0, 400 * 240 * 3, 0x10003, 3)) return 3;

    svc_create_mutex(&mutex, 1);
    u32 worker_thread;
    svc_create_thread(&worker_thread, worker, 5, (u32)(worker_stack + sizeof worker_stack), 0x20, -2);
    svc_sleep(1000000);  // 1 ms: the worker runs and blocks on the mutex
    report.sleep_ok = 1;
    worker_counter = 100;
    svc_release_mutex(mutex);  // the worker (higher priority) takes it at once
    report.mutex_ok = worker_counter == 105;

    // Post the framebuffer through shared memory, as gspPresentBuffer does.
    u8 *header = gsp_mem + 0x200 + thread_index * 0x80;
    u32 *info = (u32 *)(header + 4 + 0x1C);
    info[0] = 0; info[1] = fb; info[2] = fb; info[3] = 240 * 3; info[4] = 1; info[5] = 0; info[6] = 0;
    header[0] = 1; header[1] = 1;

    while (report.frames < 4) {
        u32 keys = hid_mem[10 + hid_mem[4] * 4];
        u32 color = keys & 1 ? 0x00FF00 : 0x2040C0;  // green while A is held
        if (keys & 1) report.a_seen = 1;
        report.color = color;
        u8 *p = (u8 *)fb;
        for (u32 i = 0; i < 400 * 240; i++) { p[0] = color; p[1] = color >> 8; p[2] = color >> 16; p += 3; }
        svc_wait1(gsp_event, -1);
        // Drain the interrupt queue, counting top-screen VBlanks.
        u8 *queue = gsp_mem + thread_index * 0x40;
        while (queue[1]) {
            u8 id = queue[0xC + queue[0]];
            queue[0] = (queue[0] + 1) % 0x34; queue[1]--;
            if (id == 2) report.frames++;
        }
    }
    say("goodbye");
    return 0;
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    asm volatile("bl main\n svc 0x03\n b .\n");
}
