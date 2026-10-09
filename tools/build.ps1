$ErrorActionPreference = 'Stop'
$repoPath = Split-Path $PSScriptRoot -Parent
$utf8 = [System.Text.UTF8Encoding]::new($false)
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'installer.template.sh')).Replace("`r`n", "`n")
$payloads = ''
foreach ($name in @('xsub', 'xserver', 'xsub-guard')) {
    $script = [IO.File]::ReadAllText((Join-Path $repoPath "scripts/$name")).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $payloads += "base64 -d > /opt/sbin/$name <<'PAYLOAD_END'`n"
    for ($offset = 0; $offset -lt $encoded.Length; $offset += 76) {
        $payloads += $encoded.Substring($offset, [Math]::Min(76, $encoded.Length - $offset)) + "`n"
    }
    $payloads += "PAYLOAD_END`n"
}
if (-not $template.Contains('__PAYLOADS__')) { throw 'Missing template payload marker' }
$installer = $template.Replace('__PAYLOADS__', $payloads.TrimEnd("`n"))
[IO.File]::WriteAllText((Join-Path $repoPath 'install-xkeen-addons.sh'), $installer, $utf8)
Write-Output 'Built install-xkeen-addons.sh'
$fullTemplate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'full-installer.template.sh')).Replace("`r`n", "`n")
if (-not $fullTemplate.Contains('__ADDON_INSTALLER__')) { throw 'Missing full-installer payload marker' }
$encodedInstaller = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($installer))
$lines = for ($offset = 0; $offset -lt $encodedInstaller.Length; $offset += 76) {
    $encodedInstaller.Substring($offset, [Math]::Min(76, $encodedInstaller.Length - $offset))
}
$fullInstaller = $fullTemplate.Replace('__ADDON_INSTALLER__', ($lines -join "`n"))
[IO.File]::WriteAllText((Join-Path $repoPath 'install.sh'), $fullInstaller, $utf8)
Write-Output 'Built install.sh'
$tunTemplate = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mihomo-installer.template.sh')).Replace("`r`n", "`n")
if (-not $tunTemplate.Contains('__TUN_PAYLOADS__')) { throw 'Missing TUN payload marker' }
$tunPayloads = ''
foreach ($item in @(
    @{Name='mtun-lib.sh'; Target='/opt/lib/mtun-lib.sh'},
    @{Name='mtun'; Target='/opt/sbin/mtun'},
    @{Name='S80mihomo-tun'; Target='/opt/etc/init.d/S80mihomo-tun'}
)) {
    $source = [IO.File]::ReadAllText((Join-Path $repoPath "scripts/$($item.Name)")).Replace("`r`n", "`n")
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $tunPayloads += "base64 -d > $($item.Target) <<'TUN_PAYLOAD_END'`n"
    for ($offset = 0; $offset -lt $payload.Length; $offset += 76) {
        $tunPayloads += $payload.Substring($offset, [Math]::Min(76, $payload.Length-$offset)) + "`n"
    }
    $tunPayloads += "TUN_PAYLOAD_END`n"
}
[IO.File]::WriteAllText((Join-Path $repoPath 'install-mihomo-tun.sh'), $tunTemplate.Replace('__TUN_PAYLOADS__', $tunPayloads.TrimEnd("`n")), $utf8)
Write-Output 'Built install-mihomo-tun.sh'
