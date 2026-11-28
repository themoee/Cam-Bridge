/*
 * spoof_host.c - launcher/injector: starts a program suspended, injects
 * smbspoof.dll from next to this exe, resumes it, and waits for it to exit
 * (so it also works as an IFEO "Debugger" value for WmiPrvSE.exe).
 *
 * Build: gcc -o spoof_host.exe spoof_host.c
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

static void LogF(const char *fmt, ...)
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
    strcat(path, "spoof_host.log");
    f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "[%lu] ", (unsigned long)GetCurrentProcessId());
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int Inject(HANDLE proc, const char *dll)
{
    SIZE_T len = strlen(dll) + 1;
    LPVOID remote;
    HANDLE t;
    remote = VirtualAllocEx(proc, NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) return 0;
    if (!WriteProcessMemory(proc, remote, dll, len, NULL)) {
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        return 0;
    }
    t = CreateRemoteThread(proc, NULL, 0,
        (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA"),
        remote, 0, NULL);
    if (!t) {
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        return 0;
    }
    WaitForSingleObject(t, 30000);
    CloseHandle(t);
    VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
    return 1;
}

/* ------------------------------------------------------- IFEO recursion fix
 * When used as an IFEO "Debugger", our own CreateProcess for the target would
 * trigger the same IFEO redirection again (fork bomb). Lift the value for the
 * duration of the spawn, then restore it. */

static HKEY  g_ifeoKey = NULL;
static char  g_ifeoVal[1024];
static DWORD g_ifeoLen = 0;

static void LiftIFEO(const char *exe)
{
    const char *base = strrchr(exe, '\\');
    char key[512];
    HKEY hk;
    DWORD type, len = sizeof(g_ifeoVal);
    base = base ? base + 1 : exe;
    snprintf(key, sizeof(key),
             "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\%s",
             base);
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, key, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, &hk) != ERROR_SUCCESS)
        return;
    if (RegQueryValueExA(hk, "Debugger", NULL, &type, (LPBYTE)g_ifeoVal, &len) == ERROR_SUCCESS) {
        LONG rd = RegDeleteValueA(hk, "Debugger");
        g_ifeoLen = len;
        g_ifeoKey = hk;
        LogF("lift: deleted Debugger='%s' (rc=%ld)", g_ifeoVal, (long)rd);
    } else {
        LogF("lift: no Debugger value under %s", key);
        RegCloseKey(hk);
    }
}

static void RestoreIFEO(void)
{
    if (g_ifeoKey) {
        RegSetValueExA(g_ifeoKey, "Debugger", 0, REG_SZ,
                       (const BYTE *)g_ifeoVal, g_ifeoLen);
        RegCloseKey(g_ifeoKey);
        g_ifeoKey = NULL;
    }
}

int main(int argc, char **argv)
{
    char dll[MAX_PATH], cmdline[4096] = "";
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    int i;
    if (argc < 2) {
        fprintf(stderr, "usage: spoof_host <exe> [args...]\n");
        return 2;
    }
    if (!GetModuleFileNameA(NULL, dll, MAX_PATH)) return 3;
    {
        int j = (int)strlen(dll) - 1;
        while (j >= 0 && dll[j] != '\\') j--;
        dll[j >= 0 ? j + 1 : 0] = 0;
    }
    strcat(dll, "smbspoof.dll");

    for (i = 1; i < argc; i++) {
        strcat(cmdline, "\"");
        strcat(cmdline, argv[i]);
        strcat(cmdline, "\" ");
    }
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);

    /* NOTE: bInheritHandles=TRUE is essential. When COM (Winmgmt) activates a
       local server it hands the activation data to the launched process via an
       inherited handle; we are that process (as IFEO debugger) and must pass
       inheritance on to the real exe, or COM never binds. */
    {
        const char *want = strrchr(argv[1], '\\');
        int attempt;
        want = want ? want + 1 : argv[1];
        for (attempt = 0; attempt < 8; attempt++) {
            char img[MAX_PATH];
            DWORD sz = MAX_PATH;
            const char *got;
            LiftIFEO(argv[1]);
            if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE,
                                CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
                RestoreIFEO();
                fprintf(stderr, "CreateProcess failed: %lu\n", (unsigned long)GetLastError());
                LogF("CreateProcess failed: %lu", (unsigned long)GetLastError());
                return 4;
            }
            RestoreIFEO();
            if (!QueryFullProcessImageNameA(pi.hProcess, 0, img, &sz)) break;
            got = strrchr(img, '\\');
            got = got ? got + 1 : img;
            if (_stricmp(got, want) == 0) {
                LogF("attempt %d: child=%s OK", attempt, got);
                break;                      /* real target - good */
            }
            LogF("attempt %d: child=%s (recursion) - retrying", attempt, got);
            TerminateProcess(pi.hProcess, 0);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            Sleep(100);
        }
    }
    if (!Inject(pi.hProcess, dll)) {
        fprintf(stderr, "warning: injection failed, running unspoofed\n");
        LogF("inject FAILED (dll=%s)", dll);
    } else {
        LogF("inject ok");
    }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hProcess);
    return 0;
}
