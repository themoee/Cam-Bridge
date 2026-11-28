/*
 * smbspoof.c - injectable DLL that rewrites VM-identifying strings in the
 * SMBIOS data returned by NtQuerySystemInformation / NtQuerySystemInformationEx,
 * so an Amazon EC2 machine presents as an ordinary Dell PC to everything that
 * reads the firmware table (WMI's cimwin32, GetSystemFirmwareTable, ...).
 *
 * Mechanism: IAT patching - for every loaded module that imports
 * NtQuerySystemInformation(/Ex) from ntdll.dll, the import-table entry is
 * redirected to our hook. No code bytes are modified, so it is stable across
 * Windows versions. A poll thread re-patches modules that load later
 * (e.g. cimwin32.dll inside WmiPrvSE.exe).
 *
 * Config: smbspoof.txt next to this DLL - one "old=>new" pair per line,
 * '#' starts a comment. Replacements are padded/truncated to the old length
 * (SMBIOS string indexes must not shift).
 *
 * Build: gcc -shared -o smbspoof.dll smbspoof.c
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#define MAX_PAIRS 128
#define MAX_STR   96

typedef struct { char old[MAX_STR]; char new[MAX_STR]; int len; } Pair;
static Pair    g_pairs[MAX_PAIRS];
static int     g_npairs  = 0;
static HMODULE g_self    = NULL;

static void DllLog(const char *fmt, ...)
{
    char path[MAX_PATH];
    FILE *f;
    va_list ap;
    const char *base;
    if (!g_self) return;
    if (!GetModuleFileNameA(g_self, path, MAX_PATH)) return;
    base = strrchr(path, '\\');
    if (base) { strcpy((char *)base + 1, "smbspoof.log"); }
    f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "[%lu] ", (unsigned long)GetCurrentProcessId());
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

typedef LONG (WINAPI *NtQsi_t)   (ULONG, PVOID, ULONG, PULONG);
typedef LONG (WINAPI *NtQsiEx_t) (ULONG, PVOID, ULONG, PVOID, ULONG, PULONG);
static NtQsi_t   g_origQsi;
static NtQsiEx_t  g_origQsiEx;

/* ------------------------------------------------------- string rewriting */

static void Rewrite(unsigned char *buf, SIZE_T len)
{
    int i;
    if (!buf || !g_npairs) return;
    for (i = 0; i < g_npairs; i++) {
        unsigned char *p = buf;
        SIZE_T n = len;
        int L = g_pairs[i].len;
        while (n >= (SIZE_T)L) {
            if (p[0] == (unsigned char)g_pairs[i].old[0] &&
                memcmp(p, g_pairs[i].old, L) == 0) {
                memcpy(p, g_pairs[i].new, L);
                p += L; n -= L;
            } else { p++; n--; }
        }
    }
}

static void LogCall(ULONG cls, PVOID ret)
{
    HMODULE m = NULL;
    char nm[MAX_PATH] = "?";
    if (ret && GetModuleHandleExA(0x6 /*FROM_ADDRESS|UNCHANGED_REFCOUNT*/, (LPCSTR)ret, &m) && m)
        GetModuleFileNameA(m, nm, MAX_PATH);
    DllLog("qsi cls=%lu from %s", cls, nm);
}

static __declspec(thread) int t_inHook = 0;

static LONG WINAPI HookQsi(ULONG cls, PVOID buf, ULONG len, PULONG retLen)
{
    LONG st;
    if (t_inHook) return g_origQsi(cls, buf, len, retLen);   /* re-entrancy guard */
    t_inHook = 1;
    st = g_origQsi(cls, buf, len, retLen);
    if (st == 0 && buf && len && cls >= 76 && cls <= 78) {
        DllLog("qsi cls=%lu len=%lu", cls, len);
        Rewrite((unsigned char *)buf, len);
    }
    t_inHook = 0;
    return st;
}

static LONG WINAPI HookQsiEx(ULONG cls, PVOID inb, ULONG inl,
                              PVOID outb, ULONG outl, PULONG retLen)
{
    LONG st;
    if (t_inHook) return g_origQsiEx(cls, inb, inl, outb, outl, retLen);
    t_inHook = 1;
    st = g_origQsiEx(cls, inb, inl, outb, outl, retLen);
    if (st == 0 && outb && outl && cls >= 76 && cls <= 78) {
        SIZE_T n = outl;
        if (retLen && *retLen && (SIZE_T)*retLen < n) n = *retLen;
        DllLog("qsiex cls=%lu len=%lu", cls, (unsigned long)n);
        Rewrite((unsigned char *)outb, n);
    }
    t_inHook = 0;
    return st;
}

/* --------------------------------------------------------- IAT patching */

