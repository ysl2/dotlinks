$ErrorActionPreference = 'Stop'

$stateVersion = 2
$badgeSlotSize = 30
$canvasWidth = $badgeSlotSize
$canvasHeight = $badgeSlotSize
$iconSize = 16
$weixinPath = 'C:\Program Files\Tencent\Weixin\Weixin.exe'
$cacheDirectory = Join-Path $env:TEMP 'yasb-weixin-unread'
$statePath = Join-Path $cacheDirectory 'state.json'
$iconPath = Join-Path $cacheDirectory 'weixin-color.png'
[void][System.IO.Directory]::CreateDirectory($cacheDirectory)

Add-Type -AssemblyName System.Drawing

function Initialize-NativeMethods {
    if ('WeixinUnread.NativeMethods' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WeixinUnread
{
    public static class NativeMethods
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

        public static IntPtr[] GetTopLevelWindows(int processId)
        {
            var windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                uint ownerProcessId;
                GetWindowThreadProcessId(hWnd, out ownerProcessId);
                if (ownerProcessId == (uint)processId)
                {
                    windows.Add(hWnd);
                }
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }
    }
}
'@
}

function Get-WeixinMainProcess {
    $candidate = $null

    try {
        $candidate = Get-CimInstance Win32_Process -Filter "Name = 'Weixin.exe'" -ErrorAction Stop |
            Where-Object {
                $_.ExecutablePath -eq $weixinPath -and
                $_.CommandLine -notmatch '(?i)(?:^|\s)--type='
            } |
            Sort-Object CreationDate |
            Select-Object -First 1
    }
    catch {
        $candidate = $null
    }

    if ($candidate) {
        $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
    }
    else {
        $process = Get-Process Weixin -ErrorAction SilentlyContinue |
            Where-Object {
                try { $_.Path -eq $weixinPath }
                catch { $false }
            } |
            Sort-Object StartTime |
            Select-Object -First 1
    }

    if (-not $process) {
        return $null
    }

    try {
        $startTicks = $process.StartTime.ToUniversalTime().Ticks
    }
    catch {
        $startTicks = 0
    }

    return [pscustomobject]@{
        Process = $process
        Signature = "{0}:{1}" -f $process.Id, $startTicks
    }
}

function Get-WeixinWindow {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    $Process.Refresh()
    $handles = New-Object 'System.Collections.Generic.List[System.IntPtr]'
    if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
        [void]$handles.Add($Process.MainWindowHandle)
    }
    foreach ($handle in [WeixinUnread.NativeMethods]::GetTopLevelWindows($Process.Id)) {
        if (-not $handles.Contains($handle)) {
            [void]$handles.Add($handle)
        }
    }

    $fallback = $null
    foreach ($handle in $handles) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            if (-not $root) {
                continue
            }

            $window = [pscustomobject]@{
                Handle = $handle
                Root = $root
            }
            if ($root.Current.ClassName -eq 'mmui::MainWindow') {
                return $window
            }
            if (-not $fallback -and $handle -eq $Process.MainWindowHandle) {
                $fallback = $window
            }
        }
        catch {
            continue
        }
    }

    return $fallback
}

function Read-WidgetState {
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$state.Version -ne $stateVersion) {
            return $null
        }
        return $state
    }
    catch {
        return $null
    }
}

