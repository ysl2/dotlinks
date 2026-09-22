$ErrorActionPreference = 'Stop'

$badgeSlotSize = 30
$canvasWidth = $badgeSlotSize
$canvasHeight = $badgeSlotSize
$cacheDirectory = Join-Path $env:TEMP 'yasb-weixin-unread'
[void][System.IO.Directory]::CreateDirectory($cacheDirectory)

$slot = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 2)
$outputPath = Join-Path $cacheDirectory "badge-$slot.png"
$temporaryPath = Join-Path $cacheDirectory "badge-$slot.tmp.png"

Add-Type -AssemblyName System.Drawing

$canvas = New-Object System.Drawing.Bitmap(
    $canvasWidth,
    $canvasHeight,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
)

$windowBitmap = $null
$windowGraphics = $null
$badgeBitmap = $null
$scaledBadgeBitmap = $null

try {
    Add-Type -AssemblyName UIAutomationClient

    if (-not ('WeixinUnread.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WeixinUnread
{
    public static class NativeMethods
    {
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
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
    }
}
'@
    }

    # PER_MONITOR_AWARE_V2 keeps UI Automation and GetWindowRect in the same
    # coordinate space when Windows display scaling is enabled.
    try {
        [void][WeixinUnread.NativeMethods]::SetProcessDpiAwarenessContext([IntPtr](-4))
    }
    catch {
        # The process may already have selected a DPI awareness context.
    }

    $process = Get-Process Weixin -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1

    if (-not $process) {
        throw 'No Weixin main window was found.'
    }

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
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

    if (-not $targetBadge) {
        throw 'The Weixin chat-tab badge was not found.'
    }

    $badgeRect = $targetBadge.Current.BoundingRectangle
    if ($badgeRect.Width -lt 2 -or $badgeRect.Height -lt 2) {
        throw 'The Weixin chat-tab badge is not visible.'
    }

    $windowRect = New-Object WeixinUnread.NativeMethods+RECT
    if (-not [WeixinUnread.NativeMethods]::GetWindowRect($process.MainWindowHandle, [ref]$windowRect)) {
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
            $process.MainWindowHandle,
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
    $capturePadding = 2
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
}
catch {
    # Keep the fixed transparent canvas on any detection or capture failure.
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

try {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
    $canvas.Save($temporaryPath, [System.Drawing.Imaging.ImageFormat]::Png)
    Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
}
finally {
    $canvas.Dispose()
}

$imageUri = $outputPath.Replace('\', '/')
Write-Output "<img src=`"file:///$imageUri`" width=`"$canvasWidth`" height=`"$canvasHeight`">"