static void PatchModule(PVOID base)
{
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    DWORD rva, oldprot;
    int i, n1 = 0, n2 = 0;
    (void)n1; (void)n2;
    if (!base) return;
    dos = (IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    nt = (IMAGE_NT_HEADERS *)((BYTE *)base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    if (nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return;
    rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) return;
    imp = (IMAGE_IMPORT_DESCRIPTOR *)((BYTE *)base + rva);
    for (; imp->Name; imp++) {
        ULONGLONG *iat, *names;
        if (!imp->FirstThunk) continue;
        iat    = (ULONGLONG *)((BYTE *)base + imp->FirstThunk);
        names  = imp->OriginalFirstThunk
                     ? (ULONGLONG *)((BYTE *)base + imp->OriginalFirstThunk)
                     : iat;
        for (i = 0; names[i]; i++) {
            char *fname;
            if (names[i] & IMAGE_ORDINAL_FLAG64) continue;
            fname = (char *)((BYTE *)base + (DWORD)(names[i] & 0x7fffffff)) + 2;
            if (g_origQsi && strcmp(fname, "NtQuerySystemInformation") == 0) {
                if (iat[i] != (ULONGLONG)HookQsi) {
                    VirtualProtect(&iat[i], sizeof(ULONGLONG), PAGE_READWRITE, &oldprot);
                    iat[i] = (ULONGLONG)HookQsi;
                    VirtualProtect(&iat[i], sizeof(ULONGLONG), oldprot, &oldprot);
                    n1++;
                }
            } else if (g_origQsiEx && strcmp(fname, "NtQuerySystemInformationEx") == 0) {
                if (iat[i] != (ULONGLONG)HookQsiEx) {
                    VirtualProtect(&iat[i], sizeof(ULONGLONG), PAGE_READWRITE, &oldprot);
                    iat[i] = (ULONGLONG)HookQsiEx;
                    VirtualProtect(&iat[i], sizeof(ULONGLONG), oldprot, &oldprot);
                    n2++;
                }
            }
        }
    }
    if (n1 || n2) {
        /* NOTE: no logging here - PatchModule also runs from a loader
           notification callback, i.e. under the loader lock, where fopen()
           (and anything that might load a DLL) is risky. */
    }
}

/* PEB pointer from the TEB (gs:0x60 on x64) - avoids TEB struct headers. */
static BYTE *GetPEB(void)
{
    BYTE *peb;
    __asm__ __volatile__("movq %%gs:0x60, %0" : "=r"(peb));
    return peb;
}

static void PatchAllModules(void)
{
    /* Walk the loader's module list via the PEB (loader-lock safe).
       PEB->Ldr at 0x18; PEB_LDR_DATA.InLoadOrderModuleList at 0x10;
       LDR_DATA_TABLE_ENTRY: InLoadOrderLinks at 0, DllBase at 0x30. */
    BYTE *peb = GetPEB();
    LIST_ENTRY *ldr = *(LIST_ENTRY **)(peb + 0x18);
    LIST_ENTRY *head = (LIST_ENTRY *)((BYTE *)ldr + 0x10);
    LIST_ENTRY *cur;
    for (cur = head->Flink; cur != head; cur = cur->Flink)
        PatchModule(*(PVOID *)((BYTE *)cur + 0x30));
}

/* Patch a module the moment it loads (cimwin32 loads lazily inside WmiPrvSE,
   and it caches SMBIOS data at init - so we must beat its first query). */
typedef struct { USHORT Length, MaximumLength; PWSTR Buffer; } MY_US;
typedef struct { ULONG Flags; MY_US FullDllName; MY_US BaseDllName; PVOID DllBase; ULONG SizeOfImage; } MY_LDR_NOTIFY;

static void PatchModule(PVOID base);

static VOID CALLBACK DllLoadNotify(ULONG reason, MY_LDR_NOTIFY *data, PVOID ctx)
{
    (void)ctx;
    if (reason == 1 && data && data->DllBase)
        PatchModule((PVOID)data->DllBase);
}

static void RegisterDllNotify(void)
{
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    FARPROC p;
    if (!ntdll) return;
    p = GetProcAddress(ntdll, "LdrRegisterDllNotification");
    if (p) {
        PVOID cookie = NULL;
        typedef LONG (NTAPI *reg_t)(ULONG, PVOID, PVOID, PVOID *);
        ((reg_t)p)(0, (PVOID)DllLoadNotify, NULL, &cookie);
    }
}

/* Inline hook of the ntdll NtQuerySystemInformation(/Ex) entry points. IAT
   patching is too late for cimwin32 (it reads SMBIOS in its DllMain, before
   our loader notification patches its imports), so patch the function itself;
   then every caller in the process is covered no matter when it runs.

   Stub shape expected (x64): 4C 8B D1 (mov r10,rcx) B8 imm32 (mov eax,..)
   then a test/jne/syscall. We steal 16 bytes (ends on an instruction boundary)
   into an executable trampoline and write a 12-byte absolute jmp. */

static BYTE *InstallInline(PVOID target, PVOID hook)
{
    BYTE *t;
    BYTE *fn = (BYTE *)target;
    DWORD old;
    const int steal = 16;
    if (!fn) return NULL;
    t = (BYTE *)VirtualAlloc(NULL, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!t) return NULL;
    memcpy(t, fn, steal);                       /* stolen prologue */
    t[steal] = 0x48; t[steal + 1] = 0xB8;       /* mov rax, fn+16 */
    *(PVOID *)(t + steal + 2) = fn + steal;
    t[steal + 10] = 0xFF; t[steal + 11] = 0xE0; /* jmp rax */
    if (!VirtualProtect(fn, steal, PAGE_EXECUTE_READWRITE, &old)) {
        VirtualFree(t, 0, MEM_RELEASE);
        return NULL;
    }
    fn[0] = 0x48; fn[1] = 0xB8;                 /* mov rax, hook */
    *(PVOID *)(fn + 2) = hook;
    fn[10] = 0xFF; fn[11] = 0xE0;               /* jmp rax */
    VirtualProtect(fn, steal, old, &old);
    return t;                                   /* trampoline = new "original" */
}

static void InstallInlineHooks(void)
{
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    PVOID t;
    if (!ntdll) return;
    if (g_origQsi) {
        t = InstallInline((PVOID)g_origQsi, (PVOID)HookQsi);
        if (t) { g_origQsi = (NtQsi_t)t; DllLog("inline hook installed: NtQuerySystemInformation"); }
        else DllLog("inline hook FAILED: NtQuerySystemInformation");
    }
    if (g_origQsiEx) {
        t = InstallInline((PVOID)g_origQsiEx, (PVOID)HookQsiEx);
        if (t) { g_origQsiEx = (NtQsiEx_t)t; DllLog("inline hook installed: NtQuerySystemInformationEx"); }
    }
}

static DWORD WINAPI PollThread(LPVOID arg)
{
    (void)arg;
    for (;;) { PatchAllModules(); Sleep(250); }
    return 0;
}

/* ------------------------------------------------------------ config/DllMain */

static void rstrip(char *s)
{
    int i = (int)strlen(s);
    while (i > 0 && (s[i-1] == '\n' || s[i-1] == '\r' || s[i-1] == ' ' || s[i-1] == '\t'))
        s[--i] = 0;
}

static void LoadConfig(void)
{
    char path[MAX_PATH], line[512], *arrow, *val;
    FILE *f;
    if (!GetModuleFileNameA(g_self, path, MAX_PATH)) return;
    {
        int i = (int)strlen(path) - 1;
        while (i >= 0 && path[i] != '\\') i--;
        path[i >= 0 ? i + 1 : 0] = 0;
    }
    strcat(path, "smbspoof.txt");
    f = fopen(path, "r");
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        int ol, vl, k;
        if (line[0] == '#') continue;
        arrow = strstr(line, "=>");
        if (!arrow) continue;
        *arrow = 0;
        val = arrow + 2;
        rstrip(line);
        rstrip(val);
        ol = (int)strlen(line);
        vl = (int)strlen(val);
        if (ol <= 0 || ol >= MAX_STR || g_npairs >= MAX_PAIRS) continue;
        memcpy(g_pairs[g_npairs].old, line, (SIZE_T)ol + 1);
        memcpy(g_pairs[g_npairs].new, val, (SIZE_T)(vl > ol ? ol : vl));
        for (k = vl; k < ol; k++) g_pairs[g_npairs].new[k] = ' ';   /* pad - never NUL inside */
        g_pairs[g_npairs].new[ol] = 0;
        g_pairs[g_npairs].len = ol;
        g_npairs++;
    }
    fclose(f);
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    HMODULE ntdll;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = (HMODULE)hinst;
        DisableThreadLibraryCalls(hinst);
        ntdll = GetModuleHandleA("ntdll.dll");
        if (!ntdll) return TRUE;
        g_origQsi   = (NtQsi_t)GetProcAddress(ntdll, "NtQuerySystemInformation");
        g_origQsiEx = (NtQsiEx_t)GetProcAddress(ntdll, "NtQuerySystemInformationEx");
        LoadConfig();
        /* InstallInlineHooks();  <-- disabled for the isolation test */
        PatchAllModules();
        RegisterDllNotify();
        DllLog("DLL loaded into pid=%lu, pairs=%d, cimwin32alreadyloaded=%s",
               (unsigned long)GetCurrentProcessId(), g_npairs,
               GetModuleHandleA("cimwin32.dll") ? "yes" : "no");
        CreateThread(NULL, 0, PollThread, NULL, 0, NULL);
    }
    return TRUE;
}