function Save-WidgetState {
    param(
        [Parameter(Mandatory)]
        $State
    )

    $temporaryStatePath = "$statePath.tmp"
    $json = $State | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText(
        $temporaryStatePath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporaryStatePath -Destination $statePath -Force
}

function Save-BitmapAtomic {
    param(
        [Parameter(Mandatory)]
        [System.Drawing.Bitmap]$Bitmap,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $temporaryPath = "$Path.tmp.png"
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
    $Bitmap.Save($temporaryPath, [System.Drawing.Imaging.ImageFormat]::Png)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Write-ImageMarkup {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $imageUri = $Path.Replace('\', '/')
    Write-Output "<img src=`"file:///$imageUri`" width=`"$badgeSlotSize`" height=`"$badgeSlotSize`">"
}

function Ensure-WeixinIcon {
    if (Test-Path -LiteralPath $iconPath) {
        return
    }
    if (-not (Test-Path -LiteralPath $weixinPath)) {
        throw 'Weixin.exe was not found.'
    }

    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($weixinPath)
    if (-not $icon) {
        throw 'The Weixin icon could not be extracted.'
    }

    $bitmap = $null
    try {
        $bitmap = $icon.ToBitmap()
        Save-BitmapAtomic -Bitmap $bitmap -Path $iconPath
    }
    finally {
        if ($bitmap) {
            $bitmap.Dispose()
        }
        $icon.Dispose()
    }
}

function Draw-WeixinIcon {
    param(
        [Parameter(Mandatory)]
        [System.Drawing.Bitmap]$Canvas
    )

    Ensure-WeixinIcon
    $iconBitmap = [System.Drawing.Bitmap]::FromFile($iconPath)
    $graphics = [System.Drawing.Graphics]::FromImage($Canvas)
    try {
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $offset = [int](($badgeSlotSize - $iconSize) / 2)
        $graphics.DrawImage(
            $iconBitmap,
            (New-Object System.Drawing.Rectangle($offset, $offset, $iconSize, $iconSize)),
            0,
            0,
            $iconBitmap.Width,
            $iconBitmap.Height,
            [System.Drawing.GraphicsUnit]::Pixel
        )
    }
    finally {
        $graphics.Dispose()
        $iconBitmap.Dispose()
    }
}

function New-HiddenState {
    param(
        [string]$Signature,
        [int]$LoginMissingCount,
        [string]$LastError
    )

    return [ordered]@{
        Version = $stateVersion
        Signature = $Signature
        LoggedIn = $false
        LoginMissingCount = $LoginMissingCount
        Visible = $false
        Visual = ''
        OutputPath = ''
        BadgeAnchorRight = $null
        BadgeCenterY = $null
        WindowWidth = 0
        WindowHeight = 0
        LastError = $LastError
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\YasbWeixinRenderV2')
$lockTaken = $false

try {
    try {
        $lockTaken = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $lockTaken = $true
    }

    if (-not $lockTaken) {
        $cachedState = Read-WidgetState
        if (
            $cachedState -and
            $cachedState.Visible -and
            (Test-Path -LiteralPath ([string]$cachedState.OutputPath))
        ) {
            Write-ImageMarkup -Path ([string]$cachedState.OutputPath)
        }
        return
    }

    $state = Read-WidgetState
    $instance = Get-WeixinMainProcess
    if (-not $instance) {
        Save-WidgetState -State (New-HiddenState -Signature '' -LoginMissingCount 0 -LastError '')
        return
    }

    $sameInstance = $state -and ([string]$state.Signature -eq $instance.Signature)
    if (-not $sameInstance) {
        $state = $null
    }

    Initialize-NativeMethods
    Add-Type -AssemblyName UIAutomationClient

    # PER_MONITOR_AWARE_V2 keeps UI Automation and GetWindowRect in the same
    # coordinate space when Windows display scaling is enabled.
    try {
        [void][WeixinUnread.NativeMethods]::SetProcessDpiAwarenessContext([IntPtr](-4))
    }
    catch {
        # The process may already have selected a DPI awareness context.
    }

    $signature = $instance.Signature
    $previousLoggedIn = $state -and [bool]$state.LoggedIn
    $previousVisible = $state -and [bool]$state.Visible
    $previousOutputPath = if ($state) { [string]$state.OutputPath } else { '' }
    $previousVisual = if ($state) { [string]$state.Visual } else { '' }
    $loginMissingCount = if ($state) { [int]$state.LoginMissingCount } else { 0 }
    $badgeAnchorRight = if ($state -and $null -ne $state.BadgeAnchorRight) {
        [double]$state.BadgeAnchorRight
    }
    else {
        $null
    }
    $badgeCenterY = if ($state -and $null -ne $state.BadgeCenterY) {
        [double]$state.BadgeCenterY
    }
    else {
        $null
    }
    $stateWindowWidth = if ($state) { [int]$state.WindowWidth } else { 0 }
    $stateWindowHeight = if ($state) { [int]$state.WindowHeight } else { 0 }
    $lastError = ''
    $badgeRect = $null
    $usingFallbackRect = $false
    $loggedIn = $false
    $window = Get-WeixinWindow -Process $instance.Process

    if ($window) {
        try {
            $root = $window.Root
            $allDescendants = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            )
            $mainTabCondition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ClassNameProperty,
                'mmui::MainTabBar'
            )
            $mainTabBar = $root.FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                $mainTabCondition
            )

            if ($mainTabBar) {
                $loggedIn = $true
                $loginMissingCount = 0
                $badgeCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
                    'mmui::XBadge'
                )
                $badges = $root.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    $badgeCondition
                )
                $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
                $targetBadge = $null

                foreach ($badge in $badges) {
                    $parent = $walker.GetParent($badge)
                    if ($parent -and $parent.Current.Name -in @('Weixin', '微信')) {
                        $targetBadge = $badge
                        break
                    }
                }

                if ($targetBadge) {
                    $candidateRect = $targetBadge.Current.BoundingRectangle
                    if ($candidateRect.Width -ge 2 -and $candidateRect.Height -ge 2) {
                        $badgeRect = $candidateRect
                        $anchorWindowRect = New-Object WeixinUnread.NativeMethods+RECT
                        if ([WeixinUnread.NativeMethods]::GetWindowRect(
                            $window.Handle,
                            [ref]$anchorWindowRect
                        )) {
                            $stateWindowWidth = $anchorWindowRect.Right - $anchorWindowRect.Left
                            $stateWindowHeight = $anchorWindowRect.Bottom - $anchorWindowRect.Top
                            $badgeAnchorRight = (
                                $candidateRect.Left + $candidateRect.Width -
                                $anchorWindowRect.Left
                            )
                            $badgeCenterY = (
                                $candidateRect.Top + ($candidateRect.Height / 2.0) -
                                $anchorWindowRect.Top
                            )
                        }
                    }
                }
            }
            elseif ($allDescendants.Count -gt 0) {
                $loginMissingCount++
                if ($previousLoggedIn -and $loginMissingCount -lt 2) {
                    Save-WidgetState -State ([ordered]@{
                        Version = $stateVersion
                        Signature = $signature
                        LoggedIn = $true
                        LoginMissingCount = $loginMissingCount
                        Visible = $previousVisible
                        Visual = $previousVisual
                        OutputPath = $previousOutputPath
                        BadgeAnchorRight = $badgeAnchorRight
                        BadgeCenterY = $badgeCenterY
                        WindowWidth = $stateWindowWidth
                        WindowHeight = $stateWindowHeight
                        LastError = 'MainTabBar was missing from a non-empty UIA tree.'
                        UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
                    })
                    if ($previousVisible -and (Test-Path -LiteralPath $previousOutputPath)) {
                        Write-ImageMarkup -Path $previousOutputPath
                    }
                    return
                }

                Save-WidgetState -State (
                    New-HiddenState `
                        -Signature $signature `
                        -LoginMissingCount $loginMissingCount `
                        -LastError 'MainTabBar was missing from a non-empty UIA tree.'
                )
                return
            }
            else {
                $lastError = 'The Weixin UIA tree was empty.'
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }
    else {
        $lastError = 'No Weixin main window was found.'
    }

    if (-not $loggedIn) {
        if (-not $previousLoggedIn) {
            Save-WidgetState -State (
                New-HiddenState -Signature $signature -LoginMissingCount 0 -LastError $lastError
            )
            return
        }

        $loggedIn = $true
        if ($window -and $null -ne $badgeAnchorRight -and $null -ne $badgeCenterY) {
            $fallbackWindowRect = New-Object WeixinUnread.NativeMethods+RECT
            if ([WeixinUnread.NativeMethods]::GetWindowRect(
                $window.Handle,
                [ref]$fallbackWindowRect
            )) {
                $fallbackWindowWidth = $fallbackWindowRect.Right - $fallbackWindowRect.Left
                $fallbackWindowHeight = $fallbackWindowRect.Bottom - $fallbackWindowRect.Top
                if (
                    $fallbackWindowWidth -eq $stateWindowWidth -and
                    $fallbackWindowHeight -eq $stateWindowHeight
                ) {
                    $fallbackRight = $fallbackWindowRect.Left + $badgeAnchorRight
                    $fallbackTop = $fallbackWindowRect.Top + $badgeCenterY - 16
                    $badgeRect = [pscustomobject]@{
                        Left = $fallbackRight - 40
                        Top = $fallbackTop
                        Width = 40
                        Height = 32
                    }
                    $usingFallbackRect = $true
                }
            }
        }

        if (-not $badgeRect -and $previousVisible -and (Test-Path -LiteralPath $previousOutputPath)) {
            Save-WidgetState -State ([ordered]@{
                Version = $stateVersion
                Signature = $signature
                LoggedIn = $true
                LoginMissingCount = $loginMissingCount
                Visible = $true
                Visual = $previousVisual
                OutputPath = $previousOutputPath
                BadgeAnchorRight = $badgeAnchorRight
                BadgeCenterY = $badgeCenterY
                WindowWidth = $stateWindowWidth
                WindowHeight = $stateWindowHeight
                LastError = $lastError
                UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            })
            Write-ImageMarkup -Path $previousOutputPath
            return
        }
    }

    $windowHandle = if ($window) { $window.Handle } else { [IntPtr]::Zero }
    $canvas = New-Object System.Drawing.Bitmap(
        $canvasWidth,
        $canvasHeight,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $windowBitmap = $null
    $windowGraphics = $null
    $badgeBitmap = $null
    $scaledBadgeBitmap = $null
    $captureSucceeded = $false
    $hasNumericBadge = $false

    if ($badgeRect -and $windowHandle -ne [IntPtr]::Zero) {
        try {

    $windowRect = New-Object WeixinUnread.NativeMethods+RECT
    if (-not [WeixinUnread.NativeMethods]::GetWindowRect($windowHandle, [ref]$windowRect)) {
        throw 'GetWindowRect failed.'
    }

    $windowWidth = $windowRect.Right - $windowRect.Left
    $windowHeight = $windowRect.Bottom - $windowRect.Top
    if ($windowWidth -le 0 -or $windowHeight -le 0) {
        throw 'The Weixin window has invalid dimensions.'
    }

    $windowBitmap = New-Object System.Drawing.Bitmap(
        $windowWidth,
        $windowHeight,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $windowGraphics = [System.Drawing.Graphics]::FromImage($windowBitmap)
    $windowHdc = $windowGraphics.GetHdc()
    try {
        $captured = [WeixinUnread.NativeMethods]::PrintWindow(
            $windowHandle,
            $windowHdc,
            2
        )
    }
    finally {
        $windowGraphics.ReleaseHdc($windowHdc)
    }

    if (-not $captured) {
        throw 'PrintWindow failed.'
    }

    # UI Automation only provides the search area. Include a small border so
    # pixels outside the visible red badge remain connected to the crop edge.
    $capturePadding = if ($usingFallbackRect) { 0 } else { 2 }
    $badgeLeft = [int][Math]::Floor($badgeRect.Left - $windowRect.Left)
    $badgeTop = [int][Math]::Floor($badgeRect.Top - $windowRect.Top)
    $badgeRight = [int][Math]::Ceiling(
        $badgeRect.Left + $badgeRect.Width - $windowRect.Left
    )
    $badgeBottom = [int][Math]::Ceiling(
        $badgeRect.Top + $badgeRect.Height - $windowRect.Top
    )
    $sourceX = [Math]::Max(0, $badgeLeft - $capturePadding)
    $sourceY = [Math]::Max(0, $badgeTop - $capturePadding)
    $sourceRight = [Math]::Min($windowBitmap.Width, $badgeRight + $capturePadding)
    $sourceBottom = [Math]::Min($windowBitmap.Height, $badgeBottom + $capturePadding)
    $sourceWidth = $sourceRight - $sourceX
    $sourceHeight = $sourceBottom - $sourceY

    if ($sourceWidth -le 0 -or $sourceHeight -le 0) {
        throw 'The Weixin badge lies outside the captured window.'
    }

    $sourcePixelCount = $sourceWidth * $sourceHeight
    $redMask = New-Object 'System.Boolean[]' $sourcePixelCount

    for ($y = 0; $y -lt $sourceHeight; $y++) {
        for ($x = 0; $x -lt $sourceWidth; $x++) {
            $color = $windowBitmap.GetPixel($sourceX + $x, $sourceY + $y)
            $isRed = (
                $color.R -ge 140 -and
                $color.R -ge ($color.G + 35) -and
                $color.R -ge ($color.B + 25)
            )

            if ($isRed) {
                $redMask[($y * $sourceWidth) + $x] = $true
            }
        }
    }

    # Keep only the largest connected red component in the search area. This
    # is the badge background; small unrelated red pixels are ignored.
    $componentVisited = New-Object 'System.Boolean[]' $sourcePixelCount
    $queue = New-Object 'System.Int32[]' $sourcePixelCount
    $largestComponent = @()

    for ($startIndex = 0; $startIndex -lt $sourcePixelCount; $startIndex++) {
        if (-not $redMask[$startIndex] -or $componentVisited[$startIndex]) {
            continue
        }

        $component = @()
        $queueHead = 0
        $queueTail = 0
        $queue[$queueTail] = $startIndex
        $queueTail++
        $componentVisited[$startIndex] = $true

        while ($queueHead -lt $queueTail) {
            $currentIndex = $queue[$queueHead]
            $queueHead++
            $component += $currentIndex
            $currentX = $currentIndex % $sourceWidth
            $currentY = [int][Math]::Floor($currentIndex / $sourceWidth)

            for ($offsetY = -1; $offsetY -le 1; $offsetY++) {
                for ($offsetX = -1; $offsetX -le 1; $offsetX++) {
                    if ($offsetX -eq 0 -and $offsetY -eq 0) {
                        continue
                    }

                    $neighborX = $currentX + $offsetX
                    $neighborY = $currentY + $offsetY
                    if (
                        $neighborX -lt 0 -or $neighborX -ge $sourceWidth -or
                        $neighborY -lt 0 -or $neighborY -ge $sourceHeight
                    ) {
                        continue
                    }

                    $neighborIndex = ($neighborY * $sourceWidth) + $neighborX
                    if ($redMask[$neighborIndex] -and -not $componentVisited[$neighborIndex]) {
                        $componentVisited[$neighborIndex] = $true
                        $queue[$queueTail] = $neighborIndex
                        $queueTail++
                    }
                }
            }
        }

        if ($component.Count -gt $largestComponent.Count) {
            $largestComponent = $component
        }
    }

    if ($largestComponent.Count -ge 10) {
        $badgeRedMask = New-Object 'System.Boolean[]' $sourcePixelCount
        $minimumX = $sourceWidth
        $minimumY = $sourceHeight
        $maximumX = -1
        $maximumY = -1

        foreach ($index in $largestComponent) {
            $badgeRedMask[$index] = $true
            $redX = $index % $sourceWidth
            $redY = [int][Math]::Floor($index / $sourceWidth)
            $minimumX = [Math]::Min($minimumX, $redX)
            $minimumY = [Math]::Min($minimumY, $redY)
            $maximumX = [Math]::Max($maximumX, $redX)
            $maximumY = [Math]::Max($maximumY, $redY)
        }

        $badgeWidth = $maximumX - $minimumX + 1
        $badgeHeight = $maximumY - $minimumY + 1
        $badgePixelCount = $badgeWidth * $badgeHeight
        $outsideMask = New-Object 'System.Boolean[]' $badgePixelCount
        $outsideQueue = New-Object 'System.Int32[]' $badgePixelCount
        $outsideQueueHead = 0
        $outsideQueueTail = 0

        # Non-red pixels reachable from the bounding rectangle edge are outside
        # the badge. White glyph pixels are enclosed by red and remain opaque.
        for ($edgeY = 0; $edgeY -lt $badgeHeight; $edgeY++) {
            for ($edgeX = 0; $edgeX -lt $badgeWidth; $edgeX++) {
                if (
                    $edgeX -ne 0 -and $edgeX -ne ($badgeWidth - 1) -and
                    $edgeY -ne 0 -and $edgeY -ne ($badgeHeight - 1)
                ) {
                    continue
                }

                $sourceIndex = (($minimumY + $edgeY) * $sourceWidth) + $minimumX + $edgeX
                $edgeIndex = ($edgeY * $badgeWidth) + $edgeX
                if (-not $badgeRedMask[$sourceIndex] -and -not $outsideMask[$edgeIndex]) {
                    $outsideMask[$edgeIndex] = $true
                    $outsideQueue[$outsideQueueTail] = $edgeIndex
                    $outsideQueueTail++
                }
            }
        }

        while ($outsideQueueHead -lt $outsideQueueTail) {
            $currentIndex = $outsideQueue[$outsideQueueHead]
            $outsideQueueHead++
            $currentX = $currentIndex % $badgeWidth
            $currentY = [int][Math]::Floor($currentIndex / $badgeWidth)

            for ($offsetY = -1; $offsetY -le 1; $offsetY++) {
                for ($offsetX = -1; $offsetX -le 1; $offsetX++) {
                    if ($offsetX -eq 0 -and $offsetY -eq 0) {
                        continue
                    }

                    $neighborX = $currentX + $offsetX
                    $neighborY = $currentY + $offsetY
                    if (
                        $neighborX -lt 0 -or $neighborX -ge $badgeWidth -or
                        $neighborY -lt 0 -or $neighborY -ge $badgeHeight
                    ) {
                        continue
                    }

                    $neighborIndex = ($neighborY * $badgeWidth) + $neighborX
                    $sourceIndex = (
                        (($minimumY + $neighborY) * $sourceWidth) +
                        $minimumX +
                        $neighborX
                    )
                    if (-not $badgeRedMask[$sourceIndex] -and -not $outsideMask[$neighborIndex]) {
                        $outsideMask[$neighborIndex] = $true
                        $outsideQueue[$outsideQueueTail] = $neighborIndex
                        $outsideQueueTail++
                    }
                }
            }
        }

        $badgeBitmap = New-Object System.Drawing.Bitmap(
            $badgeWidth,
            $badgeHeight,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $whitePixelCount = 0

        for ($y = 0; $y -lt $badgeHeight; $y++) {
            for ($x = 0; $x -lt $badgeWidth; $x++) {
                $badgeIndex = ($y * $badgeWidth) + $x
                if ($outsideMask[$badgeIndex]) {
                    continue
                }

                $color = $windowBitmap.GetPixel(
                    $sourceX + $minimumX + $x,
                    $sourceY + $minimumY + $y
                )
                $badgeBitmap.SetPixel($x, $y, $color)
                $maximumChannel = [Math]::Max($color.R, [Math]::Max($color.G, $color.B))
                $minimumChannel = [Math]::Min($color.R, [Math]::Min($color.G, $color.B))
                if (
                    $color.R -ge 190 -and
                    $color.G -ge 190 -and
                    $color.B -ge 190 -and
                    ($maximumChannel - $minimumChannel) -le 45
                ) {
                    $whitePixelCount++
                }
            }
        }

        # A dot-only badge has no enclosed white glyph and intentionally stays
        # as the fixed transparent placeholder.
        if ($whitePixelCount -ge 3) {
            $hasNumericBadge = $true
            # Treat the longer badge dimension as a logical square side. Keep
            # the natural size inside the 30x30 slot and only shrink overflow.
            $squareSide = [Math]::Max($badgeWidth, $badgeHeight)
            $scale = [Math]::Min(1.0, $badgeSlotSize / [double]$squareSide)
            $renderWidth = [Math]::Max(1, [int][Math]::Round($badgeWidth * $scale))
            $renderHeight = [Math]::Max(1, [int][Math]::Round($badgeHeight * $scale))
            $renderBitmap = $badgeBitmap

            if ($scale -lt 1.0) {
                $scaledBadgeBitmap = New-Object System.Drawing.Bitmap(
                    $renderWidth,
                    $renderHeight,
                    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
                )
                $scaleGraphics = [System.Drawing.Graphics]::FromImage($scaledBadgeBitmap)
                try {
                    $scaleGraphics.Clear([System.Drawing.Color]::Transparent)
                    $scaleGraphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                    $scaleGraphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $scaleGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $scaleGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $scaleGraphics.DrawImage(
                        $badgeBitmap,
                        (New-Object System.Drawing.Rectangle(0, 0, $renderWidth, $renderHeight)),
                        0,
                        0,
                        $badgeWidth,
                        $badgeHeight,
                        [System.Drawing.GraphicsUnit]::Pixel
                    )
                }
                finally {
                    $scaleGraphics.Dispose()
                }
                $renderBitmap = $scaledBadgeBitmap
            }

            # Pixel-index centers are used here: the 30px badge slot is centered
            # at 14.5. Fractional offsets distribute pixels between neighboring
            # rows or columns so odd and even badge sizes share that center.
            $targetCenterX = ($badgeSlotSize - 1) / 2.0
            $targetCenterY = ($badgeSlotSize - 1) / 2.0
            $sourceCenterX = ($renderWidth - 1) / 2.0
            $sourceCenterY = ($renderHeight - 1) / 2.0
            $offsetX = $targetCenterX - $sourceCenterX
            $offsetY = $targetCenterY - $sourceCenterY
            $canvasPixelCount = $canvasWidth * $canvasHeight
            $alphaAccumulator = New-Object 'System.Double[]' $canvasPixelCount
            $redAccumulator = New-Object 'System.Double[]' $canvasPixelCount
            $greenAccumulator = New-Object 'System.Double[]' $canvasPixelCount
            $blueAccumulator = New-Object 'System.Double[]' $canvasPixelCount

            for ($sourcePixelY = 0; $sourcePixelY -lt $renderHeight; $sourcePixelY++) {
                for ($sourcePixelX = 0; $sourcePixelX -lt $renderWidth; $sourcePixelX++) {
                    $sourceColor = $renderBitmap.GetPixel($sourcePixelX, $sourcePixelY)
                    if ($sourceColor.A -eq 0) {
                        continue
                    }

                    $targetX = $sourcePixelX + $offsetX
                    $targetY = $sourcePixelY + $offsetY
                    $baseX = [int][Math]::Floor($targetX)
                    $baseY = [int][Math]::Floor($targetY)
                    $fractionX = $targetX - $baseX
                    $fractionY = $targetY - $baseY
                    $sourceAlpha = $sourceColor.A / 255.0

                    for ($targetOffsetY = 0; $targetOffsetY -le 1; $targetOffsetY++) {
                        $outputY = $baseY + $targetOffsetY
                        if ($outputY -lt 0 -or $outputY -ge $canvasHeight) {
                            continue
                        }
                        $weightY = if ($targetOffsetY -eq 0) {
                            1.0 - $fractionY
                        }
                        else {
                            $fractionY
                        }
                        if ($weightY -le 0) {
                            continue
                        }

                        for ($targetOffsetX = 0; $targetOffsetX -le 1; $targetOffsetX++) {
                            $outputX = $baseX + $targetOffsetX
                            if ($outputX -lt 0 -or $outputX -ge $canvasWidth) {
                                continue
                            }
                            $weightX = if ($targetOffsetX -eq 0) {
                                1.0 - $fractionX
                            }
                            else {
                                $fractionX
                            }
                            $weight = $weightX * $weightY
                            if ($weight -le 0) {
                                continue
                            }

                            $outputIndex = ($outputY * $canvasWidth) + $outputX
                            $weightedAlpha = $sourceAlpha * $weight
                            $alphaAccumulator[$outputIndex] += $weightedAlpha
                            $redAccumulator[$outputIndex] += $sourceColor.R * $weightedAlpha
                            $greenAccumulator[$outputIndex] += $sourceColor.G * $weightedAlpha
                            $blueAccumulator[$outputIndex] += $sourceColor.B * $weightedAlpha
                        }
                    }
                }
            }

            for ($outputY = 0; $outputY -lt $canvasHeight; $outputY++) {
                for ($outputX = 0; $outputX -lt $canvasWidth; $outputX++) {
                    $outputIndex = ($outputY * $canvasWidth) + $outputX
                    $accumulatedAlpha = [Math]::Min(1.0, $alphaAccumulator[$outputIndex])
                    if ($accumulatedAlpha -le 0) {
                        continue
                    }

                    $outputAlpha = [int][Math]::Round(255 * $accumulatedAlpha)
                    $outputRed = [int][Math]::Round(
                        $redAccumulator[$outputIndex] / $alphaAccumulator[$outputIndex]
                    )
                    $outputGreen = [int][Math]::Round(
                        $greenAccumulator[$outputIndex] / $alphaAccumulator[$outputIndex]
                    )
                    $outputBlue = [int][Math]::Round(
                        $blueAccumulator[$outputIndex] / $alphaAccumulator[$outputIndex]
                    )
                    $canvas.SetPixel(
                        $outputX,
                        $outputY,
                        [System.Drawing.Color]::FromArgb(
                            $outputAlpha,
                            $outputRed,
                            $outputGreen,
                            $outputBlue
                        )
                    )
                }
            }
        }
    }
    $captureSucceeded = $true
}
catch {
    $lastError = $_.Exception.Message
}
finally {
    if ($scaledBadgeBitmap) {
        $scaledBadgeBitmap.Dispose()
    }
    if ($badgeBitmap) {
        $badgeBitmap.Dispose()
    }
    if ($windowGraphics) {
        $windowGraphics.Dispose()
    }
    if ($windowBitmap) {
        $windowBitmap.Dispose()
    }
}

    }
    else {
        $captureSucceeded = $true
    }

    if (
        -not $captureSucceeded -and
        $previousVisible -and
        (Test-Path -LiteralPath $previousOutputPath)
    ) {
        $canvas.Dispose()
        Save-WidgetState -State ([ordered]@{
            Version = $stateVersion
            Signature = $signature
            LoggedIn = $true
            LoginMissingCount = $loginMissingCount
            Visible = $true
            Visual = $previousVisual
            OutputPath = $previousOutputPath
            BadgeAnchorRight = $badgeAnchorRight
            BadgeCenterY = $badgeCenterY
            WindowWidth = $stateWindowWidth
            WindowHeight = $stateWindowHeight
            LastError = $lastError
            UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        })
        Write-ImageMarkup -Path $previousOutputPath
        return
    }

    if (-not $hasNumericBadge) {
        Draw-WeixinIcon -Canvas $canvas
    }

    $slot = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 2)
    $outputPath = Join-Path $cacheDirectory "weixin-$slot.png"

try {
    Save-BitmapAtomic -Bitmap $canvas -Path $outputPath
}
finally {
    $canvas.Dispose()
}

    $visual = if ($hasNumericBadge) { 'badge' } else { 'icon' }
    Save-WidgetState -State ([ordered]@{
        Version = $stateVersion
        Signature = $signature
        LoggedIn = $true
        LoginMissingCount = 0
        Visible = $true
        Visual = $visual
        OutputPath = $outputPath
        BadgeAnchorRight = $badgeAnchorRight
        BadgeCenterY = $badgeCenterY
        WindowWidth = $stateWindowWidth
        WindowHeight = $stateWindowHeight
        LastError = $lastError
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    })
    Write-ImageMarkup -Path $outputPath
}
finally {
    if ($lockTaken) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
