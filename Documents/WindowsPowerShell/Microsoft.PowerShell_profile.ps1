# ===================================================
# === Utils and some global environment variables ===
# ===================================================
Set-PSReadLineOption -EditMode Emacs
Set-PSReadLineOption -BellStyle None


# ============
# === PATH ===
# ============

# ===
# === In sequences, last in first out.
# ===
$vocal = "$HOME\.vocal"
if (-not (Test-Path $vocal)) {
    New-Item -ItemType Directory -Path $vocal | Out-Null
}
Get-ChildItem -Path $vocal -Directory | ForEach-Object {
    $vocalbin = Join-Path $_.FullName "bin"
    if (Test-Path $vocalbin) {
        if (-not ($env:PATH -split ";" -contains $vocalbin)) {
            $env:PATH = "$vocalbin;$env:PATH"
        }
    }
}
if (-not ($env:PATH -split ";" -contains $vocal)) {
    $env:PATH = "$vocal;$env:PATH"
}
$vocalunderscore = "$vocal\_"
if (-not ($env:PATH -split ";" -contains $vocalunderscore)) {
    $env:PATH = "$vocalunderscore;$env:PATH"
}

# ===
# === Other special cases
# ===
if (Get-Command go -ErrorAction SilentlyContinue) {
    $env:GOPATH = Join-Path (Split-Path (Split-Path (Get-Command go).Source -Parent) -Parent) "gopath"
    $tmp = Join-Path $env:GOPATH "bin"
    if ((Test-Path $tmp) -and (-not ($env:PATH -split ";" -contains $tmp))) {
        $env:PATH = "$tmp;$env:PATH"
    }
}


# ==============
# === Others ===
# ==============

# ===
# === Environment variables
# ===
$env:STARSHIP_CONFIG = "$HOME\.dotfiles\.config\starship.toml"
$env:EDITOR = "nvim"
$env:GOPROXY = "https://goproxy.cn"
$env:RUSTUP_DIST_SERVER="https://rsproxy.cn"
$env:RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
$env:YAZI_FILE_ONE="C:\Program Files\Git\usr\bin\file.exe"

# ===
# === Aliases
# ===
# Ref: https://github.com/gokcehan/lf/blob/master/etc/lf.ps1
# Change working dir in powershell to last dir in lf on exit.
#
# You need to put this file to a folder in $env:PATH variable.
#
# You may also like to assign a key to this command:
#
#     Set-PSReadLineKeyHandler -Chord Ctrl+o -ScriptBlock {
#         [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
#         [Microsoft.PowerShell.PSConsoleReadLine]::Insert('lfcd.ps1')
#         [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
#     }
#
# You may put this in one of the profiles found in $PROFILE.
# NOTE: Disable lf, instead, use yazi.
# function lf {
#     $tmp = [System.IO.Path]::GetTempFileName()
#     & "C:\ProgramData\chocolatey\bin\lf.exe" -last-dir-path="$tmp" $args
#     if (Test-Path -PathType Leaf "$tmp") {
#         $dir = Get-Content "$tmp"
#         Remove-Item -Force "$tmp"
#         if (Test-Path -PathType Container "$dir") {
#             if ("$dir" -ne "$pwd") {
#                 cd "$dir"
#             }
#         }
#     }
# }
function lf {
    $tmp = [System.IO.Path]::GetTempFileName()
    yazi $args --cwd-file="$tmp"
    $cwd = Get-Content -Path $tmp -Encoding UTF8
    if (-not [String]::IsNullOrEmpty($cwd) -and $cwd -ne $PWD.Path) {
        Set-Location -LiteralPath ([System.IO.Path]::GetFullPath($cwd))
    }
    Remove-Item -Path $tmp
}
function myexit {
    Invoke-command -ScriptBlock {exit}
}
Set-Alias :q myexit
Set-Alias :qa myexit
function ssh-copy-id {
    param(
        [string]$command
    )
	Invoke-Expression "cat ~/.ssh/id_rsa.pub | ssh $command 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'"
}
function aim {
    nvim -u ~/.vimrc $args
}
function nim {
    nvim -u NONE $args
}
Set-Alias lg lazygit
Set-Alias py python

# ===
# === Outside sources
# ===
if (Get-Command starship -ErrorAction Ignore) {
    Invoke-Expression (&starship init powershell)
}

if (Get-Command atuin -ErrorAction Ignore) {
    atuin init powershell | Out-String | Invoke-Expression
}


# ==================
# === Post loads ===
# ==================
$localpwshrc = "$HOME\.pwshrc.localhost.ps1"
if (Test-Path $localpwshrc) { . $localpwshrc }
