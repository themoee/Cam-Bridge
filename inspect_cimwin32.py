import pefile

targets = [
    r"C:\Windows\System32\kernelbase.dll",
    r"C:\Windows\System32\kernel32.dll",
]
keys = ("ntquerysystem", "firmware")

for path in targets:
    print(f"=== {path} ===")
    try:
        pe = pefile.PE(path, fast_load=True)
        pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT']])
        for entry in pe.DIRECTORY_ENTRY_IMPORT:
            dll = entry.dll.decode().lower()
            funcs = []
            for imp in entry.imports:
                if imp.name:
                    n = imp.name.decode()
                    if any(k in n.lower() for k in keys):
                        funcs.append(n)
            if funcs:
                print(f"  {dll}: {funcs}")
        pe.close()
    except Exception as e:
        print(f"  ERROR: {e}")
print("done")
