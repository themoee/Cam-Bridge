/*
 * spoof_watch.c - sits in the background and injects smbspoof.dll into every
 * WmiPrvSE.exe process it sees. Much more robust than an IFEO Debugger (which
 * breaks WMI's COM activation of its own provider host).
 *
 * Why this is enough: smbspoof.dll patches the NtQuerySystemInformation import
 * table entries inside the target, so cimwin32.dll (the provider that reads
 * SMBIOS) returns the fake strings. The DLL also re-patches modules that load
 * later, so injecting a live process works.
 *
 * Build: gcc -o spoof_watch.exe spoof_watch.c -lkernel32 -ladvapi32
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <string.h>
#include <stdio.h>

static DWORD g_seen[512];
static int   g_nseen = 0;

static int seen(DWORD pid)
{
    int i;
    for (i = 0; i < g_nseen; i++)
        if (g_seen[i] == pid) return 1;
    return 0;
}

static void remember(DWORD pid)
{
    if (g_nseen < (int)(sizeof(g_seen) / sizeof(g_seen[0]))) g_seen[g_nseen++] = pid;
}

static void LogW(const char *fmt, ...)
{
    char path[MAX_PATH];
    FILE *f;
    va_list ap;
    if (!GetModuleFileNameA(NULL, path, MAX_PATH)) return;
    {
        int j = (int)strlen(path) - 1;
        while (j >= 0 && path[j] != '\\') j--;
        path[j >= 0 ? j + 1 : 0] = 0;
    }
    strcat(path, "spoof_watch.log");
    f = fopen(path, "a");
    if (!f) return;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int kill_hosts(void)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32 pe;
    int n = 0;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, "WmiPrvSE.exe") == 0) {
                HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, pe.th32ProcessID);
                if (h) {
                    TerminateProcess(h, 0);
                    CloseHandle(h);
                    n++;
                }
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return n;
}

static int is_target(const char *name)
{
    /* WmiPrvSE = provider host; svchost = may host the WMI service (Winmgmt) */
    return _stricmp(name, "WmiPrvSE.exe") == 0 || _stricmp(name, "svchost.exe") == 0;
}

static int has_module(DWORD pid, const char *name)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    MODULEENTRY32 me;
    int found = 0;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    me.dwSize = sizeof(me);
    if (Module32First(snap, &me)) {
        do {
            if (_stricmp(me.szModule, name) == 0) { found = 1; break; }
        } while (Module32Next(snap, &me));
    }
    CloseHandle(snap);
    return found;
}

static void enable_debug_priv(void)
{
    HANDLE tok;
    TOKEN_PRIVILEGES tp;
    LUID luid;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok))
        return;
    if (LookupPrivilegeValueA(NULL, "SeDebugPrivilege", &luid)) {
        tp.PrivilegeCount = 1;
        tp.Privileges[0].Luid = luid;
        tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
        AdjustTokenPrivileges(tok, FALSE, &tp, sizeof(tp), NULL, NULL);
    }
    CloseHandle(tok);
}

static int inject(DWORD pid, const char *dll)
{
    HANDLE proc;
    LPVOID remote;
    HANDLE t;
    SIZE_T len = strlen(dll) + 1;
    proc = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION |
                       PROCESS_VM_WRITE | PROCESS_VM_READ | PROCESS_QUERY_INFORMATION,
                       FALSE, pid);
    if (!proc) return 0;
    remote = VirtualAllocEx(proc, NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) { CloseHandle(proc); return 0; }
    if (!WriteProcessMemory(proc, remote, dll, len, NULL)) {
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        CloseHandle(proc);
        return 0;
    }
    t = CreateRemoteThread(proc, NULL, 0,
        (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA"),
        remote, 0, NULL);
    if (!t) {
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        CloseHandle(proc);
        return 0;
    }
    WaitForSingleObject(t, 20000);
    CloseHandle(t);
    VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
    CloseHandle(proc);
    return 1;
}

int main(void)
{
    char dll[MAX_PATH];
    if (!GetModuleFileNameA(NULL, dll, MAX_PATH)) return 1;
    {
        int j = (int)strlen(dll) - 1;
        while (j >= 0 && dll[j] != '\\') j--;
        dll[j >= 0 ? j + 1 : 0] = 0;
    }
    strcat(dll, "smbspoof.dll");
    enable_debug_priv();

    /* Kill any hosts that were already running (they may have cached SMBIOS
       data before we could inject); WMI respawns them at once. */
    LogW("watcher start, killed %d existing hosts", kill_hosts());

    for (;;) {
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap != INVALID_HANDLE_VALUE) {
            PROCESSENTRY32 pe;
            pe.dwSize = sizeof(pe);
            if (Process32First(snap, &pe)) {
                do {
                    if (is_target(pe.szExeFile) && !seen(pe.th32ProcessID)) {
                        if (inject(pe.th32ProcessID, dll)) {
                            /* If cimwin32 is already loaded+initialised it has
                               already cached the real strings - let it respawn. */
                            if (has_module(pe.th32ProcessID, "cimwin32.dll")) {
                                HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, pe.th32ProcessID);
                                LogW("pid %lu (%s) already had cimwin32 - killing for clean respawn",
                                     (unsigned long)pe.th32ProcessID, pe.szExeFile);
                                if (h) { TerminateProcess(h, 0); CloseHandle(h); }
                            } else {
                                remember(pe.th32ProcessID);
                                LogW("injected into %s pid %lu (clean)",
                                     pe.szExeFile, (unsigned long)pe.th32ProcessID);
                            }
                        } else {
                            LogW("inject FAILED for pid %lu (err=%lu)",
                                 (unsigned long)pe.th32ProcessID, (unsigned long)GetLastError());
                        }
                    }
                } while (Process32Next(snap, &pe));
            }
            CloseHandle(snap);
        }
        Sleep(10);
    }
    return 0;
}
